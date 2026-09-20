"""Mine bounded, local same-session resumption cases with temporal holdouts.

Conversation only; no model calls, writes, or tool output extraction. Histories
end before the resumption prompt. Future text is for separate evaluation only.
"""
from __future__ import annotations

from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import time

from retrieval_live import _discover, _excluded, _tool_inputs, source_id
from retrieval_snapshot import _message, _read

MAX_SOURCE_BYTES = 64 * 1024 * 1024
MAX_TOTAL_BYTES = 512 * 1024 * 1024
MAX_HISTORY_MESSAGES = 24
MAX_HISTORY_CHARS = 30_000
MAX_FUTURE_MESSAGES = 6
MAX_FUTURE_CHARS = 12_000
CUE = re.compile(r'続き|再開|前回|昨日|\b(?:resume|continue|pick\s+up)\b', re.IGNORECASE)
EVAL_COMMAND = re.compile(r'(?<![A-Za-z0-9_-])(?:resume_replay\.py|resume_cases\.py|flight-recorder-resume)(?![A-Za-z0-9_-])')


def digest(raw: bytes) -> str:
    return 'sha256:' + hashlib.sha256(raw).hexdigest()


def _timestamp(value):
    if not isinstance(value, str):
        return None
    try:
        parsed = datetime.fromisoformat(value.replace('Z', '+00:00'))
        return parsed.astimezone(timezone.utc) if parsed.tzinfo is not None else None
    except (ValueError, OverflowError):
        return None


def _eval_call(value, adapter):
    for argument in _tool_inputs(value, adapter):
        encoded = argument if isinstance(argument, str) else json.dumps(argument, ensure_ascii=True)
        if EVAL_COMMAND.search(encoded):
            return True
    return False


def _human_request(value, adapter, text):
    """Return candidate request only; history/citation retains original text."""
    if value.get('isMeta') or value.get('isCompactSummary'):
        return None
    if any(tag in text for tag in ('<task-notification', '<local-command-stdout',
                                   '<local-command-stderr', '<command-name')):
        return None
    if text.strip().lower().rstrip('.') == 'continue from where you left off':
        return None
    if adapter == 'codex':
        marker = re.search(r'^## My request:\s*', text, re.MULTILINE)
        if marker:
            text = text[marker.end():].strip()
        else:
            # Ambient app context is not a human request. If an ordinary request
            # follows these known complete blocks, use only the remaining text.
            text = re.sub(r'<(environment_context|in-app-browser-context)>.*?</\1>',
                          '', text, flags=re.DOTALL).strip()
            if text.startswith(('<', '# AGENTS.md')):
                return None
    if not text.strip():
        return None
    return text.strip()


def _bounded(messages, *, count, chars, newest, report, counter):
    selected = []
    used = 0
    for message in reversed(messages) if newest else messages:
        if len(selected) >= count or used + len(message['text']) > chars:
            report[counter] += 1
            continue
        used += len(message['text'])
        selected.append(message)
    return list(reversed(selected)) if newest else selected


def mine_cases(roots: list[tuple[str, Path]], limit: int = 10,
               exclude_sessions: list[str] | None = None, *,
               include_gap_candidates: bool = False) -> dict:
    """Newest eligible resumption per source, then newest resumptions overall.

    Eligibility requires a short explicit user cue, timestamps with >=30 minute
    gap, preceding conversational history, and a subsequent assistant message.
    Session-wide recall/evaluation calls and subagents are conservatively omitted.
    Automation/compaction pseudo-user messages never count as human requests.
    include_gap_candidates explicitly opts into keyword-free gap candidates;
    these are labeled same_session_gap and require manual triage. All mined
    candidates need triage before evaluation; a cue alone does not prove intent.
    No ranking or case identifiers use future message content.
    """
    if type(include_gap_candidates) is not bool:
        raise ValueError('include_gap_candidates must be boolean')
    if type(limit) is not int or not 1 <= limit <= 100:
        raise ValueError('case limit must be between 1 and 100')
    if exclude_sessions is None:
        exclude_sessions = []
    if not isinstance(exclude_sessions, list) or any(
        not isinstance(item, str) or not item or len(item) > 256 for item in exclude_sessions
    ):
        raise ValueError('invalid session exclusions')
    exclusions = set(exclude_sessions)
    started = time.monotonic()
    report = dict(discovered_sources=0, missing_roots=0, symlinks_skipped=0,
                  bytes_read=0, scanned_sources=0, excluded_configured_sessions=0,
                  excluded_subagent_sessions=0, excluded_retrieval_sessions=0,
                  excluded_evaluation_sessions=0, excluded_malformed_sessions=0,
                  malformed_lines=0, partial_sources=0, cue_messages=0,
                  missing_timestamps=0, insufficient_gap=0, missing_history=0,
                  missing_future_assistant=0, omitted_history_messages=0,
                  omitted_future_messages=0, eligible_sources=0, selected_cases=0,
                  automation_messages_omitted=0, gap_only_candidates=0)
    candidates = []
    try:
        for _mtime, adapter, path, size in _discover(roots, report):
            reason = None
            if any(re.search(r'(?<![A-Za-z0-9])' + re.escape(item) + r'(?![A-Za-z0-9])', path.stem)
                   for item in exclusions):
                reason = 'configured'
            elif adapter == 'claude-code' and 'subagents' in path.parts:
                reason = 'subagent'
            if reason:
                report[f'excluded_{reason}_sessions'] += 1
                continue
            if size > MAX_SOURCE_BYTES or report['bytes_read'] + size > MAX_TOTAL_BYTES:
                raise ValueError('source byte limit exceeded')
            raw = _read(path, MAX_SOURCE_BYTES)
            report['bytes_read'] += len(raw)
            if len(raw) > MAX_SOURCE_BYTES or report['bytes_read'] > MAX_TOTAL_BYTES:
                raise ValueError('source byte limit exceeded')
            report['scanned_sources'] += 1
            if raw and not raw.endswith(b'\n'):
                report['partial_sources'] += 1
            lines = raw.split(b'\n')[:-1]
            identity = source_id(adapter, path)
            messages = []
            requests = {}
            prefix_offsets = [0]
            for number, line in enumerate(lines, 1):
                prefix_offsets.append(prefix_offsets[-1] + len(line) + 1)
                try:
                    value = json.loads(line)
                except (ValueError, RecursionError):
                    report['malformed_lines'] += 1
                    reason = 'malformed'
                    break
                if not isinstance(value, dict):
                    continue
                reason = _excluded(value, adapter, exclusions)
                if reason in (None, 'retrieval') and _eval_call(value, adapter):
                    reason = 'evaluation'
                if reason:
                    break
                message = _message(value, adapter)
                if message:
                    role, text = message
                    if role == 'user':
                        request = _human_request(value, adapter, text)
                        if request is None:
                            report['automation_messages_omitted'] += 1
                            continue
                        requests[number] = request
                    stamp = _timestamp(value.get('timestamp'))
                    citation = digest(json.dumps([identity, number, text], ensure_ascii=True).encode())
                    messages.append(dict(citation_id=citation, line=number, role=role, text=text,
                                         timestamp=stamp.isoformat() if stamp else None))
            if reason:
                report[f'excluded_{reason}_sessions'] += 1
                continue
            # Sort resume events only by their own timestamp/line, never holdout
            # content or file mtime (which can be changed by future activity).
            eligible = []
            for index, message in enumerate(messages):
                prompt = requests.get(message['line'])
                if message['role'] != 'user' or not prompt or len(prompt) > 1000:
                    continue
                has_cue = bool(CUE.search(prompt))
                if not has_cue and not include_gap_candidates:
                    continue
                if has_cue:
                    report['cue_messages'] += 1
                if index == 0:
                    report['missing_history'] += 1
                    continue
                stamp = _timestamp(message['timestamp'])
                prior = _timestamp(messages[index - 1]['timestamp'])
                if stamp is None or prior is None:
                    report['missing_timestamps'] += 1
                    continue
                if (stamp - prior).total_seconds() < 1800:
                    report['insufficient_gap'] += 1
                    continue
                if not any(item['role'] == 'assistant' for item in messages[index + 1:]):
                    report['missing_future_assistant'] += 1
                    continue
                method = 'explicit_resume_cue' if has_cue else 'same_session_gap'
                if not has_cue:
                    report['gap_only_candidates'] += 1
                eligible.append((stamp, message['line'], index, method))
            for _stamp, _line, index, method in sorted(eligible, reverse=True):
                resume = messages[index]
                history = _bounded(messages[:index], count=MAX_HISTORY_MESSAGES, chars=MAX_HISTORY_CHARS,
                                   newest=True, report=report, counter='omitted_history_messages')
                if not history:
                    report['missing_history'] += 1
                    continue
                future = _bounded(messages[index + 1:], count=MAX_FUTURE_MESSAGES, chars=MAX_FUTURE_CHARS,
                                  newest=False, report=report, counter='omitted_future_messages')
                if not any(item['role'] == 'assistant' for item in future):
                    report['missing_future_assistant'] += 1
                    continue
                prefix = digest(raw[:prefix_offsets[resume['line'] - 1]])
                case_id = digest(json.dumps([identity, prefix, resume['line'], requests[resume['line']]],
                                            ensure_ascii=True).encode())
                candidates.append(dict(case_id=case_id, source_id=identity, prefix_sha256=prefix,
                                       cutoff_line=resume['line'] - 1, resume_line=resume['line'],
                                       resume_prompt=requests[resume['line']], resumed_at=resume['timestamp'],
                                       selection_method=method, requires_triage=True,
                                       history=history, future=future))
                report['eligible_sources'] += 1
                break
    except OSError:
        raise ValueError('local case scan unavailable or changed') from None
    cases = sorted(candidates, key=lambda c: (c['resumed_at'], c['case_id']), reverse=True)[:limit]
    report['selected_cases'] = len(cases)
    report['elapsed_ms'] = round((time.monotonic() - started) * 1000, 3)
    return dict(schema_version=1, cases=cases, report=report)
