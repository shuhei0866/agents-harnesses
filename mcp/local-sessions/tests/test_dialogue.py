import concurrent.futures
import json
import fcntl
import os
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import patch

from session_bridge import dialogue
from session_bridge.runner import dispatch, run as run_job
from session_bridge.store import Store


FIXTURE = '''#!/usr/bin/env python3
import json, os, pathlib, sys, time, uuid
provider = pathlib.Path(sys.argv[0]).name
prompt = sys.stdin.read()
if provider == 'codex':
    assert 'read-only' in sys.argv and 'never' in sys.argv and '--ignore-user-config' in sys.argv
    resumed = 'resume' in sys.argv
else:
    assert '--safe-mode' in sys.argv and '--strict-mcp-config' in sys.argv
    assert sys.argv[sys.argv.index('--tools')+1] == ''
    resumed = '--resume' in sys.argv
native = str(uuid.uuid5(uuid.NAMESPACE_URL, os.getcwd()))
if resumed:
    flag = 'resume' if provider == 'codex' else '--resume'
    assert sys.argv[sys.argv.index(flag)+1] == native
with open(os.environ['DIALOGUE_TEST_CALLS'], 'a') as log:
    log.write(json.dumps({'provider':provider,'resumed':resumed,'native':native,'prompt':prompt})+'\\n')
mode = os.environ.get('DIALOGUE_TEST_MODE', '')
time.sleep(float(os.environ.get('DIALOGUE_TEST_DELAY', '.1')))
reply = ('R' * 33000 if mode == 'oversize' else provider + (' resumed' if resumed else ' first'))
if provider == 'codex':
    print(json.dumps({'type':'thread.started','thread_id':native}), flush=True)
    print(json.dumps({'type':'item.completed','item':{'type':'agent_message','text':reply}}), flush=True)
    if mode == 'fail':
        print(json.dumps({'type':'turn.failed','error':{'message':'synthetic failure'}}), flush=True)
        sys.exit(1)
    print(json.dumps({'type':'turn.completed','usage':{'input_tokens':100,'cached_input_tokens':80,'output_tokens':5}}), flush=True)
else:
    print(json.dumps({'type':'result','subtype':'success','session_id':native,'result':reply,
                     'total_cost_usd':.2 if resumed else .1,
                     'usage':{'input_tokens':2,'cache_read_input_tokens':100 if resumed else 0,
                              'cache_creation_input_tokens':20,'output_tokens':5}}), flush=True)
'''


class DialogueTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.store = Store(self.root / 'state')
        bindir = self.root / 'bin'; bindir.mkdir()
        for name in ('codex', 'claude'):
            executable = bindir / name
            executable.write_text(FIXTURE); executable.chmod(0o755)
        self.calls = self.root / 'calls.jsonl'
        env = patch.dict(os.environ, {'PATH': str(bindir)+os.pathsep+os.environ['PATH'],
            'CODEX_HOME': str(self.root/'config'), 'DIALOGUE_TEST_CALLS': str(self.calls),
            'DIALOGUE_TEST_MODE': '', 'DIALOGUE_TEST_DELAY': '.1'})
        env.start(); self.addCleanup(env.stop)

    def start(self, **overrides):
        return dialogue.start(self.store, **(dict(topic='SYNTHETIC_TOPIC', max_rounds=2,
            time_budget_seconds=40, request_id='start-1') | overrides))

    def wait(self, did, states=('completed', 'failed', 'stopped', 'timed_out'), seconds=15):
        deadline = time.monotonic()+seconds
        while time.monotonic() < deadline:
            current = dialogue.inspect(self.store, did)
            if current['status'] in states:
                return current
            time.sleep(.05)
        self.fail(current)

    def call_log(self):
        return [json.loads(line) for line in self.calls.read_text().splitlines()] if self.calls.exists() else []

    def test_alternation_native_resume_delta_prompts_and_pagination(self):
        first = self.start(); did=first['id']
        done = self.wait(did)
        self.assertEqual(done['status'], 'completed', done)
        self.assertEqual(done['reason'], 'round_limit')
        self.assertEqual(done['completed_turns'], 4)
        calls = self.call_log()
        self.assertEqual([c['provider'] for c in calls], ['codex','claude','codex','claude'])
        self.assertEqual([c['resumed'] for c in calls], [False,False,True,True])
        self.assertEqual(calls[0]['native'], calls[2]['native'])
        self.assertEqual(calls[1]['native'], calls[3]['native'])
        self.assertNotEqual(calls[0]['native'], calls[1]['native'])
        self.assertIn('SYNTHETIC_TOPIC', calls[0]['prompt'])
        self.assertIn('SYNTHETIC_TOPIC', calls[1]['prompt'])
        self.assertNotIn('SYNTHETIC_TOPIC', calls[2]['prompt'])
        self.assertIn('claude first', calls[2]['prompt'])
        self.assertNotIn('codex first', calls[2]['prompt'])
        self.assertEqual(done['turns'][3]['usage']['cache_read_input_tokens'], 100)
        self.assertEqual(done['turns'][3]['usage']['estimated_session_cost_usd'], .2)
        reopened = Store(self.store.root)
        page = dialogue.inspect(reopened, did, limit=2)
        self.assertTrue(page['has_more']); self.assertEqual(page['next_cursor'],2)
        rest = dialogue.inspect(reopened, did, after_turn=page['next_cursor'])
        self.assertEqual([t['turn'] for t in rest['turns']], [3,4])
        self.assertEqual(self.start()['id'], did)
        self.assertEqual(len(self.call_log()),4)
        with self.assertRaisesRegex(ValueError,'different dialogue'):
            self.start(topic='changed')
        with self.assertRaisesRegex(ValueError,'owned by a dialogue'):
            self.store.reserve(done['participants'][0]['id'],'inject','manual')

    def test_concurrent_start_reserves_once(self):
        with patch('session_bridge.dialogue._spawn') as spawn:
            with concurrent.futures.ThreadPoolExecutor(4) as pool:
                results=list(pool.map(lambda _:self.start(),range(4)))
            self.assertEqual(len({r['id'] for r in results}),1)
            self.assertEqual(spawn.call_count,1)
            self.assertEqual(len(self.store.sessions()),2)

    def test_pause_finishes_reply_and_resume_keeps_budget_and_sessions(self):
        with patch.dict(os.environ, {'DIALOGUE_TEST_DELAY': '.5'}):
            did=self.start(max_rounds=3)['id']
            deadline=time.monotonic()+5
            while time.monotonic()<deadline:
                current=dialogue.inspect(self.store,did)
                if current['active_job'] and self.call_log():break
                time.sleep(.03)
            dialogue.control(self.store,did,'pause')
            paused=self.wait(did,('paused',))
            self.assertEqual(paused['completed_turns'],1)
            self.assertEqual(paused['next_cursor'],1)
            budget=paused['remaining_seconds']; identities=paused['participants']
            time.sleep(.3)
            self.assertEqual(dialogue.inspect(self.store,did)['remaining_seconds'],budget)
            resumed=dialogue.control(self.store,did,'resume')
            self.assertEqual(resumed['participants'],identities)
            done=self.wait(did)
            self.assertEqual(done['completed_turns'],6)
            self.assertLess(done['remaining_seconds'],budget)

    def test_stop_before_dispatch_cancels_reserved_job_before_cli(self):
        with patch('session_bridge.dialogue._spawn'):
            did=self.start()['id']
        row=dialogue._row(self.store,did)
        dialogue._update(self.store,did,status='running',deadline=time.time()+30)
        job,_=self.store.reserve(row['codex_session'],'synthetic','reserved',5,dialogue_id=did,ordinal=1)
        dialogue.control(self.store,did,'stop')
        with self.assertRaisesRegex(ValueError,'not accepting'):
            self.store.reserve(row['claude_session'],'synthetic','next',5,dialogue_id=did,ordinal=2)
        run_job(self.store,job['id'])
        self.assertEqual(self.store.job(job['id'])['status'],'interrupted')
        self.assertEqual(self.call_log(),[])

    def test_stop_interrupts_current_reply_without_forwarding_partial_text(self):
        with patch.dict(os.environ, {'DIALOGUE_TEST_DELAY':'10'}):
            did=self.start()['id']
            deadline=time.monotonic()+5
            while not self.call_log() and time.monotonic()<deadline:time.sleep(.03)
            requested=dialogue.control(self.store,did,'stop')
            self.assertEqual(requested['control'],'stop')
            done=self.wait(did)
            self.assertEqual(done['status'],'stopped',done)
            self.assertEqual(len(self.call_log()),1)
            self.assertIsNone(done['turns'][0]['response'])
            with self.assertRaises(ValueError):dialogue.control(self.store,did,'resume')
            self.assertEqual(dialogue.control(self.store,did,'stop')['status'],'stopped')

    def test_failed_or_oversize_reply_never_reaches_partner(self):
        for mode in ('fail','oversize'):
            with self.subTest(mode=mode),patch.dict(os.environ,{'DIALOGUE_TEST_MODE':mode}):
                before=len(self.call_log())
                did=self.start(request_id=mode)['id']
                done=self.wait(did)
                self.assertEqual(done['status'],'failed',done)
                self.assertEqual(len(self.call_log())-before,1)

    def test_dead_coordinator_rejoins_completed_child_without_replaying(self):
        with patch('session_bridge.dialogue._spawn'):
            did=self.start()['id']
        row=dialogue._row(self.store,did)
        dialogue._update(self.store,did,status='running',deadline=time.time()+30)
        job,_=self.store.reserve(row['codex_session'],'synthetic','reserved',5,dialogue_id=did,ordinal=1)
        self.store.update(job['id'],status='completed',response='persisted first reply')
        with self.store.db() as db:db.execute('UPDATE dialogues SET updated=0 WHERE id=?',(did,))
        self.assertEqual(dialogue.inspect(self.store,did)['status'],'uncertain')
        dialogue.control(self.store,did,'resume')
        done=self.wait(did)
        self.assertEqual(done['status'],'completed',done)
        self.assertEqual(len(self.call_log()),3)
        self.assertEqual(done['turns'][0]['job_id'],job['id'])
        self.assertIn('persisted first reply',self.call_log()[0]['prompt'])

    def test_uncertain_child_blocks_resume(self):
        with patch('session_bridge.dialogue._spawn'):
            did=self.start()['id']
        row=dialogue._row(self.store,did)
        dialogue._update(self.store,did,status='running',deadline=time.time()+30)
        job,_=self.store.reserve(row['codex_session'],'synthetic','reserved',5,dialogue_id=did,ordinal=1)
        self.store.update(job['id'],status='uncertain')
        dialogue._update(self.store,did,status='uncertain',deadline=None)
        with self.assertRaisesRegex(ValueError,'cannot be resumed safely'):
            dialogue.control(self.store,did,'resume')
        self.assertEqual(self.call_log(),[])

    def test_child_obeys_persisted_absolute_deadline_without_coordinator(self):
        with patch('session_bridge.dialogue._spawn'):
            did=self.start()['id']
        row=dialogue._row(self.store,did)
        dialogue._update(self.store,did,status='running',deadline=time.time()+30)
        job,_=self.store.reserve(row['codex_session'],'synthetic','reserved',5,dialogue_id=did,ordinal=1)
        with self.store.db() as db:db.execute('UPDATE dialogue_turns SET deadline=0 WHERE job_id=?',(job['id'],))
        run_job(self.store,job['id'])
        self.assertEqual(self.store.job(job['id'])['status'],'timed_out')
        self.assertEqual(self.call_log(),[])

    def test_time_budget_interrupts_in_flight(self):
        with patch.dict(os.environ, {'DIALOGUE_TEST_DELAY':'20'}):
            started=time.monotonic()
            did=self.start(time_budget_seconds=10)['id']
            done=self.wait(did,seconds=16)
            self.assertEqual(done['status'],'timed_out',done)
            self.assertLess(time.monotonic()-started,16)
            self.assertEqual(len(self.call_log()),1)
            self.assertEqual(done['completed_turns'],0)

    def test_invalid_limits_do_not_create_partners(self):
        for override in ({'max_rounds':0},{'max_rounds':True},{'time_budget_seconds':float('nan')},
                         {'turn_timeout_seconds':601},{'topic':' '},{'claude_model':''}):
            with self.assertRaises(ValueError):self.start(**override)
        self.assertEqual(self.store.sessions(),[])

    def test_resume_waits_for_previous_coordinator_to_release_lock(self):
        with patch('session_bridge.dialogue._spawn'):
            did=self.start()['id']
        dialogue._update(self.store,did,status='paused')
        with open(self.store.root / f'{did}.dialogue.lock', 'a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            dialogue.control(self.store,did,'resume')
            time.sleep(.4)
            self.assertEqual(dialogue.inspect(self.store,did)['status'],'queued')
        self.assertEqual(self.wait(did)['status'],'completed')

    def test_control_wins_race_with_pause_boundary(self):
        with patch('session_bridge.dialogue._spawn'):
            did=self.start()['id']
        dialogue._update(self.store,did,status='running',control=None,deadline=time.time()+30)
        self.assertFalse(dialogue._finish(self.store,did,'paused','requested_pause'))
        self.assertEqual(dialogue.inspect(self.store,did)['status'],'running')
        dialogue.control(self.store,did,'stop')
        dialogue._finish(self.store,did,'paused','requested_pause')
        self.assertEqual(dialogue.inspect(self.store,did)['status'],'stopped')

    def test_lost_coordinator_does_not_reset_budget(self):
        with patch('session_bridge.dialogue._spawn'):
            did=self.start()['id']
        dialogue._update(self.store,did,status='running',deadline=time.time()+.3)
        with self.store.db() as db:db.execute('UPDATE dialogues SET updated=0 WHERE id=?',(did,))
        self.assertEqual(dialogue.inspect(self.store,did)['status'],'uncertain')
        time.sleep(.4)
        self.assertEqual(dialogue.inspect(self.store,did)['remaining_seconds'],0)
        with self.assertRaisesRegex(ValueError,'no time left'):
            dialogue.control(self.store,did,'resume')

    def test_child_rechecks_wall_deadline_after_clock_advance(self):
        with patch('session_bridge.dialogue._spawn'):
            did=self.start()['id']
        row=dialogue._row(self.store,did)
        dialogue._update(self.store,did,status='running',deadline=time.time()+30)
        job,_=self.store.reserve(row['codex_session'],'synthetic','reserved',20,dialogue_id=did,ordinal=1)
        wall_time=time.time
        # Model a suspend/wake while monotonic time has barely advanced.
        def clock_after_launch():
            return wall_time() + (3600 if self.calls.exists() else 0)
        started=time.monotonic()
        with patch.dict(os.environ,{'DIALOGUE_TEST_DELAY':'20'}),patch('session_bridge.runner.time.time',clock_after_launch):
            run_job(self.store,job['id'])
        self.assertLess(time.monotonic()-started,5)
        self.assertEqual(self.store.job(job['id'])['status'],'timed_out')
        self.assertEqual(len(self.call_log()),1)
