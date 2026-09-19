"""Read-only, bounded conversational-text snapshots, not raw/tool-log search.

Paths stay local to this importer; source identifiers are opaque registrations.
Only explicit user/assistant text is exported. Text may itself contain sensitive
user content: the resulting snapshot must remain local and outside version control.
"""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import re
import stat

MAX_FILES = 10_000
MAX_SOURCE_BYTES = 64 * 1024 * 1024
MAX_TOTAL_BYTES = 256 * 1024 * 1024
MAX_DOCUMENT_CHARS = 100_000
MAX_DOCUMENT_SUMMARIES = 100
MAX_MANIFEST_BYTES = 60 * 1024 * 1024
MAX_METADATA_BYTES = 128 * 1024
REF = re.compile(r"hmac-sha256:[0-9a-f]{64}\Z")
HASH = re.compile(r"sha256:[0-9a-f]{64}\Z")


def _sha(data: bytes) -> str:
    return 'sha256:' + hashlib.sha256(data).hexdigest()


def _read(path: Path, limit: int, *, prefix: bool = False) -> bytes:
    # Reject symlink components as well as final symlinks; never follow a
    # registration into a non-regular file such as a FIFO or device.
    if any(p.is_symlink() for p in (path, *path.parents)):
        raise ValueError('unsafe input')
    fd = os.open(path, os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0) | os.O_NONBLOCK)
    with os.fdopen(fd, 'rb') as stream:
        before = os.fstat(stream.fileno())
        if not stat.S_ISREG(before.st_mode) or before.st_uid != os.geteuid():
            raise ValueError('unsafe input')
        if not prefix and before.st_size > limit:
            raise ValueError('oversize input')
        data = stream.read(limit if prefix else limit + 1)
        after = os.fstat(stream.fileno())
        if (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns) != (
            after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns
        ):
            raise ValueError('input changed')
    return data


def _files(directory: Path):
    if not directory.exists():
        return
    if directory.is_symlink():
        raise ValueError('unsafe metadata directory')
    # Bound directory enumeration, not just the later file reads.
    with os.scandir(directory) as entries:
        selected = []
        for index, entry in enumerate(entries):
            if index >= MAX_FILES:
                raise ValueError('metadata file limit exceeded')
            if entry.name.endswith('.json'):
                selected.append(Path(entry.path))
    yield from sorted(selected)


def _registration(value):
    if not isinstance(value, dict):
        return False
    size = value.get('size_bytes')
    path = value.get('path')
    return (
        isinstance(path, str) and Path(path).is_absolute()
        and Path(path).suffix == '.jsonl'
        and isinstance(size, int) and not isinstance(size, bool) and size >= 0
        and value.get('adapter') in ('claude-code', 'codex')
        and isinstance(value.get('source_ref'), str)
        and REF.fullmatch(value['source_ref']) is not None
        and isinstance(value.get('content_sha256'), str)
        and HASH.fullmatch(value['content_sha256']) is not None
    )


def _message(value, adapter):
    if not isinstance(value, dict):
        return None
    if adapter == 'codex':
        if value.get('type') != 'response_item':
            return None
        message = value.get('payload')
        if not isinstance(message, dict) or message.get('type') != 'message':
            return None
        types = ('input_text', 'output_text')
    else:
        if value.get('type') not in ('user', 'assistant'):
            return None
        message = value.get('message')
        types = ('text',)
    if not isinstance(message, dict) or message.get('role') not in ('user', 'assistant'):
        return None
    content = message.get('content')
    if isinstance(content, str):
        texts = [content]
    elif isinstance(content, list):
        texts = [b['text'] for b in content if isinstance(b, dict)
                 and b.get('type') in types and isinstance(b.get('text'), str)]
    else:
        texts = []
    text = '\n'.join(texts).strip()
    return (message['role'], text) if text else None


def export_vault(vault: Path, window_lines: int = 40) -> dict:
    """Return local manifest; skip missing, altered, unsafe or oversized inputs.

    Select the newest registration per path. Appended logs are read only through
    the registered size and verified by digest. All eligible conversational
    windows are included, even when they have no semantic receipts.
    """
    if type(window_lines) is not int or not 1 <= window_lines <= 10_000:
        raise ValueError('window_lines must be between 1 and 10000')
    report = dict(registrations=0, invalid_registrations=0, selected_sources=0,
                  imported_sources=0, missing_sources=0, mismatched_sources=0,
                  bounded_sources=0, malformed_lines=0, receipts=0,
                  attached_spans=0, skipped_spans=0, invalid_receipts=0,
                  bytes_read=0, documents=0, unavailable_source_spans=0,
                  bounded_windows=0, bounded_summaries=0, manifest_bytes=0)
    records = {}
    selected = {}
    for path in _files(vault / 'session-sources'):
        try:
            record = json.loads(_read(path, MAX_METADATA_BYTES))
            if not _registration(record):
                raise ValueError('invalid registration')
        except (OSError, ValueError, RecursionError):
            report['invalid_registrations'] += 1
            continue
        report['registrations'] += 1
        records[record['source_ref']] = record
        prior = selected.get(record['path'])
        def rank(item):
            modified = item.get('modified_ns', 0)
            return (modified if type(modified) is int else 0, item['size_bytes'], item['source_ref'])
        if prior is None or rank(record) > rank(prior):
            selected[record['path']] = record
    report['selected_sources'] = len(selected)
    spans = {}
    for path in _files(vault / 'semantic-receipts'):
        try:
            receipt = json.loads(_read(path, MAX_METADATA_BYTES))
            task, result = receipt.get('task', {}), receipt.get('result', {})
            summaries = list(dict.fromkeys(s for s in (
                task.get('intent'), task.get('deliverable'), result.get('summary')
            ) if isinstance(s, str) and s.strip()))
            source_spans = receipt.get('provenance', {}).get('source_spans', [])
            if not isinstance(source_spans, list):
                raise ValueError('invalid spans')
            for span in source_spans:
                if not isinstance(span, dict):
                    report['skipped_spans'] += 1
                    continue
                ref = span.get('source_ref')
                if isinstance(ref, str) and ref in records:
                    spans.setdefault(records[ref]['path'], []).append((span, summaries))
                else:
                    report['skipped_spans'] += 1
            report['receipts'] += 1
        except (OSError, ValueError, AttributeError, TypeError, RecursionError):
            report['invalid_receipts'] += 1
    documents = []
    imported_paths = set()
    for path, record in sorted(selected.items()):
        size = record['size_bytes']
        if size > MAX_SOURCE_BYTES or report['bytes_read'] + size > MAX_TOTAL_BYTES:
            report['bounded_sources'] += 1
            continue
        try:
            raw = _read(Path(path), size, prefix=True)
            report['bytes_read'] += len(raw)
            if len(raw) != size or _sha(raw) != record['content_sha256']:
                raise ValueError('prefix mismatch')
        except FileNotFoundError:
            report['missing_sources'] += 1
            continue
        except (OSError, ValueError):
            report['mismatched_sources'] += 1
            continue
        report['imported_sources'] += 1
        imported_paths.add(path)
        # Split only on LF, matching semantic_receipts._read_registered_span.
        lines = raw.split(b'\n')
        lines = [line + b'\n' for line in lines[:-1]] + ([lines[-1]] if lines[-1] else [])
        byte_ends = []
        byte_offset = 0
        for source_line in lines:
            byte_offset += len(source_line)
            byte_ends.append(byte_offset)
        source_docs = []
        for offset in range(0, len(lines), window_lines):
            text = []
            for number, line in enumerate(lines[offset:offset + window_lines], offset + 1):
                try:
                    message = _message(json.loads(line), record['adapter'])
                except (ValueError, RecursionError):
                    report['malformed_lines'] += 1
                    continue
                if message:
                    text.append(f'[line {number}] {message[0]}: {message[1]}')
            if len('\n'.join(text)) > MAX_DOCUMENT_CHARS:
                report['bounded_windows'] += 1
                continue
            if text:
                source_docs.append(dict(source_id=record['source_ref'], start_line=offset + 1,
                                        end_line=min(offset + window_lines, len(lines)),
                                        text='\n'.join(text), summaries=[]))
        validated = {}
        for span, summaries in spans.get(path, []):
            original = records[span['source_ref']]
            ref = original['source_ref']
            if ref not in validated:
                validated[ref] = (original['size_bytes'] <= size and
                                  _sha(raw[:original['size_bytes']]) == original['content_sha256'])
            start, end = span.get('start_line'), span.get('end_line')
            valid = (validated[ref] and span.get('content_sha256') == original['content_sha256']
                     and span.get('adapter') == original['adapter']
                     and type(start) is int and type(end) is int and 1 <= start <= end <= len(lines))
            if valid:
                span_bytes = b''.join(lines[start - 1:end])
                valid = (byte_ends[end - 1] <= original['size_bytes']
                         and _sha(span_bytes) == span.get('span_sha256'))
            if not valid:
                report['skipped_spans'] += 1
                continue
            attached = False
            for doc in source_docs:
                if doc['start_line'] <= end and doc['end_line'] >= start:
                    merged = list(dict.fromkeys(doc['summaries'] + summaries))
                    report['bounded_summaries'] += max(0, len(merged) - MAX_DOCUMENT_SUMMARIES)
                    doc['summaries'] = merged[:MAX_DOCUMENT_SUMMARIES]
                    attached = True
            report['attached_spans' if attached else 'skipped_spans'] += 1
        for doc in source_docs:
            document_bytes = len(json.dumps(doc, ensure_ascii=True).encode('utf-8')) + 2
            if report['manifest_bytes'] + document_bytes > MAX_MANIFEST_BYTES:
                report['bounded_windows'] += 1
                continue
            report['manifest_bytes'] += document_bytes
            documents.append(doc)
    for path, pending in spans.items():
        if path not in imported_paths:
            report['unavailable_source_spans'] += len(pending)
            report['skipped_spans'] += len(pending)
    report['documents'] = len(documents)
    return dict(schema_version=1, documents=documents, import_report=report)
