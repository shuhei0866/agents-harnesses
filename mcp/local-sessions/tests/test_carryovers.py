import concurrent.futures
import tempfile
import unittest
from unittest.mock import patch

from session_bridge import carryovers, dialogue
from session_bridge.store import Store
import test_dialogue


class CarryoverTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.store = Store(self.tmp.name)
        self.store.create('one', 'claude')
        self.store.create('other', 'codex')

    def start(self, request='d1', **extra):
        with patch('session_bridge.dialogue._spawn'):
            return dialogue.start(self.store, 'Synthetic topic', 2, 40, request, **extra)

    def test_one_line_idempotency_and_no_implicit_reopen(self):
        note = carryovers.keep(self.store, 'Still unsure why', 'one', session='one')
        self.assertEqual(note['state'], 'open')
        carryovers.set_state(self.store, note['id'], 'closed')
        same = carryovers.keep(self.store, 'Still unsure why', 'one', session='one')
        self.assertEqual(same['state'], 'closed')
        with self.assertRaisesRegex(ValueError, 'different text'):
            carryovers.keep(self.store, 'Changed', 'one', session='one')
        for value in ('', ' ', 'two\nlines', 'x'*401, 'one\u2028two'):
            with self.assertRaises(ValueError):
                carryovers.keep(self.store, value, 'bad', session='one')
        carryovers.set_state(self.store, note['id'], 'open')
        self.assertEqual(carryovers.listing(Store(self.tmp.name), session='one')['total'], 1)

    def test_concurrent_save_is_unique_and_scopes_are_explicit(self):
        with concurrent.futures.ThreadPoolExecutor(4) as pool:
            results = list(pool.map(lambda _: carryovers.keep(self.store, 'Synthetic', 'same', session='one'), range(4)))
        self.assertEqual(len({x['id'] for x in results}), 1)
        self.assertEqual(carryovers.listing(self.store, session='other')['total'], 0)
        with self.assertRaisesRegex(ValueError, 'exactly one'):
            carryovers.keep(self.store, 'x', 'x')
        first = self.start()
        with self.assertRaisesRegex(ValueError, 'explicitly share'):
            carryovers.keep(self.store, 'Private', 'x', session=first['participants'][1]['id'])

    def test_selection_rotates_without_closing_and_retry_freezes_snapshot(self):
        notes = [carryovers.keep(self.store, f'Concern {i}', str(i), session='one') for i in range(5)]
        before = carryovers.listing(self.store, session='one')['notes']
        self.assertTrue(all(n['selected_at'] == 0 for n in before))
        first, _ = self.store.reserve('one', 'Current', 'send-1')
        snapshot = self.store.public_job(first['id'])['carryovers']
        self.assertEqual(len(snapshot['notes']), 3)
        self.assertEqual(snapshot['omitted_count'], 2)
        carryovers.set_state(self.store, snapshot['notes'][0]['id'], 'closed')
        self.store.update(first['id'], status='failed')
        retry, fresh = self.store.reserve('one', 'Current', 'send-1')
        self.assertFalse(fresh)
        self.assertEqual(self.store.public_job(retry['id'])['carryovers'], snapshot)
        second, _ = self.store.reserve('one', 'New', 'send-2')
        next_notes = self.store.public_job(second['id'])['carryovers']['notes']
        previously_omitted = {n['id'] for n in notes} - {n['id'] for n in snapshot['notes']}
        self.assertTrue(previously_omitted <= {n['id'] for n in next_notes})
        self.assertEqual(carryovers.listing(self.store, session='one')['total'], 4)
        unrelated, _ = self.store.reserve('other', 'New', 'send-3')
        self.assertEqual(self.store.public_job(unrelated['id'])['carryovers']['notes'], [])

    def test_explicit_dialogue_lineage_frozen_for_both_openings(self):
        old = self.start()
        note = carryovers.keep(self.store, 'Unexplained fragment', 'saved', dialogue_id=old['id'])
        continued = self.start('next', continue_from=old['id'])
        snap = continued['carryovers']
        self.assertEqual(snap['notes'][0]['id'], note['id'])
        self.assertEqual(self.start('unrelated')['carryovers']['notes'], [])
        carryovers.set_state(self.store, note['id'], 'closed')
        carryovers.keep(self.store, 'Later addition', 'later', dialogue_id=continued['id'])
        self.assertEqual(self.start('next', continue_from=old['id'])['carryovers'], snap)
        with self.assertRaisesRegex(ValueError, 'different dialogue'):
            self.start('next')
        with self.store.db() as db:
            carryovers.reserve_job(db, 'fake-first', 'unused', continued['id'], 1)
            carryovers.reserve_job(db, 'fake-second', 'unused', continued['id'], 2)
            carryovers.reserve_job(db, 'fake-third', 'unused', continued['id'], 3)
        self.assertEqual(carryovers.for_job(self.store, 'fake-first'), snap)
        self.assertEqual(carryovers.for_job(self.store, 'fake-second'), snap)
        self.assertEqual(carryovers.for_job(self.store, 'fake-third')['notes'], [])
        next_one = self.start('third', continue_from=continued['id'])
        self.assertEqual([n['text'] for n in next_one['carryovers']['notes']], ['Later addition'])

    def test_legacy_dialogue_and_missing_job_snapshot_remain_usable(self):
        old = self.start()
        with self.store.db() as db:
            db.execute('DELETE FROM dialogue_carryovers WHERE dialogue_id=?', (old['id'],))
        carryovers.keep(self.store, 'Legacy fragment', 'note', dialogue_id=old['id'])
        reopened = Store(self.tmp.name)
        self.assertEqual(dialogue.start(reopened, 'Synthetic topic', 2, 40, 'd1')['id'], old['id'])
        self.assertEqual(self.start('next', continue_from=old['id'])['carryovers']['notes'][0]['text'], 'Legacy fragment')
        self.assertEqual(carryovers.for_job(reopened, 'legacy-job')['notes'], [])
        before = len(reopened.sessions())
        with self.assertRaisesRegex(ValueError, 'unknown dialogue'):
            self.start('bad', continue_from='absent')
        self.assertEqual(len(reopened.sessions()), before)

    def test_pagination_is_read_only(self):
        for i in range(5):
            carryovers.keep(self.store, f'Concern {i}', str(i), session='one')
        first = carryovers.listing(self.store, session='one', limit=3)
        rest = carryovers.listing(self.store, session='one', offset=first['next_offset'])
        self.assertTrue(first['has_more'])
        self.assertFalse(rest['has_more'])
        self.assertEqual(len(first['notes']) + len(rest['notes']), 5)
        self.assertTrue(all(n['selected_at'] == 0 for n in first['notes'] + rest['notes']))


class CarryoverRunnerTests(unittest.TestCase):
    # Reuse only the fixture setup, not its test methods.
    setUp = test_dialogue.DialogueTests.setUp
    call_log = test_dialogue.DialogueTests.call_log
    wait = test_dialogue.DialogueTests.wait

    def test_continued_dialogue_injects_once_per_provider_and_preserves_native_resume(self):
        with patch('session_bridge.dialogue._spawn'):
            old = dialogue.start(self.store, 'Old synthetic topic', 2, 40, 'old')
        carryovers.keep(self.store, 'ONE_LINE_FRAGMENT', 'note', dialogue_id=old['id'])
        new = dialogue.start(self.store, 'New synthetic topic', 2, 40, 'new', continue_from=old['id'])
        done = self.wait(new['id'])
        self.assertEqual(done['status'], 'completed', done)
        calls = self.call_log()
        self.assertEqual(['ONE_LINE_FRAGMENT' in c['prompt'] for c in calls], [True, True, False, False])
        self.assertEqual([c['resumed'] for c in calls], [False, False, True, True])
        self.assertEqual(carryovers.listing(self.store, dialogue_id=new['id'])['total'], 1)
