"""One opt-in query-only fallback, linked to the original decision need."""
import copy
import json
import time
import uuid

VERSION = 'query-supplement-v1'


def excerpt(message, weights):
    if not message:
        return None
    text = message['text']; budget = 240
    starts = list(range(0, max(1, len(text) - budget + 1), 80)) + [max(0, len(text) - budget)]
    start = max(starts, key=lambda s: sum(w for t, w in weights.items() if t.casefold() in text[s:s+budget].casefold()))
    end = min(len(text), start + budget)
    return dict(message, text=text[start:end], excerpt_start=start, excerpt_end=end,
                truncated=start > 0 or end < len(text) or message.get('truncated', False))


def select(snapshot, query, primary):
    from retrieval_context import retrieve
    ranked = retrieve(snapshot, query, 3)
    keys = {(h['source_id'], h['line']) for h in primary}
    bodies = {tuple((h.get(k) or {}).get('text', '') for k in ('utterance', 'request', 'prior_response')) for h in primary}
    for hit in ranked['hits']:
        if (hit['source_id'], hit['line']) in keys or tuple((hit.get(k) or {}).get('text', '') for k in ('utterance', 'request', 'prior_response')) in bodies:
            continue
        h = copy.deepcopy(hit); weights = {}
        for c in h['explanation']['contributions']:
            weights[c['token']] = weights.get(c['token'], 0) + c['score']
        h['query_rank'] = h['rank']; h['rank'] = 1
        h['utterance'] = excerpt(h['utterance'], weights)
        contexts = [(k, excerpt(h[k], weights)) for k in ('request', 'prior_response') if h[k]]
        selected = max(contexts, key=lambda p: sum(w for t,w in weights.items() if t.casefold() in p[1]['text'].casefold())) if contexts else (None, None)
        for k in ('request', 'prior_response'):
            h[k] = selected[1] if k == selected[0] else None
        h['explanation'].pop('contributions', None)
        return [h]
    return []


def open_supplement(root, parent_id):
    import retrieval_lab as lab
    from retrieval_context import VERSION as ranker_version, retrieve
    with lab.snapshot_lock(root), lab._connect(root) as db:
        db.execute('BEGIN IMMEDIATE')
        row = lab._row(db, parent_id); parent = json.loads(row['foreground'])
        need = parent.get('decision_need', {})
        if (parent.get('mode') != 'corrections' or not need or need.get('retry_of')
                or parent.get('supplement') or row['limit_n'] != 3):
            raise ValueError('supplement requires an initial three-candidate decision search')
        for prior in db.execute('SELECT foreground FROM queries'):
            value = json.loads(prior[0])
            if value.get('supplement', {}).get('parent_request_id') == parent_id:
                return dict(value, replayed=True)
        tables = {r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        match = db.execute('SELECT match FROM context_decision_matches WHERE request_id=?', (parent_id,)).fetchone() if 'context_decision_matches' in tables else None
        if not match or match[0] != 'not_found':
            raise ValueError('record not_found for the primary search before opening a supplement')
        if parent.get('retrieval_version') != ranker_version:
            raise ValueError('ranker changed; start a new decision search')
        siblings = [json.loads(r[0]) for r in db.execute('SELECT foreground FROM queries')]
        if any(v.get('decision_need', {}).get('retry_of') == parent_id for v in siblings):
            raise ValueError('supplement must precede the focused retry')
        snapshot = lab._snapshot(root, parent['snapshot_id'])
        hits = select(snapshot, row['query'], parent['hits'])
        if hits:
            scope = '\n'.join(x for x in (parent['origin'].get('task'), need['text']) if x)
            ranks = retrieve(snapshot, row['query'], 0, scope=scope or None, rank_refs=hits)['reference_ranks']
            hits[0]['scope_rank'] = ranks[0]['rank'] if ranks else None
        primary_reads = list(db.execute('SELECT citation_id,returned_bytes FROM reads WHERE request_id=?', (parent_id,)))
        chars = sum(len(h[k]['text']) for h in hits for k in ('utterance','request','prior_response') if h[k])
        result = dict(request_id=uuid.uuid4().hex, mode='corrections', arm='recorder',
            snapshot_id=parent['snapshot_id'], retrieval_version=ranker_version,
            trigger=parent['trigger'], purpose=parent.get('purpose','task'), origin=parent['origin'],
            decision_need=dict(need, retry_of=None), hits=hits, sampled=False,
            sampling_skip_reason='supplement_has_no_paired_shadow',
            supplement=dict(version=VERSION,parent_request_id=parent_id,primary_match='not_found',
                            opened_at=time.time(),preview_characters=chars,candidate_count=len(hits),
                            primary_source_read_count=len(primary_reads),
                            primary_distinct_sources_read=len({r['citation_id'] for r in primary_reads}),
                            primary_source_returned_bytes=sum(r['returned_bytes'] for r in primary_reads),
                            query_rank=hits[0]['query_rank'] if hits else None,
                            scope_rank=hits[0]['scope_rank'] if hits else None),
            notice='Separate query-only fallback, not a verified judgment. Partial excerpts: read the original before use. Record context-use against this request ID.')
        db.execute('INSERT INTO queries(id,created,query,snapshot_id,version,arm,limit_n,foreground,job_state) VALUES(?,?,?,?,?,?,?,?,?)',
                   (result['request_id'],time.time(),row['query'],parent['snapshot_id'],ranker_version,'recorder',1,lab.canonical(result),'not_sampled'))
        return result


def observations(db, rows, boundary=None, has_followup=False):
    """Reads are tool-return volume, not inferred reading time or attention."""
    tables = {r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
    records = []
    for row in rows:
        result = json.loads(row['foreground']); meta = result.get('supplement')
        if not meta:
            continue
        reads = list(db.execute('SELECT created,returned_bytes FROM reads WHERE request_id=?', (row['id'],)))
        use = db.execute('SELECT state,recorded FROM context_uses WHERE request_id=?', (row['id'],)).fetchone() if 'context_uses' in tables else None
        match = db.execute('SELECT match FROM context_decision_matches WHERE request_id=?', (row['id'],)).fetchone() if 'context_decision_matches' in tables else None
        timely = boundary is not None and row['created'] < boundary
        timely_use = timely and use is not None and use['recorded'] < boundary
        records.append(dict(request_id=row['id'], **meta,created=row['created'],
            source_read_count=len(reads),source_returned_bytes=sum(r['returned_bytes'] for r in reads),
            decision_match=match[0] if match else 'unknown',use_state=use['state'] if use else None,
            opened_before_followup=timely if has_followup else None,
            reported_before_followup=timely_use if has_followup else None,
            decision_match_before_followup=match[0] if has_followup and timely_use and match else 'unknown',
            source_read_count_before_followup=sum(r['created']<boundary for r in reads) if has_followup else None,
            source_bytes_before_followup=sum(r['returned_bytes'] for r in reads if r['created']<boundary) if has_followup else None))
    return dict(version=VERSION,requests=len(records),records=records,
                actual_followup_observed=has_followup,
                candidate_exposures=sum(len(json.loads(r['foreground']).get('hits', [])) for r in rows),
                notice='Agent self-report and returned volume only; missing data, no reply and silence are not success. Reading time and causal savings are unmeasured.')
