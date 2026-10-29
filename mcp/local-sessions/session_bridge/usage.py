"""Allowlisted provider accounting. Never persist raw events or pricing guesses."""
from __future__ import annotations

import math


def number(value, *, integer=False):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    if not math.isfinite(value) or value < 0 or (integer and not isinstance(value, int)):
        return None
    return value


def accounting(provider, event):
    kind = event.get('type')
    if (provider, kind) not in (('claude', 'result'), ('codex', 'turn.completed')):
        return None
    raw = event.get('usage')
    raw = raw if isinstance(raw, dict) else {}
    values = {
        'provider': provider,
        'source': kind,
        'token_scope': 'session_cumulative' if provider == 'codex' else 'turn_main_loop',
        'input_tokens': number(raw.get('input_tokens'), integer=True),
        'output_tokens': number(raw.get('output_tokens'), integer=True),
        'cache_read_input_tokens': number(raw.get('cache_read_input_tokens' if provider == 'claude' else 'cached_input_tokens'), integer=True),
        'cache_creation_input_tokens': number(raw.get('cache_creation_input_tokens' if provider == 'claude' else 'cache_write_input_tokens'), integer=True),
        'input_includes_cache': provider == 'codex',
        'estimated_session_cost_usd': number(event.get('total_cost_usd')) if provider == 'claude' else None,
    }
    if provider == 'claude':
        creation = raw.get('cache_creation')
        if isinstance(creation, dict):
            values['cache_creation'] = {key: number(creation.get(key), integer=True) for key in
                ('ephemeral_5m_input_tokens', 'ephemeral_1h_input_tokens')}
    # Missing accounting is unknown, never a zero-cost turn or a cache miss.
    return values
