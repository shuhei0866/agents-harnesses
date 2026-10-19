import json
import os
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
            schema_version=1, roots=[dict(adapter='codex', path=str(Path(self.temp.name).resolve()))],
            interval_seconds=900, exclude_sessions=[])))

    def delta(self, docs, removed=None):
        return dict(schema_version=1, documents=docs, refreshed_source_ids=[d['source_id'] for d in docs],
                    excluded_source_ids=removed or [], import_report={})

    def test_deferred_source_retains_windows_and_retries_after_watermark(self):
        with patch.object(refresh,'export_live',return_value=self.delta([doc('a','original'),doc('b','old')])):
            first=refresh.refresh(self.root,force=True)
        frozen=lab.search(self.root,'original',sample_rate=0)['snapshot_id']
        partial=dict(self.delta([doc('b','new')]),deferred_source_ids=['a'],present_source_ids=['a','b'],inventory_complete=True)
        with patch.object(refresh,'export_live',return_value=partial):
            result=refresh.refresh(self.root,force=True)
        self.assertEqual(result['health'],'degraded')
        self.assertEqual(result['health_code'],'collection_incomplete')
        self.assertEqual(result['last_success'],first['last_success'])
        self.assertEqual({d['text'] for d in lab._snapshot(self.root)['documents']},{'original','new'})
        with patch.object(refresh,'export_live',return_value=dict(self.delta([doc('a','finished')]),present_source_ids=['a','b'],inventory_complete=True)) as export:
            recovered=refresh.refresh(self.root,force=True)
        self.assertNotIn('a',export.call_args.kwargs['known_source_ids'])
        self.assertEqual(recovered['health'],'ok')
        self.assertEqual(recovered['deferred_source_ids'],[])
        self.assertIn('original',str(lab._snapshot(self.root,frozen)))

    def test_collector_upgrade_rescans_old_sources_and_keeps_old_citations(self):
        with patch.object(refresh, 'export_live', return_value=self.delta([doc('a', 'old generated')])):
            refresh.refresh(self.root, force=True)
        query = lab.search(self.root, 'generated', sample_rate=0)
        before = lab._snapshot(self.root)
        state = refresh.status(self.root)
        state.pop('collector_version')
        refresh._write(self.root, 'refresh-state.json', state)
        with patch.object(refresh, 'export_live', return_value=dict(
                self.delta([]), inventory_complete=False)):
            failed = refresh.refresh(self.root, force=True)
        self.assertEqual(failed['status'], 'error')
        self.assertNotIn('collector_version', failed)
        self.assertEqual(lab._snapshot(self.root), before)
        with patch.object(refresh, 'export_live', return_value=self.delta(
                [doc('b', 'human correction')], ['a'])) as export:
            result = refresh.refresh(self.root, force=True)
        self.assertEqual(export.call_args.kwargs['since'], 0)
        self.assertEqual(result['collector_version'], refresh.COLLECTOR_VERSION)
        self.assertEqual([d['source_id'] for d in lab._snapshot(self.root)['documents']], ['b'])
        self.assertEqual(lab._snapshot(self.root, query['snapshot_id']), before)

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

    def test_archive_move_with_preserved_mtime_replaces_current_but_keeps_old_citation(self):
        source = Path(self.temp.name) / 'session.jsonl'
        source.write_text(json.dumps(dict(type='response_item', payload=dict(type='message',
            role='user', content=[dict(type='input_text', text='unique archived decision')])) ) + '\n')
        os.utime(source, (10, 10))
        refresh.refresh(self.root, force=True)
        request = lab.search(self.root, 'unique archived decision', sample_rate=0)
        archive = Path(self.temp.name) / 'archived_sessions'
        archive.mkdir()
        source.rename(archive / source.name)
        result = refresh.refresh(self.root, force=True)
        self.assertEqual(result['status'], 'updated')
        self.assertEqual(result['documents'], 1)
        current = lab.search(self.root, 'unique archived decision', sample_rate=0)
        self.assertEqual(len(current['hits']), 1)
        self.assertNotEqual(current['hits'][0]['source_id'], request['hits'][0]['source_id'])
        old = lab.read_citation(self.root, request['hits'][0]['citation_id'], request['request_id'])
        self.assertIn('unique archived decision', old['text'])

    def test_incomplete_inventory_does_not_retire_previous_paths(self):
        first = self.delta([doc('a', 'keep me')])
        first.update(present_source_ids=['a'], inventory_complete=True)
        with patch.object(refresh, 'export_live', return_value=first):
            refresh.refresh(self.root, force=True)
        missing = self.delta([])
        missing.update(present_source_ids=[], inventory_complete=False)
        with patch.object(refresh, 'export_live', return_value=missing):
            result = refresh.refresh(self.root, force=True)
        self.assertEqual(result['documents'], 1)

    def test_config_change_with_incomplete_inventory_keeps_snapshot_and_watermark(self):
        first = self.delta([doc('a', 'keep me')])
        first.update(present_source_ids=['a'], inventory_complete=True)
        with patch.object(refresh, 'export_live', return_value=first):
            refresh.refresh(self.root, force=True)
        prior = refresh.status(self.root)
        snapshot = lab._snapshot(self.root)
        path = self.root / 'refresh-config.json'
        config = json.loads(path.read_text())
        config['roots'].append(dict(adapter='codex', path='/missing-archive'))
        path.write_text(json.dumps(config))
        partial = self.delta([doc('b', 'partial')])
        partial.update(present_source_ids=['b'], inventory_complete=False)
        with patch.object(refresh, 'export_live', return_value=partial):
            result = refresh.refresh(self.root, force=True)
        self.assertEqual(result['status'], 'error')
        for key in ('source_ids', 'since', 'config_id', 'snapshot_id'):
            self.assertEqual(result[key], prior[key])
        self.assertEqual(lab._snapshot(self.root), snapshot)

    def test_stale_success_is_not_healthy_even_when_throttled(self):
        with patch.object(refresh, 'export_live', return_value=self.delta([doc('a', 'one')])):
            refresh.refresh(self.root, force=True)
        state = refresh._state(self.root)
        state['last_success'] = 1
        refresh._write(self.root, 'refresh-state.json', state)
        result = refresh.refresh(self.root)
        self.assertEqual(result['status'], 'throttled')
        self.assertEqual(result['health_code'], 'collection_stale')

    def test_orphaned_run_is_detected_without_pid_guessing(self):
        import time
        state = dict(status='running', last_attempt=time.time(), last_success=time.time(), stage='collect')
        refresh._write(self.root, 'refresh-state.json', state)
        self.assertEqual(refresh.status(self.root)['health_code'], 'collection_interrupted')
        result = refresh.refresh(self.root)
        self.assertEqual(result['health'], 'error')
        self.assertEqual(result['collection_status'], 'error')
        self.assertEqual(refresh._state(self.root)['error_code'], 'collection_interrupted')

    def test_busy_refresh_keeps_health_and_does_not_touch_owner(self):
        import fcntl, time
        state = dict(status='running', last_attempt=time.time(), last_success=1, stage='collect')
        refresh._write(self.root, 'refresh-state.json', state)
        with open(self.root / 'refresh.lock', 'w') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = refresh.refresh(self.root)
            self.assertEqual(result['status'], 'busy')
            self.assertEqual(result['health_code'], 'collection_stale')
            self.assertEqual(refresh._state(self.root), state)

    def test_collection_race_retries_once_without_advancing_failed_watermark(self):
        race = ValueError('local refresh aborted: input changed')
        with patch.object(refresh, 'export_live', side_effect=[race, self.delta([doc('a', 'one')])]):
            result = refresh.refresh(self.root, force=True)
        self.assertEqual(result['collection_attempts'], 2)
        self.assertEqual(result['health'], 'ok')
        old = lab._snapshot(self.root)
        with patch.object(refresh, 'export_live', side_effect=race) as export:
            failure = refresh.refresh(self.root, force=True)
        self.assertEqual(export.call_count, 2)
        self.assertEqual(failure['error_code'], 'source_changed')
        self.assertEqual(failure['stage'], 'collect')
        self.assertIn('collect', failure['stage_ms'])
        self.assertEqual(failure['since'], result['since'])
        self.assertEqual(lab._snapshot(self.root), old)

    def test_failed_followup_is_not_healthy_after_successful_collection(self):
        config = refresh._config(self.root)
        config['followups'] = {'since': 1}
        refresh._write(self.root, 'refresh-config.json', config)
        with patch.object(refresh, 'export_live', return_value=self.delta([doc('a', 'one')])), \
             patch('retrieval_followup.run', side_effect=ValueError('private data')):
            result = refresh.refresh(self.root, force=True)
        self.assertEqual(result['status'], 'updated')
        self.assertEqual(result['health_code'], 'observation_failed')
        self.assertNotIn('private data', json.dumps(result))


    def test_process_exit_leaves_stage_and_next_attempt_recovers(self):
        import subprocess
        code = "import sys,os,pathlib; sys.path.insert(0,sys.argv[1]); import retrieval_refresh as r; r.export_live=lambda *a,**k: os._exit(23); r.refresh(pathlib.Path(sys.argv[2]),force=True)"
        result = subprocess.run([sys.executable, '-c', code, str(Path(refresh.__file__).parent), str(self.root)])
        self.assertEqual(result.returncode, 23)
        self.assertEqual(refresh.status(self.root)['health_code'], 'collection_interrupted')
        self.assertEqual(refresh.status(self.root)['stage'], 'collect')
        with patch.object(refresh, 'export_live', return_value=self.delta([doc('a', 'recovered')])):
            recovered = refresh.refresh(self.root, force=True)
        self.assertEqual(recovered['health'], 'ok')
        self.assertEqual(recovered['last_failure']['code'], 'collection_interrupted')
        self.assertEqual(recovered['last_failure']['stage'], 'collect')


if __name__ == '__main__':
    unittest.main()
