"""Independent gzip generations, with bounded reads and crash-safe conversion."""
import gzip
import io
import json
import os
from pathlib import Path
import re
import stat
import zlib


def identity(path):
    match = re.fullmatch(r'([0-9a-f]{64})\.json(?:\.(?:gz|ref))?', path.name)
    if not match:
        raise ValueError('invalid archive name')
    return match[1]


def entries(root):
    import retrieval_lab as lab
    directory = Path(root) / 'snapshots'
    if not directory.exists() and not directory.is_symlink():
        return []
    lab._root(directory)
    result = []
    for path in directory.iterdir():
        if path.name.startswith('.'):
            continue
        identity(path)
        info = path.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o077:
            raise ValueError('unsafe archive file')
        result.append((path, info))
    return result


def unpack(raw):
    import retrieval_lab as lab
    try:
        with gzip.GzipFile(fileobj=io.BytesIO(raw), mode='rb') as stream:
            value = stream.read(lab.MAX_SNAPSHOT_BYTES + 1)
    except (OSError, EOFError, zlib.error) as exc:
        raise ValueError('invalid compressed snapshot') from exc
    if len(value) > lab.MAX_SNAPSHOT_BYTES:
        raise ValueError('expanded snapshot exceeds bound')
    return value


def read_file(path):
    import retrieval_lab as lab
    if path.suffix == '.ref':
        from retrieval_shared import read
        return read(path)
    if path.suffix == '.gz':
        return unpack(lab.safe_file(path, lab.MAX_SNAPSHOT_BYTES + 1024 * 1024))
    return lab.safe_file(path, lab.MAX_SNAPSHOT_BYTES)


def read(root, snapshot_id):
    """Also handles a legacy JSON disappearing after its gzip twin is committed."""
    import retrieval_lab as lab
    directory = Path(root) / 'snapshots'
    if directory.is_symlink():
        raise ValueError('unsafe snapshot directory')
    paths = [directory / (snapshot_id + suffix) for suffix in ('.json.ref', '.json.gz', '.json')]
    result = None
    # A converter may replace a legacy file between the lookup and open.
    for attempt in range(2):
        for path in paths:
            try:
                raw = read_file(path)
            except FileNotFoundError:
                # A missing shared dependency is corruption, not an absent generation.
                if path.exists() or path.is_symlink():
                    raise
                continue
            if result is not None and result != raw:
                raise ValueError('compressed snapshot differs from original')
            result = raw
        if result is not None:
            return result
    raise FileNotFoundError('snapshot unavailable')


def exists(root, snapshot_id):
    directory = Path(root) / 'snapshots'
    return any(p.exists() or p.is_symlink() for p in
               (directory / (snapshot_id + suffix) for suffix in ('.json', '.json.gz', '.json.ref')))


def pack(raw):
    return gzip.compress(raw, compresslevel=6, mtime=0)


def validate(raw, snapshot_id):
    import retrieval_lab as lab
    value = json.loads(raw)
    if (not isinstance(value, dict) or value.get('schema_version') != 1 or value.get('snapshot_id') != snapshot_id
            or lab.digest(value.get('documents')) != snapshot_id):
        raise ValueError('snapshot identity mismatch')


def compress(root, limit=2):
    """Convert a bounded batch; never remove a plain copy until durable readback."""
    import retrieval_lab as lab
    root = lab._root(root)
    lab.bounded_int(limit, 1, 100)
    with lab.snapshot_lock(root, exclusive=True):
        all_files = entries(root)
        pending = sorted((p for p, _ in all_files if p.suffix == '.json'), key=lambda p: p.name)
        converted, saved = 0, 0
        for path in pending[:limit]:
            snapshot_id = identity(path)
            raw = read_file(path)
            validate(raw, snapshot_id)
            target = path.with_suffix('.json.gz')
            if not (target.exists() or target.is_symlink()):
                lab._atomic_snapshot_file(target, pack(raw))
            # Existing twins can be remnants of a crash. Do not silently prefer
            # either copy if their bytes disagree, even when document IDs match.
            if read_file(target) != raw:
                raise ValueError('compressed snapshot differs from original')
            metadata = path.stat()
            os.utime(target, ns=(metadata.st_atime_ns, metadata.st_mtime_ns))
            with open(target, 'rb') as stream:
                os.fsync(stream.fileno())
            saved += path.stat().st_size
            if not any(p == target for p, _ in all_files):
                saved -= target.stat().st_size
            path.unlink()
            directory_fd = os.open(path.parent, os.O_RDONLY)
            try:
                os.fsync(directory_fd)
            finally:
                os.close(directory_fd)
            converted += 1
        return dict(converted=converted, saved_bytes=saved, pending=max(0, len(pending)-converted))
