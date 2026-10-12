"""Local follow-up observation. Cues and retrospective reviews are not causal effects."""
import json
import math
import re
import time
from collections import Counter, defaultdict

VERSION = 'recall-followup-v1'
WINDOW_SECONDS = 7 * 86400
MAX_TURNS = 3
MAX_CASES = 100
CUES = {
    'explicit_restatement': re.compile(r'前にも.{0,20}(?:言|伝え)|さっきも.{0,20}(?:言|伝え)|もう一度.{0,20}(?:説明|伝え)|I (?:already|previously) (?:said|told|explained)', re.I),
    'possible_correction': re.compile(r'そうじゃなく|そうではなく|というより|(?:の方が|のほうが).{0,12}(?:いい|良い)|違う.{0,10}(?:意味|意図)|that.s not what|I meant|rather than', re.I),
}
NOTICE = ('Selected search-invoked needs only. Follow-up text and lexical cues are observations, not proof of rework. '
          'No cue, silence, no reply, unknown linkage, or a completed window never means success. '
          'Agent-reported matches and retrospective reviews are not user feedback. Group differences are not causal savings.')


def _tables(db):
    return {r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}


def _create(db):
    db.execute('CREATE TABLE IF NOT EXISTS recall_followups (seq INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT UNIQUE NOT NULL, version TEXT NOT NULL, root_id TEXT NOT NULL, recorded REAL NOT NULL, packet TEXT NOT NULL)')
    db.execute('CREATE TABLE IF NOT EXISTS recall_followup_checks (version TEXT NOT NULL, root_id TEXT NOT NULL, checked REAL NOT NULL, PRIMARY KEY(version,root_id))')
    db.execute('CREATE TABLE IF NOT EXISTS recall_followup_heads (version TEXT NOT NULL, root_id TEXT NOT NULL, case_id TEXT NOT NULL, PRIMARY KEY(version,root_id))')
    db.execute('CREATE TABLE IF NOT EXISTS recall_followup_reviews (case_id TEXT PRIMARY KEY, recorded REAL NOT NULL, review TEXT NOT NULL)')


def _sessions(snapshot):
    from retrieval_opportunities import turns, user_text
    groups = defaultdict(dict)
    for item in turns(snapshot):
        o = item['observation']
        text = user_text(item['utterance']['text'])
        if not o or not o['native_session_id'] or not text or text.lstrip().startswith(('<external_codex_apps_', '<subagent_notification>', '<local-command-stdout>', '<local-command-caveat>', '<command-name>')):
            continue
        # Live/archive copies of an identical native turn are one observation.
        key = (o['timestamp'], text)
        prior = groups[o['native_session_id']].get(key)
        if prior is None or (item['source_id'], item['utterance']['line']) < (prior['source_id'], prior['utterance']['line']):
            groups[o['native_session_id']][key] = item
    return {sid: list(values.values()) for sid, values in groups.items()}


def _reference(item):
    from retrieval_opportunities import user_text
    m = item['utterance']; text = user_text(m['text'])
    return dict(source_id=item['source_id'], citation_id=m['citation_id'], line=m['line'],
                timestamp=item['observation']['timestamp'], text=text[:1600], truncated=len(text)>1600,
                characters=len(text))


def observe(need, session, now):
    """Use exact native identity and time only; never infer a session from cwd."""
    when = need['created']; deadline = when + WINDOW_SECONDS
    result = dict(root_request_id=need['root_request_id'], need=need, anchor=None, followups=[],
                  window_seconds=WINDOW_SECONDS, max_user_turns=MAX_TURNS, deadline=deadline,
                  status='unlinked', link_reason=None)
    if not need['session_id']:
        result['link_reason'] = 'session_unknown'; return result
    if not session:
        result['link_reason'] = 'session_not_collected'; return result
    if any(x['observation']['timestamp'] is None for x in session):
        result['link_reason'] = 'timestamp_unknown'; return result
    session = sorted(session, key=lambda x: x['observation']['timestamp'])
    stamps = [x['observation']['timestamp'] for x in session]
    if len(stamps) != len(set(stamps)):
        result['link_reason'] = 'ambiguous_timestamp'; return result
    earlier = [x for x in session if x['observation']['timestamp'] <= when]
    if not earlier:
        result['link_reason'] = 'anchor_not_collected'; return result
    anchor = earlier[-1]
    # An abandoned old session must not become an arbitrary anchor.
    if when - anchor['observation']['timestamp'] > WINDOW_SECONDS:
        result['link_reason'] = 'anchor_too_old'; return result
    if not anchor['observation']['assistant_observed']:
        result['link_reason'] = 'assistant_not_observed'; return result
    result['anchor'] = _reference(anchor)
    result['link_reason'] = 'native_session_and_timestamp'
    following = [x for x in session if when < x['observation']['timestamp'] <= min(now, deadline)][:MAX_TURNS]
    for item in following:
        ref = _reference(item)
        from retrieval_opportunities import user_text
        ref['cues'] = [name for name, regex in CUES.items() if regex.search(user_text(item['utterance']['text']))]
        result['followups'].append(ref)
    result['status'] = ('window_complete' if len(following) == MAX_TURNS or (following and now >= deadline)
                        else 'no_followup_observed' if now >= deadline
                        else 'observing' if following else 'pending')
    return result


def run(root, snapshot, config):
    import retrieval_lab as lab
    from retrieval_needs import summarize
    since = config['since']
    if type(since) not in (int, float) or not math.isfinite(since) or since < 0:
        raise ValueError('invalid follow-up start')
    now = time.time(); sessions = _sessions(snapshot)
    with lab._connect(root) as db:
        _create(db); tables = _tables(db)
        rows = [dict(r) for r in db.execute('SELECT id,created,foreground FROM queries ORDER BY created,id')
                if json.loads(r['foreground']).get('mode') == 'corrections'
                and json.loads(r['foreground']).get('purpose') == 'task']
        uses = {r['request_id']: dict(r) for r in db.execute('SELECT * FROM context_uses')} if 'context_uses' in tables else {}
        matches = {r['request_id']: r['match'] for r in db.execute('SELECT * FROM context_decision_matches')} if 'context_decision_matches' in tables else {}
        summary = summarize(rows, uses, matches, all_cases=True)
        needs = [n for n in summary['cases'] if since <= n['created'] <= now]
        eligible_roots = {n['root_request_id'] for n in needs}
        for head in list(db.execute('SELECT root_id FROM recall_followup_heads WHERE version=?',(VERSION,))):
            if head['root_id'] not in eligible_roots:
                db.execute('DELETE FROM recall_followup_heads WHERE version=? AND root_id=?',(VERSION,head['root_id']))
        checked = {r['root_id']: r['checked'] for r in db.execute('SELECT root_id,checked FROM recall_followup_checks WHERE version=?',(VERSION,))}
        row_by_id = {r['id']: r for r in rows}
        reads = defaultdict(list)
        for read in db.execute('SELECT request_id,created FROM reads'):
            reads[read['request_id']].append(read['created'])
        versions = {r['id']: json.loads(r['foreground']).get('retrieval_version') for r in rows}
        processed = changed = 0
        for need in sorted(needs, key=lambda n: (checked.get(n['root_request_id'], -1), n['created'], n['root_request_id']))[:MAX_CASES]:
            need['trigger'] = json.loads(row_by_id[need['root_request_id']]['foreground']).get('trigger','unknown')
            packet = observe(need, sessions.get(need['session_id'], []), now)
            packet.update(version=VERSION, since=since, snapshot_id=snapshot['snapshot_id'], observed_at=now,
                          retrieval_versions=sorted({versions[r] or 'unknown' for r in need['request_ids']}))
            boundary = packet['followups'][0]['timestamp'] if packet['followups'] else min(now,packet['deadline'])
            attempts = [row_by_id[r] for r in need['request_ids'] if row_by_id[r]['created'] < boundary]
            latest = attempts[-1] if attempts else None
            use = uses.get(latest['id']) if latest else None
            timely = use is not None and use['recorded'] < boundary
            packet['exposure'] = dict(request_id=latest['id'] if latest else None,
                decision_match=matches.get(latest['id'],'unknown') if timely else 'unknown',
                use_state=use['state'] if timely else None,
                reported_before_followup=timely,
                read_count=sum(t < boundary for a in attempts for t in reads[a['id']]),
                retrieval_version=versions[latest['id']] if latest else None)
            # Keep immutable evidence revisions, but do not append only because time
            # passed or an unrelated source changed the overall snapshot ID.
            identity = {k:v for k,v in packet.items() if k not in ('observed_at','snapshot_id')}
            case_id = lab.digest(identity)
            cursor = db.execute('INSERT OR IGNORE INTO recall_followups(id,version,root_id,recorded,packet) VALUES(?,?,?,?,?)',
                                (case_id, VERSION, need['root_request_id'], now, lab.canonical(packet)))
            changed += cursor.rowcount
            db.execute('INSERT OR REPLACE INTO recall_followup_heads VALUES(?,?,?)',(VERSION,need['root_request_id'],case_id))
            db.execute('INSERT OR REPLACE INTO recall_followup_checks VALUES(?,?,?)',(VERSION,need['root_request_id'],now))
            processed += 1
    return dict(status='ok', version=VERSION, since=since, eligible_needs=len(needs), processed=processed,
                task_searches_since_start=sum(since <= r['created'] <= now for r in rows),
                legacy_searches_since_start=sum(since <= r['created'] <= now and not json.loads(r['foreground']).get('decision_need') for r in rows),
                revisions_added=changed, deferred=max(0,len(needs)-processed), completed_at=now)


def _latest(db):
    if 'recall_followup_heads' not in _tables(db): return []
    rows = db.execute('SELECT f.* FROM recall_followups f JOIN recall_followup_heads h ON f.id=h.case_id WHERE h.version=? ORDER BY f.seq DESC',(VERSION,))
    return [dict(case_id=r['id'], **json.loads(r['packet'])) for r in rows]


def report(root):
    import retrieval_lab as lab
    with lab._connect(root) as db:
        cases = _latest(db)
        reviews = {r['case_id']:json.loads(r['review']) for r in db.execute('SELECT * FROM recall_followup_reviews')} if 'recall_followup_reviews' in _tables(db) else {}
    groups = defaultdict(Counter)
    for c in cases:
        c['review'] = reviews.get(c['case_id'])
        group = groups[(c['exposure']['retrieval_version'],c['need']['trigger'],c['exposure']['decision_match'])]
        group['needs'] += 1; group[c['status']] += 1
        group['with_followup'] += bool(c['followups'])
        group['with_cue'] += any(f['cues'] for f in c['followups'])
        group['complete_without_detected_cue'] += c['status']=='window_complete' and not any(f['cues'] for f in c['followups'])
    anchors = {(c['need']['session_id'],c['anchor']['timestamp']) for c in cases if c['anchor']}
    observations = Counter((c['need']['session_id'],f['timestamp']) for c in cases for f in c['followups'])
    cue_turns = {(c['need']['session_id'],f['timestamp']) for c in cases for f in c['followups'] if f['cues']}
    priority = sorted(cases, key=lambda c: (c['review'] is not None, not any(f['cues'] for f in c['followups']), -c['need']['created']))
    from retrieval_refresh import status
    collection = status(root)
    return dict(collection_status=collection.get('status','not_started'),
                observation_status=collection.get('followups',{'status':'not_started'}),
                version=VERSION, unit='decision_need_not_independent_task', needs=len(cases),
                unique_linked_turns=len(anchors), unique_followup_turns=len(observations),
                unique_cue_turns=len(cue_turns), overlapping_followup_turns=sum(n>1 for n in observations.values()),
                linked_needs=sum(bool(c['anchor']) for c in cases),
                states=dict(Counter(c['status'] for c in cases)), by_exposure=[dict(retrieval_version=k[0],trigger=k[1],decision_match=k[2],**v) for k,v in groups.items()],
                reviewed_current_revisions=dict(Counter(c['review']['label'] for c in cases if c['review'])),
                historical_reviews=len(reviews), review_cases=priority[:20],
                notice=NOTICE)


def inspect(root, case_id, blind=False):
    import retrieval_lab as lab
    with lab._connect(root) as db:
        if 'recall_followups' not in _tables(db): raise ValueError('unknown follow-up case')
        row = db.execute('SELECT packet FROM recall_followups WHERE id=?',(case_id,)).fetchone()
    if not row: raise ValueError('unknown follow-up case')
    packet = json.loads(row[0]); snapshot = lab._snapshot(root, packet['snapshot_id'])
    docs = {d['citation_id']:d for d in snapshot['documents']}; originals=[]
    for ref in [packet['anchor'],*packet['followups']]:
        if not ref: continue
        d=docs[ref['citation_id']]
        span=next(s for s in d['message_spans'] if s['line']==ref['line'] and s['role']=='user')
        originals.append(dict(ref,text=d['text'][span['start']:span['end']]))
    if blind:
        return dict(case_id=case_id,originals=originals,notice='Search results and self-reports withheld. Classify observed text before consulting retrieval outcomes.')
    return dict(case_id=case_id,packet=packet,originals=originals,notice=NOTICE)


def review(root, case_id, label, citations, reason, prior_decisions=None):
    """Agent retrospective classification, separate from explicit human feedback."""
    import retrieval_lab as lab
    from retrieval_opportunities import turns
    if label not in ('repeated_prior_decision','new_requirement','other','uncertain'):
        raise ValueError('invalid follow-up review label')
    if not isinstance(reason,str) or not reason.strip() or len(reason)>1000:
        raise ValueError('bounded review reason required')
    packet=inspect(root,case_id)['packet']; prior_decisions=prior_decisions or []
    for values in [citations]:
        if not isinstance(values,list) or len(values)>10 or any(not isinstance(c,str) for c in values):
            raise ValueError('invalid review citations')
    known={r['citation_id'] for r in packet['followups']}
    if not citations or not set(citations)<=known: raise ValueError('review requires observed follow-up citations')
    snapshot=lab._snapshot(root,packet['snapshot_id'])
    prior={(x['utterance']['citation_id'],x['utterance']['line']) for x in turns(snapshot) if x['observation'] and
           x['observation']['timestamp'] is not None and packet['anchor'] and
           x['observation']['timestamp']<packet['anchor']['timestamp']}
    if (not isinstance(prior_decisions,list) or len(prior_decisions)>10 or
        any(not isinstance(x,dict) or set(x)!={'citation_id','line'} or
            not isinstance(x['citation_id'],str) or type(x['line']) is not int for x in prior_decisions)):
        raise ValueError('invalid earlier decision references')
    if not {(x['citation_id'],x['line']) for x in prior_decisions}<=prior or (label=='repeated_prior_decision' and not prior_decisions):
        raise ValueError('restatement review requires earlier cited decision evidence')
    value=dict(label=label,citations=citations,prior_decisions=prior_decisions,reason=reason,
               provenance='agent_retrospective_review',causal_effect='unmeasured')
    with lab._connect(root) as db:
        _create(db)
        db.execute('INSERT OR REPLACE INTO recall_followup_reviews VALUES(?,?,?)',(case_id,time.time(),lab.canonical(value)))
    return dict(case_id=case_id,review=value,notice=NOTICE)
