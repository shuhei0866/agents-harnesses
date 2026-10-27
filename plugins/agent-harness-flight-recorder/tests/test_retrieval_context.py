import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
import retrieval_context as context
import retrieval_lab as lab
import retrieval_live as live


def record(text, role='user'):
    return dict(type='response_item', payload=dict(type='message', role=role,
                content=[dict(type='input_text', text=text)]))


class ContextTests(unittest.TestCase):
    def test_generated_turns_do_not_leak_through_preceding_context(self):
        logs = self.base / 'automated'
        logs.mkdir()
        (logs / 'one.jsonl').write_text(''.join(json.dumps(v)+'\n' for v in [
            record('human topic'), record('<heartbeat>automated keyword</heartbeat>'),
            record('automated keyword response', 'assistant'), record('next human topic')]))
        lab.publish_snapshot(self.root, live.export_live([('codex', logs)], since=0))
        snapshot = lab._snapshot(self.root)
        self.assertIn('automated keyword', json.dumps(snapshot))
        items, _ = context.units(snapshot)
        self.assertEqual(len(items), 2)
        self.assertIsNone(items[-1]['request'])
        self.assertIsNone(items[-1]['prior_response'])
        self.assertEqual(context.retrieve(snapshot, 'automated keyword', 3)['hits'], [])
        for text in ['<heartbeat automation="scheduled">body</heartbeat>',
                     '<task-notification>completed</task-notification>',
                     '<skill>injected instructions</skill>',
                     'This session is being continued from a previous conversation that ran out of context. Summary: generated']:
            self.assertFalse(context.conversational(text))
        for text in ['heartbeatの設定を変えて', '例: <heartbeat>quoted</heartbeat>',
                     '<send_user_message_question_reply>answer</send_user_message_question_reply>']:
            self.assertTrue(context.conversational(text))

    def test_prospective_scope_disambiguates_both_directions(self):
        logs = self.base / 'scope'
        logs.mkdir()
        for name, text in [('git', 'target main branch merge'),
                           ('book', 'target textbook vocabulary lesson reading'),
                           ('other', 'vocabulary lesson reading without the query word')]:
            (logs / (name + '.jsonl')).write_text(json.dumps(record(text)) + '\n')
        lab.publish_snapshot(self.root, live.export_live([('codex', logs)], since=0))
        snapshot = lab._snapshot(self.root)
        plain = context.retrieve(snapshot, 'target', 5)
        for scope, expected in [('textbook vocabulary lesson reading', 'textbook'), ('main branch merge', 'branch')]:
            result = context.retrieve(snapshot, 'target', 5, scope=scope)
            self.assertIn(expected, result['hits'][0]['utterance']['text'])
            for h in result['hits']:
                e = h['explanation']
                self.assertLessEqual(e['scope_bonus'], e['lexical_score'])
                self.assertAlmostEqual(h['score'], e['lexical_score'] + e['scope_bonus'])
        self.assertEqual(context.retrieve(snapshot, 'missing', 5, scope='textbook')['hits'], [])
        repeated_query = context.retrieve(snapshot, 'target', 5, scope='target target')
        self.assertEqual([(h['line'], h['score']) for h in plain['hits']],
                         [(h['line'], h['score']) for h in repeated_query['hits']])
        recorded = lab.search_corrections(self.root, 'target', 'resume',
                    task='textbook vocabulary', need='lesson reading')
        self.assertIn('textbook', recorded['hits'][0]['utterance']['text'])
        self.assertEqual(recorded['scope'], 'textbook vocabulary\nlesson reading')

    def test_single_japanese_character_scope_matches_inside_sentence(self):
        logs = self.base / 'single-scope'
        logs.mkdir()
        (logs / 'one.jsonl').write_text(json.dumps(record('配置は住んでいる家という対象で考える')) + '\n')
        lab.publish_snapshot(self.root, live.export_live([('codex', logs)], since=0))
        result = context.retrieve(lab._snapshot(self.root), '配置', 3, scope='家')
        self.assertGreater(result['hits'][0]['explanation']['scope_bonus'], 0)

    def test_compound_katakana_softens_only_unowned_fragments(self):
        self.assertIn('ボッ', context.compound_fragments('サンドボックス 権限'))
        self.assertIn('ボックス', context.compound_fragments('サンドボックス ボックス')['ボッ'])
        self.assertEqual(context.compound_fragments('箱 権限'), {})
        logs = self.base / 'compounds'
        logs.mkdir()
        for name, text in [('full', 'サンドボックスの設定を維持する'),
                           ('partial', 'ボックスの設定を維持する'),
                           ('related', '権限の設定を維持する')]:
            (logs / (name + '.jsonl')).write_text(json.dumps(record(text)) + '\n')
        lab.publish_snapshot(self.root, live.export_live([('codex', logs)], since=0))
        snapshot = lab._snapshot(self.root)
        result = context.retrieve(snapshot, 'サンドボックス 権限', 10)
        partial = next(h for h in result['hits'] if h['utterance']['text'].startswith('ボックス'))
        full = next(h for h in result['hits'] if h['utterance']['text'].startswith('サンド'))
        self.assertLess(full['rank'], partial['rank'])
        self.assertTrue(all(c['compound_weight'] == .25 for c in partial['explanation']['contributions']))
        self.assertTrue(all(c['compound_weight'] == 1 for c in full['explanation']['contributions']))
        # An explicit shorter query is still usable; there is no hard filter.
        shorter = context.retrieve(snapshot, 'ボックス', 10)
        self.assertTrue(any(h['utterance']['text'].startswith('ボックス') for h in shorter['hits']))

    def test_parent_handoff_is_not_a_human_decision_or_context(self):
        frame = '引き継ぎ: TASK-123（親セッションより）\n\n## 依頼\n秘密語の作業\n## 読む場所（参照）\ndocs/guide.md'
        self.assertFalse(context.conversational(frame))
        for human in ['引き継ぎは原文を残してほしい',
                      '引き継ぎ: 親セッションの判断を確認したい',
                      '引用例です\n' + frame,
                      frame.replace('（親セッションより）', '')]:
            self.assertTrue(context.conversational(human))
        logs = self.base / 'handoff'
        logs.mkdir()
        values = [record('元の本人判断'), record(frame),
                  record('秘密語の引き継ぎに従う', 'assistant'), record('後の本人判断')]
        (logs / 'one.jsonl').write_text(''.join(json.dumps(x)+'\n' for x in values))
        lab.publish_snapshot(self.root, live.export_live([('codex', logs)], since=0))
        snapshot = lab._snapshot(self.root)
        self.assertIn(frame, snapshot['documents'][0]['text'])
        items, _ = context.units(snapshot)
        self.assertEqual([x['utterance']['text'] for x in items], ['元の本人判断', '後の本人判断'])
        self.assertIsNone(items[-1]['request'])
        self.assertIsNone(items[-1]['prior_response'])
        self.assertEqual(context.retrieve(snapshot, '秘密語', 3)['hits'], [])

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        logs = self.base / 'logs'
        logs.mkdir()
        values = [record('Discuss the spreadsheet budget'),
                  record('I updated the spreadsheet', 'assistant'),
                  record('Only discuss the spreadsheet, do not edit it'),
                  record('Future answer should never appear as preceding context', 'assistant')]
        (logs / 'one.jsonl').write_text(''.join(json.dumps(v)+'\n' for v in values))
        self.manifest = live.export_live([('codex', logs)], since=0)
        self.root = self.base / 'lab'
        lab.create_lab(self.root, self.manifest)

    def test_context_search_read_use_and_historical_citations(self):
        r = lab.search_corrections(self.root, 'spreadsheet edit', 'ambiguous')
        hit = r['hits'][0]
        self.assertEqual(hit['line'], 3)
        self.assertEqual(hit['request']['line'], 1)
        self.assertEqual(hit['prior_response']['line'], 2)
        self.assertNotIn('Future answer', json.dumps(hit))
        citation = hit['citation_id']
        with self.assertRaises(ValueError):
            lab.context_use(self.root, r['request_id'], 'applied', [citation], 'same task')
        lab.publish_snapshot(self.root, dict(schema_version=1, documents=[]))
        read = lab.read_citation(self.root, citation, r['request_id'])
        self.assertIn('do not edit', read['text'])
        applied = lab.context_use(self.root, r['request_id'], 'applied', [citation], 'same task')
        self.assertEqual(applied['provenance'], 'agent_self_report')
        with lab._connect(self.root) as db:
            row = lab._row(db, r['request_id'])
            self.assertEqual(row['feedback'], 'unknown')
            self.assertEqual(row['assessments'], '{}')
            self.assertEqual(row['job_state'], 'not_sampled')
        usage = lab.context_report(self.root)
        self.assertEqual(usage['triggers'], {'ambiguous': 1})
        self.assertEqual(usage['uses'], {'applied': 1})
        self.assertEqual(usage['requests_with_reads'], 1)

    def test_prospective_need_retry_and_unknown_denominators(self):
        legacy = lab.search_corrections(self.root, 'spreadsheet', 'resume')
        first = lab.search_corrections(self.root, 'spreadsheet', 'resume', need='Was editing authorized?', session_id='s1')
        lab.context_use(self.root, first['request_id'], 'not_applicable', [], 'Too broad', decision_match='not_found')
        retry = lab.search_corrections(self.root, 'spreadsheet edit', 'resume', retry_of=first['request_id'], session_id='s1')
        self.assertEqual(retry['decision_need']['text'], 'Was editing authorized?')
        citation = retry['hits'][0]['citation_id']
        with self.assertRaises(ValueError):
            lab.context_use(self.root, retry['request_id'], 'applied', [citation], 'No read', decision_match='found')
        lab.read_citation(self.root, citation, retry['request_id'])
        lab.context_use(self.root, retry['request_id'], 'applied', [citation], 'Discuss only', decision_match='found', effect='changed_plan')
        lab.search_corrections(self.root, 'budget', 'explicit', need='Earlier budget ceiling?', session_id='s2')
        lab.search_corrections(self.root, 'budget', 'explicit', need='Test only', purpose='verification')
        report = lab.context_report(self.root, 'task')['decision_needs']
        self.assertEqual(report['needs'], 2)
        self.assertEqual(report['legacy_searches'], 1)
        self.assertEqual(report['statuses'], {'found': 1, 'unknown': 1})
        self.assertEqual(report['found_on'], {'retry': 1})
        self.assertEqual(report['unreported'], 1)
        self.assertEqual(report['sessions_known'], 2)
        self.assertEqual(len(report['review_cases']), 2)
        self.assertEqual(lab.context_inspect(self.root, retry['request_id'])['decision_match'], 'found')
        for kwargs in [dict(retry_of=first['request_id'], session_id='s1'),
                       dict(retry_of=retry['request_id'], session_id='s1'),
                       dict(retry_of=legacy['request_id']),
                       dict(retry_of=first['request_id'], session_id='other'),
                       dict(retry_of=first['request_id'], session_id='s1', need='Changed target'),
                       dict(retry_of=first['request_id'], session_id='s1', purpose='verification')]:
            with self.assertRaises(ValueError):
                lab.search_corrections(self.root, 'spreadsheet', 'resume', **kwargs)
        self.assertEqual(lab.context_report(self.root, 'task')['searches'], 4)

    def test_retry_retraction_does_not_preserve_old_success(self):
        first = lab.search_corrections(self.root, 'spreadsheet', 'resume', need='Edit permission')
        citation = first['hits'][0]['citation_id']
        lab.read_citation(self.root, citation, first['request_id'])
        lab.context_use(self.root, first['request_id'], 'not_applicable', [citation], 'Found but old', decision_match='found')
        retry = lab.search_corrections(self.root, 'budget', 'resume', retry_of=first['request_id'])
        report = lab.context_report(self.root)['decision_needs']
        self.assertEqual(report['statuses'], {'unknown': 1})
        lab.context_use(self.root, retry['request_id'], 'unresolved', [], 'Decision remains unclear', decision_match='unknown')
        self.assertEqual(lab.context_report(self.root)['decision_needs']['found_on'], {})

    def test_partial_evidence_survives_unsuccessful_retry(self):
        first = lab.search_corrections(self.root, 'spreadsheet', 'resume', need='Permission and budget')
        citation = first['hits'][0]['citation_id']
        lab.read_citation(self.root, citation, first['request_id'])
        lab.context_use(self.root, first['request_id'], 'unresolved', [citation], 'Permission only', decision_match='partial')
        retry = lab.search_corrections(self.root, 'budget', 'resume', retry_of=first['request_id'])
        lab.context_use(self.root, retry['request_id'], 'unresolved', [], 'No additional evidence', decision_match='not_found')
        case = lab.context_report(self.root)['decision_needs']['review_cases'][0]
        self.assertEqual(case['status'], 'not_found')
        self.assertEqual(case['attempt_reports'][0]['match'], 'partial')
        self.assertEqual(case['attempt_reports'][0]['citations'], [citation])
        self.assertEqual(case['attempt_reports'][0]['reason'], 'Permission only')

    def test_match_validation_legacy_and_replacement(self):
        old = lab.search_corrections(self.root, 'spreadsheet', 'resume')
        with self.assertRaises(ValueError):
            lab.context_use(self.root, old['request_id'], 'unresolved', [], 'Unknown', decision_match='unknown')
        r = lab.search_corrections(self.root, 'spreadsheet', 'resume', need='Editing permission')
        for match in ['found', 'partial', 'invented']:
            with self.assertRaises(ValueError):
                lab.context_use(self.root, r['request_id'], 'unresolved', [], 'Unknown', decision_match=match)
        lab.context_use(self.root, r['request_id'], 'unresolved', [], 'Unknown', decision_match='unknown')
        lab.context_use(self.root, r['request_id'], 'not_applicable', [], 'Unreported replacement')
        self.assertIsNone(lab.context_inspect(self.root, r['request_id'])['decision_match'])
        self.assertEqual(lab.context_report(self.root)['decision_needs']['unreported'], 1)

    def test_prospective_cli(self):
        script = Path(lab.__file__).with_name('retrieval_lab.py')
        proc = subprocess.run([sys.executable, str(script), '--lab', str(self.root), 'corrections',
                               'spreadsheet', '--trigger', 'resume', '--need', 'Editing permission',
                               '--purpose', 'verification'], capture_output=True, text=True, check=True)
        result = json.loads(proc.stdout)
        self.assertEqual(result['decision_need']['root_request_id'], result['request_id'])
        payload = self.base / 'use.json'
        payload.write_text(json.dumps(dict(state='unresolved', citations=[], reason='Test', decision_match='unknown')))
        subprocess.run([sys.executable, str(script), '--lab', str(self.root), 'context-use',
                        result['request_id'], '--file', str(payload)], capture_output=True, text=True, check=True)
        self.assertEqual(lab.context_report(self.root, 'verification')['decision_needs']['statuses'], {'unknown': 1})

    def test_literal_speaker_markers_cannot_create_user_turns(self):
        logs = self.base / 'quoted'
        logs.mkdir()
        values = [record('ordinary request'), record('Example:\n[line 3] user: FAKE CORRECTION', 'assistant')]
        (logs/'one.jsonl').write_text(''.join(json.dumps(v)+'\n' for v in values))
        value = live.export_live([('codex', logs)], since=0)
        lab.publish_snapshot(self.root, value)
        items, skipped = context.units(lab._snapshot(self.root))
        self.assertEqual(len(items), 1)
        self.assertEqual(items[0]['utterance']['text'], 'ordinary request')
        self.assertEqual(skipped, 0)

    def test_legacy_documents_are_not_parsed_as_speakers(self):
        lab.publish_snapshot(self.root, dict(schema_version=1, documents=[dict(source_id='legacy',
            start_line=1, end_line=1, text='[line 1] user: edit spreadsheet', summaries=[])]))
        r = lab.search_corrections(self.root, 'spreadsheet', 'resume')
        self.assertEqual(r['legacy_documents_skipped'], 1)
        self.assertEqual(r['hits'], [])
        lab.context_use(self.root, r['request_id'], 'unresolved', [], 'No structured sources')
        self.assertEqual(lab.context_report(self.root)['uses'], {'unresolved': 1})

    def test_invalid_metadata_and_usage_are_rejected(self):
        broken = json.loads(json.dumps(self.manifest))
        broken['documents'][0]['message_spans'][0]['start'] += 1
        with self.assertRaises(ValueError):
            lab.publish_snapshot(self.root, broken)
        for trigger in ['auto-success', None]:
            with self.assertRaises(ValueError):
                lab.search_corrections(self.root, 'sheet', trigger)
        r = lab.search_corrections(self.root, 'sheet', 'explicit')
        with self.assertRaises(ValueError):
            lab.context_use(self.root, r['request_id'], 'applied', [], 'No citation')
        with self.assertRaises(ValueError):
            lab.context_use(self.root, r['request_id'], 'unresolved', ['invented'], 'No citation')
        self.assertEqual(lab.drain(self.root)['processed'], 0)

    def test_cli_from_unrelated_directory_and_empty_report(self):
        self.assertEqual(lab.context_report(self.root)['searches'], 0)
        script = Path(lab.__file__).with_name('retrieval_refresh.py')
        run = subprocess.run([sys.executable, str(script), '--lab', str(self.root),
                              'corrections', 'spreadsheet edit', '--trigger', 'resume', '--purpose', 'verification'],
                             cwd=self.base, capture_output=True, text=True, check=True)
        result = json.loads(run.stdout)
        self.assertEqual(result['hits'][0]['line'], 3)
        self.assertEqual(result['trigger'], 'resume')
        self.assertEqual(lab.context_report(self.root)['purposes'], {'verification': 1})
        output = json.loads(run.stdout)
        self.assertNotIn('contributions', output['hits'][0]['explanation'])
        inspected = subprocess.run([sys.executable, str(script), '--lab', str(self.root),
            'context-inspect', output['request_id']], cwd=self.base, capture_output=True, text=True, check=True)
        packet = json.loads(inspected.stdout)
        self.assertIn('contributions', packet['result']['hits'][0]['explanation'])
        self.assertEqual(packet['result']['origin']['cwd'], str(self.base))

    def test_context_does_not_cross_sources_or_include_injected_frames(self):
        original = self.manifest['documents'][0]
        other = dict(original, source_id='other')
        lab.publish_snapshot(self.root, dict(schema_version=1, documents=[original, other]))
        items, _ = context.units(lab._snapshot(self.root))
        self.assertEqual(len(items), 4)
        self.assertEqual(sum(x['request'] is None for x in items), 2)
        for prefix in ['<environment_context>', 'Stop hook feedback:', '[exploration-budget]']:
            self.assertFalse(context.conversational(prefix + ' automated'))

    def test_diagnostics_explain_score_and_record_only_allowlisted_origin(self):
        with patch.dict(os.environ, {'CODEX_THREAD_ID': 'thread-example', 'SECRET_KEY': 'not-recorded'}):
            r = lab.search_corrections(self.root, 'spreadsheet edit absent', 'resume', task='resume budgeting')
        self.assertEqual(r['origin']['session_id'], 'thread-example')
        self.assertEqual(r['origin']['task'], 'resume budgeting')
        self.assertNotIn('not-recorded', json.dumps(r))
        for hit in r['hits']:
            self.assertAlmostEqual(hit['score'], sum(d['score'] for d in hit['explanation']['contributions']) + hit['explanation']['scope_bonus'])
            self.assertIn('absent', hit['explanation']['unmatched_tokens'])
        packet = lab.context_inspect(self.root, r['request_id'])
        self.assertEqual(packet['result'], r)
        self.assertEqual(packet['reads'], [])
        self.assertIsNone(packet['use'])
        with patch.dict(os.environ, {}, clear=True):
            unknown = lab.search_corrections(self.root, 'spreadsheet', 'resume')
        self.assertIsNone(unknown['origin']['session_id'])

    def test_usage_details_filtering_and_legacy_records(self):
        task = lab.search_corrections(self.root, 'spreadsheet edit', 'resume')
        verification = lab.search_corrections(self.root, 'spreadsheet', 'explicit', purpose='verification')
        citation = task['hits'][0]['citation_id']
        lab.read_citation(self.root, citation, task['request_id'])
        lab.context_use(self.root, task['request_id'], 'applied', [citation], 'Changed work',
                        reason_code='relevant', effect='changed_plan')
        lab.context_use(self.root, verification['request_id'], 'not_applicable', [], 'Only a test')
        report = lab.context_report(self.root, 'task')
        self.assertEqual(report['searches'], 1)
        self.assertEqual(report['effects'], {'changed_plan': 1})
        self.assertEqual(report['uses'], {'applied': 1})
        self.assertEqual(report['unreported'], 0)
        before = lab.context_inspect(self.root, task['request_id'])
        self.assertEqual(before['use_details']['effect'], 'changed_plan')
        self.assertEqual(lab.context_inspect(self.root, task['request_id'])['reads'], before['reads'])
        with self.assertRaises(ValueError):
            lab.context_use(self.root, task['request_id'], 'not_applicable', [], 'No', effect='changed_plan')
        # Existing v1 rows without diagnostic data remain inspectable and counted.
        with lab._connect(self.root) as db:
            old = dict(task)
            old.pop('origin')
            old.pop('diagnostics_version')
            db.execute('UPDATE queries SET foreground=?,version=? WHERE id=?', (lab.canonical(old), 'user-context-bm25-v1', task['request_id']))
            db.execute('DROP TABLE context_use_details')
        self.assertIsNone(lab.context_inspect(self.root, task['request_id'])['use_details'])
        self.assertEqual(lab.context_report(self.root, 'task')['origin_missing'], 1)
        lab.context_use(self.root, task['request_id'], 'applied', [citation], 'Legacy API still works')

    def test_mixed_japanese_query_softens_fragments_without_dropping_them(self):
        logs = self.base / 'mixed'
        logs.mkdir()
        (logs / 'one.jsonl').write_text(''.join(json.dumps(v)+'\n' for v in [
            record('写真アルバムは日付を選んで整理したい。削除はしない。'),
            record('別の話だけど、なんかいまいち考えきられてない感じがする。')]))
        lab.publish_snapshot(self.root, live.export_live([('codex', logs)], since=0))
        r = lab.search_corrections(self.root, '写真アルバム 整理 しない なんか', 'resume')
        self.assertEqual(r['hits'][0]['line'], 1)
        self.assertEqual(r['query_weights']['写真'], 1)
        self.assertEqual(r['query_weights']['ない'], .5)
        self.assertIn('ない', r['hits'][0]['explanation']['matched_tokens'])
        for hit in r['hits']:
            self.assertAlmostEqual(hit['score'], sum(d['score'] for d in hit['explanation']['contributions']) + hit['explanation']['scope_bonus'])
        self.assertEqual(r['diagnostics_version'], 4)

    def test_hiragana_only_and_non_hiragana_queries_keep_full_weights(self):
        for query in ['ありがとう', '家', 'spreadsheet edit', 'APP-587', 'カタカナ', '']:
            tokens = set(context.context_tokens(query))
            self.assertEqual(context.query_weights(tokens), dict.fromkeys(tokens, 1.0))
        logs = self.base / 'kana'
        logs.mkdir()
        (logs / 'one.jsonl').write_text(json.dumps(record('りんごをえらびたい'))+'\n')
        lab.publish_snapshot(self.root, live.export_live([('codex', logs)], since=0))
        r = lab.search_corrections(self.root, 'りんご', 'resume')
        self.assertEqual(r['hits'][0]['line'], 1)
        self.assertTrue(all(d['query_weight'] == 1 for d in r['hits'][0]['explanation']['contributions']))

    def test_compound_ticket_identifiers_do_not_match_bare_numbers(self):
        self.assertEqual(context.context_tokens('APP-587'), ['app-587'])
        self.assertNotIn('587', context.context_tokens('APP-587'))
        logs = self.base / 'ids'
        logs.mkdir()
        (logs / 'tickets.jsonl').write_text(''.join(json.dumps(v)+'\n' for v in [
            record('PR 587 is merged'), record('APP-587 remains on hold')]))
        lab.publish_snapshot(self.root, live.export_live([('codex', logs)], since=0))
        r = lab.search_corrections(self.root, 'APP-587', 'resume')
        self.assertEqual(len(r['hits']), 1)
        self.assertEqual(r['hits'][0]['line'], 2)


    def test_context_queries_do_not_break_or_pollute_ordinary_report(self):
        r = lab.search_corrections(self.root, 'spreadsheet', 'resume')
        lab.read_citation(self.root, r['hits'][0]['citation_id'], r['request_id'])
        ordinary = lab.search(self.root, 'spreadsheet', sample_rate=0)
        lab.read_citation(self.root, ordinary['hits'][0]['citation_id'], ordinary['request_id'])
        report = lab.report(self.root)
        self.assertEqual(report['total_queries'], 1)
        self.assertEqual(report['citation_reads'], 1)
        self.assertEqual(lab.context_report(self.root)['searches'], 1)

    def test_cli_masks_supported_credentials_without_changing_citation(self):
        from retrieval_redaction import redact_payload
        secret = 'sk-proj-' + 'a' * 24
        body = 'spreadsheet API_KEY="example-secret-value" ' + secret
        logs = self.base / 'credentials'
        logs.mkdir()
        (logs/'one.jsonl').write_text(json.dumps(record(body))+'\n')
        lab.publish_snapshot(self.root, live.export_live([('codex', logs)], since=0))
        script = Path(lab.__file__)
        run = subprocess.run([sys.executable, str(script), '--lab', str(self.root),
            'corrections', 'spreadsheet', '--trigger', 'explicit'], capture_output=True, text=True, check=True)
        shown = json.loads(run.stdout)
        self.assertTrue(shown['display_redacted'])
        self.assertNotIn(secret, run.stdout)
        self.assertNotIn('example-secret-value', run.stdout)
        citation = shown['hits'][0]['citation_id']
        read = subprocess.run([sys.executable, str(script), '--lab', str(self.root),
            'read', citation, '--request-id', shown['request_id']], capture_output=True, text=True, check=True)
        self.assertNotIn(secret, read.stdout)
        self.assertEqual(json.loads(read.stdout)['citation_id'], citation)
        self.assertIn(secret, lab._snapshot(self.root)['documents'][0]['text'])
        for value in ['Authorization: Bearer example-token',
                      '-----BEGIN PRIVATE KEY-----\nexample\n-----END PRIVATE KEY-----']:
            self.assertEqual(redact_payload({'text': value})['text'], '[credential redacted]')

    def test_consultation_remains_in_history_but_not_human_context_candidates(self):
        logs = self.base / 'bridge'
        logs.mkdir()
        (logs/'one.jsonl').write_text(''.join(json.dumps(v)+'\n' for v in [
            record(live.BRIDGE_PROMPT + '\nCompare constellation designs'),
            record('Use a constellation layout for this reason', 'assistant'),
            record('More constellation details')]))
        manifest = live.export_live([('codex', logs)], since=0)
        lab.publish_snapshot(self.root, manifest)
        ordinary = lab.search(self.root, 'constellation', sample_rate=0)
        self.assertTrue(ordinary['hits'])
        self.assertEqual(ordinary['hits'][0]['source_kind'], 'agent_consultation')
        raw = lab.read_citation(self.root, ordinary['hits'][0]['citation_id'], ordinary['request_id'])
        self.assertIn('for this reason', raw['text'])
        recalled = lab.search_corrections(self.root, 'constellation', 'resume')
        self.assertEqual(recalled['hits'], [])
        self.assertEqual(recalled['consultation_sources_skipped'], 1)
        legacy = json.loads(json.dumps(lab._snapshot(self.root)))
        for document in legacy['documents']:
            document.pop('source_kind', None)
        self.assertEqual(context.retrieve(legacy, 'constellation', 3)['hits'], [])
        self.assertIn('constellation', json.dumps(legacy))
        bad = json.loads(json.dumps(manifest))
        bad['documents'][0]['source_kind'] = 'human-confirmed'
        with self.assertRaises(ValueError):
            lab.publish_snapshot(self.root, bad)
        mixed = json.loads(json.dumps(manifest))
        duplicate = dict(mixed['documents'][0])
        duplicate.pop('source_kind')
        mixed['documents'].append(duplicate)
        with self.assertRaises(ValueError):
            lab.publish_snapshot(self.root, mixed)


    def test_single_character_japanese_terms_match_within_sentences(self):
        logs = self.base / 'single'
        logs.mkdir()
        (logs/'one.jsonl').write_text(''.join(json.dumps(v)+'\n' for v in [
            record('自分が本当に住んでいる家という事実です'), record('家')]))
        lab.publish_snapshot(self.root, live.export_live([('codex', logs)], since=0))
        r = lab.search_corrections(self.root, '家', 'resume')
        self.assertEqual({h['line'] for h in r['hits']}, {1, 2})
        for hit in r['hits']:
            self.assertIn('家', hit['explanation']['matched_tokens'])
        self.assertEqual(lab.search_corrections(self.root, '山', 'resume')['hits'], [])
        combined = lab.search_corrections(self.root, '家 山', 'resume')
        for hit in combined['hits']:
            self.assertNotIn('山', hit['explanation']['matched_tokens'])
            self.assertIn('山', hit['explanation']['unmatched_tokens'])

    def test_model_review_is_not_a_user_correction_but_stays_readable(self):
        frame = ("<user_action>\n  <context>User initiated a review task. "
                 "Here's the full review output from reviewer model. User may select comments.</context>\n"
                 "review model constellation advice</user_action>")
        self.assertFalse(context.conversational(frame))
        self.assertTrue(context.conversational('<user_action>My own constellation request</user_action>'))
        logs = self.base / 'review'
        logs.mkdir()
        (logs/'one.jsonl').write_text(''.join(json.dumps(v)+'\n' for v in [record(frame), record('ordinary request')]))
        lab.publish_snapshot(self.root, live.export_live([('codex', logs)], since=0))
        self.assertTrue(lab.search(self.root, 'constellation', sample_rate=0)['hits'])
        self.assertEqual(lab.search_corrections(self.root, 'constellation', 'resume')['hits'], [])


if __name__ == '__main__':
    unittest.main()
