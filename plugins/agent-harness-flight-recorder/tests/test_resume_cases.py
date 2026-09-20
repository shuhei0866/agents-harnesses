import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
import resume_cases as miner


def msg(text, role, timestamp):
    return dict(type=role, timestamp=timestamp, message=dict(role=role, content=[dict(type='text', text=text)]))


def encode(values):
    return b''.join(json.dumps(v).encode() + b'\n' for v in values)


def conversation():
    return [msg('Design the red widget', 'user', '2026-09-01T09:00:00Z'),
            msg('Decision: use blue widgets instead', 'assistant', '2026-09-01T09:01:00Z'),
            msg('続きから再開しよう', 'user', '2026-09-01T10:00:00Z'),
            msg('Now I will implement blue widgets', 'assistant', '2026-09-01T10:01:00Z')]


class MinerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.roots = [('claude-code', self.root)]

    def write(self, values, name='session.jsonl'):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(encode(values))
        return path

    def test_strict_cutoff_holdout_and_prefix_identity(self):
        values = conversation()
        self.write(values)
        case = miner.mine_cases(self.roots)['cases'][0]
        self.assertEqual(case['cutoff_line'], 2)
        self.assertEqual(case['resume_line'], 3)
        self.assertEqual([m['line'] for m in case['history']], [1, 2])
        self.assertEqual([m['line'] for m in case['future']], [4])
        self.assertEqual(case['prefix_sha256'], miner.digest(encode(values[:2])))
        self.assertNotIn('Now I will', json.dumps(case['history']))
        values[-1]['message']['content'][0]['text'] = 'completely different future'
        self.write(values)
        changed = miner.mine_cases(self.roots)['cases'][0]
        self.assertEqual(case['case_id'], changed['case_id'])
        self.assertNotIn(str(self.root), json.dumps(changed))

    def test_cue_requires_real_gap_and_following_assistant(self):
        for kind in ['small_gap', 'no_time', 'no_cue', 'no_future']:
            values = conversation()
            if kind == 'small_gap': values[2]['timestamp'] = '2026-09-01T09:02:00Z'
            if kind == 'no_time': del values[2]['timestamp']
            if kind == 'no_cue': values[2]['message']['content'][0]['text'] = 'New unrelated task'
            if kind == 'no_future': values.pop()
            self.write(values)
            with self.subTest(kind=kind):
                self.assertEqual(miner.mine_cases(self.roots)['cases'], [])

    def test_retrieval_or_resume_tool_at_tail_excludes_whole_source(self):
        values = conversation()
        values.append(dict(type='assistant', message=dict(role='assistant', content=[dict(
            type='tool_use', name='Bash', input={'command':'python resume_replay.py run'})])))
        self.write(values)
        result = miner.mine_cases(self.roots)
        self.assertEqual(result['cases'], [])
        self.assertEqual(result['report']['excluded_evaluation_sessions'], 1)

    def test_plain_user_mentions_and_developer_tool_listing_do_not_exclude(self):
        values = conversation()
        values[0]['message']['content'][0]['text'] = 'Discuss resume_cases.py requirements'
        self.write(values)
        self.assertEqual(len(miner.mine_cases(self.roots)['cases']), 1)

    def test_subagent_and_explicit_session_excluded(self):
        self.write(conversation(), 'subagents/child.jsonl')
        self.write(conversation(), 'explicit.jsonl')
        result = miner.mine_cases(self.roots, exclude_sessions=['explicit'])
        self.assertEqual(result['cases'], [])
        self.assertEqual(result['report']['excluded_subagent_sessions'], 1)
        self.assertEqual(result['report']['excluded_configured_sessions'], 1)

    def test_one_case_per_source_newest_resume_first(self):
        values = conversation()
        values.extend([msg('continue please', 'user', '2026-09-01T12:00:00Z'),
                       msg('next step', 'assistant', '2026-09-01T12:01:00Z')])
        self.write(values)
        result = miner.mine_cases(self.roots)
        self.assertEqual(len(result['cases']), 1)
        self.assertEqual(result['cases'][0]['resume_line'], 5)

    def test_malformed_and_budget_guards(self):
        path = self.write(conversation())
        path.write_bytes(path.read_bytes() + b'not json\n')
        result = miner.mine_cases(self.roots)
        self.assertEqual(result['cases'], [])
        self.assertEqual(result['report']['excluded_malformed_sessions'], 1)
        self.write(conversation())
        with patch.object(miner, 'MAX_TOTAL_BYTES', 1), self.assertRaises(ValueError):
            miner.mine_cases(self.roots)

    def test_automation_cues_are_never_resumption_candidates(self):
        for text, flags in [
            ('Continue from where you left off.', {}),
            ('<task-notification>resume earlier task</task-notification>', {}),
            ('<local-command-stdout>Compacted. Continue</local-command-stdout>', {}),
            ('再開して', {'isMeta': True}),
            ('再開して', {'isCompactSummary': True}),
        ]:
            values = conversation()
            values[2]['message']['content'][0]['text'] = text
            values[2].update(flags)
            self.write(values)
            with self.subTest(text=text):
                self.assertEqual(miner.mine_cases(self.roots)['cases'], [])

    def test_codex_request_marker_extracts_prompt_preserving_history_text(self):
        values = [dict(type='response_item', timestamp=m['timestamp'], payload=dict(
            type='message', role=m['message']['role'], content=[dict(type='input_text',
                text=m['message']['content'][0]['text'])])) for m in conversation()]
        values[2]['payload']['content'][0]['text'] = '<environment_context>' + 'x'*2000 + '</environment_context>\n## My request:\n続きから再開しよう'
        self.write(values)
        case = miner.mine_cases([('codex', self.root)])['cases'][0]
        self.assertEqual(case['resume_prompt'], '続きから再開しよう')
        self.assertEqual(case['selection_method'], 'explicit_resume_cue')

    def test_gap_only_candidates_require_opt_in_and_triage(self):
        values = conversation()
        values[2]['message']['content'][0]['text'] = 'Can you implement the blue widgets?'
        self.write(values)
        self.assertEqual(miner.mine_cases(self.roots)['cases'], [])
        result = miner.mine_cases(self.roots, include_gap_candidates=True)
        self.assertEqual(result['cases'][0]['selection_method'], 'same_session_gap')
        self.assertTrue(result['cases'][0]['requires_triage'])

    def test_codex_messages_and_wrapped_evaluation_calls(self):
        values = [dict(type='response_item', timestamp=m['timestamp'], payload=dict(
            type='message', role=m['message']['role'], content=[dict(type='input_text',
                text=m['message']['content'][0]['text'])])) for m in conversation()]
        self.write(values)
        roots = [('codex', self.root)]
        self.assertEqual(len(miner.mine_cases(roots)['cases']), 1)
        values.append(dict(type='response_item', payload=dict(type='function_call',
            name='functions.exec', arguments=json.dumps({'code':
                'await tools.exec_command({cmd: "flight-recorder-resume mine"})'}))))
        self.write(values)
        result = miner.mine_cases(roots)
        self.assertEqual(result['cases'], [])
        self.assertEqual(result['report']['excluded_evaluation_sessions'], 1)

    def test_message_budgets_omit_without_truncation(self):
        values = conversation()
        values[0]['message']['content'][0]['text'] = 'X' * 30001
        self.write(values)
        result = miner.mine_cases(self.roots)
        self.assertEqual(len(result['cases'][0]['history']), 1)
        self.assertEqual(result['report']['omitted_history_messages'], 1)


if __name__ == '__main__':
    unittest.main()
