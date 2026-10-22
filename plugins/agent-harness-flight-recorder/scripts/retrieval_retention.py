"""Conservative, local-only snapshot retention. Never evict referenced evidence."""
from __future__ import annotations

import json
import hashlib
from contextlib import closing
import os
from pathlib import Path
import re
import sqlite3
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
            if path in (root / 'snapshots', root / 'snapshot-objects') or name == '__pycache__':
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


def _plan(root, config, reserve_bytes=0, extra_protected=(), protected_objects=()):
    config = policy(config)
    current = lab._snapshot(root)['snapshot_id']
    protected = _references(root) | {current} | set(extra_protected)
    from retrieval_archive import entries as archive_entries, identity
    entries = archive_entries(root)
    groups = {}
    for path, info in entries:
        groups.setdefault(identity(path), []).append((path, info))
    from retrieval_shared import inventory, references
    objects = inventory(root)
    refs = {key: references([p for p, _ in files]) for key, files in groups.items()}
    if any(not keys <= objects.keys() for keys in refs.values()):
        raise ValueError('missing shared block')
    def usage(keys):
        shared = set(protected_objects) & objects.keys()
        for key in keys:
            shared.update(refs[key])
        return sum(i.st_size for key in keys for _, i in groups[key]) + sum(objects[k] for k in shared)
    total = sum(info.st_size for _, info in entries) + sum(objects.values())
    retained = set(groups) & protected
    pinned = usage(retained)
    candidates = sorted([(key, files) for key, files in groups.items() if key not in protected],
                        key=lambda pair: (max(i.st_mtime_ns for _, i in pair[1]), pair[0]), reverse=True)
    for index, (key, files) in enumerate(candidates):
        if index < config['keep_recent'] and usage(retained | {key}) + reserve_bytes <= config['budget_bytes']:
            retained.add(key)
    remaining = usage(retained) + reserve_bytes
    deleting = [(p, i) for key, files in candidates if key not in retained for p, i in files]
    blocked = pinned + reserve_bytes > config['budget_bytes']
    warning = ('protected_snapshots_exceed_budget' if blocked else
               'snapshot_capacity_high' if remaining * 100 >= config['budget_bytes'] * config['warning_percent'] else None)
    result = dict(schema_version=1, status='error' if blocked else 'ok', checked_at=time.time(),
                  archive_bytes=total, projected_bytes=remaining, reserved_bytes=reserve_bytes,
                  protected_bytes=pinned, protected_count=sum(key in protected for key in groups),
                  archive_count=len(groups), removable_count=len({identity(p) for p, _ in deleting}),
                  removable_bytes=total - (remaining - reserve_bytes), warning=warning,
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


def maintain(root, config=None, *, reserve_bytes=0, extra_protected=(), protected_objects=()):
    root = lab._root(root)
    with lab.snapshot_lock(root, exclusive=True):
        try:
            result, deleting = _plan(root, config or {}, reserve_bytes, extra_protected, protected_objects)
            if result['status'] == 'error':
                _save(root, result)
                raise RetentionError('protected_snapshots_exceed_budget')
            # Validate every deletion before deleting ANY file. Corruption or
            # unknown reference inputs abort cleanup, preserving all evidence.
            twins = {}
            for path, info in deleting:
                from retrieval_archive import read_file, validate, identity
                raw = read_file(path)
                key = identity(path)
                validate(raw, key)
                fingerprint = hashlib.sha256(raw).digest()
                if key in twins and twins[key] != fingerprint:
                    raise ValueError('compressed snapshot differs from original')
                twins[key] = fingerprint
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
            from retrieval_shared import collect_unused
            collect_unused(root, protected_objects)
            result.update(deleted_count=result['removable_count'], freed_bytes=result['removable_bytes'],
                          archive_bytes=result['archive_bytes'] - result['removable_bytes'],
                          archive_count=result['archive_count'] - result['removable_count'])
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
    if value.get('deleted_count') or value.get('freed_bytes', 0) > 0:
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
