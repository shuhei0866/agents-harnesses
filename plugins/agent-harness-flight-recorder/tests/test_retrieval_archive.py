import gzip
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
import retrieval_lab as lab
import retrieval_archive as archive
import retrieval_retention as retention
import retrieval_refresh as refresh


def corpus(text):
    return dict(schema_version=1, documents=[dict(source_id='source', start_line=1,
                                                end_line=1, text=text, summaries=['topic'])])


class ArchiveTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = (Path(self.tmp.name) / 'lab').resolve()
        lab.create_lab(self.root, corpus('earlier decision '*100))
        self.query = lab.search(self.root, 'decision', sample_rate=1)
        lab.publish_snapshot(self.root, corpus('current decision '*100))
        self.old = self.root/'snapshots'/(self.query['snapshot_id']+'.json')

    def test_round_trip_preserves_every_byte_and_old_search_evidence(self):
        before = {p.name[:64]:p.read_bytes() for p,_ in archive.entries(self.root)}
        original_time = self.old.stat().st_mtime_ns
        stats = archive.compress(self.root, 100)
        self.assertEqual(stats['converted'],2)
        self.assertGreater(stats['saved_bytes'],0)
        for identity,raw in before.items():
            self.assertEqual(archive.read(self.root,identity),raw)
        self.assertEqual(self.old.with_suffix('.json.gz').stat().st_mtime_ns,original_time)
        self.assertEqual(lab.drain(self.root)['processed'],1)
        result = lab.read_citation(self.root,self.query['hits'][0]['citation_id'],self.query['request_id'])
        self.assertEqual(result['text'],'earlier decision '*100)
        self.assertEqual(archive.compress(self.root,100)['converted'],0)

    def test_mixed_formats_are_counted_by_actual_bytes_and_pinned(self):
        archive.compress(self.root,1)
        result=retention.maintain(self.root,{'keep_recent':0})
        self.assertEqual(result['archive_count'],2)
        self.assertEqual(result['archive_bytes'],sum(i.st_size for _,i in archive.entries(self.root)))
        self.assertEqual(lab._snapshot(self.root,self.query['snapshot_id'])['snapshot_id'],self.query['snapshot_id'])

    def test_capacity_admission_uses_compressed_size(self):
        archive.compress(self.root,100)
        new=corpus('very compressible new value '*1000)
        _,raw=lab._build_snapshot(new)
        current_bytes=sum(i.st_size for _,i in archive.entries(self.root))
        budget=current_bytes+len(archive.pack(raw))
        self.assertLess(budget,len(raw))
        result=lab.publish_snapshot(self.root,new,storage_policy={'budget_bytes':budget})
        self.assertEqual(result['storage']['archive_bytes'],budget)
        self.assertLessEqual(sum(i.st_size for _,i in archive.entries(self.root)),budget)
        self.assertTrue((self.root/'snapshot.json').exists())

    def test_crash_after_gzip_commit_leaves_plain_and_retry_finishes(self):
        before=self.old.read_bytes();unlink=Path.unlink
        def fail_old(path,*args,**kwargs):
            if path==self.old:raise OSError('simulated interruption')
            return unlink(path,*args,**kwargs)
        with patch.object(Path,'unlink',fail_old):
            with self.assertRaises(OSError):archive.compress(self.root,100)
        self.assertEqual(self.old.read_bytes(),before)
        self.assertEqual(archive.read_file(self.old.with_suffix('.json.gz')),before)
        archive.compress(self.root,100)
        self.assertFalse(self.old.exists())
        self.assertEqual(archive.read(self.root,self.query['snapshot_id']),before)

    def test_bad_or_conflicting_twin_never_removes_original(self):
        raw=self.old.read_bytes();target=self.old.with_suffix('.json.gz')
        target.write_bytes(b'invalid gzip');target.chmod(0o600)
        with self.assertRaises(ValueError):archive.compress(self.root,100)
        self.assertEqual(self.old.read_bytes(),raw)
        value=json.loads(raw);value['import_report']={'different':True}
        target.write_bytes(archive.pack(lab.canonical(value).encode()))
        with self.assertRaisesRegex(ValueError,'differs from original'):archive.compress(self.root,100)
        self.assertEqual(self.old.read_bytes(),raw)

    def test_truncated_corrupt_or_oversized_expansion_is_rejected(self):
        packed=archive.pack(b'x'*100)
        for raw in [packed[:-4],packed[:12]+b'bad'+packed[15:]]:
            with self.assertRaises(ValueError):archive.unpack(raw)
        with patch.object(lab,'MAX_SNAPSHOT_BYTES',50):
            with self.assertRaisesRegex(ValueError,'exceeds bound'):archive.unpack(packed)

    def test_reader_handles_conversion_between_lookup_and_open(self):
        original=archive.read_file;switched=False
        def racing(path):
            nonlocal switched
            if path==self.old and not switched:
                switched=True;archive.compress(self.root,100)
            return original(path)
        with patch.object(archive,'read_file',side_effect=racing):
            self.assertEqual(lab._snapshot(self.root,self.query['snapshot_id'])['snapshot_id'],self.query['snapshot_id'])

    def test_symlink_target_is_not_followed(self):
        target=self.old.with_suffix('.json.gz')
        outside=self.root.parent/'outside';outside.write_bytes(b'do not touch')
        target.symlink_to(outside)
        with self.assertRaises(ValueError):archive.compress(self.root,100)
        self.assertTrue(self.old.exists())
        self.assertEqual(outside.read_bytes(),b'do not touch')

    def test_duplicate_formats_count_once_and_unused_twins_are_deleted_together(self):
        extra=lab.publish_snapshot(self.root,corpus('spare'))['snapshot_id']
        lab.publish_snapshot(self.root,corpus('current'))
        path=self.root/'snapshots'/(extra+'.json')
        twin=path.with_suffix('.json.gz');twin.write_bytes(archive.pack(path.read_bytes()));twin.chmod(0o600)
        plan=retention.inspect(self.root,{'keep_recent':0})
        self.assertEqual(plan['archive_count'],4)
        self.assertEqual(plan['removable_count'],2)
        retention.maintain(self.root,{'keep_recent':0})
        self.assertFalse(path.exists());self.assertFalse(twin.exists())
        self.assertEqual(lab._snapshot(self.root,self.query['snapshot_id'])['snapshot_id'],self.query['snapshot_id'])

    def test_same_generation_is_not_duplicated_after_compression(self):
        archive.compress(self.root,100)
        before=sum(i.st_size for _,i in archive.entries(self.root))
        lab.publish_snapshot(self.root,corpus('current decision '*100),storage_policy={})
        self.assertEqual(sum(i.st_size for _,i in archive.entries(self.root)),before)
        self.assertEqual(len(archive.entries(self.root)),2)

    def test_refresh_compresses_in_bounded_batches_then_keeps_collecting(self):
        for index in range(5):lab.publish_snapshot(self.root,corpus('old '+str(index)))
        (self.root/'refresh-config.json').write_text(json.dumps(dict(schema_version=1,
            roots=[dict(adapter='codex',path=str(self.root.parent))])))
        delta=dict(documents=corpus('fresh')['documents'],refreshed_source_ids=['source'],excluded_source_ids=[],import_report={})
        with patch.object(refresh,'export_live',return_value=delta):result=refresh.refresh(self.root,force=True)
        self.assertEqual(result['compression']['converted'],2)
        self.assertEqual(result['status'],'updated')
        self.assertEqual(lab._snapshot(self.root)['documents'][0]['text'],'fresh')
        self.assertEqual(lab._snapshot(self.root,self.query['snapshot_id'])['snapshot_id'],self.query['snapshot_id'])

    def test_disk_write_failure_preserves_plain_evidence(self):
        before=self.old.read_bytes()
        with patch.object(lab,'_atomic_snapshot_file',side_effect=OSError('disk full')):
            with self.assertRaises(OSError):archive.compress(self.root,100)
        self.assertEqual(self.old.read_bytes(),before)
        self.assertEqual(lab._snapshot(self.root,self.query['snapshot_id'])['snapshot_id'],self.query['snapshot_id'])

    def test_non_object_snapshot_fails_cleanly(self):
        self.old.write_text('[]')
        with self.assertRaises(ValueError):archive.compress(self.root,100)
        self.assertEqual(self.old.read_text(),'[]')
        target=self.old.with_suffix('.json.gz')
        target.write_bytes(archive.pack(b'null'));target.chmod(0o600)
        with self.assertRaises(ValueError):lab._snapshot(self.root,self.query['snapshot_id'])

    def test_compression_can_recover_an_over_budget_archive(self):
        raw_bytes=sum(i.st_size for _,i in archive.entries(self.root))
        budget=raw_bytes//2
        with self.assertRaises(retention.RetentionError):retention.maintain(self.root,{'budget_bytes':budget})
        archive.compress(self.root,100)
        result=retention.maintain(self.root,{'budget_bytes':budget})
        self.assertEqual(result['status'],'ok')
        self.assertLess(result['archive_bytes'],budget)
        self.assertEqual(result['archive_count'],2)


if __name__=='__main__':unittest.main()
