"""Synthetic local collector tests; no real histories or model calls."""
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1] / 'scripts'
sys.path.insert(0, str(SCRIPTS))
spec = importlib.util.spec_from_file_location('retrieval_live', SCRIPTS / 'retrieval_live.py')
live = importlib.util.module_from_spec(spec)
spec.loader.exec_module(live)


def encode(*items):
    return b''.join(json.dumps(item).encode() + b'\n' for item in items)


def claude(text, role='user'):
    return dict(type=role, message=dict(role=role, content=[dict(type='text', text=text)]))


def codex(text, role='user'):
    return dict(type='response_item', payload=dict(type='message', role=role,
                content=[dict(type='input_text', text=text)]))


class LiveTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.claude = self.root / 'claude'
        self.codex = self.root / 'codex'
        self.claude.mkdir()
        self.codex.mkdir()
        self.roots = [('claude-code', self.claude), ('codex', self.codex)]

    def write(self, root, name, raw):
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(raw)
        return path

    def test_complete_conversational_lines_keep_citations_and_stable_ids(self):
        p = self.write(self.claude, 'one.jsonl', encode(claude('first'), {'type':'tool', 'text':'hidden'},
                        claude('answer', 'assistant')) + b'{"partial":')
        first = live.export_live(self.roots, since=0)
        self.assertEqual(len(first['documents']), 1)
        self.assertEqual(first['documents'][0]['end_line'], 3)
        self.assertIn('[line 3] assistant: answer', first['documents'][0]['text'])
        self.assertNotIn('hidden', first['documents'][0]['text'])
        self.assertEqual(first['import_report']['partial_sources'], 1)
        p.write_bytes(encode(claude('first'), {'type':'tool', 'text':'hidden'}, claude('answer', 'assistant'), claude('new')))
        second = live.export_live(self.roots, since=0)
        self.assertEqual(first['documents'][0]['source_id'], second['documents'][0]['source_id'])
        self.assertNotIn(str(self.root), json.dumps(second))

    def test_since_limits_files_and_never_reads_symlinks_or_other_extensions(self):
        p = self.write(self.claude, 'old.jsonl', encode(claude('old')))
        os.utime(p, (10, 10))
        self.write(self.claude, 'new.jsonl', encode(claude('new')))
        self.write(self.claude, '.env', b'SECRET=x')
        (self.codex / 'linked.jsonl').symlink_to(p)
        (self.codex / 'linked-directory').symlink_to(self.claude)
        value = live.export_live(self.roots, since=20)
        self.assertEqual(len(value['documents']), 1)
        self.assertIn('new', value['documents'][0]['text'])
        self.assertEqual(value['import_report']['unchanged_sources'], 1)
        self.assertEqual(value['import_report']['symlinks_skipped'], 2)

    def test_tool_wrappers_exclude_entire_session_but_mentions_do_not(self):
        tool = dict(type='response_item', payload=dict(type='function_call', name='functions.exec',
                    arguments=json.dumps({'code': 'await tools.exec_command({cmd:"python retrieval_lab.py search"})'})))
        self.write(self.codex, 'bad.jsonl', encode(codex('must disappear'), tool))
        listing = codex('tools include flight-recorder-retrieval and recall-history', 'developer')
        self.write(self.codex, 'good.jsonl', encode(listing, codex('Discuss retrieval_lab.py naming')))
        value = live.export_live(self.roots, since=0)
        self.assertEqual(len(value['documents']), 1)
        self.assertIn('Discuss', value['documents'][0]['text'])
        self.assertEqual(len(value['excluded_source_ids']), 1)
        self.assertEqual(value['import_report']['excluded_retrieval_sessions'], 1)

    def test_claude_tool_and_subagent_exclusions(self):
        tool = dict(type='assistant', message=dict(role='assistant', content=[dict(type='tool_use',
                    name='Bash', input={'command':'cat /skills/recall-history/SKILL.md'})]))
        self.write(self.claude, 'bad.jsonl', encode(claude('bad'), tool))
        self.write(self.claude, 'subagents/agent-one.jsonl', encode(claude('subagent')))
        self.write(self.codex, 'agent.jsonl', encode(dict(type='session_meta', payload={
            'id':'child', 'source':{'subagent':{'thread_spawn':{'parent_thread_id':'parent'}}}}), codex('child')))
        value = live.export_live(self.roots, since=0)
        self.assertEqual(value['documents'], [])
        self.assertEqual(value['import_report']['excluded_subagent_sessions'], 2)
        self.assertEqual(value['import_report']['excluded_retrieval_sessions'], 1)

    def test_explicit_session_id_excludes_filename_and_metadata(self):
        self.write(self.claude, 'filename-id.jsonl', encode(claude('one')))
        self.write(self.claude, 'other.jsonl', encode(dict(claude('two'), sessionId='metadata-id')))
        self.write(self.codex, 'rollout.jsonl', encode(dict(type='session_meta', payload={'id':'codex-id'}), codex('three')))
        result = live.export_live(self.roots, since=0, exclude_sessions=['filename-id','metadata-id','codex-id'])
        self.assertEqual(result['documents'], [])
        self.assertEqual(result['import_report']['excluded_configured_sessions'], 3)

    def test_all_overflows_fail_closed_and_errors_do_not_expose_path(self):
        self.write(self.claude, 'one.jsonl', encode(claude('a')))
        self.write(self.codex, 'two.jsonl', encode(codex('b')))
        for bound in ('MAX_FILES','MAX_TOTAL_BYTES','MAX_SOURCE_BYTES','MAX_DOCUMENTS','MAX_MANIFEST_BYTES'):
            with self.subTest(bound=bound), patch.object(live, bound, 1):
                with self.assertRaises(ValueError) as raised:
                    live.export_live(self.roots, since=0)
                self.assertNotIn(str(self.root), str(raised.exception))
        with patch.object(live, '_records', side_effect=OSError('private absolute path')):
            with self.assertRaises(ValueError) as raised:
                live.export_live(self.roots, since=0)
            self.assertNotIn('private absolute path', str(raised.exception))

    def test_oversized_single_line_is_explicitly_omitted(self):
        self.write(self.claude, 'large.jsonl', encode(claude('z' * 150000), claude('small useful text')))
        result = live.export_live(self.roots, since=0)
        self.assertEqual(result['import_report']['omitted_oversized_lines'], 1)
        self.assertEqual(len(result['documents']), 1)
        self.assertIn('[line 2]', result['documents'][0]['text'])

    def test_malformed_source_is_quarantined_entirely(self):
        self.write(self.claude, 'bad.jsonl', encode(claude('must disappear')) + b'{invalid}\n')
        result = live.export_live(self.roots, since=0)
        self.assertEqual(result['documents'], [])
        self.assertEqual(result['import_report']['excluded_malformed_sessions'], 1)
        self.assertEqual(len(result['excluded_source_ids']), 1)

    def test_large_window_splits_without_losing_original_lines(self):
        self.write(self.claude, 'window.jsonl', encode(claude('a' * 60000), claude('b' * 60000)))
        result = live.export_live(self.roots, since=0)
        self.assertEqual(len(result['documents']), 2)
        self.assertEqual([(d['start_line'], d['end_line']) for d in result['documents']], [(1, 1), (2, 2)])
        self.assertTrue(all(len(d['text']) <= 100000 for d in result['documents']))

    def test_settled_source_and_empty_refresh_identifiers(self):
        p = self.write(self.claude, 'pending.jsonl', encode(claude('pending')))
        os.utime(p, (100, 100))
        result = live.export_live(self.roots, since=0, now=120, settle_seconds=60)
        self.assertEqual(result['documents'], [])
        self.assertEqual(result['refreshed_source_ids'], [])
        self.assertEqual(result['import_report']['deferred_sources'], 1)
        result = live.export_live(self.roots, since=0, now=200, settle_seconds=60)
        self.assertEqual(len(result['refreshed_source_ids']), 1)

    def test_archive_over_old_file_limit_is_streamed_with_original_line_numbers(self):
        path = self.codex / 'archive.jsonl'
        ignored = encode(dict(type='tool_result', text='x' * (1024 * 1024)))
        with path.open('wb') as stream:
            for _ in range(65):
                stream.write(ignored)
            stream.write(encode(codex('archived decision')))
        result = live.export_live(self.roots, since=0)
        self.assertGreater(result['import_report']['bytes_read'], 64 * 1024 * 1024)
        self.assertEqual(len(result['documents']), 1)
        self.assertIn('[line 66] user: archived decision', result['documents'][0]['text'])

    def test_late_evaluation_record_discards_earlier_streamed_messages(self):
        tool = dict(type='response_item', payload=dict(type='function_call', name='exec',
                    arguments='recall-history search test'))
        self.write(self.codex, 'late.jsonl', encode(*([codex('must disappear')] * 120), tool))
        result = live.export_live(self.roots, since=0)
        self.assertEqual(result['documents'], [])
        self.assertEqual(result['import_report']['excluded_retrieval_sessions'], 1)

    def test_oversized_json_record_quarantines_entire_source(self):
        self.write(self.codex, 'large.jsonl', encode(codex('earlier'), codex('x' * 4096)))
        with patch.object(live, 'MAX_LINE_BYTES', 1024):
            result = live.export_live(self.roots, since=0)
        self.assertEqual(result['documents'], [])
        self.assertEqual(result['import_report']['excluded_oversized_sessions'], 1)
        self.assertLess(result['import_report']['bytes_read'], 2000)

    def test_changed_source_is_rejected_during_streaming(self):
        path = self.write(self.codex, 'racing.jsonl', encode(codex('before')))
        original = live._message
        def mutate(value, adapter):
            with path.open('ab') as stream:
                stream.write(encode(codex('after')))
            return original(value, adapter)
        with patch.object(live, '_message', side_effect=mutate):
            # Exclude after the first message to stop iteration, but still
            # require the generator's final stability check on close.
            records = live._records(path, dict(bytes_read=0, partial_sources=0, oversized_records=0))
            next(records)
            mutate({}, 'codex')
            with self.assertRaisesRegex(ValueError, 'input changed'):
                records.close()

    def test_new_archive_path_bypasses_old_mtime_and_inventory_tracks_removal(self):
        old = self.write(self.codex, 'old.jsonl', encode(codex('move me')))
        os.utime(old, (10, 10))
        before = live.export_live(self.roots, since=0)
        new = self.codex / 'archived' / 'old.jsonl'
        new.parent.mkdir()
        old.rename(new)
        after = live.export_live(self.roots, since=20, known_source_ids=before['present_source_ids'])
        self.assertEqual(len(after['documents']), 1)
        self.assertNotEqual(before['present_source_ids'], after['present_source_ids'])
        self.assertTrue(after['inventory_complete'])
        unchanged = live.export_live(self.roots, since=20, known_source_ids=after['present_source_ids'])
        self.assertEqual(unchanged['documents'], [])

    def test_duplicate_roots_do_not_duplicate_documents(self):
        self.write(self.claude, 'one.jsonl', encode(claude('one')))
        result = live.export_live(self.roots + [('claude-code', self.claude)], since=0)
        self.assertEqual(len(result['documents']), 1)


if __name__ == '__main__':
    unittest.main()
