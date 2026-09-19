import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
import retrieval_lab as lab
import retrieval_refresh as refresh


def doc(source, text):
    return dict(source_id=source, start_line=1, end_line=1, text=text, summaries=[])


class RefreshTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / 'lab'
        lab.create_lab(self.root, dict(schema_version=1, documents=[doc('legacy', 'old')]))
        (self.root / 'refresh-config.json').write_text(json.dumps(dict(
            schema_version=1, roots=[dict(adapter='codex', path=self.temp.name)],
            interval_seconds=900, exclude_sessions=[])))

    def delta(self, docs, removed=None):
        return dict(schema_version=1, documents=docs, refreshed_source_ids=[d['source_id'] for d in docs],
                    excluded_source_ids=removed or [], import_report={})

    def test_initial_replaces_legacy_then_updates_and_removes_excluded(self):
        with patch.object(refresh, 'export_live', return_value=self.delta([doc('a', 'one'), doc('b', 'two')])):
            first = refresh.refresh(self.root, force=True)
        self.assertEqual(first['status'], 'updated')
        with patch.object(refresh, 'export_live', return_value=self.delta([doc('b', 'new'), doc('c', 'three')], ['a'])):
            second = refresh.refresh(self.root, force=True)
        self.assertEqual(second['documents'], 2)
        self.assertEqual({d['text'] for d in lab._snapshot(self.root)['documents']}, {'new', 'three'})
        self.assertEqual(len(lab._snapshot(self.root, first['snapshot_id'])['documents']), 2)

    def test_failed_refresh_preserves_snapshot_and_watermark(self):
        with patch.object(refresh, 'export_live', return_value=self.delta([doc('a', 'one')])):
            refresh.refresh(self.root, force=True)
        old = lab._snapshot(self.root)
        state = refresh.status(self.root)
        with patch.object(refresh, 'export_live', side_effect=ValueError('secret content must not leak')):
            result = refresh.refresh(self.root, force=True)
        self.assertEqual(result['status'], 'error')
        self.assertNotIn('secret', json.dumps(result))
        self.assertEqual(refresh.status(self.root)['since'], state['since'])
        self.assertEqual(lab._snapshot(self.root), old)

    def test_throttle_and_no_change_do_not_publish_new_generation(self):
        with patch.object(refresh, 'export_live', return_value=self.delta([doc('a', 'one')])):
            refresh.refresh(self.root, force=True)
        with patch.object(refresh, 'export_live') as export:
            result = refresh.refresh(self.root)
        export.assert_not_called()
        self.assertEqual(result['status'], 'throttled')
        with patch.object(refresh, 'export_live', return_value=self.delta([])):
            result = refresh.refresh(self.root, force=True)
        self.assertEqual(result['status'], 'unchanged')

    def test_changed_roots_force_full_recollection(self):
        with patch.object(refresh, 'export_live', return_value=self.delta([doc('a', 'one')])):
            refresh.refresh(self.root, force=True)
        config_path = self.root / 'refresh-config.json'
        config = json.loads(config_path.read_text())
        config['exclude_sessions'] = ['previously-included']
        config_path.write_text(json.dumps(config))
        with patch.object(refresh, 'export_live', return_value=self.delta([doc('b', 'two')])) as export:
            refresh.refresh(self.root, force=True)
        self.assertEqual(export.call_args.kwargs['since'], 0)
        self.assertEqual([d['text'] for d in lab._snapshot(self.root)['documents']], ['two'])


    def test_all_sources_quarantined_publish_empty_current_corpus(self):
        with patch.object(refresh, 'export_live', return_value=self.delta([doc('a', 'one')])):
            refresh.refresh(self.root, force=True)
        request = lab.search(self.root, 'one', sample_rate=0)
        with patch.object(refresh, 'export_live', return_value=self.delta([], ['a'])):
            result = refresh.refresh(self.root, force=True)
        self.assertEqual(result['status'], 'updated')
        self.assertEqual(lab.search(self.root, 'one', sample_rate=0)['hits'], [])
        evidence = lab.read_citation(self.root, request['hits'][0]['citation_id'], request['request_id'])
        self.assertEqual(evidence['text'], 'one')


if __name__ == '__main__':
    unittest.main()
