"""Synthetic evidence only: shared storage must preserve historical bytes."""
import hashlib
import json
import random
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
import retrieval_lab as lab
import retrieval_archive as archive
import retrieval_retention as retention
import retrieval_shared as shared


def corpus(revision):
    rng = random.Random(123)
    docs = [dict(source_id='source-'+str(i), start_line=1, end_line=1,
                 text='decision 日本語 '+''.join(rng.choices('abcdefghijklmnopqrstuvwxyz', k=5000)),
                 summaries=['topic']) for i in range(12)]
    docs[6]['text'] += str(revision)
    return dict(schema_version=1, documents=docs)


class SharedTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve() / 'lab'
        lab.create_lab(self.root, corpus(0))
        self.query = lab.search(self.root, 'decision', sample_rate=1)
        for n in range(1, 5):
            lab.publish_snapshot(self.root, corpus(n))
        archive.compress(self.root, 100)
        self.before = {archive.identity(p): archive.read_file(p) for p, _ in archive.entries(self.root)}

    def test_lossless_dedup_and_historical_citation(self):
        result = shared.migrate(self.root, 100)
        self.assertEqual(result['converted'], 5)
        self.assertLess(result['after_bytes'], result['before_bytes'] / 2)
        for key, raw in self.before.items():
            self.assertEqual(archive.read(self.root, key), raw)
        self.assertEqual(lab.drain(self.root)['processed'], 1)
        cited = lab.read_citation(self.root, self.query['hits'][0]['citation_id'], self.query['request_id'])
        self.assertIn('decision 日本語', cited['text'])
        self.assertEqual(shared.migrate(self.root, 100)['converted'], 0)

    def test_noncanonical_unicode_bytes_roundtrip(self):
        key, raw = next(iter(self.before.items()))
        raw = (' \n'+json.dumps(json.loads(raw), ensure_ascii=False, indent=3)+' \n').encode()
        with lab.snapshot_lock(self.root, exclusive=True):
            path = shared.write(self.root, key, shared.prepare(raw, key))
        self.assertEqual(shared.read(path), raw)

    def test_interruption_after_manifest_commit_preserves_twin_and_retry(self):
        target = next(iter(sorted(self.before)))
        old = self.root/'snapshots'/(target+'.json.gz')
        unlink = Path.unlink
        def fail(path, *args, **kwargs):
            if path == old:
                raise OSError('interruption')
            return unlink(path, *args, **kwargs)
        with patch.object(Path, 'unlink', fail):
            with self.assertRaises(OSError):
                shared.migrate(self.root, 100)
        self.assertTrue(old.exists())
        self.assertEqual(archive.read(self.root, target), self.before[target])
        shared.migrate(self.root, 100)
        self.assertFalse(old.exists())
        self.assertEqual(archive.read(self.root, target), self.before[target])

    def test_disk_failure_never_removes_legacy(self):
        with patch.object(lab, '_atomic_snapshot_file', side_effect=OSError('disk full')):
            with self.assertRaises(OSError):
                shared.migrate(self.root, 100)
        for key, raw in self.before.items():
            self.assertEqual(archive.read(self.root, key), raw)

    def test_retention_accounts_union_and_keeps_shared_evidence(self):
        shared.migrate(self.root, 100)
        objects = shared.inventory(self.root)
        result = retention.maintain(self.root, {'keep_recent': 0})
        self.assertEqual(result['archive_count'], 2)
        self.assertGreater(result['freed_bytes'], 0)
        paths = [p for p, _ in archive.entries(self.root)]
        self.assertEqual(result['archive_bytes'], shared.usage(paths, shared.inventory(self.root)))
        self.assertEqual(set(shared.inventory(self.root)), shared.references(paths))
        self.assertLess(len(shared.inventory(self.root)), len(objects))
        self.assertEqual(archive.read(self.root, self.query['snapshot_id']), self.before[self.query['snapshot_id']])

    def test_publication_admits_incremental_bytes_and_remains_shared(self):
        shared.migrate(self.root, 100)
        result = retention.maintain(self.root, {'keep_recent': 0})
        value, raw = lab._build_snapshot(corpus(5))
        meta, chunks = shared.prepare(raw, value['snapshot_id'])
        existing = shared.inventory(self.root)
        added = len(meta)+sum(len(data) for key, data in chunks.items() if key not in existing)
        budget = result['archive_bytes']+added
        self.assertLess(added, len(archive.pack(raw)))
        published = lab.publish_snapshot(self.root, corpus(5), storage_policy={'keep_recent': 0, 'budget_bytes': budget})
        self.assertEqual(published['storage']['archive_bytes'], budget)
        self.assertEqual(archive.read(self.root, value['snapshot_id']), raw)
        self.assertTrue(all(p.suffix == '.ref' for p, _ in archive.entries(self.root)))

    def test_missing_or_corrupt_block_aborts_cleanup(self):
        shared.migrate(self.root, 100)
        key = self.query['snapshot_id']
        path = self.root/'snapshots'/(key+'.json.ref')
        ref = shared.manifest(path)['blocks'][0]
        block = shared.object_path(self.root, ref['hash'])
        original = block.read_bytes()
        for corrupt in (None, b'bad gzip'):
            if corrupt is None:
                block.unlink()
            else:
                block.write_bytes(corrupt); block.chmod(0o600)
            before = {p.name for p, _ in archive.entries(self.root)}
            with self.assertRaises((ValueError, OSError)):
                archive.read(self.root, key)
            with self.assertRaises(retention.RetentionError):
                retention.maintain(self.root, {'keep_recent': 0})
            self.assertEqual(before, {p.name for p, _ in archive.entries(self.root)})
            block.write_bytes(original); block.chmod(0o600)

    def test_unused_blocks_collected_but_new_publication_objects_reserved(self):
        shared.migrate(self.root, 100)
        orphan = b'orphan block'
        key = hashlib.sha256(orphan).hexdigest()
        lab._atomic_snapshot_file(shared.object_path(self.root, key), archive.pack(orphan))
        retention.maintain(self.root, {'keep_recent': 0}, protected_objects={key})
        self.assertTrue(shared.object_path(self.root, key).exists())
        result = retention.maintain(self.root, {'keep_recent': 0})
        self.assertFalse(shared.object_path(self.root, key).exists())
        self.assertEqual(result['freed_bytes'], len(archive.pack(orphan)))

    def test_new_generation_can_reuse_blocks_of_evicted_generation(self):
        shared.migrate(self.root, 100)
        # Revision 2 is unpinned and is about to be evicted, but its changed
        # source is reused in a genuinely new generation.
        next_corpus = corpus(2)
        next_corpus['documents'][7]['text'] += 'another change'
        value, raw = lab._build_snapshot(next_corpus)
        meta, chunks = shared.prepare(raw, value['snapshot_id'])
        current = lab._snapshot(self.root)['snapshot_id']
        protected = [p for p, _ in archive.entries(self.root)
                     if archive.identity(p) in (current, self.query['snapshot_id'])]
        existing = shared.inventory(self.root)
        keep = shared.references(protected) | (set(chunks) & existing.keys())
        budget = (sum(p.stat().st_size for p in protected) + sum(existing[k] for k in keep)
                  + len(meta) + sum(len(v) for k, v in chunks.items() if k not in existing))
        result = lab.publish_snapshot(self.root, next_corpus,
                                      storage_policy={'budget_bytes': budget, 'keep_recent': 0})
        self.assertEqual(result['storage']['archive_bytes'], budget)
        self.assertEqual(archive.read(self.root, value['snapshot_id']), raw)
        self.assertEqual(sum(i.st_size for _, i in archive.entries(self.root))
                         + sum(shared.inventory(self.root).values()), budget)

    def test_manifest_tampering_and_symlinks_rejected(self):
        shared.migrate(self.root, 100)
        path = next(p for p, _ in archive.entries(self.root))
        raw = path.read_bytes(); meta = json.loads(raw)
        meta['blocks'][0]['hash'] = '../unsafe'
        path.write_text(json.dumps(meta))
        with self.assertRaises(ValueError):
            shared.read(path)
        path.write_bytes(raw)
        key = shared.manifest(path)['blocks'][0]['hash']
        block = shared.object_path(self.root, key)
        block.unlink(); block.symlink_to(self.root/'snapshot.json')
        with self.assertRaises((ValueError, OSError)):
            shared.read(path)


if __name__ == '__main__':
    unittest.main()
