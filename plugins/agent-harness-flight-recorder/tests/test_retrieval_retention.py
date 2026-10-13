import concurrent.futures
import json
import os
from pathlib import Path
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
import retrieval_lab as lab
import retrieval_retention as retention
import retrieval_refresh as refresh


def corpus(text):
    return dict(schema_version=1, documents=[dict(source_id='example', start_line=1,
                                                end_line=1, text=text, summaries=[])])


class RetentionTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name) / 'lab'
        lab.create_lab(self.root, corpus('first decision'))

    def publish(self, text):
        return lab.publish_snapshot(self.root, corpus(text))['snapshot_id']

    def archive(self):
        return {p.stem for p in (self.root / 'snapshots').glob('*.json')}

    def test_preserves_queries_historical_packets_and_local_fixtures(self):
        query = lab.search(self.root, 'decision', sample_rate=0)
        opportunity = self.publish('opportunity decision')
        followup = self.publish('old followup revision')
        fixture = self.publish('frozen regression')
        obsolete = self.publish('unreferenced')
        current = self.publish('current')
        with lab._connect(self.root) as db:
            for table, identity in [('recall_opportunities', opportunity), ('recall_followups', followup)]:
                db.execute('CREATE TABLE '+table+' (packet TEXT)')
                db.execute('INSERT INTO '+table+' VALUES(?)', (json.dumps({'snapshot_id': identity}),))
        (self.root / 'fixture.json').write_text(json.dumps({'frozen_generation': fixture}))
        before = retention.inspect(self.root, {'keep_recent': 0})
        self.assertIn(obsolete, self.archive())
        self.assertEqual(before['removable_count'], 1)
        result = retention.maintain(self.root, {'keep_recent': 0})
        self.assertEqual(result['deleted_count'], 1)
        self.assertEqual(self.archive(), {query['snapshot_id'], opportunity, followup, fixture, current})
        self.assertEqual(lab.read_citation(self.root, query['hits'][0]['citation_id'], query['request_id'])['text'], 'first decision')
        self.assertEqual(retention.maintain(self.root, {'keep_recent': 0})['deleted_count'], 0)
        self.assertEqual(retention.read_status(self.root)['last_cleanup']['deleted_count'], 1)

    def test_manual_pin_protects_external_fixture(self):
        identity = lab._snapshot(self.root)['snapshot_id']
        retention.pin(self.root, identity)
        self.publish('next')
        retention.maintain(self.root, {'keep_recent': 0})
        self.assertIn(identity, self.archive())

    def test_over_budget_recovers_without_discarding_references(self):
        request = lab.search(self.root, 'decision', sample_rate=0)
        for i in range(8):
            self.publish('generation '+str(i))
        files = list((self.root / 'snapshots').glob('*.json'))
        required = sum(p.stat().st_size for p in files if p.stem in (request['snapshot_id'], lab._snapshot(self.root)['snapshot_id']))
        result = retention.maintain(self.root, {'budget_bytes': required, 'keep_recent': 3})
        self.assertEqual(result['archive_bytes'], required)
        self.assertEqual(result['warning'], 'snapshot_capacity_high')
        self.assertEqual(len(self.archive()), 2)

    def test_protected_overflow_blocks_without_deletion(self):
        lab.search(self.root, 'decision', sample_rate=0)
        self.publish('unreferenced')
        self.publish('current')
        before = self.archive()
        with self.assertRaisesRegex(retention.RetentionError, 'protected_snapshots_exceed_budget'):
            retention.maintain(self.root, {'budget_bytes': 1, 'keep_recent': 0})
        self.assertEqual(self.archive(), before)
        self.assertEqual(retention.read_status(self.root)['status'], 'error')

    def test_publication_reserves_space_before_switching(self):
        lab.search(self.root, 'decision', sample_rate=0)
        self.publish('current')
        before = lab._snapshot(self.root)
        size = sum(p.stat().st_size for p in (self.root / 'snapshots').glob('*.json'))
        with self.assertRaises(retention.RetentionError):
            lab.publish_snapshot(self.root, corpus('new corpus'), storage_policy={'budget_bytes': size})
        self.assertEqual(lab._snapshot(self.root), before)
        self.assertEqual(len(self.archive()), 2)

    def test_missing_required_snapshot_aborts_cleanup(self):
        request = lab.search(self.root, 'decision', sample_rate=0)
        self.publish('unused')
        self.publish('current')
        (self.root / 'snapshots' / (request['snapshot_id']+'.json')).unlink()
        before = self.archive()
        with self.assertRaises(retention.RetentionError):
            retention.maintain(self.root, {'keep_recent': 0})
        self.assertEqual(self.archive(), before)

    def test_corrupt_candidate_aborts_all_deletions(self):
        identity = self.publish('bad candidate')
        self.publish('current')
        (self.root / 'snapshots' / (identity+'.json')).write_text('{}')
        before = self.archive()
        with self.assertRaises(retention.RetentionError):
            retention.maintain(self.root, {'keep_recent': 0})
        self.assertEqual(self.archive(), before)

    def test_reference_symlink_and_scan_limit_fail_closed(self):
        self.publish('current')
        (self.root / 'fixture.json').symlink_to(self.root / 'snapshot.json')
        with self.assertRaisesRegex(retention.RetentionError, 'unsafe_reference_path'):
            retention.maintain(self.root, {'keep_recent': 0})
        (self.root / 'fixture.json').unlink()
        (self.root / 'fixture.json').write_text('large reference file')
        with patch.object(retention, 'MAX_REFERENCE_BYTES', 1):
            with self.assertRaisesRegex(retention.RetentionError, 'reference_scan_budget_exhausted'):
                retention.maintain(self.root, {'keep_recent': 0})
        self.assertEqual(len(self.archive()), 2)

    def test_warning_and_prospective_size_are_visible(self):
        self.publish('current')
        size = sum(p.stat().st_size for p in (self.root / 'snapshots').glob('*.json'))
        result = retention.maintain(self.root, {'budget_bytes': size+10, 'warning_percent': 80})
        self.assertEqual(result['warning'], 'snapshot_capacity_high')
        result = lab.publish_snapshot(self.root, corpus('next'), storage_policy={})
        actual = sum(p.stat().st_size for p in (self.root / 'snapshots').glob('*.json*'))
        self.assertEqual(result['storage']['archive_bytes'], actual)
        self.assertEqual(result['storage']['reserved_bytes'], 0)

    def test_search_registers_reference_before_cleanup_can_proceed(self):
        loaded, resume, publishing = threading.Event(), threading.Event(), threading.Event()
        original = lab._retrieve
        def paused(*args, **kwargs):
            loaded.set()
            if not resume.wait(5):
                raise RuntimeError('test timed out')
            return original(*args, **kwargs)
        def replace_twice():
            publishing.set()
            lab.publish_snapshot(self.root, corpus('next'), storage_policy={'keep_recent': 0})
            lab.publish_snapshot(self.root, corpus('after next'), storage_policy={'keep_recent': 0})
        with concurrent.futures.ThreadPoolExecutor(2) as pool:
            with patch.object(lab, '_retrieve', side_effect=paused):
                query = pool.submit(lab.search, self.root, 'decision', sample_rate=0)
                self.assertTrue(loaded.wait(5))
                publication = pool.submit(replace_twice)
                self.assertTrue(publishing.wait(5))
                with self.assertRaises(concurrent.futures.TimeoutError):
                    publication.result(timeout=0.1)
                resume.set()
                request = query.result(timeout=5)
                publication.result(timeout=5)
        retention.maintain(self.root, {'keep_recent': 0})
        self.assertEqual(lab._snapshot(self.root, request['snapshot_id'])['documents'][0]['text'], 'first decision')

    def test_refresh_failure_keeps_watermark_and_reports_capacity(self):
        (self.root / 'refresh-config.json').write_text(json.dumps(dict(schema_version=1,
            roots=[dict(adapter='codex', path=str(self.root.parent))], retention={'budget_bytes': 1})))
        self.publish('current')
        refresh._write(self.root, 'refresh-state.json', {'since': 123, 'last_success': 456})
        result = refresh.refresh(self.root, force=True)
        self.assertEqual(result['status'], 'error')
        self.assertEqual(result['last_success'], 456)
        self.assertEqual(result['since'], 123)
        self.assertEqual(result['error_code'], 'protected_snapshots_exceed_budget')
        throttled = refresh.refresh(self.root)
        self.assertEqual(throttled['collection_status'], 'error')
        self.assertEqual(throttled['storage']['warning'], 'protected_snapshots_exceed_budget')


if __name__ == '__main__':
    unittest.main()
