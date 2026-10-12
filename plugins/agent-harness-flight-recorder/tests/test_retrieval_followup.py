import json
from pathlib import Path
import sys
import subprocess
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'scripts'))
import retrieval_lab as lab
import retrieval_live as live
import retrieval_followup as followup
import retrieval_refresh as refresh
from test_retrieval_opportunities import msg


class FollowupTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.base=Path(self.tmp.name).resolve(); self.logs=self.base/'logs'; self.logs.mkdir()
        self.root=self.base/'lab'
        self.write('past','past',[msg('Project budget must stay below twenty',100)])
        self.current=[msg('Plan project budget',200),msg('Planning',201,'assistant'),
                      msg('I already said twenty is the limit',210),msg('Understood',211,'assistant'),
                      msg('Add a new export feature',220),msg('Planning export',221,'assistant'),
                      msg('Thanks',230)]
        self.write('current','session-a',self.current)
        self.manifest=live.export_live([('codex',self.logs)],since=0)
        lab.create_lab(self.root,self.manifest)
        self.snapshot=lab._snapshot(self.root)

    def write(self,name,sid,records):
        (self.logs/(name+'.jsonl')).write_text(''.join(json.dumps(x)+'\n' for x in [dict(type='session_meta',payload=dict(id=sid)),*records]))

    def search(self,when=205,**kwargs):
        args=dict(need='Earlier budget limit?',session_id='session-a');args.update(kwargs)
        with patch('time.time',return_value=when):
            return lab.search_corrections(self.root,'budget twenty','resume',**args)

    def use(self,r,when=207):
        citation=r['hits'][0]['citation_id']
        with patch('time.time',return_value=when):
            lab.read_citation(self.root,citation,r['request_id'])
            lab.context_use(self.root,r['request_id'],'applied',[citation],'Earlier limit applies',decision_match='found')

    def run_at(self,now=240):
        with patch('time.time',return_value=now):
            return followup.run(self.root,self.snapshot,dict(since=0))

    def case(self):return followup.report(self.root)['review_cases'][0]

    def test_links_original_turn_and_observes_next_three_without_future_leak(self):
        r=self.search();self.use(r);self.run_at(215);c=self.case()
        self.assertEqual(c['anchor']['timestamp'],200)
        self.assertEqual([f['timestamp'] for f in c['followups']],[210])
        self.assertEqual(c['exposure']['decision_match'],'found')
        self.assertEqual(c['exposure']['read_count'],1)
        self.assertEqual(c['status'],'observing')
        self.assertEqual(c['followups'][0]['cues'],['explicit_restatement'])
        self.run_at();self.assertEqual(self.case()['status'],'window_complete')
        self.assertEqual(len(self.case()['followups']),3)
        self.assertEqual(lab.context_report(self.root)['searches'],1)

    def test_silence_never_becomes_success(self):
        self.search();self.run_at(209)
        self.assertEqual(self.case()['status'],'pending')
        self.write('current','session-a',self.current[:2])
        self.snapshot=lab._build_snapshot(live.export_live([('codex',self.logs)],since=0))[0]
        lab.publish_snapshot(self.root,dict(schema_version=1,documents=self.snapshot['documents']))
        self.run_at(205+followup.WINDOW_SECONDS)
        self.assertEqual(self.case()['status'],'no_followup_observed')
        self.assertNotIn('success',followup.report(self.root)['states'])

    def test_retry_is_one_need_and_late_self_report_is_not_prior_exposure(self):
        first=self.search()
        retry=self.search(208,retry_of=first['request_id'])
        self.use(retry,212);self.run_at()
        c=self.case();self.assertEqual(c['need']['attempts'],2)
        self.assertEqual(c['need']['status'],'found')
        self.assertEqual(c['exposure']['decision_match'],'unknown')
        self.assertEqual(c['exposure']['read_count'],0)
        self.assertEqual(followup.report(self.root)['needs'],1)

    def test_unknown_missing_and_ambiguous_sessions_are_not_guessed(self):
        for sid,reason in [('missing','session_not_collected'),(None,'session_unknown')]:
            with patch.dict('os.environ',{},clear=True):self.search(session_id=sid)
            self.run_at()
            self.assertIn(reason,[c['link_reason'] for c in followup.report(self.root)['review_cases']])
        self.search();self.write('collision','session-a',[msg('Different simultaneous turn',200)])
        self.snapshot=lab._build_snapshot(live.export_live([('codex',self.logs)],since=0))[0]
        self.run_at();self.assertIn('ambiguous_timestamp',[c['link_reason'] for c in followup.report(self.root)['review_cases']])

    def test_archive_duplicates_and_overlapping_windows_not_double_counted_as_events(self):
        self.write('archive','session-a',self.current)
        self.snapshot=lab._build_snapshot(live.export_live([('codex',self.logs)],since=0))[0]
        self.search();self.search(206);self.run_at()
        report=followup.report(self.root)
        self.assertEqual(report['needs'],2)
        self.assertEqual(report['unique_linked_turns'],1)
        self.assertEqual(report['unique_followup_turns'],3)
        self.assertEqual(report['unique_cue_turns'],1)
        self.assertEqual(report['overlapping_followup_turns'],3)

    def test_verification_legacy_and_pre_cohort_queries_are_excluded(self):
        self.search(purpose='verification');self.search(206,need=None);self.search(207)
        with patch('time.time',return_value=240):
            result=followup.run(self.root,self.snapshot,dict(since=208))
        self.assertEqual(result['eligible_needs'],0)
        self.run_at();self.assertEqual(followup.report(self.root)['needs'],1)

    def test_idempotence_immutable_inspection_and_review_evidence(self):
        self.search();self.run_at(215);c=self.case();old=followup.inspect(self.root,c['case_id'])
        self.assertEqual(self.run_at(216)['revisions_added'],0)
        self.run_at();self.assertEqual(followup.inspect(self.root,c['case_id']),old)
        c=self.case();refs=[c['followups'][0]['citation_id']]
        with self.assertRaises(ValueError):followup.review(self.root,c['case_id'],'repeated_prior_decision',refs,'Earlier decision')
        from retrieval_opportunities import turns
        earlier=next(x for x in turns(self.snapshot) if x['observation']['timestamp']==100)
        prior=dict(citation_id=earlier['utterance']['citation_id'],line=earlier['utterance']['line'])
        result=followup.review(self.root,c['case_id'],'repeated_prior_decision',refs,'Same budget decision',[prior])
        self.assertEqual(result['review']['provenance'],'agent_retrospective_review')
        self.assertEqual(followup.report(self.root)['reviewed_current_revisions'],{'repeated_prior_decision':1})
        later=dict(citation_id=c['followups'][0]['citation_id'],line=c['followups'][0]['line'])
        with self.assertRaises(ValueError):followup.review(self.root,c['case_id'],'repeated_prior_decision',refs,'Future evidence',[later])
        with self.assertRaises(ValueError):followup.review(self.root,c['case_id'],'other',['unknown'],'Invalid citation')
        followup.review(self.root,c['case_id'],'new_requirement',refs,'Reviewer found a new requirement')
        self.assertEqual(followup.report(self.root)['reviewed_current_revisions'],{'new_requirement':1})

    def test_refresh_connection_and_bounded_round_robin(self):
        self.search();self.search(206)
        with patch.object(followup,'MAX_CASES',1):
            self.assertEqual(self.run_at()['processed'],1)
            self.assertEqual(self.run_at(241)['processed'],1)
        self.assertEqual(followup.report(self.root)['needs'],2)
        (self.root/'refresh-config.json').write_text(json.dumps(dict(schema_version=1,roots=[dict(adapter='codex',path=str(self.logs))],followups=dict(since=0))))
        result=refresh.refresh(self.root,force=True)
        self.assertEqual(result['followups']['status'],'ok')
        self.assertEqual(result['followups']['eligible_needs'],2)

    def test_reverting_to_an_existing_revision_updates_current_pointer(self):
        r=self.search();self.use(r);self.run_at();first=self.case()
        with lab._connect(self.root) as db:
            db.execute('UPDATE context_decision_matches SET match=? WHERE request_id=?',('unknown',r['request_id']))
        self.run_at(241);self.assertEqual(self.case()['exposure']['decision_match'],'unknown')
        with lab._connect(self.root) as db:
            db.execute('UPDATE context_decision_matches SET match=? WHERE request_id=?',('found',r['request_id']))
        self.run_at(242);self.assertEqual(self.case()['case_id'],first['case_id'])
        self.assertEqual(self.case()['exposure']['decision_match'],'found')

    def test_injected_turns_do_not_consume_window_and_blind_view_hides_matches(self):
        self.write('current','session-a',self.current[:2]+[
            msg('<external_codex_apps_open_page>{}</external_codex_apps_open_page>',202),
            msg('<subagent_notification>unrelated agent report</subagent_notification>',203),
            *self.current[2:]])
        self.snapshot=lab._build_snapshot(live.export_live([('codex',self.logs)],since=0))[0]
        lab.publish_snapshot(self.root,dict(schema_version=1,documents=self.snapshot['documents']))
        self.search();self.run_at();c=self.case()
        self.assertEqual(c['anchor']['timestamp'],200)
        self.assertEqual(len(c['followups']),3)
        blind=followup.inspect(self.root,c['case_id'],blind=True)
        self.assertNotIn('packet',blind)
        self.assertNotIn('decision_match',json.dumps(blind))
        self.assertEqual(len(blind['originals']),4)

    def test_cli_report_blind_inspection_and_review(self):
        self.search();self.run_at();c=self.case()
        command=[sys.executable,str(Path(lab.__file__)),'--lab',str(self.root)]
        report=json.loads(subprocess.check_output(command+['followup-report'],text=True))
        self.assertEqual(report['unique_cue_turns'],1)
        blind=json.loads(subprocess.check_output(command+['followup-inspect',c['case_id'],'--blind'],text=True))
        self.assertNotIn('packet',blind)
        payload=self.base/'review.json';payload.write_text(json.dumps(dict(label='uncertain',citations=[c['followups'][0]['citation_id']],reason='Needs semantic review')))
        reviewed=json.loads(subprocess.check_output(command+['followup-review',c['case_id'],'--file',str(payload)],text=True))
        self.assertEqual(reviewed['review']['label'],'uncertain')
        self.assertEqual(lab.context_report(self.root,'task')['followups']['needs'],1)
        self.assertIsNone(lab.context_report(self.root,'verification')['followups'])

    def test_tightened_cohort_hides_old_heads_but_preserves_evidence(self):
        self.search();self.run_at();case_id=self.case()['case_id']
        with patch('time.time',return_value=240):
            followup.run(self.root,self.snapshot,dict(since=206))
        self.assertEqual(followup.report(self.root)['needs'],0)
        self.assertTrue(followup.inspect(self.root,case_id)['originals'])

    def test_invalid_config_and_uncollected_future_are_not_results(self):
        self.search(1000)
        self.assertEqual(self.run_at(240)['eligible_needs'],0)
        for since in [True,-1,float('nan')]:
            with self.assertRaises(ValueError):followup.run(self.root,self.snapshot,dict(since=since))


if __name__=='__main__':unittest.main()
