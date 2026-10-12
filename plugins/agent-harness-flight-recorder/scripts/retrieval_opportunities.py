"""Local, bounded retrospective candidates for unobserved recall opportunities.

No causal labels: absence of a known tool marker is not proof of no retrieval.
"""
import json
import math
import re
import time
from collections import Counter, defaultdict

VERSION = 'recall-opportunities-v1'
HISTORY = re.compile(r'(?:前に|以前|前回|過去の).{0,24}(?:決め|判断|方針|話|相談|確認|言|伝え)|覚えて|previously decided|as we agreed|last time|earlier decision', re.I)
CORRECTION = re.compile(r'前にも.{0,15}(?:言|伝え)|そうじゃなく|そうではなく|I (?:already|previously) (?:said|told)', re.I)
MAX_CASES = 10
MAX_SECONDS = 8


def validate_observations(value, spans):
    if not isinstance(value, list) or spans is None:
        raise ValueError('invalid turn observations')
    user_lines = {m['line'] for m in spans if m['role'] == 'user'}
    seen = set()
    for o in value:
        if not isinstance(o, dict) or set(o) != {'line', 'timestamp', 'closed', 'assistant_observed', 'recall_marker', 'native_session_id'}:
            raise ValueError('invalid turn observation fields')
        if type(o['line']) is not int or o['line'] not in user_lines or o['line'] in seen:
            raise ValueError('invalid observed turn line')
        seen.add(o['line'])
        if o['timestamp'] is not None and (type(o['timestamp']) not in (float, int) or not math.isfinite(o['timestamp']) or o['timestamp'] < 0):
            raise ValueError('invalid turn timestamp')
        if any(type(o[k]) is not bool for k in ('closed', 'assistant_observed', 'recall_marker')):
            raise ValueError('invalid turn flags')
        sid = o['native_session_id']
        if sid is not None and (not isinstance(sid, str) or not sid or len(sid) > 256):
            raise ValueError('invalid native session identity')
    return value


def turns(snapshot):
    from retrieval_context import units
    items, _ = units(snapshot)
    observations = {(d['source_id'], o['line']): o for d in snapshot['documents']
                    for o in d.get('turn_observations', [])}
    return [dict(x, observation=observations.get((x['source_id'], x['utterance']['line']))) for x in items]


def identity(item):
    # Native identity joins live/archive copies; old sources without it remain distinct.
    from retrieval_lab import digest
    o = item['observation']
    return digest([o.get('native_session_id') or item['source_id'], o['timestamp'], item['utterance']['text']])


def candidates(items, since, now):
    groups = defaultdict(list)
    counts = Counter(total_turns=len(items))
    for item in items:
        o = item['observation']
        if not o or o['timestamp'] is None:
            counts['timestamp_unknown'] += 1
            continue
        groups[item['source_id']].append(item)
    eligible, marked = {}, {}
    seen = set()
    for group in groups.values():
        previous = None
        for item in sorted(group, key=lambda x: x['utterance']['line']):
            o = item['observation']
            if not since <= o['timestamp'] <= now:
                previous = item
                continue
            key = identity(item)
            if key in seen:
                counts['duplicate_turns'] += 1
                previous = item
                continue
            seen.add(key)
            if o['closed'] and o['assistant_observed']:
                counts['closed_answered_turns'] += 1
                if o['recall_marker']:
                    counts['recall_marker_observed'] += 1
                else:
                    counts['no_recall_marker_observed'] += 1
                    eligible[key] = item
            else:
                counts['pending_or_no_answer'] += 1
            text = item['utterance']['text']
            if CORRECTION.search(text) and previous and previous['observation']['timestamp'] >= since:
                # The later correction discovers the case, never supplies query terms.
                marked[identity(previous)] = dict(kind='later_correction', cue=item)
            elif HISTORY.search(text):
                marked[key] = dict(kind='explicit_history_reference', cue=item)
            previous = item
    selected = []
    controls_used = set()
    for key in sorted(marked):
        if key not in eligible:
            continue
        anchor = eligible[key]
        selected.append(dict(key=key, anchor=anchor, **marked[key]))
        # Same source/day controls: descriptive comparison only, not a causal test.
        pool = [(k, v) for k, v in eligible.items() if k not in marked and k not in controls_used
                and v['source_id'] == anchor['source_id']
                and int(v['observation']['timestamp'] // 86400) == int(anchor['observation']['timestamp'] // 86400)]
        if pool:
            k, control = min(pool)
            controls_used.add(k)
            selected.append(dict(key=k, anchor=control, kind='control', cue=None))
    counts['cue_candidates'] = sum(x['kind'] != 'control' for x in selected)
    counts['control_candidates'] = sum(x['kind'] == 'control' for x in selected)
    return selected, dict(counts)


def replay(snapshot, items, target):
    from retrieval_context import retrieve
    anchor = target['anchor']
    when = anchor['observation']['timestamp']
    sid = anchor['observation']['native_session_id']
    docs = []
    for item in items:
        o = item['observation']
        if not o or o['timestamp'] is None or o['timestamp'] >= when:
            continue
        if item['source_id'] == anchor['source_id'] or (sid and o['native_session_id'] == sid):
            continue
        m = item['utterance']
        if m['text'] == anchor['utterance']['text']:
            continue
        prefix = f"[line {m['line']}] user: "
        docs.append(dict(source_id=item['source_id'], citation_id=m['citation_id'],
                         start_line=m['line'], end_line=m['line'], text=prefix + m['text'],
                         message_spans=[dict(line=m['line'], role='user', start=len(prefix), end=len(prefix)+len(m['text']))]))
    query = anchor['utterance']['text'][:600]
    result = retrieve(dict(snapshot_id=snapshot['snapshot_id'], documents=docs), query, 3)
    def excerpt(item):
        return dict(source_id=item['source_id'], line=item['utterance']['line'],
                    citation_id=item['utterance']['citation_id'], text=item['utterance']['text'][:1600],
                    timestamp=item['observation']['timestamp'])
    return dict(kind=target['kind'], anchor=excerpt(anchor), cue=excerpt(target['cue']) if target['cue'] else None,
                query=query, query_truncated=len(anchor['utterance']['text']) > 600,
                recall_observation='no_known_tool_marker', snapshot_id=snapshot['snapshot_id'],
                prior_candidates=len(docs), hits=result['hits'],
                availability_at_turn='unknown', usefulness='unassessed', lineage='native_session_and_exact_text_dedup_only')


def run(root, snapshot, config):
    import retrieval_lab as lab
    since, prospective = config['since'], config['prospective_since']
    if any(type(x) not in (int, float) or not math.isfinite(x) or x < 0 for x in (since, prospective)) or since > prospective:
        raise ValueError('invalid opportunity observation window')
    started = time.monotonic()
    items = turns(snapshot)
    selected, counts = candidates(items, since, time.time())
    selected = [dict(x, key=lab.digest([VERSION, x['key']])) for x in selected]
    with lab._connect(root) as db:
        db.execute('CREATE TABLE IF NOT EXISTS recall_opportunities (id TEXT PRIMARY KEY, version TEXT NOT NULL, recorded REAL NOT NULL, packet TEXT NOT NULL)')
        done = {r[0] for r in db.execute('SELECT id FROM recall_opportunities WHERE version=?', (VERSION,))}
        processed = 0
        pending = [x for x in selected if x['key'] not in done]
        for target in sorted(pending, key=lambda x: x['anchor']['observation']['timestamp']):
            if processed >= MAX_CASES or time.monotonic() - started > MAX_SECONDS:
                break
            packet = replay(snapshot, items, target)
            packet['cohort'] = 'prospective' if packet['anchor']['timestamp'] >= prospective else 'bootstrap_retrospective'
            db.execute('INSERT OR IGNORE INTO recall_opportunities VALUES(?,?,?,?)',
                       (target['key'], VERSION, time.time(), lab.canonical(packet)))
            processed += 1
    return dict(version=VERSION, status='ok', counts=counts, processed=processed,
                pending=len(pending)-processed, since=since, prospective_since=prospective,
                completed_at=time.time(), elapsed_ms=round((time.monotonic()-started)*1000))


def report(root):
    import retrieval_lab as lab
    with lab._connect(root) as db:
        tables = {r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        rows = list(db.execute('SELECT * FROM recall_opportunities WHERE version=? ORDER BY recorded DESC', (VERSION,))) if 'recall_opportunities' in tables else []
    packets = [dict(case_id=r['id'], version=r['version'], **json.loads(r['packet'])) for r in rows]
    groups = {}
    for cohort in ('bootstrap_retrospective', 'prospective'):
        groups[cohort] = {kind: dict(cases=sum(p['cohort']==cohort and p['kind']==kind for p in packets),
                           with_hits=sum(p['cohort']==cohort and p['kind']==kind and bool(p['hits']) for p in packets))
                         for kind in ('explicit_history_reference', 'later_correction', 'control')}
    from retrieval_refresh import status
    return dict(status=status(root).get('opportunities', {'status':'not_started'}), cohorts=groups,
                review_cases=[p for p in packets if p['kind'] != 'control'][:10],
                control_cases=[p for p in packets if p['kind'] == 'control'][:10],
                notice='Candidates only. Later correction text never enters the earlier query. '
                       'Replay uses currently collected earlier user text, not the corpus available then. '
                       'No marker is not proof of no retrieval; aliases, other tools and fork lineage may be unknown. '
                       'Lexical hits do not prove a decision, applicability, missed benefit or causal improvement. '
                       'Open/final turns without a subsequent user boundary remain pending; no silence-based success labels.')


def inspect(root, case_id):
    import retrieval_lab as lab
    with lab._connect(root) as db:
        tables = {r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        row = db.execute('SELECT packet FROM recall_opportunities WHERE id=?', (case_id,)).fetchone() if 'recall_opportunities' in tables else None
    if row is None:
        raise ValueError('unknown opportunity case')
    packet = json.loads(row[0])
    snapshot = lab._snapshot(root, packet['snapshot_id'])
    docs = {d['citation_id']: d for d in snapshot['documents']}
    originals = []
    for reference in [packet['anchor'], packet['cue'], *packet['hits']]:
        if not reference:
            continue
        doc = docs[reference['citation_id']]
        span = next(m for m in doc['message_spans'] if m['role']=='user' and m['line']==reference['line'])
        originals.append(dict(source_id=doc['source_id'], line=span['line'], citation_id=doc['citation_id'],
                              text=doc['text'][span['start']:span['end']]))
    return dict(case_id=case_id, packet=packet, originals=originals,
                notice='Read-only reconstruction. Cue text is later evidence, never an input to earlier-turn replay.')
