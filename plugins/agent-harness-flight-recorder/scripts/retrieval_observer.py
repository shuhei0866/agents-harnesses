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
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                              timeout=30, check=False)
        result['status'] = 'ok' if proc.returncode == 0 else 'error'
    except (OSError, ValueError, KeyError, TypeError, subprocess.TimeoutExpired):
        result['status'] = 'error'
    try:
        atomic_replace(root / 'scheduler/recall-observer-status.json', canonical_json(result))
    except OSError:
        pass  # Diagnostic failure must not affect Vault sync.
