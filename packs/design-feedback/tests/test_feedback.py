import contextlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

PACK=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('feedback',PACK/'design_feedback.py')
f=importlib.util.module_from_spec(spec); spec.loader.exec_module(f)
spec=importlib.util.spec_from_file_location('installer',PACK/'install.py')
installer=importlib.util.module_from_spec(spec); spec.loader.exec_module(installer)


def run(*args,cwd=None):
    return subprocess.run(args,cwd=cwd,check=True,capture_output=True,text=True).stdout.strip()


class FeedbackTest(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name); self.home=self.root/'state'; self.project=self.root/'app'; self.project.mkdir()
        self.cfg=dict(artifact_roots=[str(self.project)])
        self.payload=dict(session_id='synthetic-session',turn_id='one',cwd=str(self.project),hook_event_name='UserPromptSubmit',prompt='比較画面は左の一覧から右の詳細を見る方が分かりやすい')

    def case(self,eid,**changes):
        value=dict(event_id=eid,key='layout',summary='List and detail help this comparison task',reason=None,
            inferred_reason=None,purpose='Compare items',scope='project',conditions='Wide comparison screens',tags=['comparison'],
            authority='user_explicit',generalization='none',guideline_action='evidence',safe_to_share=True)
        value.update(changes); return value

    def test_both_runtime_hooks_capture_and_bounded_stop(self):
        for harness in ('codex','claude-code'):
            with self.subTest(harness=harness), f.database(self.home/harness) as db:
                result=f.hook(self.home/harness,db,self.cfg,self.payload,harness)
                self.assertIn('additionalContext',result['hookSpecificOutput'])
                eid=db.execute('SELECT id FROM events').fetchone()[0]
                f.hook(self.home/harness,db,self.cfg,self.payload,harness)
                self.assertEqual(db.execute('SELECT count(*) FROM events').fetchone()[0],1)
                stop=dict(self.payload,hook_event_name='Stop')
                self.assertEqual(f.hook(self.home/harness,db,self.cfg,stop,harness)['decision'],'block')
                self.assertEqual(f.hook(self.home/harness,db,self.cfg,stop,harness),{})
                self.assertEqual(f.hook(self.home/harness,db,self.cfg,dict(stop,stop_hook_active=True),harness),{})
                automated=dict(self.payload,turn_id='continuation',prompt='[design-feedback] 今回の捕捉が未処理です。デザイン評価を記録してください。')
                self.assertEqual(f.hook(self.home/harness,db,self.cfg,automated,harness),{})
                f.record(db,self.case(eid))
                self.assertEqual(f.hook(self.home/harness,db,self.cfg,stop,harness),{})

    def test_unrelated_and_automated_prompts_do_not_activate(self):
        with f.database(self.home) as db:
            for text in ('What is two plus two?','<heartbeat>画面のデザインが悪い</heartbeat>','# AGENTS.md\n画面を見やすくする'):
                self.assertIsNone(f.capture(db,self.payload,'codex',text))
            self.assertEqual(db.execute('SELECT count(*) FROM events').fetchone()[0],0)

    def test_unrelated_creation_after_design_does_not_receive_cases(self):
        with f.database(self.home) as db:
            f.capture(db,self.payload,'codex',self.payload['prompt'])
            for text in ('社内勉強会の案内文を作ってほしい','仕組みを簡単に説明してほしい','以上を踏まえて要約してください'):
                output=f.hook(self.home,db,self.cfg,dict(self.payload,turn_id=text,prompt=text),'codex')
                self.assertEqual(output,{})

    def test_short_reaction_after_mock_and_immutable_exhibit(self):
        page=self.project/'mock.html'; page.write_text('<button>Open details</button>')
        with f.database(self.home) as db:
            first=f.exhibit(self.home,db,self.cfg,str(page),'list-detail','synthetic-session',str(self.project))
            f.capture(db,self.payload,'codex',self.payload['prompt'])
            eid=f.capture(db,dict(self.payload,turn_id='two'),'codex','左の方がいい')
            page.write_text('<button>Changed later</button>')
            f.record(db,self.case(eid))
            c=json.loads(db.execute('SELECT payload FROM cases').fetchone()[0])
            self.assertEqual(c['artifact']['sha256'],first['sha256'])
            self.assertNotEqual(first['sha256'],f.digest(page.read_bytes()))
            self.assertEqual(Path(first['snapshot']).read_text(),'<button>Open details</button>')
            self.assertNotIn('original',c['artifact'])

    def test_multiple_variants_stay_unresolved_without_choice(self):
        with f.database(self.home) as db:
            for name in ('table','board'):
                p=self.project/(name+'.html'); p.write_text('<p>'+name+'</p>')
                f.exhibit(self.home,db,self.cfg,str(p),name,'synthetic-session',str(self.project))
            eid=f.capture(db,self.payload,'codex',self.payload['prompt'])
            result=f.record(db,self.case(eid))
            c=json.loads(db.execute('SELECT payload FROM cases').fetchone()[0])
            self.assertEqual(c['artifact_status'],'unresolved')
            self.assertEqual(result['delivery'],'queued')

    def test_case_scope_and_reason_are_preserved_and_records_are_immutable(self):
        with f.database(self.home) as db:
            eid=f.capture(db,self.payload,'codex',self.payload['prompt'])
            c=self.case(eid,inferred_reason='possibly less eye movement')
            receipt=f.record(db,c); self.assertEqual(f.record(db,c),receipt)
            raw=json.loads(db.execute('SELECT payload FROM cases').fetchone()[0])
            self.assertIsNone(raw['reason']); self.assertEqual(raw['inferred_reason'],c['inferred_reason'])
            self.assertNotIn(self.payload['prompt'],json.dumps(raw))
            self.assertNotIn(str(self.project),json.dumps(raw))
            with self.assertRaises(ValueError): f.record(db,dict(c,summary='different'))
            with self.assertRaises(ValueError): f.record(db,self.case(eid,key='broad',scope='common'))
            with self.assertRaises(ValueError): f.record(db,self.case(eid,key='new-rule',guideline_action='add'))

    def test_next_ui_reads_case_only_in_appropriate_project(self):
        with f.database(self.home) as db:
            eid=f.capture(db,self.payload,'codex',self.payload['prompt'])
            f.record(db,self.case(eid))
            self.assertEqual(len(f.context(db,self.cfg,'comparison',str(self.project))['cases']),1)
            other=self.root/'other'; other.mkdir()
            self.assertEqual(f.context(db,self.cfg,'comparison',str(other))['cases'],[])

    def test_correction_retires_prior_in_same_scope(self):
        with f.database(self.home) as db:
            eid=f.capture(db,self.payload,'codex',self.payload['prompt'])
            first=f.record(db,self.case(eid))['case_id']
            eid2=f.capture(db,dict(self.payload,turn_id='two'),'codex','狭い画面では一覧と詳細を同時にしない方がいい')
            second=f.record(db,self.case(eid2,summary='Use navigation on narrow screens',supersedes=[first]))['case_id']
            self.assertEqual([c['id'] for c in f.context(db,self.cfg,'comparison',str(self.project))['cases']],[second])

    def test_artifact_boundary(self):
        p=self.root/'outside.html'; p.write_text('private')
        link=self.project/'link.html'; link.symlink_to(p)
        with f.database(self.home) as db:
            for filename in (p,link):
                with self.assertRaises(ValueError): f.exhibit(self.home,db,self.cfg,str(filename),'x','s',str(self.project))
            with self.assertRaises(ValueError): f.relative('../secret')

    def test_git_projection_and_remote_context(self):
        remote=self.root/'remote.git'; run('git','init','--bare',str(remote))
        owner=self.root/'owner'; run('git','clone',str(remote),str(owner))
        for key,value in [('user.name','Example'),('user.email','example@example.invalid')]: run('git','config',key,value,cwd=owner)
        run('git','checkout','-b','main',cwd=owner)
        doc=owner/'docs/guidance.md'; doc.parent.mkdir(); doc.write_text('# Existing guidance\n\nKeep this paragraph.\n')
        run('git','add','.',cwd=owner); run('git','commit','-m','initial',cwd=owner); run('git','push','origin','main',cwd=owner)
        cfg=dict(guidance_checkout=str(owner),guideline_path='docs/guidance.md',case_dir='docs/cases',publish_mode='trunk-direct')
        with f.database(self.home) as db:
            eid=f.capture(db,self.payload,'codex',self.payload['prompt'])
            f.record(db,self.case(eid,scope='common',generalization='explicit',guideline_action='add'))
            receipt=f.publish(self.home,db,cfg)
            self.assertEqual(receipt['published'],1)
            self.assertIn('Keep this paragraph.',doc.read_text()); self.assertIn('List and detail',doc.read_text())
            self.assertNotIn(self.payload['prompt'],doc.read_text())
            self.assertEqual(f.publish(self.home,db,cfg)['status'],'idle')
            with f.database(self.root/'another-runtime') as other:
                self.assertEqual(len(f.context(other,cfg,'comparison',str(self.project))['cases']),1)
            doc.write_text(doc.read_text()+'foreign uncommitted edit\n')
            eid=f.capture(db,dict(self.payload,turn_id='next'),'codex','この画面は余白が大きすぎる')
            f.record(db,self.case(eid))
            with self.assertRaises(ValueError): f.publish(self.home,db,cfg)
            self.assertEqual(db.execute('SELECT count(*) FROM cases WHERE delivered IS NULL').fetchone()[0],1)

    def test_installer_preserves_existing_handlers_and_is_idempotent(self):
        initial=dict(env=dict(EXAMPLE='preserve'),hooks=dict(UserPromptSubmit=[dict(hooks=[dict(type='command',command='existing-guard')])]))
        merged=installer.merged_hooks(initial,'python release/design_feedback.py hook',True)
        self.assertEqual(merged['env'],initial['env'])
        self.assertEqual(merged['hooks']['UserPromptSubmit'][0],initial['hooks']['UserPromptSubmit'][0])
        self.assertEqual(installer.merged_hooks(merged,'python release/design_feedback.py hook',True),merged)

    def test_install_into_isolated_home_preserves_guards_and_does_not_trust_hooks(self):
        user=self.root/'user'; (user/'.codex').mkdir(parents=True); (user/'.claude').mkdir()
        initial={'hooks':{'PreToolUse':[{'hooks':[{'type':'command','command':'guard'}]}]}}
        (user/'.codex/hooks.json').write_text(json.dumps(initial))
        (user/'.codex/config.toml').write_text('[hooks.state]\n')
        args=[sys.executable,str(PACK/'install.py'),'--home',str(self.home),'--user-home',str(user),
            '--guidance-checkout',str(self.project),'--guideline-path','docs/guidance.md','--case-dir','docs/cases','--apply']
        run(*args)
        hooks=json.loads((user/'.codex/hooks.json').read_text())
        self.assertEqual(hooks['hooks']['PreToolUse'],initial['hooks']['PreToolUse'])
        self.assertEqual((user/'.codex/config.toml').read_text(),'[hooks.state]\n')
        self.assertTrue(json.loads((self.home/'installation.json').read_text())['codex_hook_trust_required'])
        run(*args)
        self.assertEqual(json.loads((user/'.codex/hooks.json').read_text()),hooks)

    def test_recovery_preserves_unknown_project_and_historical_artifact_missingness(self):
        # Exercise the published retrieval interfaces with a synthetic adapter.
        import types
        snapshot={'snapshot_id':'a'*64,'documents':[]}
        rows=[dict(source_id='source',utterance=dict(line=9,citation_id='citation',text='この比較画面は配置が悪い'),
                   observation=dict(native_session_id='new-native',timestamp=f.time.time()))]
        lock=contextlib.nullcontext
        lab=types.SimpleNamespace(snapshot_lock=lambda _:lock(),_snapshot=lambda _:snapshot)
        opportunities=types.SimpleNamespace(turns=lambda _:rows,user_text=lambda x:x)
        cfg=dict(retrieval_scripts=str(self.root),retrieval_lab=str(self.root),started_at=f.time.time(),recover_registered_only=False)
        with f.database(self.home) as db, patch.dict(sys.modules,{'retrieval_lab':lab,'retrieval_opportunities':opportunities}):
            result=f.recover(db,cfg); self.assertEqual(result['captures'],1)
            row=db.execute('SELECT * FROM events').fetchone()
            self.assertEqual(row['project'],'unassigned'); self.assertEqual(json.loads(row['artifacts']),[])
            with self.assertRaises(ValueError): f.record(db,self.case(row['id']))
            self.assertEqual(f.recover(db,cfg)['status'],'unchanged')

    def test_consultation_stays_excluded_on_later_turns(self):
        with f.database(self.home) as db:
            self.assertIsNone(f.capture(db,self.payload,'claude-code','You are a continuing discussion partner. Answer the message directly.'))
            self.assertIsNone(f.capture(db,dict(self.payload,turn_id='later'),'claude-code','画面の配置が見づらい'))


if __name__=='__main__': unittest.main()
