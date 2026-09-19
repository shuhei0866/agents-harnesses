import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts' / 'retrieval_snapshot.py'
spec = importlib.util.spec_from_file_location('retrieval_snapshot', SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def sha(raw):
    return 'sha256:' + hashlib.sha256(raw).hexdigest()


def line(value):
    return json.dumps(value).encode() + b'\n'


def claude(text, role='user'):
    return dict(type=role, message=dict(role=role, content=[dict(type='text', text=text)]))


class SnapshotTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        (self.root / 'session-sources').mkdir()
        (self.root / 'semantic-receipts').mkdir()

    def register(self, path, raw, index=1, adapter='claude-code'):
        ref = 'hmac-sha256:' + f'{index:064x}'
        record = dict(source_ref=ref, adapter=adapter, path=str(path),
                      size_bytes=len(raw), content_sha256=sha(raw), modified_ns=index)
        (self.root / 'session-sources' / f'{index}.json').write_text(json.dumps(record))
        return record

    def receipt(self, record, raw, start=1, end=1, index=1, bad_hash=False):
        span = dict(source_ref=record['source_ref'], adapter=record['adapter'],
                    content_sha256=record['content_sha256'], start_line=start, end_line=end,
                    span_sha256=sha(raw) if not bad_hash else sha(b'wrong'))
        value = dict(task=dict(intent='find decision', deliverable='answer'),
                     result=dict(summary='known reason'), provenance=dict(source_spans=[span]))
        (self.root / 'semantic-receipts' / f'{index}.json').write_text(json.dumps(value))

    def test_latest_prefix_and_old_receipt_and_full_conversation_windows(self):
        first = line(claude('first decision'))
        second = line(claude('another topic', 'assistant'))
        path = self.root / 'source.jsonl'
        old = self.register(path, first)
        latest = self.register(path, first + second, 2)
        path.write_bytes(first + second + line(claude('unregistered tail')))
        self.receipt(old, first)
        self.receipt(old, first, index=2)
        reads = []
        real = module._read
        def observe(p, *args, **kwargs):
            if p == path:
                reads.append(p)
            return real(p, *args, **kwargs)
        with patch.object(module, '_read', side_effect=observe):
            value = module.export_vault(self.root, 1)
        self.assertEqual(len(reads), 1)
        docs = value['documents']
        self.assertEqual(len(docs), 2)
        self.assertEqual(docs[0]['source_id'], latest['source_ref'])
        self.assertEqual(docs[0]['summaries'], ['find decision', 'answer', 'known reason'])
        self.assertEqual(docs[1]['summaries'], [])
        self.assertIn('[line 2] assistant: another topic', docs[1]['text'])
        self.assertNotIn(str(path), json.dumps(value))
        self.assertNotIn('unregistered tail', json.dumps(value))

    def test_omits_tools_thinking_and_codex_event_duplicates(self):
        path = self.root / 'claude.jsonl'
        message = claude('visible', 'assistant')
        message['message']['content'] += [dict(type='thinking', thinking='PRIVATE'),
                                         dict(type='tool_use', input={'text': 'PRIVATE'})]
        raw = line(message) + line(dict(type='user', message=dict(role='user', content=[
            dict(type='tool_result', content='PRIVATE')])) )
        path.write_bytes(raw)
        self.register(path, raw)
        codex = self.root / 'codex.jsonl'
        raw = line(dict(type='response_item', payload=dict(type='message', role='assistant',
                   content=[dict(type='output_text', text='codex visible')])))
        raw += line(dict(type='event_msg', payload=dict(type='agent_message', message='DUPLICATE')))
        codex.write_bytes(raw)
        self.register(codex, raw, 2, 'codex')
        value = json.dumps(module.export_vault(self.root))
        self.assertIn('codex visible', value)
        self.assertNotIn('PRIVATE', value)
        self.assertNotIn('DUPLICATE', value)

    def test_changed_missing_and_over_budget_sources_are_counted(self):
        self.register(self.root / 'missing.jsonl', b'123')
        changed = self.root / 'changed.jsonl'
        changed.write_bytes(b'456')
        self.register(changed, b'123', 2)
        with patch.object(module, 'MAX_SOURCE_BYTES', 2):
            result = module.export_vault(self.root)
        self.assertEqual(result['import_report']['bounded_sources'], 2)
        result = module.export_vault(self.root)
        self.assertEqual(result['import_report']['missing_sources'], 1)
        self.assertEqual(result['import_report']['mismatched_sources'], 1)
        self.assertEqual(result['documents'], [])

    def test_receipts_require_exact_span_hash_and_registered_content(self):
        path = self.root / 'source.jsonl'
        raw = line(claude('real content'))
        path.write_bytes(raw)
        record = self.register(path, raw)
        self.receipt(record, raw, bad_hash=True)
        result = module.export_vault(self.root)
        self.assertEqual(result['documents'][0]['summaries'], [])
        self.assertEqual(result['import_report']['skipped_spans'], 1)

    def test_unavailable_source_spans_are_reported(self):
        record = self.register(self.root / 'missing.jsonl', b'123')
        self.receipt(record, b'123')
        result = module.export_vault(self.root)
        self.assertEqual(result['import_report']['unavailable_source_spans'], 1)
        self.assertEqual(result['import_report']['skipped_spans'], 1)
        with patch.object(module, 'MAX_SOURCE_BYTES', 2):
            result = module.export_vault(self.root)
        self.assertEqual(result['import_report']['unavailable_source_spans'], 1)

    def test_large_windows_and_manifest_are_bounded_without_losing_other_windows(self):
        path = self.root / 'source.jsonl'
        raw = line(claude('x' * 100001)) + line(claude('small useful message'))
        path.write_bytes(raw)
        self.register(path, raw)
        result = module.export_vault(self.root, 1)
        self.assertEqual(len(result['documents']), 1)
        self.assertEqual(result['documents'][0]['start_line'], 2)
        self.assertEqual(result['import_report']['bounded_windows'], 1)
        with patch.object(module, 'MAX_MANIFEST_BYTES', 1):
            result = module.export_vault(self.root, 1)
        self.assertEqual(result['documents'], [])
        self.assertEqual(result['import_report']['bounded_windows'], 2)

    def test_rejects_non_session_files_and_symlinks(self):
        secret = self.root / '.env'
        secret.write_text('SECRET=value')
        self.register(secret, secret.read_bytes())
        target = self.root / 'source.jsonl'
        target.write_bytes(line(claude('hidden')))
        link = self.root / 'link.jsonl'
        link.symlink_to(target)
        self.register(link, target.read_bytes(), 2)
        result = module.export_vault(self.root)
        self.assertEqual(result['documents'], [])
        self.assertEqual(result['import_report']['invalid_registrations'], 1)
        self.assertEqual(result['import_report']['mismatched_sources'], 1)


if __name__ == '__main__':
    unittest.main()
