"""Bounded local conversational-log collection for incremental recall refresh.

Read-only: caller owns publishing and must keep the prior snapshot on failure.
A selected session is rescanned in full to isolate retrieval/evaluation feedback,
then only complete LF-terminated JSONL records are indexed. No model calls.
"""
from __future__ import annotations

import datetime as dt
import hashlib
import json
import math
import os
from pathlib import Path
import re
import stat
import shutil
import subprocess
import time

from retrieval_snapshot import _message
from retrieval_context import INJECTED_PREFIXES

MAX_FILES = 10_000
MAX_ENTRIES = 100_000
READ_BLOCK_BYTES = 1024 * 1024
MAX_SOURCE_BYTES = 1024 * 1024 * 1024
MAX_TOTAL_BYTES = 4 * 1024 * 1024 * 1024
MAX_LINE_BYTES = 8 * 1024 * 1024
MAX_DOCUMENTS = 20_000
MAX_DOCUMENT_CHARS = 100_000
MAX_MANIFEST_BYTES = 60 * 1024 * 1024
WINDOW_LINES = 40
ADAPTERS = {'claude-code', 'codex'}
COLLECTOR_VERSION = 'structured-message-context-v11-blocks'


BRIDGE_PROMPT = (
    'You are a continuing discussion partner. Answer the message directly. '
    'Do not use tools, modify files, or invoke another agent. '
    'Messages here are supplied by the bridge caller, not necessarily a human.'
)


def bridge_session_prompt(text: str) -> bool:
    """Known bridge envelope, only at the first user message of a source.

    The whole session shares this provenance: later bridge turns need not repeat
    the envelope. A quoted example or a later discussion must not classify a
    human session as agent consultation. This is a known-frame detector, not authorship inference.
    """
    return text == BRIDGE_PROMPT or text.startswith(BRIDGE_PROMPT + '\n')


def generated_session_prompt(text: str) -> bool:
    """Recognize bundled automation frames, not arbitrary user sentiment.

    Only call for the first user message. Quoted examples and later discussion
    of these prompts must not remove a human conversation.
    """
    return (
        (text.startswith('あなたは作業セッションの引き継ぎカードを書く係。')
         and '\n<transcript>\n' in text and '\n</transcript>' in text
         and '## 現在地' in text and '## 次の一手' in text)
        or (text.startswith('あなたは探索セッションの評価者で、計画者ではない。')
            and '却下するものが無ければ {"rejections": []} と返す。' in text
            and '## 方針\n' in text and '## 台帳の事実\n' in text)
    )

RETRIEVAL_COMMAND = re.compile(
    r'(?<![A-Za-z0-9_-])(?:recall-history|retrieval_lab\.py|retrieval_live\.py|'
    r'retrieval_refresh\.py|retrieval_context\.py|flight-recorder-retrieval|retrieval-live|resume_replay\.py|'
    r'resume_cases\.py|flight-recorder-resume)(?![A-Za-z0-9_-])'
)


def source_id(adapter: str, path: Path) -> str:
    """Stable opaque identity for one adapter's absolute local source path."""
    if adapter not in ADAPTERS or not Path(path).is_absolute():
        raise ValueError('invalid local source identity')
    path = Path(path)
    if path.name.endswith('.jsonl.zst'):
        path = path.with_suffix('')
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
    routine_recall = False
    for argument in _tool_inputs(value, adapter):
        if not isinstance(argument, str):
            argument = json.dumps(argument, ensure_ascii=True)
        matches = RETRIEVAL_COMMAND.findall(argument)
        if matches:
            # Ordinary skill use must not erase the conversation. Low-level
            # evaluation tools and explicit verification retain quarantine.
            if any(name not in ('recall-history', 'flight-recorder-retrieval') for name in matches) or re.search(
                    r'--purpose(?:[=\s]+|[\\\"\']+)+verification', argument):
                return 'retrieval'
            routine_recall = True
    return 'recall' if routine_recall else None


def _directory_identity(path):
    value = path.stat(follow_symlinks=False)
    return (value.st_dev, value.st_ino, value.st_mode, value.st_mtime_ns, value.st_ctime_ns)


def _discover(roots, report, *, directory_stamps=None, include_compressed=False):
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
        if directory_stamps is not None:
            directory_stamps[directory] = _directory_identity(directory)
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
                elif (entry.name.endswith('.jsonl') or (include_compressed and entry.name.endswith('.jsonl.zst'))) and entry.is_file(follow_symlinks=False):
                    identity = (adapter, entry.path)
                    if identity in seen_files:
                        continue
                    seen_files.add(identity)
                    if len(seen_files) > MAX_FILES:
                        raise ValueError('local source count limit exceeded')
                    metadata = entry.stat(follow_symlinks=False)
                    files.append((metadata.st_mtime, adapter, Path(entry.path), metadata.st_size))
    identities = [source_id(adapter, path) for _, adapter, path, _ in files]
    if len(set(identities)) != len(identities):
        raise ValueError('ambiguous compressed source twins')
    report['discovered_sources'] = len(files)
    return sorted(files, key=lambda item: (-item[0], item[1], str(item[2])))


class SourceBudgetExceeded(ValueError):
    """Discard this source's partial output, retain its previous published windows."""


def _block_lines(stream, report):
    """Bound input buffers independently of session size; preserve original LF lines."""
    pending = bytearray()
    while True:
        block = stream.read(min(READ_BLOCK_BYTES, MAX_LINE_BYTES + 1))
        if not block:
            if pending:
                yield bytes(pending)
            return
        report['read_blocks'] = report.get('read_blocks', 0) + 1
        parts = block.split(b'\n')
        for index, part in enumerate(parts):
            pending.extend(part)
            if index < len(parts) - 1:
                pending.append(10)
            if len(pending) > MAX_LINE_BYTES:
                yield bytes(pending[:MAX_LINE_BYTES + 1])
                return
            if index < len(parts) - 1:
                yield bytes(pending)
                pending.clear()


def _records(path: Path, report: dict):
    """Stream bounded records; closing early is allowed only for excluded sources."""
    if any(p.is_symlink() for p in (path, *path.parents)):
        raise ValueError('unsafe input')
    fd = os.open(path, os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0) | os.O_NONBLOCK)
    with os.fdopen(fd, 'rb') as stream:
        before = os.fstat(stream.fileno())
        if not stat.S_ISREG(before.st_mode) or before.st_uid != os.geteuid():
            raise ValueError('unsafe input')
        if before.st_size > MAX_SOURCE_BYTES:
            raise SourceBudgetExceeded('source_byte_budget')
        consumed = 0
        decoder = None
        decoded = stream
        if path.name.endswith('.jsonl.zst'):
            executable = shutil.which('zstd')
            if executable is None:
                raise ValueError('zstd decoder unavailable')
            # Pass the already validated descriptor, never reopen a path in the
            # child. Limit both decoder memory and decompressed output bytes.
            decoder = subprocess.Popen([executable, '-q', '-d', '-c', '-M256MB'],
                                       stdin=stream, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
            decoded = decoder.stdout
        try:
            for line in _block_lines(decoded, report):
                consumed += len(line)
                report['bytes_read'] += len(line)
                if consumed > MAX_SOURCE_BYTES:
                    raise SourceBudgetExceeded('source_byte_budget')
                if report['bytes_read'] > MAX_TOTAL_BYTES:
                    raise SourceBudgetExceeded('total_byte_budget')
                if len(line) > MAX_LINE_BYTES:
                    # Do not omit an unparsed record that might contain an
                    # evaluation command; quarantine this entire source.
                    report['oversized_records'] += 1
                    yield None
                    return
                if not line.endswith(b'\n'):
                    if decoder is not None and decoder.wait() != 0:
                        raise ValueError('invalid compressed source')
                    report['partial_sources'] += 1
                    break
                yield line
            if decoder is not None and decoder.wait() != 0:
                raise ValueError('invalid compressed source')
        finally:
            if decoder is not None:
                decoded.close()
                if decoder.poll() is None:
                    decoder.kill()
                decoder.wait()
            after = os.fstat(stream.fileno())
            current = path.stat(follow_symlinks=False)
            identity = lambda st: (st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns)
            if identity(before) != identity(after) or identity(after) != identity(current):
                raise ValueError('input changed')


def message_time(value):
    raw = value.get('timestamp')
    if not isinstance(raw, str):
        return None
    try:
        parsed = dt.datetime.fromisoformat(raw.replace('Z', '+00:00'))
        return parsed.timestamp() if parsed.tzinfo is not None else None
    except (ValueError, OverflowError):
        return None


def export_live(roots: list[tuple[str, Path]], *, since: float,
                exclude_sessions: list[str] | None = None,
                now: float | None = None, settle_seconds: float = 0,
                known_source_ids: list[str] | None = None) -> dict:
    """Export changed sources, preserving original line ranges and source IDs.

    `since` filters source modification times, not conversation timestamps. Each
    selected source replaces ALL its old windows. Caller must merge untouched
    sources and remove `excluded_source_ids`. A complete source inventory allows
    the caller to retire moved/deleted paths from the current snapshot only.
    Known source IDs let new archive paths bypass the mtime filter.
    With optional settling, deferred sources stay untouched in the caller.
    Budget-exhausted sources keep their prior windows and are explicitly deferred.
    Read races and invalid input still abort the update. Individual text
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
                  excluded_generated_sessions=0, consultation_sources=0, retained_recall_sessions=0,
                  omitted_recall_assistant_messages=0, omitted_injected_messages=0,
                  missing_roots=0, symlinks_skipped=0, malformed_lines=0,
                  partial_sources=0, bytes_read=0, documents=0, manifest_bytes=0,
                  omitted_oversized_lines=0, excluded_malformed_sessions=0,
                  oversized_records=0, excluded_oversized_sessions=0)
    if known_source_ids is not None and (not isinstance(known_source_ids, list) or
            any(not isinstance(item, str) for item in known_source_ids)):
        raise ValueError('invalid known source identifiers')
    known = set(known_source_ids) if known_source_ids is not None else None
    documents = []
    refreshed = []
    excluded = []
    deferred = []
    try:
        directory_stamps = {}
        files = _discover(roots, report, directory_stamps=directory_stamps, include_compressed=True)
        present = [source_id(adapter, path) for _, adapter, path, _ in files]
        for mtime, adapter, path, _size in files:
            identity = source_id(adapter, path)
            if mtime < since and (known is None or identity in known):
                report['unchanged_sources'] += 1
                continue
            document_start = len(documents)
            manifest_before = report['manifest_bytes']
            try:
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
                messages = []
                candidate_bytes = 0
                observations = []
                native_id = None
                chronology_valid = True
                previous_time = None
                source_kind = None
                seen_user = False
                routine_recall = False
                recall_boundary = None
                last_user_line = 0
                line_count = 0
                if report['bytes_read'] >= MAX_TOTAL_BYTES:
                    raise SourceBudgetExceeded('total_byte_budget')
                records = _records(path, report)
                try:
                    for number, line in enumerate(records, 1):
                        if line is None:
                            reason = 'oversized'
                            break
                        line_count = number
                        try:
                            value = json.loads(line)
                        except (ValueError, RecursionError):
                            report['malformed_lines'] += 1
                            reason = 'malformed'
                            break
                        if not isinstance(value, dict):
                            continue
                        stamp = message_time(value)
                        if stamp is not None:
                            if previous_time is not None and stamp < previous_time:
                                chronology_valid = False
                            previous_time = stamp
                        sid = value.get('sessionId') if adapter == 'claude-code' else (
                            value['payload'].get('id') if value.get('type') == 'session_meta' and isinstance(value.get('payload'), dict) else None)
                        if isinstance(sid, str) and len(sid) <= 256:
                            if native_id is not None and native_id != sid:
                                chronology_valid = False
                            native_id = sid
                        found = _excluded(value, adapter, exclusions)
                        if found == 'recall':
                            if observations:
                                observations[-1]['recall_marker'] = True
                            if not routine_recall:
                                recall_boundary = last_user_line
                                kept = [(n, t) for n, t in messages if n < recall_boundary or t.startswith(f'[line {n}] user: ')]
                                report['omitted_recall_assistant_messages'] += len(messages) - len(kept)
                                messages = kept
                                candidate_bytes = sum(len(json.dumps(t, ensure_ascii=True).encode()) for _, t in messages)
                            routine_recall = True
                        elif found:
                            reason = found
                            break
                        message = _message(value, adapter)
                        if message and message[0] == 'user':
                            if not seen_user and bridge_session_prompt(message[1]):
                                source_kind = 'agent_consultation'
                            if not seen_user and generated_session_prompt(message[1]):
                                reason = 'generated'
                                break
                            seen_user = True
                        if message and message[0] == 'user' and message[1].lstrip().startswith(INJECTED_PREFIXES):
                            report['omitted_injected_messages'] += 1
                            continue
                        if message:
                            if message[0] == 'user':
                                if observations:
                                    observations[-1]['closed'] = True
                                observations.append(dict(line=number, timestamp=stamp, closed=False,
                                                         assistant_observed=False, recall_marker=False))
                                last_user_line = number
                            elif observations:
                                observations[-1]['assistant_observed'] = True
                            if routine_recall and message[0] == 'assistant':
                                report['omitted_recall_assistant_messages'] += 1
                                continue
                            text = f'[line {number}] {message[0]}: {message[1]}'
                            if len(text) > MAX_DOCUMENT_CHARS:
                                report['omitted_oversized_lines'] += 1
                            else:
                                candidate_bytes += len(json.dumps(text, ensure_ascii=True).encode())
                                if candidate_bytes > MAX_MANIFEST_BYTES:
                                    raise SourceBudgetExceeded('output_budget')
                                messages.append((number, text))
                finally:
                    records.close()
                if reason:
                    report[f'excluded_{reason}_sessions'] += 1
                    excluded.append(identity)
                    continue
                if routine_recall:
                    # Keep pre-recall context. Drop assistant output starting with
                    # the invoking user turn, including pre-tool commentary, so a
                    # later correction cannot inherit a stale preceding response.
                    report['retained_recall_sessions'] += 1
                    kept = [(n, t) for n, t in messages if n < recall_boundary or t.startswith(f'[line {n}] user: ')]
                    report['omitted_recall_assistant_messages'] += len(messages) - len(kept)
                    messages = kept
                # Streaming is bounded by MAX_SOURCE_BYTES; apply output limits only
                # after removing assistant text that will not enter the corpus.
                if sum(len(json.dumps(t, ensure_ascii=True).encode()) for _, t in messages) > MAX_MANIFEST_BYTES:
                    raise SourceBudgetExceeded('output_budget')
                if source_kind:
                    report['consultation_sources'] += 1
                refreshed.append(identity)
                report['imported_sources'] += 1
                groups = {}
                for number, text in messages:
                    groups.setdefault((number - 1) // WINDOW_LINES, []).append((number, text))
                for window, items in groups.items():
                    start = window * WINDOW_LINES + 1
                    end = min(start + WINDOW_LINES - 1, line_count)
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
                        if source_kind:
                            doc['source_kind'] = source_kind
                        spans, offset = [], 0
                        for rendered in texts:
                            header, body = rendered.split(': ', 1)
                            match = re.fullmatch(r'\[line (\d+)\] (user|assistant)', header)
                            spans.append(dict(line=int(match[1]), role=match[2],
                                              start=offset + len(header) + 2,
                                              end=offset + len(rendered)))
                            offset += len(rendered) + 1
                        doc['message_spans'] = spans
                        user_lines = {m['line'] for m in spans if m['role'] == 'user'}
                        doc['turn_observations'] = [dict(o, timestamp=o['timestamp'] if chronology_valid else None,
                                                           native_session_id=native_id)
                                                    for o in observations if o['line'] in user_lines]
                        serialized_size = len(json.dumps(doc, ensure_ascii=True).encode()) + 2
                        if (len(documents) >= MAX_DOCUMENTS or
                                report['manifest_bytes'] + serialized_size > MAX_MANIFEST_BYTES):
                            raise SourceBudgetExceeded('output_budget')
                        report['manifest_bytes'] += serialized_size
                        documents.append(doc)
            except SourceBudgetExceeded as exc:
                del documents[document_start:]
                report['manifest_bytes'] = manifest_before
                if identity in refreshed:
                    refreshed.remove(identity)
                    report['imported_sources'] -= 1
                deferred.append(dict(source_id=identity, reason=str(exc)))
                report['deferred_sources'] += 1
    except OSError:
        raise ValueError('local session scan unavailable or changed; prior snapshot retained') from None
    except ValueError as error:
        # Own errors are generic; imported readers also deliberately use generic
        # errors. Do not include paths or contents in public diagnostics.
        raise ValueError('local refresh aborted: ' + str(error)) from None
    changed_directories = 0
    for directory, before in directory_stamps.items():
        try:
            changed_directories += _directory_identity(directory) != before
        except OSError:
            changed_directories += 1
    report['changed_directories'] = changed_directories
    report['documents'] = len(documents)
    report['deferred_source_details'] = deferred
    report['collection_complete'] = not deferred
    report['elapsed_ms'] = round((time.monotonic() - started) * 1000, 3)
    return dict(schema_version=1, documents=documents, import_report=report,
                refreshed_source_ids=refreshed, excluded_source_ids=excluded,
                deferred_source_ids=[item['source_id'] for item in deferred],
                present_source_ids=present, inventory_complete=not report['missing_roots'] and not changed_directories)
