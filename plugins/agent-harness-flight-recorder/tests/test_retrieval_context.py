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

    def test_context_does_not_cross_sources_or_include_injected_frames(self):
        original = self.manifest['documents'][0]
        other = dict(original, source_id='other')
        lab.publish_snapshot(self.root, dict(schema_version=1, documents=[original, other]))
        items, _ = context.units(lab._snapshot(self.root))
        self.assertEqual(len(items), 4)
        self.assertEqual(sum(x['request'] is None for x in items), 2)
        for prefix in ['<environment_context>', 'Stop hook feedback:', '[exploration-budget]']:
            self.assertFalse(context.conversational(prefix + ' automated'))


if __name__ == '__main__':
    unittest.main()
