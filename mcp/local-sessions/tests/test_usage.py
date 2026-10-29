import json
from pathlib import Path
import tempfile
import unittest

from session_bridge.runner import Events
from session_bridge.store import Store
from session_bridge.usage import accounting


class UsageTests(unittest.TestCase):
    def test_claude_scope_allowlist_and_missing_values(self):
        result = accounting('claude', {'type': 'result', 'usage': {
            'input_tokens': 10, 'output_tokens': 20, 'cache_read_input_tokens': 3000,
            'cache_creation_input_tokens': 400, 'private': 'SECRET',
            'cache_creation': {'ephemeral_1h_input_tokens': 400, 'extra': 'SECRET'}},
            'total_cost_usd': .12, 'private': 'SECRET'})
        self.assertEqual(result['cache_read_input_tokens'], 3000)
        self.assertFalse(result['input_includes_cache'])
        self.assertEqual(result['token_scope'], 'turn_main_loop')
        self.assertEqual(result['estimated_session_cost_usd'], .12)
        self.assertIsNone(result['cache_creation']['ephemeral_5m_input_tokens'])
        self.assertNotIn('SECRET', json.dumps(result))
        missing = accounting('claude', {'type': 'result'})
        self.assertIsNone(missing['cache_read_input_tokens'])
        self.assertIsNone(missing['estimated_session_cost_usd'])

    def test_codex_cache_is_subset_and_cost_unknown(self):
        result = accounting('codex', {'type': 'turn.completed', 'usage': {
            'input_tokens': 5000, 'cached_input_tokens': 4000, 'output_tokens': 20}})
        self.assertTrue(result['input_includes_cache'])
        self.assertEqual(result['token_scope'], 'session_cumulative')
        self.assertEqual(result['cache_read_input_tokens'], 4000)
        self.assertIsNone(result['cache_creation_input_tokens'])
        self.assertIsNone(result['estimated_session_cost_usd'])

    def test_invalid_accounting_not_turned_into_zero(self):
        for bad in (True, '3', -1, float('nan'), float('inf'), 2.5):
            value = accounting('claude', {'type': 'result', 'usage': {'input_tokens': bad}})
            self.assertIsNone(value['input_tokens'])
        self.assertIsNone(accounting('claude', {'type': 'assistant', 'usage': {'input_tokens': 40}}))

    def test_result_replaces_snapshot_and_persists_across_reopen(self):
        with tempfile.TemporaryDirectory() as root:
            store = Store(root)
            session = store.create('test', 'claude')
            job, _ = store.reserve('test', 'synthetic', 'one')
            events = Events(store, session, job['id'])
            for cost in (.3, .4):
                events.accept({'type': 'result', 'subtype': 'success', 'result': 'ok',
                               'total_cost_usd': cost, 'usage': {'cache_read_input_tokens': 1000}})
            events.accept({'type': 'system', 'subtype': 'compact_boundary', 'metadata': 'PRIVATE'})
            events.flush(force=True)
            saved = Store(root).public_job(job['id'])
            self.assertEqual(saved['usage']['estimated_session_cost_usd'], .4)
            self.assertEqual(saved['usage']['cache_read_input_tokens'], 1000)
            self.assertEqual(saved['progress']['compactions'], 1)
            self.assertNotIn('PRIVATE', json.dumps(saved))
            self.assertEqual(Store(root).history('test')[0]['usage'], saved['usage'])
