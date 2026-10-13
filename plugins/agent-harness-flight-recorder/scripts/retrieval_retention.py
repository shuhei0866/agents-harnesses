"""Conservative, local-only snapshot retention. Never evict referenced evidence."""
from __future__ import annotations

import json
from contextlib import closing
import os
from pathlib import Path
import re
import sqlite3
import stat
import time

import retrieval_lab as lab

HASH = re.compile(rb'(?<![0-9a-f])[0-9a-f]{64}(?![0-9a-f])')
TEXT_SUFFIXES = {'.json', '.jsonl', '.md', '.txt', '.py', '.log', '.diff', '.err'}
MAX_REFERENCE_BYTES = 256 * 1024 * 1024
MAX_REFERENCE_FILES = 10000


class RetentionError(ValueError):
    def __init__(self, code):
        self.code = code
        super().__init__(code)


def policy(value):
    if not isinstance(value, dict) or set(value) - {'budget_bytes', 'warning_percent', 'keep_recent'}:
        raise RetentionError('invalid_retention_policy')
    result = dict(budget_bytes=1024**3, warning_percent=80, keep_recent=3)
    result.update(value)
    lab.bounded_int(result['budget_bytes'], 1, 16 * 1024**3)
    lab.bounded_int(result['warning_percent'], 1, 99)
    lab.bounded_int(result['keep_recent'], 0, 100)
    return result


def _references(root):
    """Scan ALL DB columns plus local text artifacts, including historical cases.

    Hash scanning deliberately over-protects. It also preserves references in
    partially written JSON and fixtures using nonstandard field names. This is
    not a parser of user content and never executes artifact text.
    """
    found, consumed, count = set(), 0, 0

    def scan(raw):
        nonlocal consumed
        consumed += len(raw)
        if consumed > MAX_REFERENCE_BYTES:
            raise RetentionError('reference_scan_budget_exhausted')
        found.update(x.decode('ascii') for x in HASH.findall(raw))

    if not (root / 'measurements.sqlite').is_file():
        raise RetentionError('reference_database_unavailable')
    for directory, directories, files in os.walk(root, followlinks=False):
        base = Path(directory)
        for name in list(directories):
            path = base / name
            if path.is_symlink():
                raise RetentionError('unsafe_reference_path')
            if path == root / 'snapshots' or name == '__pycache__':
                directories.remove(name)
        for name in files:
            path = base / name
            if path == root / 'snapshot.json' or path == root / 'storage-state.json':
                continue
            count += 1
            if count > MAX_REFERENCE_FILES:
                raise RetentionError('reference_scan_budget_exhausted')
            if path.is_symlink():
                raise RetentionError('unsafe_reference_path')
            if path.suffix == '.sqlite':
                # A read transaction gives a consistent view of every table.
                with closing(sqlite3.connect(path.as_uri() + '?mode=ro', uri=True)) as db:
                    db.execute('BEGIN')
                    tables = list(db.execute("SELECT name FROM sqlite_master WHERE type='table'"))
                    if path == root / 'measurements.sqlite':
                        names = {t[0] for t in tables}
                        required = {r[0] for r in db.execute('SELECT DISTINCT snapshot_id FROM queries')}
                        for table in ('recall_opportunities', 'recall_followups'):
                            if table in names:
                                required.update(json.loads(r[0])['snapshot_id'] for r in db.execute('SELECT packet FROM ' + table))
                        for identity in required:
                            lab._snapshot(root, identity)
                    for (table,) in tables:
                        quoted = '"' + table.replace('"', '""') + '"'
                        for row in db.execute('SELECT * FROM ' + quoted):
                            for value in row:
                                if isinstance(value, str):
                                    scan(value.encode())
                                elif isinstance(value, bytes):
                                    scan(value)
            elif path.suffix in TEXT_SUFFIXES:
                scan(lab.safe_file(path, lab.MAX_SNAPSHOT_BYTES))
    return found


def _plan(root, config, reserve_bytes=0, extra_protected=()):
    config = policy(config)
    current = lab._snapshot(root)['snapshot_id']
    protected = _references(root) | {current} | set(extra_protected)
    archive = root / 'snapshots'
    entries = []
    if archive.exists() or archive.is_symlink():
        lab._root(archive)
        for path in archive.iterdir():
            # Temporary atomic-publication files are not deletion candidates.
            if path.name.startswith('.'):
                continue
            info = path.lstat()
            if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid()
                    or info.st_mode & 0o077 or not re.fullmatch('[0-9a-f]{64}\\.json', path.name)):
                raise RetentionError('unsafe_snapshot_archive')
            entries.append((path, info))
    total = sum(info.st_size for _, info in entries)
    pinned = sum(info.st_size for path, info in entries if path.stem in protected)
    candidates = sorted([(p, i) for p, i in entries if p.stem not in protected],
                        key=lambda pair: (pair[1].st_mtime_ns, pair[0].name), reverse=True)
    retained, remaining = [], pinned + reserve_bytes
    for index, (path, info) in enumerate(candidates):
        if index < config['keep_recent'] and remaining + info.st_size <= config['budget_bytes']:
            retained.append(path)
            remaining += info.st_size
    deleting = [(p, i) for p, i in candidates if p not in retained]
    blocked = pinned + reserve_bytes > config['budget_bytes']
    warning = ('protected_snapshots_exceed_budget' if blocked else
               'snapshot_capacity_high' if remaining * 100 >= config['budget_bytes'] * config['warning_percent'] else None)
    result = dict(schema_version=1, status='error' if blocked else 'ok', checked_at=time.time(),
                  archive_bytes=total, projected_bytes=remaining, reserved_bytes=reserve_bytes,
                  protected_bytes=pinned, protected_count=sum(p.stem in protected for p, _ in entries),
                  archive_count=len(entries), removable_count=len(deleting),
                  removable_bytes=sum(i.st_size for _, i in deleting), warning=warning,
                  usage_percent=round(remaining / config['budget_bytes'] * 100, 2), **config)
    return result, deleting


def read_status(root):
    return json.loads(lab.safe_file(Path(root) / 'storage-state.json', 1024 * 1024))


def inspect(root, config=None):
    root = lab._root(root)
    with lab.snapshot_lock(root):
        try:
            result, _ = _plan(root, config or {})
        except (OSError, sqlite3.Error, KeyError, TypeError) as exc:
            raise RetentionError('retention_reference_check_failed') from exc
        result['dry_run'] = True
        return result


def maintain(root, config=None, *, reserve_bytes=0, extra_protected=()):
    root = lab._root(root)
    with lab.snapshot_lock(root, exclusive=True):
        try:
            result, deleting = _plan(root, config or {}, reserve_bytes, extra_protected)
            if result['status'] == 'error':
                _save(root, result)
                raise RetentionError('protected_snapshots_exceed_budget')
            # Validate every deletion before deleting ANY file. Corruption or
            # unknown reference inputs abort cleanup, preserving all evidence.
            for path, info in deleting:
                lab._snapshot(root, path.stem)
                actual = path.lstat()
                if (actual.st_dev, actual.st_ino, actual.st_size, actual.st_mtime_ns, actual.st_mode) != (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_mode):
                    raise RetentionError('snapshot_changed_during_retention')
            for path, _ in deleting:
                path.unlink()
            if deleting:
                fd = os.open(root / 'snapshots', os.O_RDONLY)
                try:
                    os.fsync(fd)
                finally:
                    os.close(fd)
            result.update(deleted_count=len(deleting), freed_bytes=result['removable_bytes'],
                          archive_bytes=result['archive_bytes'] - result['removable_bytes'],
                          archive_count=result['archive_count'] - len(deleting))
            _save(root, result)
            return result
        except RetentionError as exc:
            if exc.code != 'protected_snapshots_exceed_budget':
                _save(root, dict(schema_version=1, status='error', warning=exc.code, checked_at=time.time()))
            raise
        except (OSError, ValueError, sqlite3.Error, TypeError, KeyError) as exc:
            _save(root, dict(schema_version=1, status='error', warning='retention_reference_check_failed', checked_at=time.time()))
            raise RetentionError('retention_reference_check_failed') from exc


def _save(root, value):
    # No paths, excerpts, or IDs: this diagnostic must not pin its own garbage.
    if value.get('deleted_count'):
        value['last_cleanup'] = dict(at=value['checked_at'], deleted_count=value['deleted_count'], freed_bytes=value['freed_bytes'])
    else:
        try:
            previous = read_status(root)
            if previous.get('last_cleanup'):
                value['last_cleanup'] = previous['last_cleanup']
        except FileNotFoundError:
            pass
    lab._atomic_snapshot_file(root / 'storage-state.json', lab.canonical(value).encode())


def pin(root, identity):
    root = lab._root(root)
    with lab.snapshot_lock(root, exclusive=True):
        lab._snapshot(root, identity)
        path = root / 'snapshot-pins.json'
        value = json.loads(lab.safe_file(path, 1024 * 1024)) if path.exists() else {'snapshot_ids': []}
        identities = value['snapshot_ids']
        if not isinstance(identities, list) or any(not isinstance(x, str) or not re.fullmatch('[0-9a-f]{64}', x) for x in identities):
            raise RetentionError('invalid_snapshot_pins')
        value['snapshot_ids'] = sorted(set(identities) | {identity})
        lab._atomic_snapshot_file(path, lab.canonical(value).encode())
        return dict(status='ok', snapshot_id=identity, pinned=True)
