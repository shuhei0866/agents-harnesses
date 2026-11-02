import json
import os
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import patch

from session_bridge.runner import run, dispatch
from session_bridge.store import Store


NATIVE = '1caf260c-9241-4cbb-8e91-a633f467d416'


CLI = '''#!/usr/bin/env python3
import json, os, sys, time
args=sys.argv[1:]
prompt=sys.stdin.read()
model=args[args.index('--model')+1] if '--model' in args else 'fable'
native=args[args.index('--resume')+1] if '--resume' in args else '1caf260c-9241-4cbb-8e91-a633f467d416'
with open(os.environ['FIXTURE_CALLS'],'a') as out:
    out.write(json.dumps({'model':model,'args':args,'prompt':prompt,
        'api_key_present':'ANTHROPIC_API_KEY' in os.environ})+'\\n')
def emit(value):print(json.dumps(value),flush=True)
if 'no-native' not in prompt:
    initial={'type':'system','subtype':'init','session_id':native}
    initial['apiKeySource']='apiKeyHelper' if 'helper-auth' in prompt else 'none'
    if 'no-model' not in prompt:
        initial['model']='claude-opus-fixture' if model=='opus' else 'claude-fable-fixture' if model=='fable' else 'claude-other-fixture'
    emit(initial)
if 'success-quote' in prompt:
    emit({'type':'result','subtype':'success','is_error':False,'session_id':native,
          'result':"You're out of usage credits. This is quoted example text."})
    sys.exit(0)
error="You're out of usage credits. Switch to another model."
if 'auth-error' in prompt:error='Invalid API key'
if 'budget-error' in prompt:error='Reached maximum budget ($10)'
if 'overload-error' in prompt:error='Model overloaded; retry later'
if 'rate-error' in prompt:error='429 rate limit exceeded'
if 'stderr-only' in prompt:
    print(error,file=sys.stderr);sys.exit(1)
if model=='fable' and 'partial' in prompt:
    emit({'type':'stream_event','event':{'type':'content_block_delta',
        'delta':{'type':'text_delta','text':'partial response'}}})
if model=='fable' and 'thinking' in prompt:
    emit({'type':'stream_event','event':{'type':'content_block_delta',
        'delta':{'type':'thinking_delta','thinking':'private thought'}}})
if model=='fable' and 'direct-content' in prompt:
    emit({'type':'assistant','message':{'model':'claude-fable-fixture',
        'content':[{'type':'text','text':'already generated'}]}})
if model=='fable' and 'redacted' in prompt:
    emit({'type':'stream_event','event':{'type':'content_block_start',
        'content_block':{'type':'redacted_thinking'}}})
if model=='fable' and 'synthetic-refusal' in prompt:
    emit({'type':'assistant','message':{'model':'<synthetic>',
        'content':[{'type':'text','text':error}]}})
if model=='opus' and 'slow' in prompt:time.sleep(10)
failed=model!='opus' or 'both-quota' in prompt or 'fallback-error' in prompt
if model=='opus' and 'fallback-error' in prompt:error='Unavailable target model'
event={'type':'result','subtype':'error_during_execution' if failed else 'success',
       'is_error':failed,'result':error if failed else 'OPUS RESPONSE',
       'usage':{'input_tokens':0 if failed else 5,'output_tokens':0 if failed else 7}}
if 'output-token' in prompt and model=='fable':event['usage']['output_tokens']=1
if 'no-native' not in prompt:event['session_id']=native
emit(event)
sys.exit(1 if failed else 0)
'''


class QuotaFallbackTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.bin = self.root/'bin'
        self.bin.mkdir()
        executable = self.bin/'claude'
        executable.write_text(CLI)
        executable.chmod(0o755)
        self.calls = self.root/'calls.jsonl'
        env = patch.dict(os.environ,dict(
            PATH=str(self.bin)+os.pathsep+os.environ['PATH'],
            FIXTURE_CALLS=str(self.calls), SESSION_BRIDGE_CLAUDE_AUTH='subscription',
            SESSION_BRIDGE_CLAUDE_QUOTA_FALLBACK_MODEL='opus',ANTHROPIC_BASE_URL='',
            CLAUDE_CODE_USE_BEDROCK='',CLAUDE_CODE_USE_VERTEX='',CLAUDE_CODE_USE_FOUNDRY='',
            # Synthetic inherited key: subscription mode must strip it from the child.
            **{'ANTHROPIC_API_KEY': 'SYNTHETIC_KEY'}))
        env.start()
        self.addCleanup(env.stop)
        self.store = Store(self.root/'state')
        self.session = self.store.create('synthetic-partner','claude','fable')

    def execute(self,prompt='quota',timeout=5):
        job,_=self.store.reserve('synthetic-partner',prompt,prompt,timeout)
        run(self.store,job['id'])
        return self.store.public_job(job['id'])

    def logged(self):
        return [json.loads(line) for line in self.calls.read_text().splitlines()]

    def test_quota_falls_back_once_on_same_native_history_and_preserves_attempt(self):
        result=self.execute()
        self.assertEqual(result['status'],'completed')
        self.assertEqual(result['response'],'OPUS RESPONSE')
        self.assertIsNone(result['error'])
        self.assertEqual(result['requested_model'],'fable')
        self.assertTrue(result['fallback_used'])
        self.assertEqual(result['actual_model'],'claude-opus-fixture')
        attempts=result['attempts']
        self.assertEqual([row['status'] for row in attempts],['failed','completed'])
        self.assertIn('out of usage credits',attempts[0]['error'])
        self.assertEqual(attempts[0]['actual_model'],'claude-fable-fixture')
        self.assertEqual(attempts[1]['reason'],'claude_subscription_quota')
        self.assertEqual(attempts[1]['usage']['output_tokens'],7)
        self.assertEqual(self.store.session('synthetic-partner')['model'],'fable')
        self.assertEqual(result['native_session_id'],NATIVE)
        first,second=self.logged()
        self.assertNotIn('--resume',first['args'])
        self.assertEqual(second['args'][second['args'].index('--resume')+1],NATIVE)
        self.assertEqual(first['prompt'],second['prompt'])
        for row in (first,second):
            self.assertFalse(row['api_key_present'])
            self.assertIn('--safe-mode',row['args'])
            self.assertIn('--strict-mcp-config',row['args'])
            self.assertIn('--tools',row['args'])
        again=dispatch(self.store,'synthetic-partner','quota','quota',5)
        self.assertEqual(again['id'],result['id'])
        self.assertEqual(len(self.logged()),2)
        self.assertEqual(Store(self.store.root).history('synthetic-partner')[0]['attempts'],attempts)

    def test_success_quoted_quota_auth_budget_overload_and_partial_never_retry(self):
        for prompt in ('success-quote','auth-error','budget-error','overload-error','rate-error',
                       'partial-quota','thinking-quota','quota-output-token','stderr-only','helper-auth'):
            with self.subTest(prompt=prompt):
                before=len(self.logged()) if self.calls.exists() else 0
                result=self.execute(prompt)
                self.assertEqual(len(self.logged()),before+1)
                self.assertEqual(len(result['attempts']),1)
                self.assertFalse(result['fallback_used'])
                self.assertEqual(result['status'],'completed' if prompt=='success-quote' else 'failed')

    def test_direct_content_and_redacted_thinking_block_retry_but_synthetic_refusal_does_not(self):
        for prompt in ('direct-content','redacted'):
            with self.subTest(prompt=prompt):
                result=self.execute(prompt)
                self.assertEqual(len(result['attempts']),1)
                self.assertFalse(result['fallback_used'])
        result=self.execute('synthetic-refusal')
        self.assertEqual(result['status'],'completed')
        self.assertEqual(len(result['attempts']),2)

    def test_initial_missing_native_or_unknown_default_model_never_retries(self):
        result=self.execute('quota-no-native')
        self.assertEqual(result['status'],'failed')
        self.assertEqual(len(result['attempts']),1)
        self.store.create('unknown-default','claude')
        job,_=self.store.reserve('unknown-default','quota-no-model','one',5)
        run(self.store,job['id'])
        result=self.store.public_job(job['id'])
        self.assertEqual(result['status'],'failed')
        self.assertIsNone(result['actual_model'])
        self.assertEqual(len(result['attempts']),1)

    def test_secondary_failure_is_retained_and_never_retries_a_third_time(self):
        for prompt in ('both-quota','fallback-error'):
            result=self.execute(prompt)
            self.assertEqual(result['status'],'failed')
            self.assertEqual(len(result['attempts']),2)
            self.assertEqual(result['attempts'][0]['status'],'failed')
            self.assertEqual(result['attempts'][1]['status'],'failed')

    def test_non_subscription_other_primary_and_opt_out_do_not_retry(self):
        for name,env,model in (
            ('api',{'SESSION_BRIDGE_CLAUDE_AUTH':''},'fable'),
            ('alternate',{'CLAUDE_CODE_USE_VERTEX':'1'},'fable'),
            ('off',{'SESSION_BRIDGE_CLAUDE_QUOTA_FALLBACK_MODEL':''},'fable'),
            ('other',{},'other-model')):
            with self.subTest(name=name),patch.dict(os.environ,env):
                session=self.store.create(name,'claude',model)
                job,_=self.store.reserve(name,'quota','one',5)
                run(self.store,job['id'])
                result=self.store.public_job(job['id'])
                self.assertEqual(len(result['attempts']),1)

    def test_cli_default_needs_observed_fable_identity_and_actual_model_is_not_inferred(self):
        self.store.create('default','claude')
        job,_=self.store.reserve('default','quota','one',5)
        run(self.store,job['id'])
        result=self.store.public_job(job['id'])
        self.assertEqual(result['status'],'completed')
        self.assertIsNone(result['requested_model'])
        self.assertEqual(result['actual_model'],'claude-opus-fixture')

    def test_fallback_uses_original_job_deadline(self):
        began=time.monotonic()
        result=self.execute('quota-slow')
        self.assertEqual(result['status'],'timed_out')
        self.assertEqual(len(result['attempts']),2)
        self.assertLess(time.monotonic()-began,8)
        self.assertIn('exceeded 5s',result['error'])
        # The timed-out fallback reported no accounting: unknown, not the refusal's zero.
        self.assertEqual(result['attempts'][0]['usage']['output_tokens'],0)
        self.assertIsNone(result['attempts'][1]['usage'])
        self.assertIsNone(result['usage'])
        self.assertIsNone(Store(self.store.root).history('synthetic-partner')[-1]['usage'])


if __name__=='__main__':unittest.main()
