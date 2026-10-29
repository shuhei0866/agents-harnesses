#!/usr/bin/env python3
"""Submit one research request to an existing, authorized Grok Bot routine."""
from __future__ import annotations

import argparse
import http.client
import json
import os
import socket
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone
from urllib.parse import urlsplit

from research_review import ContractError, brief, load, sha


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def request_payload(bundle):
    return json.dumps({"schema_version": 1, "request_id": bundle["task"]["id"],
                       "task_id": bundle["task"]["id"], "request": brief(bundle)},
                      ensure_ascii=False).encode("utf-8")


def valid_configuration(endpoint, key, expected_origin):
    try:
        url, origin = urlsplit(endpoint), urlsplit(expected_origin)
        return bool(url.scheme == origin.scheme == "https" and url.hostname
                    and not url.username and not url.password and not url.fragment
                    and origin.hostname and not origin.username and not origin.password
                    and not origin.query and not origin.fragment and origin.path in {"", "/"}
                    and (url.hostname.lower(), url.port or 443)
                    == (origin.hostname.lower(), origin.port or 443)
                    and key.strip() and not any(c in endpoint + key + expected_origin
                                               for c in "\r\n"))
    except ValueError:
        return False


def send_once(bundle, endpoint, key, expected_origin, timeout=30, opener=None, payload=None):
    payload = request_payload(bundle) if payload is None else payload
    result = {"task_id": bundle["task"]["id"], "request_sha256": sha(payload),
              "research_complete": False, "automatic_retry": False}
    if not valid_configuration(endpoint, key, expected_origin):
        return {**result, "status": "not_sent", "reason": "invalid_webhook_configuration"}
    request = urllib.request.Request(endpoint, data=payload, method="POST", headers={
        "Authorization": "Bearer " + key, "Content-Type": "application/json; charset=utf-8"})
    opener = opener or urllib.request.build_opener(NoRedirect())
    try:
        # Never consume or log a response body. 200 is acceptance, not completion.
        with opener.open(request, timeout=timeout) as response:
            code = response.status
        return {**result, "status": "accepted" if code == 200 else "unknown",
                "http_status": code}
    except urllib.error.HTTPError as exc:
        code = exc.code
        exc.close()
        return {**result, "status": "not_accepted" if 400 <= code < 500 else "unknown",
                "http_status": code}
    except (urllib.error.URLError, OSError, socket.timeout, http.client.HTTPException, ValueError):
        return {**result, "status": "unknown", "reason": "inspect_bot_chat_before_any_retry"}


def main():
    from pathlib import Path
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle", type=Path)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    try:
        bundle = load(args.bundle)
        if args.dry_run:
            result = {"task_id": bundle["task"]["id"], "status": "not_sent",
                      "dry_run": True, "network_calls": 0, "research_complete": False}
        else:
            endpoint = os.environ.get("GROK_BOT_WEBHOOK_URL", "")
            key = os.environ.get("GROK_BOT_WEBHOOK_KEY", "")
            origin = os.environ.get("GROK_BOT_WEBHOOK_ORIGIN", "")
            if not valid_configuration(endpoint, key, origin):
                result = {"status": "not_sent", "reason": "invalid_webhook_configuration",
                          "research_complete": False}
            else:
                payload = request_payload(bundle)
                marker = args.bundle.parent / ".grok-webhook-attempt.json"
                try:
                    fd = os.open(marker, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
                except FileExistsError:
                    result = {"status": "not_sent", "reason": "attempt_already_reserved",
                              "task_id": bundle["task"]["id"], "research_complete": False}
                else:
                    # Persist before networking. A crash leaves uncertainty, not retry permission.
                    with os.fdopen(fd, "w", encoding="utf-8") as file:
                        json.dump({"task_id": bundle["task"]["id"],
                                   "request_sha256": sha(payload), "origin_sha256": sha(origin.encode()),
                                   "reserved_at": datetime.now(timezone.utc).isoformat()}, file)
                        file.flush()
                        os.fsync(file.fileno())
                    result = send_once(bundle, endpoint, key, origin, payload=payload)
        print(json.dumps(result, sort_keys=True))
        if args.dry_run:
            return 0
        return {"accepted": 0, "not_accepted": 1, "not_sent": 2, "unknown": 75}[result["status"]]
    except (ContractError, OSError, ValueError, TypeError, KeyError):
        print(json.dumps({"status": "not_sent", "reason": "invalid_request_bundle",
                          "research_complete": False}), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
