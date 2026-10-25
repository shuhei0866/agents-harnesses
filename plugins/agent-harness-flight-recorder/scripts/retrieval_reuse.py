"""Answer reuse evidence. Self reports and observed windows never prove savings."""
import json

VERSION = 'answer-reuse-v1'


def prior_answers(root, query, citations, refs):
    import retrieval_lab as lab
    from retrieval_opportunities import turns
    if not isinstance(refs, list) or not 1 <= len(refs) <= 10:
        raise ValueError('bounded prior answers required')
    result = json.loads(query['foreground'])
    snapshot = lab._snapshot(root, result['snapshot_id'])
    known = {(x['utterance']['citation_id'], x['utterance']['line']): x for x in turns(snapshot)}
    values = []
    for ref in refs:
        if not isinstance(ref, dict) or set(ref) != {'citation_id', 'line'} or type(ref['line']) is not int:
            raise ValueError('invalid prior answer reference')
        if not isinstance(ref['citation_id'], str) or ref['citation_id'] not in citations:
            raise ValueError('prior answer must be a read and used citation')
        item = known.get((ref['citation_id'], ref['line']))
        o = item.get('observation') if item else None
        if not o or o['timestamp'] is None or o['timestamp'] >= query['created']:
            raise ValueError('prior answer must precede search with known timestamp')
        raw = item['utterance']['text'].lstrip()
        if raw.startswith(('<heartbeat', '<task-notification', '<external_codex_apps_', '<subagent_notification')):
            raise ValueError('automated message is not a prior answer')
        values.append(dict(ref, snapshot_id=snapshot['snapshot_id'], source_id=item['source_id'],
                           timestamp=o['timestamp'], session_id=o['native_session_id']))
    return values


def validate(root, query, citations, value):
    if not isinstance(value, dict) or set(value) - {'used_answer'} != {'request_presence', 'other_context', 'action', 'question', 'prior_answers'}:
        raise ValueError('invalid reuse report fields')
    if value['request_presence'] not in ('absent', 'present', 'unknown') or value['other_context'] not in ('present', 'not_seen', 'unknown'):
        raise ValueError('invalid reuse context')
    if value['action'] not in ('proceeded', 'self_corrected', 'confirmed', 'skipped_question'):
        raise ValueError('invalid reuse action')
    question = value['question']
    if not isinstance(question, str) or len(question) > 500 or (value['action'] == 'skipped_question' and not question.strip()):
        raise ValueError('skipped question requires the specific question')
    if 'used_answer' in value and (not isinstance(value['used_answer'], str) or not value['used_answer'].strip() or len(value['used_answer']) > 1000):
        raise ValueError('used_answer requires a bounded description of what was reused')
    refs = prior_answers(root, query, citations, value['prior_answers'])
    return dict(value, prior_answers=refs, version=VERSION, provenance='agent_self_report', causal_effect='unmeasured')


def answered_questions(raw):
    """Only questions in answered structured envelopes; never infer full coverage."""
    prefix, suffix = '<send_user_message_question_reply>', '</send_user_message_question_reply>'
    raw = raw.strip()
    if not raw.startswith(prefix) or not raw.endswith(suffix):
        return []
    try:
        values = json.loads(raw[len(prefix):-len(suffix)])
        if not isinstance(values, list): return []
        return [dict(question=x['question'][:1600], truncated=len(x['question']) > 1600)
                for x in values[:10] if isinstance(x, dict) and isinstance(x.get('question'), str)
                and isinstance(x.get('answer'), str)]
    except (ValueError, RecursionError):
        return []


def exposure(db, need, boundary, anchor):
    tables = {r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
    records = []
    if 'context_answer_reuse' in tables:
        for request in need['request_ids']:
            for row in db.execute('SELECT request_id,recorded,report FROM context_answer_reuse WHERE request_id=? ORDER BY seq', (request,)):
                records.append(dict(request_id=row['request_id'], recorded=row['recorded'], report=json.loads(row['report'])))
    timely = [r for r in records if r['recorded'] < boundary]
    # Retain the first statement for each invocation; later edits cannot rewrite
    # a pre-outcome claim. All submissions remain inspectable in context-inspect.
    first = {}
    for record in timely: first.setdefault(record['request_id'], record)
    for record in first.values():
        for ref in record['report']['prior_answers']:
            ref['precedes_consultation'] = bool(anchor and ref['timestamp'] < anchor['timestamp'])
            ref['different_session'] = bool(ref['session_id'] and need['session_id'] and ref['session_id'] != need['session_id'])
    return dict(status='recorded_before_followup' if first else 'late_only' if records else 'not_recorded',
                reports=list(first.values()), question_coverage='answered_structured_replies_only',
                unanswered_and_freeform_questions='unknown', causal_effect='unmeasured')


def review(root, packet, value):
    """Retrospective classifications with source checks, separate from self reports."""
    import retrieval_lab as lab
    if not isinstance(value, dict) or set(value) != {'classification', 'prior_answers', 'limitations'}:
        raise ValueError('invalid reuse review')
    if value['classification'] not in ('reuse_without_observed_repetition', 'corroboration', 'repeated_question', 'user_restatement', 'new_requirement', 'uncertain'):
        raise ValueError('invalid reuse classification')
    if not isinstance(value['limitations'], str) or not value['limitations'].strip() or len(value['limitations']) > 1000:
        raise ValueError('reuse review requires limitations')
    refs = value['prior_answers']
    if not isinstance(refs, list) or len(refs) > 10 or (not refs and value['classification'] != 'uncertain'):
        raise ValueError('reuse review requires earlier answers')
    verified = []
    with lab._connect(root) as db:
        for ref in refs:
            if not isinstance(ref, dict) or set(ref) != {'request_id', 'citation_id', 'line'} or ref['request_id'] not in packet['need']['request_ids']:
                raise ValueError('reuse reference must belong to this need')
            query = lab._row(db, ref['request_id'])
            boundary = packet['followups'][0]['timestamp'] if packet['followups'] else packet['deadline']
            read = db.execute('SELECT 1 FROM reads WHERE request_id=? AND citation_id=? AND created<?', (ref['request_id'], ref['citation_id'], boundary)).fetchone()
            if not read: raise ValueError('reuse evidence must be read before outcome')
            answer = prior_answers(root, query, [ref['citation_id']], [{k:ref[k] for k in ('citation_id', 'line')}])[0]
            if not packet['anchor'] or answer['timestamp'] >= packet['anchor']['timestamp']:
                raise ValueError('reuse review answer must precede consultation')
            verified.append(dict(answer, request_id=ref['request_id']))
    return dict(value, prior_answers=verified, provenance='agent_retrospective_review', causal_effect='unmeasured')


def freeze(root, request_id, case_id):
    import retrieval_lab as lab
    from retrieval_followup import inspect
    c = lab.context_inspect(root, request_id)
    packet = inspect(root, case_id)['packet']
    if request_id not in packet['need']['request_ids']: raise ValueError('case and request mismatch')
    selected = set(json.loads(c['use']['citations'])) if c['use'] else set()
    targets = [dict(citation_id=h['citation_id'], line=h['line']) for h in c['result']['hits'] if h['citation_id'] in selected]
    if not targets: raise ValueError('fixture requires used answer targets')
    value = dict(version=VERSION, purpose='verification', request_id=request_id, case_id=case_id,
                 snapshot_id=c['result']['snapshot_id'], followup_snapshot_id=packet['snapshot_id'],
                 query=c['query'], need=c['result']['decision_need']['text'], targets=targets,
                 baseline=c, observation=packet, causal_effect='unmeasured')
    return dict(value, fingerprint=lab.digest(value))


def replay(root, value):
    import retrieval_lab as lab
    from retrieval_context import retrieve
    identity = {k:v for k,v in value.items() if k != 'fingerprint'}
    if value.get('purpose') != 'verification' or lab.digest(identity) != value.get('fingerprint'):
        raise ValueError('invalid frozen reuse fixture')
    # Query and corpus are the original pre-outcome inputs. No live search/read
    # commands, outcome text, or newer corpus are used by the retriever.
    original = value.get('baseline', {}).get('result', {})
    scope = '\n'.join(x for x in (original.get('origin', {}).get('task'), value.get('need')) if x)
    result = retrieve(lab._snapshot(root, value['snapshot_id']), value['query'], 3, scope=scope or None)
    ranks = {(h['citation_id'],h['line']):h['rank'] for h in result['hits']}
    return dict(purpose='verification', fixture_fingerprint=value['fingerprint'],
                targets=[dict(t, rank=ranks.get((t['citation_id'], t['line']))) for t in value['targets']],
                all_targets_found=all((t['citation_id'],t['line']) in ranks for t in value['targets']),
                retrieval_version=result['retrieval_version'], causal_effect='unmeasured')


def use_template(root, request_id):
    """Read-only draft; candidates are not claims of adoption or avoided questions."""
    import retrieval_lab as lab
    c = lab.context_inspect(root, request_id)
    if c['result'].get('mode') != 'corrections' or not c['result'].get('decision_need'):
        raise ValueError('template requires a decision need')
    read = {r['citation_id'] for r in c['reads']}
    candidates = []
    with lab._connect(root) as db:
        query = lab._row(db, request_id)
        seen = set()
        for hit in c['result']['hits']:
            for key in ('utterance', 'request'):
                item = hit.get(key)
                if not item or item.get('role') != 'user':
                    continue
                ref = dict(citation_id=item['citation_id'], line=item['line'])
                identity = (ref['citation_id'], ref['line'])
                if ref['citation_id'] not in read or identity in seen:
                    continue
                try:
                    prior_answers(root, query, read, [ref])
                except ValueError:
                    continue
                seen.add(identity)
                candidates.append(ref)
    return dict(request_id=request_id, candidates=candidates,
                notice='Draft only. Select actually used sources; fill reason, used_answer and action. Do not invent an avoided question or backfill a past use.',
                already_recorded=bool(c['use']),
                draft=dict(state='applied', citations=[], reason='', decision_match='',
                           reuse=dict(request_presence='unknown', other_context='unknown',
                                      action='', question='', used_answer='', prior_answers=[])))
