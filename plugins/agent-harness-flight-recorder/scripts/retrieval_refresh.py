#!/usr/bin/env python3
"""Opt-in local conversation refresh, triggered after foreground searches."""
from __future__ import annotations

import fcntl
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import uuid

import retrieval_lab as lab
from retrieval_live import export_live, source_id
from retrieval_snapshot import _files, _read, _registration, MAX_METADATA_BYTES


def _json(path):
    return json.loads(lab.safe_file(path, 1024 * 1024))


def _write(root, name, value):
    path = root / ('.refresh-' + uuid.uuid4().hex)
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, 'w') as stream:
            stream.write(lab.canonical(value))
        os.replace(path, root / name)
    finally:
        path.unlink(missing_ok=True)


def status(root):
    root = lab._root(root)
    path = root / 'refresh-state.json'
    return _json(path) if path.exists() else dict(status='not_started', since=0)


def _config(root):
    value = _json(root / 'refresh-config.json')
    if value.get('schema_version') != 1:
        raise ValueError('invalid refresh config')
    roots = value.get('roots')
    if not isinstance(roots, list) or not 1 <= len(roots) <= 10:
        raise ValueError('invalid roots')
    for item in roots:
        if item['adapter'] not in ('codex', 'claude-code') or not Path(item['path']).is_absolute():
            raise ValueError('invalid root')
    interval = value.get('interval_seconds', 900)
    if type(interval) is not int or not 60 <= interval <= 86400:
        raise ValueError('invalid interval')
    excluded = value.get('exclude_sessions', [])
    if not isinstance(excluded, list) or any(not isinstance(s, str) or not s for s in excluded):
        raise ValueError('invalid excluded sessions')
    return value


def _summaries(root, current, config):
    # Registration metadata maps old opaque identifiers to current path-derived
    # identifiers. Only identical source/span/text can inherit a verified summary.
    aliases = {}
    if config.get('source_vault'):
        for path in _files(Path(config['source_vault']) / 'session-sources'):
            try:
                record = json.loads(_read(path, MAX_METADATA_BYTES))
                if _registration(record):
                    aliases[record['source_ref']] = source_id(record['adapter'], Path(record['path']))
            except (OSError, ValueError, TypeError):
                continue
    result = {}
    for doc in current['documents']:
        key = (aliases.get(doc['source_id'], doc['source_id']), doc['start_line'], doc['end_line'], doc['text'])
        if doc['summaries']:
            result[key] = doc['summaries']
    return result


def refresh(root, force=False):
    root = lab._root(root)
    config = _config(root)
    fd = os.open(root / 'refresh.lock', os.O_CREAT | os.O_RDWR | getattr(os, 'O_NOFOLLOW', 0), 0o600)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return dict(status='busy')
        state = status(root)
        started = time.time()
        if not force and started - state.get('last_attempt', 0) < config.get('interval_seconds', 900):
            return dict(status='throttled')
        state.update(last_attempt=started, status='running')
        _write(root, 'refresh-state.json', state)
        try:
            current = lab._snapshot(root)
            # A hard storage ceiling prevents unattended unbounded disk growth.
            archive = root / 'snapshots'
            if archive.exists() and sum(p.stat().st_size for p in archive.glob('*.json')) > 1024 ** 3:
                raise ValueError('snapshot archive budget exhausted')
            delta = export_live([(r['adapter'], Path(r['path'])) for r in config['roots']],
                                since=state.get('since', 0) if state.get('config_id') == lab.digest(config) else 0, exclude_sessions=config.get('exclude_sessions', []),
                                settle_seconds=0, known_source_ids=state.get('source_ids', []))
            if delta.get('inventory_complete') is False and state.get('config_id') != lab.digest(config):
                raise ValueError('incomplete inventory after config change')
            replaced = set(delta['refreshed_source_ids']) | set(delta['excluded_source_ids'])
            present = set(delta.get('present_source_ids', []))
            documents = ([d for d in current['documents'] if d['source_id'] not in replaced
                          and (not delta.get('inventory_complete', False) or d['source_id'] in present)]
                         if state.get('bootstrapped') and state.get('config_id') == lab.digest(config) else [])
            summaries = _summaries(root, current, config)
            for doc in delta['documents']:
                doc['summaries'] = summaries.get((doc['source_id'], doc['start_line'], doc['end_line'], doc['text']), [])
            documents.extend(delta['documents'])
            result = lab.publish_snapshot(root, dict(schema_version=1, documents=documents,
                                                     import_report=delta['import_report']))
            state.update(result, status='updated' if result['changed'] else 'unchanged',
                         sources=len({d['source_id'] for d in documents}),
                         source_ids=delta.get('present_source_ids', state.get('source_ids', [])), bootstrapped=True, config_id=lab.digest(config), since=max(0, started - 60), last_success=time.time(),
                         elapsed_ms=round((time.time() - started) * 1000), error_type=None)
        except (OSError, ValueError, KeyError, TypeError, RecursionError) as exc:
            # Never publish partial collections or move the successful watermark.
            state.update(status='error', error_type=type(exc).__name__,
                         elapsed_ms=round((time.time() - started) * 1000))
        _write(root, 'refresh-state.json', state)
        return state
    finally:
        os.close(fd)


def maybe_start(root):
    root = lab._root(root)
    if not (root / 'refresh-config.json').exists():
        return
    config = _config(root)
    state = status(root)
    if state.get('status') == 'error':
        print('Conversation refresh failed; using the last valid corpus. See refresh-status.', file=sys.stderr)
    if time.time() - state.get('last_attempt', 0) >= config.get('interval_seconds', 900):
        subprocess.Popen([sys.executable, str(Path(__file__).resolve()), '--lab', str(root), 'refresh'],
                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         start_new_session=True, close_fds=True)


def main():
    # Preserve the existing retrieval CLI. Refresh is optional and never changes
    # behavior of fixed labs or request-bound historical operations.
    if len(sys.argv) < 4 or sys.argv[1] != '--lab':
        return lab.main()
    root, command = Path(sys.argv[2]), sys.argv[3]
    if command in ('refresh', 'refresh-status'):
        try:
            if command == 'refresh-status':
                result = status(root)
            else:
                if any(a != '--force' for a in sys.argv[4:]):
                    raise ValueError('invalid refresh option')
                result = refresh(root, force='--force' in sys.argv[4:])
            print(lab.canonical(result))
            return 1 if result['status'] == 'error' else 0
        except (OSError, ValueError, KeyError, TypeError) as exc:
            print(lab.canonical(dict(error=type(exc).__name__, message='Invalid refresh configuration or state.')), file=sys.stderr)
            return 1
    code = lab.main()
    if code == 0 and command == 'search':
        try:
            maybe_start(root)
        except (OSError, ValueError, KeyError, TypeError):
            print('Conversation refresh unavailable; search used the last valid corpus.', file=sys.stderr)
    return code


if __name__ == '__main__':
    raise SystemExit(main())
