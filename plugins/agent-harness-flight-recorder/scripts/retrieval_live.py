"""Bounded local conversational-log collection for incremental recall refresh.

Read-only: caller owns publishing and must keep the prior snapshot on failure.
A selected session is rescanned in full to exclude retrieval/evaluation feedback,
then only complete LF-terminated JSONL records are indexed. No model calls.
"""
from __future__ import annotations

import hashlib
import json
import math
import os
from pathlib import Path
import re
import time

from retrieval_snapshot import _message, _read

MAX_FILES = 10_000
MAX_ENTRIES = 100_000
MAX_SOURCE_BYTES = 64 * 1024 * 1024
MAX_TOTAL_BYTES = 512 * 1024 * 1024
MAX_DOCUMENTS = 20_000
MAX_DOCUMENT_CHARS = 100_000
MAX_MANIFEST_BYTES = 60 * 1024 * 1024
WINDOW_LINES = 40
ADAPTERS = {'claude-code', 'codex'}
RETRIEVAL_COMMAND = re.compile(
    r'(?<![A-Za-z0-9_-])(?:recall-history|retrieval_lab\.py|retrieval_live\.py|'
    r'retrieval_refresh\.py|flight-recorder-retrieval|retrieval-live)(?![A-Za-z0-9_-])'
)


def source_id(adapter: str, path: Path) -> str:
    """Stable opaque identity for one adapter's absolute local source path."""
    if adapter not in ADAPTERS or not Path(path).is_absolute():
        raise ValueError('invalid local source identity')
    key = json.dumps([adapter, os.path.normpath(str(path))], ensure_ascii=True, separators=(',', ':'))
    return 'sha256:' + hashlib.sha256(key.encode()).hexdigest()


def _tool_inputs(value: dict, adapter: str):
    if adapter == 'codex':
        if value.get('type') != 'response_item':
            return
        payload = value.get('payload')
        if not isinstance(payload, dict):
            return
        if payload.get('type') == 'function_call':
            yield payload.get('name', '')
            yield payload.get('arguments', '')
        elif payload.get('type') == 'custom_tool_call':
            yield payload.get('name', '')
            yield payload.get('input', '')
    elif value.get('type') == 'assistant':
        message = value.get('message')
        content = message.get('content') if isinstance(message, dict) else None
        if isinstance(content, list):
            for block in content:
                if isinstance(block, dict) and block.get('type') == 'tool_use':
                    yield block.get('name', '')
                    yield block.get('input', '')


def _excluded(value: dict, adapter: str, exclusions: set[str]) -> str | None:
    if isinstance(value.get('sessionId'), str) and value['sessionId'] in exclusions:
        return 'configured'
    if adapter == 'claude-code' and value.get('isSidechain') is True:
        return 'subagent'
    if adapter == 'codex' and value.get('type') == 'session_meta':
        payload = value.get('payload')
        if isinstance(payload, dict):
            if isinstance(payload.get('id'), str) and payload['id'] in exclusions:
                return 'configured'
            origin = payload.get('source')
            if (isinstance(origin, dict) and 'subagent' in origin) or origin == 'subagent':
                return 'subagent'
    for argument in _tool_inputs(value, adapter):
        if not isinstance(argument, str):
            argument = json.dumps(argument, ensure_ascii=True)
        if RETRIEVAL_COMMAND.search(argument):
            return 'retrieval'
    return None


def _discover(roots, report):
    pending = []
    seen_dirs = set()
    seen_files = set()
    entries_seen = 0
    for adapter, root_arg in roots:
        root = Path(root_arg)
        if adapter not in ADAPTERS or not root.is_absolute():
            raise ValueError('invalid configured log root')
        if any(p.is_symlink() for p in (root, *root.parents)):
            raise ValueError('unsafe configured log root')
        if not root.exists():
            report['missing_roots'] += 1
            continue
        pending.append((adapter, root))
    files = []
    while pending:
        adapter, directory = pending.pop()
        key = (adapter, str(directory))
        if key in seen_dirs:
            continue
        seen_dirs.add(key)
        if directory.is_symlink():
            report['symlinks_skipped'] += 1
            continue
        with os.scandir(directory) as entries:
            for entry in entries:
                entries_seen += 1
                if entries_seen > MAX_ENTRIES:
                    raise ValueError('local directory scan limit exceeded')
                if entry.is_symlink():
                    report['symlinks_skipped'] += 1
                    continue
                if entry.is_dir(follow_symlinks=False):
                    pending.append((adapter, Path(entry.path)))
                elif entry.name.endswith('.jsonl') and entry.is_file(follow_symlinks=False):
                    identity = (adapter, entry.path)
                    if identity in seen_files:
                        continue
                    seen_files.add(identity)
                    if len(seen_files) > MAX_FILES:
                        raise ValueError('local source count limit exceeded')
                    metadata = entry.stat(follow_symlinks=False)
                    files.append((metadata.st_mtime, adapter, Path(entry.path), metadata.st_size))
    report['discovered_sources'] = len(files)
    return sorted(files, key=lambda item: (-item[0], item[1], str(item[2])))


def export_live(roots: list[tuple[str, Path]], *, since: float,
                exclude_sessions: list[str] | None = None,
                now: float | None = None, settle_seconds: float = 0) -> dict:
    """Export changed sources, preserving original line ranges and source IDs.

    `since` filters source modification times, not conversation timestamps. Each
    selected source replaces ALL its old windows. Caller must merge untouched
    sources and remove `excluded_source_ids`; deletion detection is not provided.
    With optional settling, deferred sources stay untouched in the caller.
    File/corpus limits and read races abort the whole update. Individual text
    lines over the consumer's character limit are omitted and explicitly counted;
    malformed complete records quarantine their entire source.
    """
    started = time.monotonic()
    if (type(since) not in (int, float) or not math.isfinite(since) or since < 0
            or type(settle_seconds) not in (int, float) or not math.isfinite(settle_seconds)
            or settle_seconds < 0):
        raise ValueError('invalid refresh time boundary')
    now = time.time() if now is None else now
    if type(now) not in (int, float) or not math.isfinite(now):
        raise ValueError('invalid refresh clock')
    if exclude_sessions is None:
        exclude_sessions = []
    if not isinstance(exclude_sessions, list) or any(
        not isinstance(item, str) or not item or len(item) > 256 for item in exclude_sessions
    ):
        raise ValueError('invalid excluded session identifiers')
    exclusions = set(exclude_sessions)
    report = dict(discovered_sources=0, imported_sources=0, unchanged_sources=0,
                  deferred_sources=0, excluded_configured_sessions=0,
                  excluded_subagent_sessions=0, excluded_retrieval_sessions=0,
                  missing_roots=0, symlinks_skipped=0, malformed_lines=0,
                  partial_sources=0, bytes_read=0, documents=0, manifest_bytes=0,
                  omitted_oversized_lines=0, excluded_malformed_sessions=0)
    documents = []
    refreshed = []
    excluded = []
    try:
        files = _discover(roots, report)
        for mtime, adapter, path, size in files:
            if mtime < since:
                report['unchanged_sources'] += 1
                continue
            identity = source_id(adapter, path)
            reason = None
            if any(re.search(r'(?<![A-Za-z0-9])' + re.escape(item) + r'(?![A-Za-z0-9])', path.stem)
                   for item in exclusions):
                reason = 'configured'
            elif adapter == 'claude-code' and 'subagents' in path.parts:
                reason = 'subagent'
            if reason:
                report[f'excluded_{reason}_sessions'] += 1
                excluded.append(identity)
                continue
            if settle_seconds and now - mtime < settle_seconds:
                report['deferred_sources'] += 1
                continue
            if size > MAX_SOURCE_BYTES or report['bytes_read'] + size > MAX_TOTAL_BYTES:
                raise ValueError('local source byte limit exceeded')
            raw = _read(path, MAX_SOURCE_BYTES)
            report['bytes_read'] += len(raw)
            if len(raw) > MAX_SOURCE_BYTES or report['bytes_read'] > MAX_TOTAL_BYTES:
                raise ValueError('local source byte limit exceeded')
            if raw and not raw.endswith(b'\n'):
                report['partial_sources'] += 1
            lines = raw.split(b'\n')[:-1]
            messages = []
            for number, line in enumerate(lines, 1):
                try:
                    value = json.loads(line)
                except (ValueError, RecursionError):
                    # Unparseable complete lines could conceal a retrieval tool
                    # call; quarantine the whole source rather than index contamination.
                    report['malformed_lines'] += 1
                    reason = 'malformed'
                    continue
                if not isinstance(value, dict):
                    continue
                found = _excluded(value, adapter, exclusions)
                if found:
                    reason = found
                    break
                message = _message(value, adapter)
                if message:
                    text = f'[line {number}] {message[0]}: {message[1]}'
                    if len(text) > MAX_DOCUMENT_CHARS:
                        report['omitted_oversized_lines'] += 1
                    else:
                        messages.append((number, text))
            if reason:
                report[f'excluded_{reason}_sessions'] += 1
                excluded.append(identity)
                continue
            refreshed.append(identity)
            report['imported_sources'] += 1
            groups = {}
            for number, text in messages:
                groups.setdefault((number - 1) // WINDOW_LINES, []).append((number, text))
            for window, items in groups.items():
                start = window * WINDOW_LINES + 1
                end = min(start + WINDOW_LINES - 1, len(lines))
                # Preserve ordinary 40-line boundaries. Split unusually large
                # windows between JSONL records, never truncate source text.
                chunks = []
                current = []
                chars = 0
                chunk_start = start
                for number, text in items:
                    if current and chars + 1 + len(text) > MAX_DOCUMENT_CHARS:
                        chunks.append((chunk_start, number - 1, current))
                        chunk_start, current, chars = number, [], 0
                    chars += len(text) + bool(current)
                    current.append(text)
                if current:
                    chunks.append((chunk_start, end, current))
                for first, last, texts in chunks:
                    doc = dict(source_id=identity, start_line=first, end_line=last,
                               text='\n'.join(texts), summaries=[])
                    serialized_size = len(json.dumps(doc, ensure_ascii=True).encode()) + 2
                    if (len(documents) >= MAX_DOCUMENTS or
                            report['manifest_bytes'] + serialized_size > MAX_MANIFEST_BYTES):
                        raise ValueError('local snapshot size limit exceeded')
                    report['manifest_bytes'] += serialized_size
                    documents.append(doc)
    except OSError:
        raise ValueError('local session scan unavailable or changed; prior snapshot retained') from None
    except ValueError as error:
        # Own errors are generic; imported readers also deliberately use generic
        # errors. Do not include paths or contents in public diagnostics.
        raise ValueError('local refresh aborted: ' + str(error)) from None
    report['documents'] = len(documents)
    report['elapsed_ms'] = round((time.monotonic() - started) * 1000, 3)
    return dict(schema_version=1, documents=documents, import_report=report,
                refreshed_source_ids=refreshed, excluded_source_ids=excluded)
