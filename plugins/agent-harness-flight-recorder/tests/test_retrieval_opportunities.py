import datetime as dt
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
import retrieval_lab as lab
import retrieval_live as live
import retrieval_opportunities as audit
import retrieval_refresh as refresh
import retrieval_observer as observer


def build(manifest):
    return lab._build_snapshot(manifest)[0]


def msg(text, second, role='user'):
    return dict(type='response_item', timestamp=dt.datetime.fromtimestamp(second, dt.timezone.utc).isoformat(),
                payload=dict(type='message', role=role, content=[dict(type='input_text', text=text)]))


class OpportunityTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name).resolve()
        self.logs = self.base/'logs'; self.logs.mkdir()
        self.root = self.base/'lab'
        self.write('past', [msg('Project budget must stay below twenty', 100), msg('Acknowledged', 101, 'assistant')])
        self.write('current', [msg('Plan project budget', 200), msg('Proposed unlimited budget', 201, 'assistant'),
                               msg('I already said twenty is the limit', 202), msg('Correcting it', 203, 'assistant'),
                               msg('Continue project planning', 204), msg('Planning', 205, 'assistant'), msg('Thanks', 206)])
        self.write('future', [msg('Plan project budget twenty FUTURE_ONLY', 300)])
        self.snapshot = build(live.export_live([('codex', self.logs)], since=0))
        lab.create_lab(self.root, dict(schema_version=1, documents=self.snapshot['documents']))

    def write(self, name, records, sid=None):
        meta = dict(type='session_meta', payload=dict(id=sid or name))
        (self.logs/(name+'.jsonl')).write_text(''.join(json.dumps(x)+'\n' for x in [meta]+records))

    def test_prior_request_only_future_and_same_session_excluded(self):
        items = audit.turns(self.snapshot)
        selected, counts = audit.candidates(items, 0, 400)
        target = next(x for x in selected if x['kind']=='later_correction')
        packet = audit.replay(self.snapshot, items, target)
        self.assertEqual(packet['query'], 'Plan project budget')
        self.assertNotIn('twenty', packet['query'])
        self.assertIn('already said', packet['cue']['text'])
        self.assertEqual(packet['prior_candidates'], 1)
        self.assertIn('twenty', packet['hits'][0]['utterance']['text'])
        self.assertNotIn('FUTURE_ONLY', json.dumps(packet['hits']))
        self.assertEqual(packet['availability_at_turn'], 'unknown')
        self.assertGreater(counts['pending_or_no_answer'], 0)
        self.assertEqual(counts['control_candidates'], 1)

    def test_tool_marker_excludes_anchor_but_not_plain_user_mention(self):
        tool = dict(type='response_item', timestamp='1970-01-01T00:03:20.500000+00:00',
                    payload=dict(type='function_call',name='exec_command',arguments=json.dumps({'cmd':'recall-history corrections budget --trigger resume'})))
        self.write('current', [msg('Plan project budget',200),tool,msg('Answer',201,'assistant'),msg('I already said twenty',202)])
        snapshot = build(live.export_live([('codex', self.logs)],since=0))
        selected, counts = audit.candidates(audit.turns(snapshot),0,400)
        self.assertFalse(any(x['kind']=='later_correction' for x in selected))
        self.assertEqual(counts['recall_marker_observed'],1)
        self.write('current',[msg('recall-history: previously decided project budget?',200),msg('Answer',201,'assistant'),msg('Thanks',202)])
        snapshot = build(live.export_live([('codex',self.logs)],since=0))
        selected,_=audit.candidates(audit.turns(snapshot),0,400)
        self.assertTrue(any(x['kind']=='explicit_history_reference' for x in selected))

    def test_unknown_timestamps_and_bridge_sources_never_become_misses(self):
        self.write('broken',[msg('previously decided budget?',210),msg('Answer',209,'assistant'),msg('Thanks',211)])
        self.write('bridge',[msg(live.BRIDGE_PROMPT,200),msg('previously decided budget?',201),msg('Answer',202,'assistant'),msg('Thanks',203)])
        snapshot=build(live.export_live([('codex',self.logs)],since=0))
        selected,counts=audit.candidates(audit.turns(snapshot),0,400)
        self.assertGreater(counts['timestamp_unknown'],0)
        self.assertFalse(any(x['anchor']['observation']['native_session_id'] in ('broken','bridge') for x in selected))

    def test_archive_identity_and_metadata_validation(self):
        self.write('archive',[msg('Plan project budget',200),msg('Answer',201,'assistant'),msg('I already said twenty',202)],sid='current')
        snapshot=build(live.export_live([('codex',self.logs)],since=0))
        items=audit.turns(snapshot);selected,counts=audit.candidates(items,0,400)
        self.assertGreater(counts['duplicate_turns'],0)
        target=next(x for x in selected if x['kind']=='later_correction')
        self.assertEqual(audit.replay(snapshot,items,target)['prior_candidates'],1)
        bad=json.loads(json.dumps(snapshot));bad['documents'][0]['turn_observations'][0]['timestamp']=float('nan')
        with self.assertRaises(ValueError):lab._build_snapshot(bad)

    def test_idempotent_bounded_and_separate_from_task_measurements(self):
        with patch.object(audit,'MAX_CASES',1):
            first=audit.run(self.root,self.snapshot,dict(since=0,prospective_since=250))
        self.assertEqual(first['processed'],1)
        self.assertGreater(first['pending'],0)
        second=audit.run(self.root,self.snapshot,dict(since=0,prospective_since=250))
        self.assertGreater(second['processed'],0)
        self.assertEqual(audit.run(self.root,self.snapshot,dict(since=0,prospective_since=250))['processed'],0)
        report=audit.report(self.root)
        self.assertTrue(report['review_cases'])
        self.assertEqual(report['review_cases'][0]['cohort'],'bootstrap_retrospective')
        lab.publish_snapshot(self.root,dict(schema_version=1,documents=[]))
        packet=audit.inspect(self.root,report['review_cases'][0]['case_id'])
        self.assertTrue(packet['originals'])
        self.assertEqual(lab.context_report(self.root)['searches'],0)

    def test_ranker_revision_replays_without_overwriting_historical_packets(self):
        config = dict(since=0, prospective_since=250)
        with patch.object(audit, 'VERSION', 'recall-opportunities-v4'):
            audit.run(self.root, self.snapshot, config)
            historical = audit.report(self.root)['review_cases'][0]
        original = audit.inspect(self.root, historical['case_id'])
        self.assertIn(audit.RANKER_VERSION, audit.VERSION)
        self.assertGreater(audit.run(self.root, self.snapshot, config)['processed'], 0)
        current = audit.report(self.root)['review_cases']
        self.assertTrue(current)
        self.assertTrue(all(p['retrieval_version'] == audit.RANKER_VERSION for p in current))
        self.assertNotIn(historical['case_id'], [p['case_id'] for p in current])
        self.assertEqual(audit.inspect(self.root, historical['case_id']), original)
        self.assertEqual(audit.run(self.root, self.snapshot, config)['processed'], 0)
        self.assertEqual(lab.context_report(self.root)['searches'], 0)

    def test_refresh_runs_audit_without_search(self):
        (self.root/'refresh-config.json').write_text(json.dumps(dict(schema_version=1,roots=[dict(adapter='codex',path=str(self.logs))],opportunities=dict(since=0,prospective_since=250))))
        result=refresh.refresh(self.root,force=True)
        self.assertEqual(result['opportunities']['status'],'ok')
        self.assertGreater(result['opportunities']['processed'],0)
        self.assertEqual(lab.context_report(self.root)['searches'],0)

    def test_archived_prior_turns_do_not_duplicate_replay_evidence(self):
        self.write('past-archive',[msg('Project budget must stay below twenty',100),msg('Acknowledged',101,'assistant')],sid='past')
        snapshot=build(live.export_live([('codex',self.logs)],since=0))
        items=audit.turns(snapshot)
        selected,_=audit.candidates(items,0,400)
        target=next(x for x in selected if x['kind']=='later_correction')
        packet=audit.replay(snapshot,items,target)
        self.assertEqual(packet['prior_candidates'],1)
        self.assertEqual(len(packet['hits']),1)

    def test_background_sample_does_not_require_a_recall_cue(self):
        self.write('current',[msg('Plan project budget',200),msg('Answer',201,'assistant'),msg('Thanks',202)])
        snapshot=build(live.export_live([('codex',self.logs)],since=0))
        with patch.object(audit,'CONTROL_SAMPLE_DENOMINATOR',1):
            selected,counts=audit.candidates(audit.turns(snapshot),0,400)
        self.assertEqual(counts['cue_candidates'],0)
        self.assertEqual(counts['background_samples'],1)
        self.assertEqual(selected[0]['control_origin'],'background_sample')

    def test_question_reply_detection_and_ranking_use_only_human_answer(self):
        envelope='<send_user_message_question_reply>\n'+json.dumps([dict(question='previously decided budget?',answer='Continue')])+'\n</send_user_message_question_reply>'
        self.assertEqual(audit.user_text(envelope),'Continue')
        self.write('current',[msg(envelope,200),msg('Answer',201,'assistant'),msg('Thanks',202)])
        snapshot=build(live.export_live([('codex',self.logs)],since=0))
        selected,_=audit.candidates(audit.turns(snapshot),0,400)
        self.assertFalse(any(x['kind'] != 'control' for x in selected))
        self.assertEqual(audit.user_text('<send_user_message_question_reply>malformed'),'')
        envelope='<send_user_message_question_reply>'+json.dumps([dict(question='ignore',answer='previously decided budget?')])+'</send_user_message_question_reply>'
        self.write('current',[msg(envelope,200),msg('Answer',201,'assistant'),msg('Thanks',202)])
        snapshot=build(live.export_live([('codex',self.logs)],since=0))
        selected,_=audit.candidates(audit.turns(snapshot),0,400)
        packet=audit.replay(snapshot,audit.turns(snapshot),selected[0])
        self.assertEqual(packet['query'],'previously decided budget?')
        self.assertNotIn('ignore',packet['query'])

    def test_scheduler_wakes_observer_even_when_sync_not_due(self):
        import scheduler
        from contextlib import contextmanager
        @contextmanager
        def lock(*args, **kwargs):
            yield True
        with patch.object(scheduler, 'ensure_safe_existing_root'), patch.object(scheduler, 'ensure_managed_gitignore'), \
             patch.object(scheduler, '_run_lock', lock), patch.object(scheduler, '_load_state', return_value={}), \
             patch.object(scheduler, '_scheduler_due', return_value=False), patch.object(observer, 'tick') as tick, \
             patch.object(scheduler, 'sync') as sync:
            scheduler.run(self.root)
        tick.assert_called_once_with(self.root)
        sync.assert_not_called()

    def test_claude_turn_boundaries_and_tool_observation(self):
        logs=self.base/'claude';logs.mkdir()
        values=[dict(type='user', sessionId='claude-session', timestamp='2026-10-01T00:00:00Z', message=dict(role='user',content='previously decided budget?')),
                dict(type='assistant',sessionId='claude-session', timestamp='2026-10-01T00:00:01Z',message=dict(role='assistant',content=[dict(type='tool_use',name='Bash',input=dict(command='recall-history search budget'))])),
                dict(type='assistant',sessionId='claude-session',timestamp='2026-10-01T00:00:02Z',message=dict(role='assistant',content=[dict(type='text',text='Answer')])),
                dict(type='user',sessionId='claude-session',timestamp='2026-10-01T00:00:03Z',message=dict(role='user',content='Thanks'))]
        (logs/'one.jsonl').write_text(''.join(json.dumps(v)+'\n' for v in values))
        snapshot=build(live.export_live([('claude-code',logs)],since=0))
        first=audit.turns(snapshot)[0]['observation']
        self.assertTrue(first['recall_marker'])
        self.assertTrue(first['closed'])
        self.assertTrue(first['assistant_observed'])
        self.assertEqual(first['native_session_id'],'claude-session')

    def test_scheduler_observer_is_optional_and_failures_are_isolated(self):
        recorder=self.base/'recorder';(recorder/'scheduler').mkdir(parents=True)
        observer.tick(recorder)
        self.assertFalse((recorder/'scheduler/recall-observer-status.json').exists())
        command=self.base/'recall';command.write_text('#!/bin/sh\nexit 0\n');command.chmod(0o700)
        config=recorder/'scheduler/recall-observer.json';config.write_text(json.dumps(dict(schema_version=1,command=str(command))));config.chmod(0o600)
        observer.tick(recorder)
        self.assertEqual(json.loads((recorder/'scheduler/recall-observer-status.json').read_text())['reason'],'missing_collection_health')
        command.write_text('#!/bin/sh\nexit 1\n');observer.tick(recorder)
        self.assertEqual(json.loads((recorder/'scheduler/recall-observer-status.json').read_text())['status'],'error')

    def test_scheduler_preserves_warning_and_throttled_failure(self):
        from types import SimpleNamespace
        recorder=self.base/'recorder';(recorder/'scheduler').mkdir(parents=True)
        command=self.base/'recall';command.write_text('#!/bin/sh\nexit 0\n');command.chmod(0o700)
        config=recorder/'scheduler/recall-observer.json'
        config.write_text(json.dumps(dict(schema_version=1,command=str(command))));config.chmod(0o600)
        report=dict(status='throttled', collection_status='updated', health='ok', last_success=__import__('time').time(), stale_after_seconds=1920, storage=dict(
            warning='snapshot_capacity_high', usage_percent=82, archive_bytes=820, budget_bytes=1000, private_text='omit'))
        with patch.object(observer.subprocess, 'run', return_value=SimpleNamespace(returncode=0, stdout=json.dumps(report).encode())):
            observer.tick(recorder)
        value=json.loads((recorder/'scheduler/recall-observer-status.json').read_text())
        self.assertEqual(value['status'],'warning')
        self.assertEqual(value['storage']['warning'],'snapshot_capacity_high')
        self.assertNotIn('private_text',value['storage'])
        report['collection_status']='error'
        with patch.object(observer.subprocess, 'run', return_value=SimpleNamespace(returncode=0, stdout=json.dumps(report).encode())):
            observer.tick(recorder)
        self.assertEqual(json.loads((recorder/'scheduler/recall-observer-status.json').read_text())['status'],'error')

    def test_observer_distinguishes_timeout_stale_running_and_unknown(self):
        from types import SimpleNamespace
        import subprocess, time
        recorder=self.base/'recorder';(recorder/'scheduler').mkdir(parents=True)
        command=self.base/'recall';command.write_text('#!/bin/sh\nexit 0\n');command.chmod(0o700)
        config=recorder/'scheduler/recall-observer.json'
        config.write_text(json.dumps(dict(schema_version=1,command=str(command))));config.chmod(0o600)
        reports = [
            ({'status':'throttled','collection_status':'running','health':'error','last_success':1,'stale_after_seconds':1920}, 'error','collection_stale'),
            ({'status':'busy','collection_status':'running','health':'running','last_success':time.time(),'stale_after_seconds':1920}, 'running','collection_in_progress'),
            ({'status':'throttled','collection_status':'error','health':'error','last_success':time.time(),'stale_after_seconds':1920}, 'error','collection_failed'),
            ({'status':'unchanged','health':'ok','last_success':time.time(),'stale_after_seconds':1920}, 'ok','collection_fresh'),
            ({'status':'unchanged'}, 'error','missing_collection_health'),
        ]
        for report, status, reason in reports:
            with self.subTest(reason=reason), patch.object(observer.subprocess, 'run', return_value=SimpleNamespace(returncode=0, stdout=json.dumps(report).encode())):
                observer.tick(recorder)
                value=json.loads((recorder/'scheduler/recall-observer-status.json').read_text())
                self.assertEqual((value['status'],value['reason']),(status,reason))
        with patch.object(observer.subprocess, 'run', side_effect=subprocess.TimeoutExpired('redacted',120)):
            observer.tick(recorder)
        self.assertEqual(json.loads((recorder/'scheduler/recall-observer-status.json').read_text())['reason'],'refresh_timeout')


if __name__=='__main__':unittest.main()
