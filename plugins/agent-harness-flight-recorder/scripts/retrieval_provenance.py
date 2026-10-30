"""Reversible, structural provenance view. Unknown never means human-authored.

Offsets are Unicode character offsets into the unchanged message. Only a
leading sequence of complete known envelopes is classified; quotes, malformed
frames and unmarked prose remain unknown. No model or wording heuristic.
"""
import hashlib
import re

VERSION = 'message-origin-v1'
TAGS = ('recommended_plugins', 'environment_context', 'app-context')
HEADER = re.compile(r'# AGENTS\.md instructions(?: for [^\n]+)?\r?\n\s*<INSTRUCTIONS>')


def classify(text):
    result, cursor = [], 0
    while cursor < len(text):
        start = cursor
        pos = cursor + len(text[cursor:]) - len(text[cursor:].lstrip())
        reason, end = None, None
        header = HEADER.match(text, pos)
        if header:
            close = text.find('</INSTRUCTIONS>', header.end())
            if close >= 0:
                reason, end = 'agents_instructions', close + len('</INSTRUCTIONS>')
        else:
            for tag in TAGS:
                opening = re.match(r'<' + re.escape(tag) + r'(?:\s[^>]*|)>', text[pos:])
                if opening:
                    close = text.find('</' + tag + '>', pos + opening.end())
                    if close >= 0:
                        reason, end = tag, close + len(tag) + 3
                    break
        if end is None:
            result.append(_region(text, start, len(text), 'unknown', 'unclassified'))
            break
        result.append(_region(text, start, end, 'injected', reason))
        cursor = end
    return result


def _region(text, start, end, kind, basis):
    return dict(start=start, end=end, kind=kind, basis=basis,
                confidence='structural' if kind == 'injected' else 'unknown',
                text_sha256=hashlib.sha256(text[start:end].encode()).hexdigest())


def view(text):
    regions = classify(text)
    return dict(version=VERSION, offset_unit='unicode_characters',
                original_sha256=hashlib.sha256(text.encode()).hexdigest(),
                regions=regions), ''.join(text[r['start']:r['end']] for r in regions if r['kind'] == 'unknown')
