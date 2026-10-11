"""User-turn recall with preceding context. Candidates, never standing rules."""
from collections import Counter, defaultdict
import math
import time

VERSION = 'user-context-bm25-v1'
TRIGGERS = ('resume', 'ambiguous', 'explicit')


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
    return bool(text.strip()) and not text.lstrip().startswith((
        '<', '# AGENTS.md', 'Stop hook feedback:', '[exploration-budget]',
        'あなたは作業セッションの引き継ぎカード', 'あなたは探索セッションの評価者'))


def units(snapshot):
    groups = defaultdict(list)
    missing = 0
    for d in snapshot['documents']:
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
        request = response = None
        for m in sorted(messages, key=lambda x: (x['line'], x['citation_id'])):
            if not conversational(m['text']):
                continue
            if m['role'] == 'assistant':
                response = m
                continue
            result.append(dict(source_id=source, utterance=m, request=request, prior_response=response))
            request, response = m, None
    return result, missing


def retrieve(snapshot, query, limit):
    from retrieval_lab import tokens
    started = time.perf_counter()
    items, missing = units(snapshot)
    q = set(tokens(query))
    scores = [0.0] * len(items)
    for field, weight in [('utterance', 1.0), ('context', 0.2)]:
        counts, frequency = [], Counter()
        for item in items:
            text = item['utterance']['text'] if field == 'utterance' else '\n'.join(
                item[k]['text'][:2000] for k in ('request', 'prior_response') if item[k])
            c = Counter(tokens(text))
            counts.append(c)
            frequency.update(c.keys())
        average = sum(sum(c.values()) for c in counts) / max(1, len(items))
        for i, c in enumerate(counts):
            length = sum(c.values())
            for token in q & c.keys():
                idf = math.log(1 + (len(items) - frequency[token] + .5) / (frequency[token] + .5))
                scores[i] += weight * idf * c[token] * 2.2 / (
                    c[token] + 1.2 * (.25 + .75 * length / max(1, average)))
    ranked = sorted(((s, x) for s, x in zip(scores, items) if s > 0),
                    key=lambda pair: (-pair[0], pair[1]['source_id'], pair[1]['utterance']['line']))
    hits = []
    for rank, (score, item) in enumerate(ranked[:limit], 1):
        hit = dict(rank=rank, score=score, source_id=item['source_id'],
                   citation_id=item['utterance']['citation_id'], line=item['utterance']['line'])
        for key in ('utterance', 'request', 'prior_response'):
            m = item[key]
            hit[key] = dict(m, text=m['text'][:1600], truncated=len(m['text']) > 1600) if m else None
        hits.append(hit)
    return dict(arm='recorder', snapshot_id=snapshot['snapshot_id'], retrieval_version=VERSION,
                mode='corrections', hits=hits, candidate_count=len(items),
                legacy_documents_skipped=missing,
                notice='User-role candidates, not verified corrections or standing instructions. Read originals and check current scope. Prior context may be incomplete.',
                metrics=dict(elapsed_ms=(time.perf_counter()-started)*1000,
                             input_tokens=None, output_tokens=None, cost_microusd=None))
