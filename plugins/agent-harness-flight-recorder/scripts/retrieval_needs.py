"""Prospective decision needs; descriptive self-reports, never success labels."""
import json
from collections import Counter


def summarize(rows, uses, matches, all_cases=False):
    groups = {}
    legacy = 0
    for row in rows:
        result = json.loads(row['foreground'])
        need = result.get('decision_need')
        if not need:
            legacy += 1
            continue
        groups.setdefault(need['root_request_id'], []).append((row, result))
    cases = []
    for root, attempts in groups.items():
        initial, first = attempts[0]
        last, latest = attempts[-1]
        status = matches.get(last['id'], 'unknown')
        found = next(((r, v) for r, v in attempts if matches.get(r['id']) == 'found'), None) if status == 'found' else None
        chosen = (last, latest)
        r, result = chosen
        citations = set(json.loads(uses.get(r['id'], {}).get('citations', '[]')))
        ranks = [h['rank'] for h in result['hits'] if any(h.get(k) and h[k]['citation_id'] in citations
                 for k in ('utterance', 'request', 'prior_response'))]
        cases.append(dict(root_request_id=root, created=initial['created'], need=first['decision_need']['text'],
                          session_id=first.get('origin', {}).get('session_id'), attempts=len(attempts),
                          status=status, reported=last['id'] in matches,
                          found_on=('initial' if found[0]['id'] == root else 'supplement' if found[1].get('supplement') else 'retry') if found else None,
                          selected_ranks=ranks, request_ids=[a['id'] for a, _ in attempts],
                          reason=uses.get(r['id'], {}).get('reason'),
                          attempt_reports=[dict(request_id=a['id'], match=matches.get(a['id'], 'unknown'),
                                                citations=json.loads(uses.get(a['id'], {}).get('citations', '[]')),
                                                reason=uses.get(a['id'], {}).get('reason')) for a, _ in attempts]))
    return dict(**(dict(cases=cases) if all_cases else {}), version=1, needs=len(cases), legacy_searches=legacy,
                statuses=dict(Counter(c['status'] for c in cases)),
                found_on=dict(Counter(c['found_on'] for c in cases if c['found_on'])),
                unreported=sum(not c['reported'] for c in cases),
                attempts_unreported=sum(r['id'] not in matches for group in groups.values() for r, _ in group),
                sessions_known=len({c['session_id'] for c in cases if c['session_id']}),
                session_unknown=sum(not c['session_id'] for c in cases),
                review_cases=sorted((c for c in cases if c['status'] != 'found' or c['found_on'] in ('retry','supplement')),
                                    key=lambda c: c['created'], reverse=True)[:20],
                notice='Search-invoked needs only; matches are agent self-reports, not human validation. '
                       'Silence, missing reports and sessions without searches do not imply success. '
                       'Need status is the latest attempt; earlier partial/found evidence remains in attempt_reports. '
                       'Ranks are observed; downstream quality and reduced rework are not measured.')
