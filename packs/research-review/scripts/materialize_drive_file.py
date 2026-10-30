#!/usr/bin/env python3
"""Download a connector-issued file reference; no app/session credential lookup."""
import argparse
import http.client
import json
import os
import sys
import termios
import urllib.request
from pathlib import Path
from urllib.parse import urlsplit

from grok_webhook import NoRedirect
from grok_runtime import LIMIT, private_directory, write_new
from research_review import ContractError, require, sha, unique_pairs


def download(reference, destination, opener=None):
    require(isinstance(reference, dict) and isinstance(reference.get("download_url"), str),
            "expected a connector-issued file reference")
    url = reference["download_url"]
    parsed = urlsplit(url)
    require(parsed.scheme == "https" and parsed.hostname and
            parsed.hostname.endswith(".oaiusercontent.com") and
            not parsed.username and not parsed.password and not parsed.fragment and
            parsed.port in (None, 443) and url.isascii() and
            not any(ord(c) <= 32 or ord(c) == 127 for c in url), "unsupported file reference")
    private_directory(destination.parent)
    require(not destination.exists(), "download destination already exists")
    opener = opener or urllib.request.build_opener(NoRedirect())
    with opener.open(url, timeout=20) as response:
        require(response.status == 200, "raw file download failed")
        raw = response.read(LIMIT + 1)
    require(0 < len(raw) <= LIMIT, "raw download size rejected")
    write_new(destination, raw)
    return {"materialized": True, "bytes": len(raw), "sha256": sha(raw)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    prior = None
    try:
        # Tool PTYs can supply this one JSON line automatically. Hide echo before
        # announcing readiness, so the short-lived bearer URL is never echoed.
        if sys.stdin.isatty():
            prior = termios.tcgetattr(sys.stdin)
            hidden = termios.tcgetattr(sys.stdin)
            hidden[3] &= ~termios.ECHO
            termios.tcsetattr(sys.stdin, termios.TCSANOW, hidden)
        print('{"waiting_for":"connector_file_reference"}', flush=True)
        raw = sys.stdin.buffer.readline(16385)
        require(0 < len(raw) <= 16384, "file reference size rejected")
        reference = json.loads(raw, object_pairs_hook=unique_pairs)
        result = download(reference, args.destination.expanduser().absolute())
        print(json.dumps(result))
        return 0
    except (ContractError, OSError, ValueError, TypeError, RecursionError, http.client.HTTPException):
        print('{"materialized":false,"reason":"raw_file_unavailable"}', file=sys.stderr)
        return 2
    finally:
        if prior is not None:
            termios.tcsetattr(sys.stdin, termios.TCSANOW, prior)


if __name__ == "__main__":
    sys.exit(main())
