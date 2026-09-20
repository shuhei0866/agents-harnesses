import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
import retrieval_lab as lab
import resume_replay as replay


def case():
    return dict(case_id='case-a',source_id='source-a',cutoff_line=2,resume_line=3,resume_prompt='Continue the work',
                history=[dict(citation_id='c1',line=1,role='user',text='Publish after tests pass',timestamp='2026-01-01T00:00:00Z')],
                future=[dict(citation_id='f1',line=4,role='assistant',text='FUTURE_SECRET',timestamp='2026-01-02T00:00:00Z')],prefix_sha256='a'*64)


class ReplayTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name)/'lab'
        lab.create_lab(self.root,dict(schema_version=1,documents=[dict(source_id='seed',start_line=1,end_line=1,text='seed',summaries=[])]))
        self.set_id=replay.save_cases(self.root,dict(schema_version=1,cases=[case()],report={}))['set_id']

    def fake(self, prompt, schema, budget, **kwargs):
        if schema is replay.protocol.MEMO_SCHEMA:
            self.assertNotIn('FUTURE_SECRET',prompt)
            value=dict(decisions=[dict(text='Publish after tests',citations=['c1'])],open_questions=[],planned_next_steps=[])
        elif schema is replay.protocol.PLAN_SCHEMA:
            self.assertNotIn('FUTURE_SECRET',prompt)
            value=dict(next_action='Check tests',reason='Required before publish',citations=['c1'],needs_current_check=True)
        else:
            self.assertIn('FUTURE_SECRET',prompt)
            value=dict(candidates={k:dict(grounded=True,stale_assumption=False,appropriate_next_action=True,reason='Supported') for k in ['A','B']},preference='tie')
        return dict(value=value,metrics=dict(elapsed_ms=10,reported_cost_usd=.01,input_tokens=20,output_tokens=10,model='test'))

    def test_replays_are_cached_and_do_not_overwrite_retrieval_snapshot(self):
        original=lab._snapshot(self.root)['snapshot_id']
        with patch.object(replay,'call_model',side_effect=self.fake) as model:
            first=replay.evaluate(self.root,self.set_id,max_cases=1,max_calls=4,budget_usd=1)
            second=replay.evaluate(self.root,self.set_id,max_cases=1,max_calls=4,budget_usd=1)
        self.assertEqual(model.call_count,4)
        self.assertEqual(first['batch_id'],second['batch_id'])
        self.assertEqual(lab._snapshot(self.root)['snapshot_id'],original)
        report=replay.report(self.root,first['batch_id'])
        self.assertEqual(report['completed_pairs'],1)
        self.assertEqual(report['differences'],[])
        self.assertEqual(report['assessment'],'provisional_model_judgment')
        memo=replay.read_memo(self.root,first['batch_id'],'case-a')
        self.assertNotIn('FUTURE_SECRET',json.dumps(memo))
        self.assertEqual(memo['current_state'],'unverified')

    def test_call_limit_stops_before_next_stage(self):
        with patch.object(replay,'call_model',side_effect=self.fake) as model:
            result=replay.evaluate(self.root,self.set_id,max_cases=1,max_calls=1,budget_usd=1)
        self.assertEqual(model.call_count,1)
        self.assertEqual(result['status'],'budget_exhausted')

    def test_invalid_model_citation_is_not_accepted(self):
        def bad(*args, **kwargs):
            return dict(value=dict(decisions=[dict(text='invented',citations=['future'])],open_questions=[],planned_next_steps=[]),metrics=dict(reported_cost_usd=.01))
        with patch.object(replay,'call_model',side_effect=bad):
            result=replay.evaluate(self.root,self.set_id,max_cases=1,max_calls=4,budget_usd=1)
        self.assertEqual(result['status'],'errors')
        report=replay.report(self.root,result['batch_id'])
        self.assertEqual(report['completed_pairs'],0)


    def test_mining_telemetry_does_not_change_case_identity(self):
        value=replay.save_cases(self.root,dict(schema_version=1,cases=[case()],report={'elapsed_ms':999}))
        self.assertEqual(value['set_id'],self.set_id)

    def test_raising_limit_resumes_without_repeating_model_calls(self):
        with patch.object(replay,'call_model',side_effect=self.fake) as model:
            first=replay.evaluate(self.root,self.set_id,max_cases=1,max_calls=1,budget_usd=1)
            second=replay.evaluate(self.root,self.set_id,max_cases=1,max_calls=4,budget_usd=2)
        self.assertEqual(first['batch_id'],second['batch_id'])
        self.assertEqual(second['status'],'complete')
        self.assertEqual(model.call_count,4)


    def test_invalid_usage_stops_before_another_case(self):
        for invalid in (-1,float('nan'),float('inf')):
            a=case();b=case();b['case_id']='case-b'
            a['case_id']='case-a-'+str(invalid)
            identity=replay.save_cases(self.root,dict(schema_version=1,cases=[a,b],report={}))['set_id']
            def bad(prompt,schema,budget, **kwargs):
                answer=self.fake(prompt,schema,budget)
                answer['metrics']['reported_cost_usd']=invalid
                return answer
            with patch.object(replay,'call_model',side_effect=bad) as model:
                result=replay.evaluate(self.root,identity,max_cases=2,max_calls=8,budget_usd=1)
            self.assertEqual(model.call_count,1)
            self.assertEqual(result['status'],'unknown_usage')
            self.assertIsNone(replay.report(self.root,result['batch_id'])['reported_cost_usd'])


    def test_codex_unknown_price_uses_actual_token_gate(self):
        def codex(prompt,schema,budget, **kwargs):
            answer=self.fake(prompt,schema,budget)
            answer['metrics']['reported_cost_usd']=None
            return answer
        with patch('resume_codex._model_preference',return_value='test'), patch('resume_codex.call_codex',side_effect=codex) as model:
            result=replay.evaluate(self.root,self.set_id,max_cases=1,max_calls=4,provider='codex',budget_tokens=25)
        self.assertEqual(model.call_count,1)
        self.assertEqual(result['status'],'budget_exhausted')
        report=replay.report(self.root,result['batch_id'])
        self.assertIsNone(report['reported_cost_usd'])
        self.assertEqual(report['total_tokens'],30)


    def test_unreviewed_gap_cases_cannot_run_and_selection_is_immutable(self):
        candidate=dict(case(),requires_triage=True,selection_method='same_session_gap')
        parent=replay.save_cases(self.root,dict(schema_version=1,cases=[candidate],report={}))['set_id']
        with patch.object(replay,'call_model') as model, self.assertRaises(ValueError):
            replay.evaluate(self.root,parent)
        model.assert_not_called()
        selected=replay.select_cases(self.root,parent,{'case-a':'Prefix confirms continuation of a pending action.'})
        self.assertNotEqual(parent,selected['set_id'])
        self.assertTrue(replay._load_set(self.root,parent)['cases'][0]['requires_triage'])
        self.assertFalse(replay._load_set(self.root,selected['set_id'])['cases'][0]['requires_triage'])

    def test_invalidated_artifact_set_cannot_be_evaluated(self):
        with lab._connect(self.root) as db:db.execute('INSERT INTO resume_invalid_sets VALUES(?,?)',(self.set_id,'synthetic automation'))
        with patch.object(replay,'call_model') as model, self.assertRaises(ValueError):
            replay.evaluate(self.root,self.set_id)
        model.assert_not_called()


    def test_changed_codex_model_cannot_mix_into_cached_pair(self):
        def codex(prompt,schema,budget,**kwargs):
            self.assertEqual(kwargs['model'],'test')
            answer=self.fake(prompt,schema,budget)
            answer['metrics']['reported_cost_usd']=None
            return answer
        with patch('resume_codex._model_preference',return_value='test'),patch('resume_codex.call_codex',side_effect=codex):
            replay.evaluate(self.root,self.set_id,max_cases=1,max_calls=1,provider='codex')
        with patch('resume_codex._model_preference',return_value='different'),patch('resume_codex.call_codex') as model,self.assertRaises(ValueError):
            replay.evaluate(self.root,self.set_id,max_cases=1,max_calls=4,provider='codex')
        model.assert_not_called()

if __name__=='__main__':unittest.main()
