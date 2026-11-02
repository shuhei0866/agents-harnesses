"""One explicit subscription-model fallback after a pre-generation quota refusal."""
from __future__ import annotations

import os
import re


QUOTA_REFUSALS = (
    re.compile(r"^you're out of usage credits(?:\b|[.!])", re.I),
    re.compile(r"^you've hit your (?:usage )?limit(?:\b|[.!])", re.I),
    re.compile(r"^usage limit (?:reached|exceeded)(?:\b|[.!])", re.I),
)


def is_fable(model):
    return isinstance(model, str) and (model.lower() == 'fable'
        or model.lower().startswith('claude-fable-'))


def quota_fallback(session, events, status):
    """Do not retry uncertain turns, partial generation, auth or budget errors.

    CLI result.is_error must confirm a failed provider turn. Natural-language
    assistant answers, stderr, generic 429s and success text are not evidence.
    The opt-in subscription environment remains the same; no API route/login is
    read, changed or tried. A returned alias is a request, not an observed model.
    """
    if (session['provider'] != 'claude' or status != 'failed'
            or os.environ.get('SESSION_BRIDGE_CLAUDE_AUTH') != 'subscription'
            or events.auth_source == 'other'
            or not events.terminal_error or not events.native_id
            or events.generation_seen
            or events.progress['thinking_deltas'] or events.progress['answer_chars']):
        return None
    if any(os.environ.get(key) not in (None, '', '0', 'false', 'False') for key in
           ('CLAUDE_CODE_USE_BEDROCK', 'CLAUDE_CODE_USE_VERTEX', 'CLAUDE_CODE_USE_FOUNDRY',
            'ANTHROPIC_BASE_URL')):
        return None
    if not is_fable(events.actual_model or session['model']):
        return None
    if events.usage and events.usage.get('output_tokens') not in (None, 0):
        return None
    if not any(pattern.match((events.error or '').strip()) for pattern in QUOTA_REFUSALS):
        return None
    target = os.environ.get('SESSION_BRIDGE_CLAUDE_QUOTA_FALLBACK_MODEL', 'opus')
    if not target:
        return None
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}', target):
        raise ValueError('Invalid SESSION_BRIDGE_CLAUDE_QUOTA_FALLBACK_MODEL')
    if is_fable(target):
        return None
    return target
