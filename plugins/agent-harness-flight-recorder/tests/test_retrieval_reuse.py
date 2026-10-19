import json
import unittest
from unittest.mock import patch
from test_retrieval_followup import FollowupTests as Fixtures
import retrieval_lab as lab
import retrieval_reuse as reuse
import retrieval_followup as followup
from retrieval_opportunities import turns


class ReuseTests(unittest.TestCase):
    setUp = Fixtures.setUp
    write = Fixtures.write
    search = Fixtures.search
    use = Fixtures.use
    run_at = Fixtures.run_at
    case = Fixtures.case

    def prepare(self):
        r = self.search()
        item = next(x for x in turns(self.snapshot) if x['observation']['timestamp'] == 100)
        ref = {k:item['utterance'][k] for k in ('citation_id','line')}
        self.assertIn(ref['citation_id'], [h['citation_id'] for h in r['hits']])
        with patch('time.time', return_value=206):
            lab.read_citation(self.root, ref['citation_id'], r['request_id'])
        value = dict(request_presence='absent', other_context='unknown', action='skipped_question',
                     question='What is the budget limit?', prior_answers=[ref])
        return r, ref, value

    def record(self, r, ref, value, when=207):
        with patch('time.time', return_value=when):
            lab.context_use(self.root, r['request_id'], 'applied', [ref['citation_id']], 'Reuse earlier answer',
                            decision_match='found', effect='avoided_question', reuse=value)

    def test_template_does_not_claim_use_and_roundtrips_with_followup(self):
        import subprocess, sys
        from pathlib import Path
        r, ref, value = self.prepare()
        before = lab.context_report(self.root)
        command = [sys.executable, str(Path(lab.__file__).with_name('retrieval_refresh.py')), '--lab', str(self.root)]
        template = json.loads(subprocess.check_output(command + ['context-use-template', r['request_id']]))
        self.assertIn(ref, template['candidates'])
        self.assertEqual(template['draft']['citations'], [])
        self.assertEqual(template['draft']['reuse']['prior_answers'], [])
        self.assertEqual(template['draft']['reuse']['question'], '')
        self.assertFalse(template['already_recorded'])
        self.assertEqual(lab.context_report(self.root), before)
        with self.assertRaises(ValueError):
            self.record(r, ref, dict(value, used_answer=''))
        self.record(r, ref, dict(value, used_answer='Use the earlier budget to choose the implementation.'))
        self.run_at()
        report = self.case()['answer_reuse']
        self.assertEqual(report['status'], 'recorded_before_followup')
        self.assertIn('earlier budget', report['reports'][0]['report']['used_answer'])
        self.assertTrue(reuse.use_template(self.root, r['request_id'])['already_recorded'])

    def test_template_includes_read_preceding_user_request_once(self):
        r, ref, value = self.prepare()
        real = lab.context_inspect(self.root, r['request_id'])
        earlier = dict(ref, role='user', text='Earlier answer')
        hit = dict(real['result']['hits'][0], request=earlier,
                   utterance=dict(role='assistant', citation_id='not-a-user', line=999))
        real['result']['hits'] = [hit, hit]
        with patch.object(lab, 'context_inspect', return_value=real):
            self.assertEqual(reuse.use_template(self.root, r['request_id'])['candidates'], [ref])

    def test_missing_reuse_keeps_use_but_surfaces_missing_record(self):
        r, ref, _ = self.prepare()
        result = lab.context_use(self.root, r['request_id'], 'applied', [ref['citation_id']],
                                 'Confirm existing scope', decision_match='found')
        self.assertEqual(result['reuse_recording'], 'not_recorded')
        self.assertIn('context-use-template', result['next_step'])
        self.assertEqual(lab.context_inspect(self.root, r['request_id'])['reuse_reports'], [])
        self.assertEqual(lab.context_inspect(self.root, r['request_id'])['use']['state'], 'applied')

    def test_prospective_evidence_and_first_statement_survive_revisions(self):
        r, ref, value = self.prepare(); self.record(r, ref, value)
        self.record(r, ref, dict(value, other_context='present'), 208)
        self.run_at()
        e = self.case()['answer_reuse']
        self.assertEqual(e['status'], 'recorded_before_followup')
        self.assertEqual(e['reports'][0]['report']['other_context'], 'unknown')
        prior = e['reports'][0]['report']['prior_answers'][0]
        self.assertTrue(prior['different_session']); self.assertTrue(prior['precedes_consultation'])
        self.assertEqual(len(lab.context_inspect(self.root,r['request_id'])['reuse_reports']),2)
        self.assertEqual(e['causal_effect'], 'unmeasured')

    def test_late_or_missing_report_is_not_success(self):
        r, ref, value = self.prepare(); self.run_at()
        self.assertEqual(self.case()['answer_reuse']['status'], 'not_recorded')
        self.record(r, ref, value, 212); self.run_at()
        e=self.case()['answer_reuse']; self.assertEqual(e['status'], 'late_only'); self.assertEqual(e['reports'], [])

    def test_invalid_prior_answer_rejected_without_overwriting_use(self):
        r, ref, value = self.prepare(); self.record(r,ref,value)
        before=lab.context_inspect(self.root,r['request_id'])['use']
        for bad in [dict(value, question=''), dict(value, request_presence='definitely absent'),
                    dict(value, prior_answers=[dict(ref,line=9999)]),
                    dict(value, prior_answers=[dict(ref,citation_id='unknown')])]:
            with self.assertRaises(ValueError):self.record(r,ref,bad)
        self.assertEqual(lab.context_inspect(self.root,r['request_id'])['use'],before)

    def test_future_or_unread_evidence_rejected(self):
        r, ref, value = self.prepare()
        future=next(x for x in turns(self.snapshot) if x['observation']['timestamp']==210)
        with lab._connect(self.root) as db: row=lab._row(db,r['request_id'])
        fref={k:future['utterance'][k] for k in ('citation_id','line')}
        with self.assertRaises(ValueError):reuse.prior_answers(self.root,row,[fref['citation_id']],[fref])
        other=self.search(206)
        with self.assertRaises(ValueError):self.record(other,ref,value)

    def test_structured_questions_keep_new_approval_distinct_from_repetition(self):
        raw='<send_user_message_question_reply>'+json.dumps([{'question':'Approve this new credential?', 'answer':'Yes'}])+'</send_user_message_question_reply>'
        self.assertEqual(reuse.answered_questions(raw)[0]['question'],'Approve this new credential?')
        self.assertEqual(reuse.answered_questions('<heartbeat>Question?</heartbeat>'),[])
        self.assertEqual(reuse.answered_questions('Question?'),[])
        self.assertEqual(reuse.answered_questions('<send_user_message_question_reply>oops</send_user_message_question_reply>'),[])

    def test_frozen_replay_never_adds_searches_reads_or_feedback(self):
        r, ref, value=self.prepare();self.record(r,ref,value);self.run_at()
        frozen=reuse.freeze(self.root,r['request_id'],self.case()['case_id'])
        before=lab.context_report(self.root)
        result=reuse.replay(self.root,frozen)
        self.assertTrue(result['all_targets_found'])
        after=lab.context_report(self.root)
        for key in ['searches','requests_with_reads','uses']: self.assertEqual(before[key],after[key])
        tampered=dict(frozen,query='later correction leaked')
        with self.assertRaises(ValueError):reuse.replay(self.root,tampered)

    def test_review_uses_search_snapshot_and_requires_limitations(self):
        r, ref, value=self.prepare();self.record(r,ref,value);self.run_at()
        packet=self.case()
        outcome=dict(classification='reuse_without_observed_repetition', prior_answers=[dict(ref,request_id=r['request_id'])],limitations='Other context may suffice; no causal claim')
        result=reuse.review(self.root,packet,outcome)
        self.assertEqual(result['prior_answers'][0]['snapshot_id'],r['snapshot_id'])
        with self.assertRaises(ValueError):reuse.review(self.root,packet,dict(outcome,limitations=''))
        with self.assertRaises(ValueError):reuse.review(self.root,packet,dict(outcome,prior_answers=[]))

    def test_cli_fixture_and_reuse_review_roundtrip(self):
        import subprocess
        import sys
        r, ref, value = self.prepare(); self.record(r, ref, value); self.run_at()
        case = self.case()
        outcome = dict(classification='reuse_without_observed_repetition',
                       prior_answers=[dict(ref, request_id=r['request_id'])],
                       limitations='Structured replies only; other context may suffice')
        followup.review(self.root, case['case_id'], 'other',
                        [case['followups'][0]['citation_id']], 'Bounded observation', reuse_outcome=outcome)
        report = followup.report(self.root)
        self.assertEqual(report['answer_reuse']['reviewed'], {'reuse_without_observed_repetition': 1})
        script = str(__import__('pathlib').Path(lab.__file__).with_name('retrieval_refresh.py'))
        command = [sys.executable, script, '--lab', str(self.root)]
        frozen = json.loads(subprocess.check_output(command + ['reuse-freeze', r['request_id'], '--case-id', case['case_id']]))
        path = self.root/'fixture.json'; path.write_text(json.dumps(frozen))
        replayed = json.loads(subprocess.check_output(command + ['reuse-replay', '--file', str(path)]))
        self.assertTrue(replayed['all_targets_found'])


# Fixture class is not a second discovered test suite.
del Fixtures
