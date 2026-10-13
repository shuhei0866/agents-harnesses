"""Opt-in local recall refresh on the existing recorder scheduler wakeup."""
import json
import os
from pathlib import Path
import stat
import subprocess
import time


def tick(root):
    from retrieval_lab import safe_file
    from chunk_rotation import atomic_replace, canonical_json
    config = root / 'scheduler/recall-observer.json'
    if not config.exists() and not config.is_symlink():
        return
    result = dict(attempted_at=time.time())
    try:
        metadata = config.lstat()
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.geteuid() or metadata.st_mode & 0o077:
            raise ValueError('unsafe observer configuration')
        value = json.loads(safe_file(config, 8192))
        command = Path(value['command'])
        if value.get('schema_version') != 1 or not command.is_absolute() or any(p.is_symlink() for p in (command, *command.parents)):
            raise ValueError('unsafe observer command')
        metadata = command.stat()
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.geteuid() or metadata.st_mode & 0o022:
            raise ValueError('unsafe observer command')
        proc = subprocess.run([str(command), 'refresh'], stdin=subprocess.DEVNULL,
                              stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                              timeout=30, check=False)
        result['status'] = 'ok' if proc.returncode == 0 else 'error'
        raw = getattr(proc, 'stdout', None)
        if isinstance(raw, bytes) and raw and len(raw) <= 1024 * 1024:
            report = json.loads(raw)
            if not isinstance(report, dict):
                raise ValueError('invalid refresh report')
            if report.get('collection_status') == 'error':
                result['status'] = 'error'
            storage = report.get('storage', {})
            # Only fixed codes and numeric metrics cross the scheduler boundary.
            if isinstance(storage, dict):
                result['storage'] = {k: storage[k] for k in
                    ('archive_bytes', 'budget_bytes', 'protected_bytes', 'usage_percent')
                    if type(storage.get(k)) in (int, float)}
                warning = storage.get('warning')
                if warning in ('snapshot_capacity_high', 'protected_snapshots_exceed_budget',
                               'reference_scan_budget_exhausted', 'unsafe_reference_path',
                               'unsafe_snapshot_archive', 'snapshot_changed_during_retention',
                               'retention_reference_check_failed', 'reference_database_unavailable'):
                    result['storage']['warning'] = warning
                    if result['status'] == 'ok':
                        result['status'] = 'warning'

    except (OSError, ValueError, KeyError, TypeError, subprocess.TimeoutExpired):
        result['status'] = 'error'
    try:
        atomic_replace(root / 'scheduler/recall-observer-status.json', canonical_json(result))
    except OSError:
        pass  # Diagnostic failure must not affect Vault sync.
