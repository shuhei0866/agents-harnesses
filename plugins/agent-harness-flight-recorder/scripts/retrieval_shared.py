"""Lossless shared snapshot blocks; manifests never depend on other generations."""
import hashlib
import json
import os
import re
from pathlib import Path

import retrieval_lab as lab

FORMAT = 'shared-snapshot-v1'
BLOCK_BYTES = 256 * 1024
HEX = re.compile(r'^[0-9a-f]{64}$')


def enabled(root):
    p = Path(root) / 'archive-format.json'
    if not p.exists() and not p.is_symlink():
        return False
    if json.loads(lab.safe_file(p, 1024)) != {'format': FORMAT}:
        raise ValueError('invalid archive format')
    return True


def object_directory(root):
    p = Path(root) / 'snapshot-objects'
    if p.exists() or p.is_symlink():
        lab._root(p)
    return p


def object_path(root, key):
    if not isinstance(key, str) or not HEX.fullmatch(key):
        raise ValueError('invalid shared block identity')
    return object_directory(root) / (key + '.gz')


def inventory(root):
    p = object_directory(root)
    result = {}
    if p.exists():
        import stat
        for f in p.iterdir():
            if f.name.startswith('.'):
                continue
            key = f.name[:-3]
            if f.suffix != '.gz' or not HEX.fullmatch(key):
                raise ValueError('invalid shared object name')
            st = f.lstat()
            if not stat.S_ISREG(st.st_mode) or st.st_uid != os.geteuid() or st.st_mode & 0o077:
                raise ValueError('unsafe shared object')
            result[key] = st.st_size
    return result


def blocks(raw):
    """Keep exact JSON bytes, grouping adjacent documents from the same source."""
    # Find the top-level documents member using the JSON decoder, not a text
    # regex that could match quoted document text or nested metadata.
    text = raw.decode('utf-8'); decoder = json.JSONDecoder()
    pos = text.index('{') + 1
    def ws(i):
        while i < len(text) and text[i].isspace(): i += 1
        return i
    while True:
        pos = ws(pos)
        key, end = decoder.raw_decode(text, pos)
        pos = ws(end)
        if text[pos] != ':': raise ValueError('invalid snapshot object')
        pos = ws(pos + 1)
        if key == 'documents': break
        _, pos = decoder.raw_decode(text, pos)
        pos = ws(pos)
        if text[pos] != ',': raise ValueError('missing snapshot documents')
        pos += 1
    if text[pos] != '[': raise ValueError('invalid snapshot documents')
    pos += 1; start = 0; source = None; size = 0
    while True:
        pos = ws(pos)
        if text[pos] == ']': break
        doc_start = pos
        doc, end = decoder.raw_decode(text, pos)
        new_source = doc['source_id']
        doc_size = len(text[pos:end].encode('utf-8'))
        if source is not None and (source != new_source or size + doc_size > BLOCK_BYTES):
            yield text[start:doc_start].encode('utf-8')
            start = doc_start; size = 0
        source = new_source; size += doc_size
        pos = ws(end)
        if text[pos] == ',': pos += 1
        elif text[pos] != ']': raise ValueError('invalid document separator')
    yield text[start:].encode('utf-8')


def prepare(raw, snapshot_id):
    from retrieval_archive import pack, validate
    if not 0 < len(raw) <= lab.MAX_SNAPSHOT_BYTES:
        raise ValueError('snapshot exceeds bound')
    validate(raw, snapshot_id)
    refs, objects = [], {}
    for block in blocks(raw):
        key = hashlib.sha256(block).hexdigest()
        refs.append(dict(hash=key, bytes=len(block)))
        objects.setdefault(key, pack(block))
    manifest = dict(format=FORMAT, snapshot_id=snapshot_id, bytes=len(raw),
                    sha256=hashlib.sha256(raw).hexdigest(), blocks=refs)
    return lab.canonical(manifest).encode(), objects


def manifest(path):
    value = json.loads(lab.safe_file(path, lab.MAX_SNAPSHOT_BYTES))
    if (not isinstance(value, dict) or value.get('format') != FORMAT
            or value.get('snapshot_id') != path.name[:64]
            or type(value.get('bytes')) is not int or not 0 < value['bytes'] <= lab.MAX_SNAPSHOT_BYTES
            or not isinstance(value.get('sha256'), str) or not HEX.fullmatch(value['sha256'])
            or not isinstance(value.get('blocks'), list) or not 1 <= len(value['blocks']) <= 100000):
        raise ValueError('invalid shared manifest')
    total = 0
    for ref in value['blocks']:
        if (not isinstance(ref, dict) or set(ref) != {'hash','bytes'}
                or not isinstance(ref['hash'],str) or not HEX.fullmatch(ref['hash'])
                or type(ref['bytes']) is not int or ref['bytes'] <= 0):
            raise ValueError('invalid shared reference')
        total += ref['bytes']
    if total != value['bytes']: raise ValueError('shared length mismatch')
    return value


def read_block(root, ref):
    from retrieval_archive import unpack
    raw = unpack(lab.safe_file(object_path(root,ref['hash']), lab.MAX_SNAPSHOT_BYTES + 1024*1024))
    if len(raw) != ref['bytes'] or hashlib.sha256(raw).hexdigest() != ref['hash']:
        raise ValueError('shared block mismatch')
    return raw


def read(path):
    value = manifest(path); root = path.parent.parent
    raw = b''.join(read_block(root, ref) for ref in value['blocks'])
    if hashlib.sha256(raw).hexdigest() != value['sha256']:
        raise ValueError('shared snapshot mismatch')
    from retrieval_archive import validate
    validate(raw, value['snapshot_id'])
    return raw


def write(root, snapshot_id, prepared):
    from retrieval_archive import unpack
    meta, objects = prepared
    directory = object_directory(root)
    directory.mkdir(mode=0o700, exist_ok=True)
    # Persist the new directory entry before retiring any legacy snapshot.
    fd = os.open(root, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)
    for key, data in objects.items():
        path = object_path(root,key)
        if path.exists() or path.is_symlink():
            old = unpack(lab.safe_file(path,lab.MAX_SNAPSHOT_BYTES+1024*1024))
            if hashlib.sha256(old).hexdigest() != key: raise ValueError('shared block mismatch')
        else:
            lab._atomic_snapshot_file(path,data)
    path = Path(root)/'snapshots'/(snapshot_id+'.json.ref')
    if path.exists() or path.is_symlink():
        if lab.safe_file(path,lab.MAX_SNAPSHOT_BYTES) != meta: raise ValueError('shared manifest conflict')
    else:
        lab._atomic_snapshot_file(path,meta)
    return path


def references(paths):
    return {r['hash'] for p in paths if p.suffix == '.ref' for r in manifest(p)['blocks']}


def usage(paths, objects):
    refs = references(paths)
    if not refs <= objects.keys(): raise ValueError('missing shared block')
    return sum(p.stat().st_size for p in paths) + sum(objects[k] for k in refs)


def collect_unused(root, protected_objects=()):
    """Caller holds exclusive snapshot lock; preserve every remaining manifest."""
    from retrieval_archive import entries
    objects = inventory(root); paths = [p for p,_ in entries(root)]
    refs = references(paths) | (set(protected_objects) & objects.keys())
    if not refs <= objects.keys(): raise ValueError('missing shared block')
    for key in objects.keys() - refs:
        object_path(root,key).unlink()
    if objects.keys() - refs:
        fd=os.open(object_directory(root),os.O_RDONLY)
        try: os.fsync(fd)
        finally: os.close(fd)


def migrate(root, limit=5):
    """Commit and byte-verify each generation before retiring its legacy copy."""
    from retrieval_archive import entries, identity, read as read_archive
    root=lab._root(root); lab.bounded_int(limit,1,1000)
    with lab.snapshot_lock(root,exclusive=True):
        candidates={identity(p) for p,_ in entries(root) if p.suffix != '.ref'}
        before=sum(i.st_size for _,i in entries(root))+sum(inventory(root).values())
        converted=0
        for key in sorted(candidates)[:limit]:
            raw=read_archive(root,key)
            old=[p for p,_ in entries(root) if identity(p)==key and p.suffix!='.ref']
            path=write(root,key,prepare(raw,key))
            if read(path)!=raw: raise ValueError('shared migration mismatch')
            stamp=max(p.stat().st_mtime_ns for p in old)
            os.utime(path,ns=(stamp,stamp))
            with open(path, 'rb') as stream:
                os.fsync(stream.fileno())
            for p in old:p.unlink()
            fd=os.open(path.parent,os.O_RDONLY)
            try:os.fsync(fd)
            finally:os.close(fd)
            converted+=1
        lab._atomic_snapshot_file(root/'archive-format.json',lab.canonical({'format':FORMAT}).encode())
        after=sum(i.st_size for _,i in entries(root))+sum(inventory(root).values())
        return dict(converted=converted,pending=max(0,len(candidates)-converted),before_bytes=before,after_bytes=after,saved_bytes=before-after)
