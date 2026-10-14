#!/usr/bin/env python3
"""Opt-in local conversation refresh, triggered after foreground searches."""
from __future__ import annotations

import fcntl
import json
import os
import math
from pathlib import Path
import subprocess
import sys
import time
import uuid

import retrieval_lab as lab
import retrieval_retention as retention
from retrieval_live import COLLECTOR_VERSION, export_live, source_id
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


def _state(root):
    root = lab._root(root)
    path = root / 'refresh-state.json'
    return _json(path) if path.exists() else dict(status='not_started', since=0)


# Two missed collection intervals plus the bounded worker allowance.
WORKER_TIMEOUT = 120


def status(root):
    value = _state(root)
    try:
        config = _config(Path(root))
    except FileNotFoundError:
        return dict(value, health='unknown', health_code='refresh_not_configured')
    interval = config.get('interval_seconds', 900)
    last = value.get('last_success')
    age = max(0, time.time() - last) if type(last) in (int, float) and math.isfinite(last) and 0 < last <= time.time() + 60 else None
    health = 'ok'
    code = None
    if age is None or age > 2 * interval + WORKER_TIMEOUT:
        health, code = 'error', 'collection_stale'
    if value.get('status') == 'error':
        health, code = 'error', value.get('error_code') or 'collection_failed'
    if value.get('status') == 'running':
        fd = os.open(Path(root) / 'refresh.lock', os.O_CREAT | os.O_RDWR | getattr(os, 'O_NOFOLLOW', 0), 0o600)
        try:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                if health == 'ok': health = 'running'
            else:
                health, code = 'error', 'collection_interrupted'
        finally:
            os.close(fd)
    for name in ('followups', 'opportunities'):
        if config.get(name) and value.get(name, {}).get('status') != 'ok':
            health, code = 'error', 'observation_failed'
    value.update(health=health, health_code=code, success_age_seconds=age,
                 stale_after_seconds=2 * interval + WORKER_TIMEOUT)
    return value


def _failure_code(exc):
    if isinstance(exc, retention.RetentionError):
        return exc.code
    # Only known literals leave this process; never log exception text or paths.
    message = str(exc).removeprefix('local refresh aborted: ')
    return {
        'input changed': 'source_changed',
        'local session scan unavailable or changed; prior snapshot retained': 'source_unavailable',
        'local source byte limit exceeded': 'source_size_limit',
        'local snapshot size limit exceeded': 'collection_size_limit',
        'snapshot too large': 'snapshot_size_limit',
        'corpus document count outside supported range': 'document_count_limit',
        'incomplete inventory after collection change': 'inventory_incomplete',
    }.get(message, 'collection_failed')


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
    retention.policy(value.get("retention", {}))
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


def _collect(state, *args, **kwargs):
    # An actively appended log can change during a bounded read. Retry the
    # complete export once; never publish a partial source or skip its evidence.
    for attempt in range(2):
        state['collection_attempts'] = attempt + 1
        try:
            return export_live(*args, **kwargs)
        except ValueError as exc:
            if _failure_code(exc) != 'source_changed' or attempt:
                raise


def refresh(root, force=False):
    root = lab._root(root)
    config = _config(root)
    fd = os.open(root / 'refresh.lock', os.O_CREAT | os.O_RDWR | getattr(os, 'O_NOFOLLOW', 0), 0o600)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return dict(status(root), status='busy', collection_status=_state(root).get('status'))
        with lab.snapshot_lock(root, exclusive=True):
            state = _state(root)
            started = time.time()
            interrupted = state.get('status') == 'running'
            if interrupted:
                state.update(status='error', error_code='collection_interrupted',
                             last_failure=dict(at=started, code='collection_interrupted', stage=state.get('stage', 'unknown')))
                _write(root, 'refresh-state.json', state)
            if not force and started - state.get('last_attempt', 0) < config.get('interval_seconds', 900):
                return dict(status(root), status='throttled', collection_status=state.get('status'))
            state.update(last_attempt=started, status='running', error_code=None, error_type=None,
                         interrupted_previous_attempt=interrupted, stage='starting', stage_ms={})
            _write(root, 'refresh-state.json', state)
            def stage(name, fn, *args, **kwargs):
                state['stage'] = name
                _write(root, 'refresh-state.json', dict(state, status='running'))
                began = time.monotonic()
                try:
                    return fn(*args, **kwargs)
                finally:
                    state['stage_ms'][name] = round((time.monotonic() - began) * 1000)

            try:
                from retrieval_archive import compress
                state['compression'] = stage('compress', compress, root, limit=2)
                current = stage('load_snapshot', lab._snapshot, root)
                state['storage'] = stage('retention', retention.maintain, root, config.get('retention', {}))
                same_collection = (state.get('config_id') == lab.digest(config)
                                   and state.get('collector_version') == COLLECTOR_VERSION)
                delta = stage('collect', _collect, state, [(r['adapter'], Path(r['path'])) for r in config['roots']],
                                    since=state.get('since', 0) if same_collection else 0, exclude_sessions=config.get('exclude_sessions', []),
                                    settle_seconds=0, known_source_ids=state.get('source_ids', []))
                if delta.get('inventory_complete') is False and not same_collection:
                    raise ValueError('incomplete inventory after collection change')
                replaced = set(delta['refreshed_source_ids']) | set(delta['excluded_source_ids'])
                present = set(delta.get('present_source_ids', []))
                documents = ([d for d in current['documents'] if d['source_id'] not in replaced
                              and (not delta.get('inventory_complete', False) or d['source_id'] in present)]
                             if state.get('bootstrapped') and same_collection else [])
                summaries = stage('summaries', _summaries, root, current, config)
                for doc in delta['documents']:
                    doc['summaries'] = summaries.get((doc['source_id'], doc['start_line'], doc['end_line'], doc['text']), [])
                documents.extend(delta['documents'])
                result = stage('publish', lab.publish_snapshot, root, dict(schema_version=1, documents=documents,
                                                         import_report=delta['import_report']),
                                              storage_policy=config.get('retention', {}))
                state.update(result, status='updated' if result['changed'] else 'unchanged',
                             sources=len({d['source_id'] for d in documents}),
                             source_ids=delta.get('present_source_ids', state.get('source_ids', [])), bootstrapped=True, collector_version=COLLECTOR_VERSION, config_id=lab.digest(config), since=max(0, started - 60), last_success=time.time(),
                             elapsed_ms=round((time.time() - started) * 1000), error_type=None, error_code=None)
            except (OSError, ValueError, KeyError, TypeError, RecursionError) as exc:
                # Never publish partial collections or move the successful watermark.
                state.update(status='error', error_type=type(exc).__name__,
                             error_code=_failure_code(exc),
                             elapsed_ms=round((time.time() - started) * 1000),
                             last_failure=dict(at=time.time(), code=_failure_code(exc),
                                               stage=state['stage'], error_type=type(exc).__name__))
            if state.get('status') in ('updated', 'unchanged') and config.get('opportunities'):
                try:
                    from retrieval_opportunities import run as audit_opportunities
                    state['opportunities'] = stage('opportunities', audit_opportunities, root, lab._snapshot(root), config['opportunities'])
                except (OSError, ValueError, KeyError, TypeError, RecursionError) as exc:
                    state['opportunities'] = dict(status='error', error_type=type(exc).__name__)
            if state.get('status') in ('updated', 'unchanged') and config.get('followups'):
                try:
                    from retrieval_followup import run as observe_followups
                    state['followups'] = stage('followups', observe_followups, root, lab._snapshot(root), config['followups'])
                except (OSError, ValueError, KeyError, TypeError, RecursionError) as exc:
                    state['followups'] = dict(status='error', error_type=type(exc).__name__)
            try:
                state['storage'] = retention.read_status(root)
            except (OSError, ValueError):
                pass
            if state.get('status') in ('updated', 'unchanged'):
                state['stage'] = 'complete'
            _write(root, 'refresh-state.json', state)
            return status(root)
    finally:
        os.close(fd)


def maybe_start(root):
    root = lab._root(root)
    if not (root / 'refresh-config.json').exists():
        return
    config = _config(root)
    state = status(root)
    storage = state.get('storage', {})
    if storage.get('warning'):
        print('Snapshot storage warning: ' + storage['warning'] + '; see refresh-status storage.', file=sys.stderr)
    if state.get('health') == 'error':
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
    if command in ('refresh', 'refresh-status', 'storage-status', 'snapshot-pin', 'storage-compress'):
        try:
            if command == 'storage-compress':
                from retrieval_archive import compress
                if len(sys.argv) != 4:
                    raise ValueError('storage-compress takes no options')
                config = _config(lab._root(root))
                with lab.snapshot_lock(root, exclusive=True):
                    result = dict(status='ok', compression=compress(root, limit=5))
                    result['storage'] = retention.maintain(root, config.get('retention', {}))
            elif command == 'snapshot-pin':
                if len(sys.argv) != 5:
                    raise ValueError('snapshot-pin requires one snapshot ID')
                result = retention.pin(root, sys.argv[4])
            elif command == 'storage-status':
                result = retention.inspect(root, _config(lab._root(root)).get('retention', {}))
            elif command == 'refresh-status':
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
    if code == 0 and command in ('search', 'corrections'):
        try:
            maybe_start(root)
        except (OSError, ValueError, KeyError, TypeError):
            print('Conversation refresh unavailable; search used the last valid corpus.', file=sys.stderr)
    return code


if __name__ == '__main__':
    raise SystemExit(main())
