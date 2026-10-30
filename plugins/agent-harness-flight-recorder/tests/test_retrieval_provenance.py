import sys
import unittest
from unittest.mock import patch
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from retrieval_provenance import view
import retrieval_context as context

FRAME = '# AGENTS.md instructions for /example\n<INSTRUCTIONS>\nconsult partner repeatedly\n</INSTRUCTIONS>'
PREFIX = '<recommended_plugins>available plugins</recommended_plugins>\n'
ENV = '\n<environment_context>machine</environment_context>'


def snapshot(messages):
    text, spans = '', []
    for line, (role, body) in enumerate(messages, 1):
        prefix = f'[line {line}] {role}: '
        start = len(text) + len(prefix)
        text += prefix + body + '\n'
        spans.append(dict(line=line, role=role, start=start, end=len(text)-1))
    return dict(snapshot_id='fixture', documents=[dict(source_id='source', citation_id='citation',
        start_line=1, end_line=len(messages), text=text.rstrip('\n'), message_spans=spans)])


class ProvenanceTests(unittest.TestCase):
    def test_machine_prefix_does_not_hide_consultation_session(self):
        from retrieval_live import BRIDGE_PROMPT
        for prefix in [PREFIX + FRAME + ENV, ENV]:
            for messages in [
                [('user', prefix), ('user', BRIDGE_PROMPT)],
                [('user', prefix + '\n' + BRIDGE_PROMPT)],
            ]:
                s = snapshot(messages + [('assistant', 'advice'),
                                         ('user', 'unwrapped followup')])
                for enabled in [True, False]:
                    self.assertEqual(context.units(s, provenance=enabled)[0], [])

    def test_complete_frames_and_unknown_tail(self):
        original = PREFIX + FRAME + ENV + '\nKeep my learning history.'
        meta, selected = view(original)
        self.assertEqual(selected.strip(), 'Keep my learning history.')
        self.assertEqual(''.join(original[r['start']:r['end']] for r in meta['regions']), original)
        self.assertEqual([r['kind'] for r in meta['regions']], ['injected']*3+['unknown'])
        self.assertEqual(meta['regions'][-1]['confidence'], 'unknown')

    def test_quotes_mentions_and_broken_frames_stay_unknown(self):
        for original in ['Please change AGENTS.md', 'I disagree with:\n'+FRAME,
                         '```text\n'+FRAME+'\n```', PREFIX+'# AGENTS.md instructions\n<INSTRUCTIONS>unfinished']:
            meta, selected = view(original)
            self.assertIn('AGENTS.md', selected)
            self.assertEqual(meta['regions'][-1]['kind'], 'unknown')

    def test_no_injected_terms_or_context_leak_but_tail_remains(self):
        s = snapshot([('user','old request'), ('assistant','old answer'),
                      ('user',PREFIX+FRAME+ENV+'\nPreserve grades'),
                      ('assistant','yes preserve'), ('user','Next question')])
        original = s['documents'][0]['text']
        result = context.retrieve(s, 'partner', 3)
        self.assertEqual(result['hits'], [])
        result = context.retrieve(s, 'grades', 3)
        self.assertTrue(result['hits'])
        h = next(h for h in result['hits'] if h['line']==3)
        self.assertEqual(h['utterance']['text'].strip(), 'Preserve grades')
        self.assertIsNone(h['prior_response'])
        self.assertEqual(s['documents'][0]['text'], original)
        self.assertEqual(result['candidate_filter']['excluded_turns'], 1)
        self.assertEqual(result['candidate_filter']['excluded_regions'], 3)

    def test_observer_does_not_count_structured_injection_as_reply(self):
        self.assertFalse(context.conversational(PREFIX+FRAME+ENV))
        self.assertTrue(context.conversational(PREFIX+FRAME+ENV+'\nMy reply'))

    def test_empty_frame_resets_assistant_context(self):
        s=snapshot([('user',PREFIX+FRAME),('assistant','partner generated'),('user','ordinary request')])
        self.assertEqual(context.retrieve(s,'partner',3)['hits'],[])

    def test_filter_does_not_change_unmodified_candidate_scores(self):
        s=snapshot([('user', 'partner repeated dialogue'), ('user', PREFIX+FRAME)])
        actual=context.retrieve(s,'partner',3)
        original_units=context.units
        with patch.object(context, 'units', side_effect=lambda snap, **kw: original_units(snap, provenance=False)):
            baseline=context.retrieve(s,'partner',3)
        a=next(h for h in actual['hits'] if h['line']==1)
        b=next(h for h in baseline['hits'] if h['line']==1)
        self.assertEqual(a['score'],b['score'])

    def test_same_human_text_is_not_deduplicated(self):
        s=snapshot([('user','preserve history'),('user','preserve history')])
        self.assertEqual(len(context.retrieve(s,'preserve',3)['hits']),2)

if __name__ == '__main__': unittest.main()
