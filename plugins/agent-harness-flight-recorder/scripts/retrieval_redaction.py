"""Best-effort credential masking at the display boundary; originals stay local."""
import re

PATTERNS = (
    re.compile(r'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----.*?-----END (?:RSA |EC |OPENSSH )?PRIVATE KEY-----', re.S),
    re.compile(r'(?i)\bAuthorization\s*:\s*Bearer\s+[^\s"\'<>]+'),
    re.compile(r'\bsk-(?:(?:ant|proj|test)-)?[A-Za-z0-9_-]{12,}\b'),
    re.compile(r'\b(?:gh[pousr]_[A-Za-z0-9]{12,}|github_pat_[A-Za-z0-9_]{12,})\b'),
    re.compile(r'\bAKIA[0-9A-Z]{16}\b'),
    re.compile(r'''(?ix)\b(?:[a-z0-9]+_)*(?:api[_-]?key|access[_-]?token|secret|password)\b["']?\s*[:=]\s*(?:"[^"\n]+"|'[^'\n]+'|[^\s,;}]+)'''),
)


def redact_payload(value):
    """Return a display copy and whether any supported credential form was masked.

    This is deliberately not a guarantee of secret detection. It does not alter
    source text, citation hashes, matching scores, or owner-only stored evidence.
    """
    changed = False

    def visit(item):
        nonlocal changed
        if isinstance(item, str):
            result = item
            for pattern in PATTERNS:
                result = pattern.sub('[credential redacted]', result)
            changed |= result != item
            return result
        if isinstance(item, list):
            return [visit(x) for x in item]
        if isinstance(item, dict):
            return {k: visit(v) for k, v in item.items()}
        return item

    result = visit(value)
    if changed and isinstance(result, dict):
        result['display_redacted'] = True
    return result
