"""User-turn recall with preceding context. Candidates, never standing rules."""
from collections import Counter, defaultdict
import math
import re
import time

VERSION = 'user-context-bm25-v8'
TRIGGERS = ('resume', 'ambiguous', 'explicit')
INJECTED_PREFIXES = ('# AGENTS.md', 'Stop hook feedback:', '[exploration-budget]',
    'Base directory for this skill:', 'Another Claude session sent a message:',
    '<environment_context>', '<system-reminder>', '<turn_aborted>', '<app-context>')


def validate_spans(text, first, last, spans):
    if not isinstance(spans, list) or not spans:
        raise ValueError('invalid message spans')
    cursor, previous_line = 0, first - 1
    for m in spans:
        if not isinstance(m, dict) or set(m) != {'line', 'role', 'start', 'end'}:
            raise ValueError('invalid message span')
        if any(type(m[k]) is not int for k in ('line', 'start', 'end')):
            raise ValueError('invalid message coordinates')
        if m['role'] not in ('user', 'assistant') or not previous_line < m['line'] <= last:
            raise ValueError('invalid message order')
        prefix = f"[line {m['line']}] {m['role']}: "
        if not text.startswith(prefix, cursor) or m['start'] != cursor + len(prefix):
            raise ValueError('message boundary mismatch')
        if not m['start'] < m['end'] <= len(text):
            raise ValueError('invalid message end')
        if m['end'] < len(text) and text[m['end']] != '\n':
            raise ValueError('invalid message separator')
        cursor, previous_line = m['end'] + 1, m['line']
    if cursor != len(text) + 1:
        raise ValueError('incomplete message spans')
    return spans


def conversational(text):
    # Known injected frames only. User role does not prove human authorship.
    # A review model's report is a tool-injected user-role envelope, not a
    # human correction. Keep it in ordinary history, but not in this view.
    stripped = text.lstrip()
    if re.match(r'^<heartbeat(?:\s[^>]*|)>', stripped):
        return False
    if stripped.startswith(('<external_codex_apps_', '<subagent_notification>',
                            '<task-notification>', '<skill>',
                            'This session is being continued from a previous conversation that ran out of context.',
                            '<local-command-stdout>', '<local-command-caveat>', '<command-name>')):
        return False
    if (stripped.startswith('<user_action>')
            and '<context>User initiated a review task.' in stripped[:200]
            and 'full review output from reviewer model.' in stripped[:250]):
        return False
    return bool(text.strip()) and not stripped.startswith(INJECTED_PREFIXES + (
        'あなたは作業セッションの引き継ぎカード', 'あなたは探索セッションの評価者'))


def units(snapshot):
    from retrieval_live import bridge_session_prompt, generated_session_prompt
    groups = defaultdict(list)
    missing = 0
    for d in snapshot['documents']:
        if d.get('source_kind') == 'agent_consultation':
            continue
        spans = d.get('message_spans')
        if spans is None:
            missing += 1
            continue
        validate_spans(d['text'], d['start_line'], d['end_line'], spans)
        for m in spans:
            groups[d['source_id']].append(dict(line=m['line'], role=m['role'],
                text=d['text'][m['start']:m['end']], citation_id=d['citation_id']))
    result = []
    for source, messages in groups.items():
        ordered = sorted(messages, key=lambda x: (x['line'], x['citation_id']))
        first_user = next((m for m in ordered if m['role'] == 'user'), None)
        if first_user and (bridge_session_prompt(first_user['text']) or
                           generated_session_prompt(first_user['text'])):
            continue
        request = response = None
        automated_turn = False
        for m in ordered:
            if not conversational(m['text']):
                if m['role'] == 'user':
                    request = response = None
                    automated_turn = True
                continue
            if m['role'] == 'assistant':
                if not automated_turn:
                    response = m
                continue
            automated_turn = False
            result.append(dict(source_id=source, utterance=m, request=request, prior_response=response))
            request, response = m, None
    return result, missing


def context_tokens(text):
    """Keep compound identifiers intact; a ticket suffix is not a bare PR ID."""
    from retrieval_lab import tokens
    compound = re.compile(r'(?<![a-zA-Z0-9_])[a-zA-Z][a-zA-Z0-9_]*-\d+(?![a-zA-Z0-9_-])')
    identifiers = [m.group().lower() for m in compound.finditer(text)]
    return tokens(compound.sub(' ', text)) + identifiers


def query_weights(tokens):
    """Retain kana-only queries; soften kana fragments in mixed queries.

    Character bigrams give conversational Japanese many independent votes.
    Half weight keeps those matches (including negation) while reducing their
    ability to swamp subject words. This is a lexical heuristic, not a parser
    or a claim that hiragana words carry no meaning.
    """
    kana = {t for t in tokens if re.fullmatch(r'[\u3041-\u3096ー]+', t)}
    mixed = bool(tokens - kana)
    return {t: .5 if mixed and t in kana else 1.0 for t in sorted(tokens)}


def compound_fragments(query):
    """Group long katakana query words without a domain-specific dictionary.

    Keep fragments that also occur outside those words at their normal weight.
    This is soft lexical evidence, not semantic domain classification.
    """
    pattern = re.compile(r'[ァ-ヺー]{4,}')
    words = set(pattern.findall(query))
    independent = set(context_tokens(pattern.sub(' ', query)))
    return {token: sorted(word for word in words if token in context_tokens(word))
            for word in words for token in context_tokens(word)
            if token not in independent}


def retrieve(snapshot, query, limit, *, scope=None, rank_refs=()):
    started = time.perf_counter()
    items, missing = units(snapshot)
    q = set(context_tokens(query))
    weights = query_weights(q)
    fragments = compound_fragments(query)
    # Prospective task/need only; never outcomes or inferred standing preferences.
    # Exclude query tokens so an ambiguous shared word cannot vote twice.
    scope_q = set(context_tokens((scope or '')[:2000])) - q
    scope_weights = query_weights(scope_q)
    scope_scores = [0.0] * len(items)
    scores = [0.0] * len(items)
    contributions = [[] for _ in items]
    for field, weight in [('utterance', 1.0), ('context', 0.2)]:
        counts, texts, frequency = [], [], Counter()
        for item in items:
            text = item['utterance']['text'] if field == 'utterance' else '\n'.join(
                item[k]['text'][:2000] for k in ('request', 'prior_response') if item[k])
            c = Counter(context_tokens(text))
            # A one-character Japanese query must also match inside an
            # unsegmented sentence. Do not duplicate standalone occurrences.
            for token in q | scope_q:
                if len(token) == 1 and re.fullmatch(r'[\u3040-\u30ff\u3400-\u9fff]', token):
                    occurrences = text.count(token)
                    if occurrences:
                        c[token] = occurrences
            counts.append(c)
            texts.append(text)
            frequency.update(c.keys())
        average = sum(sum(c.values()) for c in counts) / max(1, len(items))
        for i, c in enumerate(counts):
            length = sum(c.values())
            for token in sorted((q | scope_q) & c.keys()):
                idf = math.log(1 + (len(items) - frequency[token] + .5) / (frequency[token] + .5))
                contribution = (weights.get(token, scope_weights.get(token, 1.0))) * weight * idf * c[token] * 2.2 / (
                    c[token] + 1.2 * (.25 + .75 * length / max(1, average)))
                if token in scope_q:
                    scope_scores[i] += contribution
                    continue
                owners = fragments.get(token, ())
                compound_weight = .25 if owners and not any(word in texts[i] for word in owners) else 1.0
                contribution *= compound_weight
                scores[i] += contribution
                contributions[i].append(dict(field=field, token=token, score=contribution, query_weight=weights[token], compound_weight=compound_weight))
    lexical_scores = list(scores)
    # At most double a lexical match. Scope cannot introduce query-unmatched
    # candidates or hard-exclude other domains. Missing scope keeps lexical order.
    bonuses = [min(base, support) for base, support in zip(scores, scope_scores)]
    scores = [base + bonus for base, bonus in zip(scores, bonuses)]
    scope_details = {(x['source_id'], x['utterance']['line']):
                     dict(lexical_score=base, scope_score=support, scope_bonus=bonus)
                     for x, base, support, bonus in zip(items, lexical_scores, scope_scores, bonuses)}
    ranked = sorted(((s, x, detail) for s, x, detail in zip(scores, items, contributions) if s > 0),
                    key=lambda pair: (-pair[0], pair[1]['source_id'], pair[1]['utterance']['line']))
    reference_keys = {(r['citation_id'], r['line']) for r in rank_refs}
    reference_ranks = [dict(citation_id=x['utterance']['citation_id'], line=x['utterance']['line'], rank=rank)
                       for rank, (_, x, _) in enumerate(ranked, 1)
                       if (x['utterance']['citation_id'], x['utterance']['line']) in reference_keys]
    hits = []
    for rank, (score, item, detail) in enumerate(ranked[:limit], 1):
        hit = dict(rank=rank, score=score, source_id=item['source_id'],
                   citation_id=item['utterance']['citation_id'], line=item['utterance']['line'],
                   explanation=dict(contributions=sorted(detail, key=lambda d: (-d['score'], d['field'], d['token'])),
                                    matched_tokens=sorted({d['token'] for d in detail}),
                                    unmatched_tokens=sorted(q - {d['token'] for d in detail})))
        for key in ('utterance', 'request', 'prior_response'):
            m = item[key]
            hit[key] = dict(m, text=m['text'][:1600], truncated=len(m['text']) > 1600) if m else None
        hit['explanation'].update(scope_details[(item['source_id'], item['utterance']['line'])])
        hits.append(hit)
    return dict(arm='recorder', snapshot_id=snapshot['snapshot_id'], retrieval_version=VERSION,
                mode='corrections', hits=hits, candidate_count=len(items),
                **(dict(reference_ranks=reference_ranks) if rank_refs else {}),
                diagnostics_version=4, query_tokens=sorted(q), query_weights=weights,
                scope_tokens=sorted(scope_q), scope=scope,
                scored_candidate_count=len(ranked),
                legacy_documents_skipped=missing,
                consultation_sources_skipped=len({d['source_id'] for d in snapshot['documents']
                                                  if d.get('source_kind') == 'agent_consultation'}),
                notice='User-role candidates, not verified corrections or standing instructions. Read originals and check current scope. Prior context may be incomplete.',
                metrics=dict(elapsed_ms=(time.perf_counter()-started)*1000,
                             input_tokens=None, output_tokens=None, cost_microusd=None))
