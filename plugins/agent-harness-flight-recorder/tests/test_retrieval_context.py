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
            self.assertAlmostEqual(hit['score'], sum(d['score'] for d in hit['explanation']['contributions']))
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


if __name__ == '__main__':
    unittest.main()
