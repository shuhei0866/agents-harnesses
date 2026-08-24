#!/usr/bin/env bash
# Local-only Flight Recorder Observatory API, rendering, and HTTP contract.
# External dependencies: python3. Network/provider/Vault access is not required.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_ROOT="$(mktemp -d)" || exit 1
readonly TEST_ROOT
PASS=0
FAIL=0

cleanup() {
  [[ -n "$TEST_ROOT" && "$TEST_ROOT" != "/" && -d "$TEST_ROOT" ]] \
    || return
  [[ "${TEST_ROOT##*/}" == tmp.* ]] || return
  rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT

pass() {
  echo "  PASS: $1"
  PASS=$((PASS + 1))
}

fail() {
  echo "  FAIL: $1"
  FAIL=$((FAIL + 1))
}

test_overview_is_one_sealed_fixed_projection() {
  echo "test_overview_is_one_sealed_fixed_projection:"
  local err="$TEST_ROOT/overview.err"
  if PYTHONPATH="$PLUGIN_DIR/scripts" python3 - "$TEST_ROOT" 2>"$err" <<'PY'
import pathlib
import sqlite3
import sys

import observatory
import receipt_automation
import reporting
import semantic_receipts
import value_compiler


root = pathlib.Path(sys.argv[1]) / "overview-vault"
root.mkdir()
(root / "inbox").mkdir()
(root / "inbox/events.jsonl").write_text("one\ntwo\n", encoding="utf-8")

connection = sqlite3.connect(":memory:")
connection.executescript(
    """
    PRAGMA user_version = 4;
    CREATE TABLE source_events(event_id TEXT, canonical_event_json TEXT);
    CREATE TABLE episodes(
        policy_version TEXT, episode_id TEXT, member_count INTEGER
    );
    CREATE TABLE session_atlas_facets(
        policy_version TEXT,
        episode_id TEXT,
        event_lifecycle_state TEXT,
        operation_state TEXT,
        artifact_change_state TEXT
    );
    """
)
raw_canary = "RAW-SESSION-CANARY-DO-NOT-LEAK"
connection.executemany(
    "INSERT INTO source_events VALUES (?, ?)",
    [(f"event-{number}", raw_canary) for number in range(5)],
)
connection.executemany(
    "INSERT INTO episodes VALUES (?, ?, ?)",
    [
        ("default-v1", "episode-1", 1),
        ("default-v1", "episode-2", 1),
        ("default-v1", "episode-3", 2),
        ("default-v1", "episode-4", 3),
        ("other-v1", "not-in-default", 1),
    ],
)
connection.executemany(
    "INSERT INTO session_atlas_facets VALUES (?, ?, ?, ?, ?)",
    [
        ("default-v1", "episode-1", "present", "present", "present"),
        ("default-v1", "episode-2", "mixed", "present", "mixed"),
        ("default-v1", "episode-3", "unknown", "present", "present"),
        ("default-v1", "episode-4", "present", "unknown", "present"),
        ("other-v1", "not-in-default", "present", "present", "present"),
    ],
)

sealed_calls = []


def sealed_query(actual_root, policy_version, query, trusted_policy=None):
    sealed_calls.append((actual_root, policy_version, trusted_policy))
    assert actual_root == root
    assert policy_version == "default-v1"
    return query(connection, {"policy_version": "default-v1"})


def receipts(_root):
    return [(None, b"", {}) for _ in range(2)]


def values(_root):
    return [(None, b"", {})]


automation = {
    "schema_version": 1,
    "state": "attention",
    "enabled": True,
    "discovered": 11,
    "matched": 7,
    "ambiguous": 2,
    "missing": 1,
    "active": 1,
    "queued": 3,
    "generated": 4,
    "failed": 0,
    "measured_cost_microusd": 12345,
    "diagnostic_code": None,
    "attempt_count": 4,
    "private_path": raw_canary,
}

# Support either module-qualified strict readers or explicit local aliases.
observatory.read_sealed_query_locked = sealed_query
observatory._inbox_count = lambda _root: 2
reporting._inbox_count = observatory._inbox_count
observatory._stored_receipts = receipts
semantic_receipts._stored_receipts = receipts
observatory._stored_value_records = values
observatory._stored_records = values
value_compiler._stored_records = values
observatory.receipt_automation_status = lambda _root: automation
receipt_automation.status = observatory.receipt_automation_status

value = observatory.overview(root)
assert len(sealed_calls) == 1
assert value == {
    "schema_version": 1,
    "command": "observatory.overview",
    "recording": {
        "state": "ready",
        "index_schema_version": 4,
        "events": 5,
        "pending_events": 2,
    },
    "episode_formation": {
        "episodes": 4,
        "singleton_episodes": 2,
        "singleton_basis_points": 5000,
    },
    "comparison_readiness": {
        "comparable_episodes": 2,
        "comparable_basis_points": 5000,
    },
    "semantic_coverage": {
        "semantic_receipts": 2,
        "value_cards": 1,
    },
    "receipt_automation": {
        "schema_version": 1,
        "state": "attention",
        "enabled": True,
        "discovered": 11,
        "matched": 7,
        "ambiguous": 2,
        "missing": 1,
        "active": 1,
        "queued": 3,
        "generated": 4,
        "failed": 0,
        "measured_cost_microusd": 12345,
        "diagnostic_code": None,
        "attempt_count": 4,
    },
}
assert raw_canary not in repr(value)
PY
  then
    pass "overviewは1回のsealed queryから固定schemaと比較可能性を集計する"
  else
    cat "$err" >&2
    fail "overviewは1回のsealed queryから固定schemaと比較可能性を集計する"
  fi
}

test_overview_uses_strict_local_readers_and_zero_denominator() {
  echo "test_overview_uses_strict_local_readers_and_zero_denominator:"
  local err="$TEST_ROOT/overview-strict.err"
  if PYTHONPATH="$PLUGIN_DIR/scripts" python3 - "$TEST_ROOT" 2>"$err" <<'PY'
import pathlib
import sqlite3
import sys

import observatory
import receipt_automation
import reporting
import semantic_receipts
import value_compiler
from vault import VaultError


root = pathlib.Path(sys.argv[1]) / "strict-vault"
root.mkdir()
connection = sqlite3.connect(":memory:")
connection.executescript(
    """
    PRAGMA user_version = 4;
    CREATE TABLE source_events(event_id TEXT);
    CREATE TABLE episodes(
        policy_version TEXT, episode_id TEXT, member_count INTEGER
    );
    CREATE TABLE session_atlas_facets(
        policy_version TEXT,
        episode_id TEXT,
        event_lifecycle_state TEXT,
        operation_state TEXT,
        artifact_change_state TEXT
    );
    """
)


def sealed_query(_root, _version, query, trusted_policy=None):
    return query(connection, {"policy_version": "default-v1"})


empty_automation = {
    "schema_version": 1,
    "state": "idle",
    "enabled": False,
    "discovered": 0,
    "matched": 0,
    "ambiguous": 0,
    "missing": 0,
    "active": 0,
    "queued": 0,
    "generated": 0,
    "failed": 0,
    "measured_cost_microusd": 0,
    "diagnostic_code": None,
    "attempt_count": 0,
}

observatory.read_sealed_query_locked = sealed_query
observatory._inbox_count = lambda _root: 0
reporting._inbox_count = observatory._inbox_count
observatory.receipt_automation_status = lambda _root: empty_automation
receipt_automation.status = observatory.receipt_automation_status
observatory._stored_receipts = lambda _root: []
semantic_receipts._stored_receipts = observatory._stored_receipts
observatory._stored_value_records = lambda _root: []
observatory._stored_records = observatory._stored_value_records
value_compiler._stored_records = observatory._stored_value_records

value = observatory.overview(root)
assert value["episode_formation"]["singleton_basis_points"] == 0
assert value["comparison_readiness"]["comparable_basis_points"] == 0


def unsafe_receipts(_root):
    raise VaultError("stored Semantic Receipt is invalid or unsafe")


observatory._stored_receipts = unsafe_receipts
semantic_receipts._stored_receipts = unsafe_receipts
try:
    observatory.overview(root)
except VaultError as error:
    assert "Semantic Receipt" in str(error)
else:
    raise AssertionError("invalid Semantic Receipt was counted as harmless")

observatory._stored_receipts = lambda _root: []
semantic_receipts._stored_receipts = observatory._stored_receipts


def unsafe_values(_root):
    raise VaultError("stored Value Primitive Card is invalid")


observatory._stored_value_records = unsafe_values
observatory._stored_records = unsafe_values
value_compiler._stored_records = unsafe_values
try:
    observatory.overview(root)
except VaultError as error:
    assert "Value Primitive Card" in str(error)
else:
    raise AssertionError("invalid Value Card was counted as harmless")
PY
  then
    pass "空母集団は0bpとしlocal semantic recordsのstrict失敗を隠さない"
  else
    cat "$err" >&2
    fail "空母集団は0bpとしlocal semantic recordsのstrict失敗を隠さない"
  fi
}

test_semantic_coverage_only_counts_current_visible_bindings() {
  echo "test_semantic_coverage_only_counts_current_visible_bindings:"
  local err="$TEST_ROOT/semantic-bindings.err"
  if PYTHONPATH="$PLUGIN_DIR/scripts" python3 - "$TEST_ROOT" 2>"$err" <<'PY'
import pathlib
import sqlite3
import sys

import observatory


root = pathlib.Path(sys.argv[1]) / "semantic-binding-vault"
root.mkdir()
connection = sqlite3.connect(":memory:")
connection.executescript(
    """
    PRAGMA user_version = 4;
    CREATE TABLE source_events(event_id TEXT, canonical_event_json TEXT);
    CREATE TABLE episodes(
        policy_version TEXT, episode_id TEXT, member_count INTEGER
    );
    CREATE TABLE episode_members(
        policy_version TEXT,
        episode_id TEXT,
        event_id TEXT,
        ordinal INTEGER
    );
    CREATE TABLE deterministic_evidence(
        evidence_id TEXT,
        source_event_id TEXT
    );
    CREATE TABLE session_atlas_facets(
        policy_version TEXT,
        episode_id TEXT,
        event_lifecycle_state TEXT,
        operation_state TEXT,
        artifact_change_state TEXT
    );
    """
)
connection.executemany(
    "INSERT INTO source_events VALUES (?, '{}')",
    [("event-a",), ("event-b",), ("event-forgotten",)],
)
connection.executemany(
    "INSERT INTO episodes VALUES (?, ?, ?)",
    [
        ("default-v1", "episode-current", 2),
        ("default-v1", "episode-forgotten", 1),
        ("other-v1", "episode-current", 2),
    ],
)
connection.executemany(
    "INSERT INTO episode_members VALUES (?, ?, ?, ?)",
    [
        ("default-v1", "episode-current", "event-a", 0),
        ("default-v1", "episode-current", "event-b", 1),
        ("default-v1", "episode-forgotten", "event-forgotten", 0),
        ("other-v1", "episode-current", "event-a", 0),
        ("other-v1", "episode-current", "event-b", 1),
    ],
)
connection.execute(
    "INSERT INTO deterministic_evidence VALUES (?, ?)",
    ("evidence-current", "event-a"),
)
connection.executemany(
    "INSERT INTO session_atlas_facets VALUES (?, ?, ?, ?, ?)",
    [
        ("default-v1", "episode-current", "present", "present", "present"),
        ("default-v1", "episode-forgotten", "present", "present", "present"),
        ("other-v1", "episode-current", "present", "present", "present"),
    ],
)


def receipt(receipt_id, episode_id, policy, events, evidence):
    return {
        "receipt_id": receipt_id,
        "episode_id": episode_id,
        "provenance": {
            "policy_version": policy,
            "source_event_ids": events,
            "evidence_ids": evidence,
        },
    }


def value_card(card_id, episode_id, policy, events):
    return {
        "value_primitive_card_id": card_id,
        "episode_id": episode_id,
        "provenance": {
            "policy_version": policy,
            "source_event_ids": events,
        },
    }


receipts = [
    receipt(
        "receipt-current",
        "episode-current",
        "default-v1",
        ["event-a", "event-b"],
        ["evidence-current"],
    ),
    receipt(
        "receipt-stale-events",
        "episode-current",
        "default-v1",
        ["event-a"],
        ["evidence-current"],
    ),
    receipt(
        "receipt-stale-evidence",
        "episode-current",
        "default-v1",
        ["event-a", "event-b"],
        ["evidence-no-longer-present"],
    ),
    receipt(
        "receipt-forgotten",
        "episode-forgotten",
        "default-v1",
        ["event-forgotten"],
        [],
    ),
    receipt(
        "receipt-other-policy",
        "episode-current",
        "other-v1",
        ["event-a", "event-b"],
        ["evidence-current"],
    ),
    receipt(
        "receipt-missing-episode",
        "episode-missing",
        "default-v1",
        ["event-missing"],
        [],
    ),
]
values = [
    value_card(
        "value-current",
        "episode-current",
        "default-v1",
        ["event-a", "event-b"],
    ),
    value_card(
        "value-stale-events",
        "episode-current",
        "default-v1",
        ["event-a"],
    ),
    value_card(
        "value-forgotten",
        "episode-forgotten",
        "default-v1",
        ["event-forgotten"],
    ),
    value_card(
        "value-other-policy",
        "episode-current",
        "other-v1",
        ["event-a", "event-b"],
    ),
    value_card(
        "value-missing-episode",
        "episode-missing",
        "default-v1",
        ["event-missing"],
    ),
]
strict_calls = {"receipts": 0, "values": 0}


def strict_receipts(_root):
    strict_calls["receipts"] += 1
    return [(None, b"", value) for value in receipts]


def strict_values(_root):
    strict_calls["values"] += 1
    return [(None, b"", value) for value in values]


def sealed_query(_root, version, query, trusted_policy=None):
    assert version == "default-v1"
    return query(connection, {"policy_version": version})


observatory.read_sealed_query_locked = sealed_query
observatory.load_forgotten = lambda _root: {
    ("default-v1", "episode-forgotten")
}
observatory._inbox_count = lambda _root: 0
observatory._stored_receipts = strict_receipts
observatory._stored_value_records = strict_values
observatory.receipt_automation_status = lambda _root: {
    "schema_version": 1,
    "state": "idle",
    "enabled": False,
    "discovered": 0,
    "matched": 0,
    "ambiguous": 0,
    "missing": 0,
    "active": 0,
    "queued": 0,
    "generated": 0,
    "failed": 0,
    "measured_cost_microusd": 0,
    "diagnostic_code": None,
    "attempt_count": 0,
}

result = observatory.overview(root)
assert strict_calls == {"receipts": 1, "values": 1}
assert result["episode_formation"]["episodes"] == 1
assert result["semantic_coverage"] == {
    "semantic_receipts": 1,
    "value_cards": 1,
}
PY
  then
    pass "semantic coverageは現行default-v1の非forgotten bindingだけを数える"
  else
    cat "$err" >&2
    fail "semantic coverageは現行default-v1の非forgotten bindingだけを数える"
  fi
}

test_unbounded_local_scans_do_not_hold_global_vault_lock() {
  echo "test_unbounded_local_scans_do_not_hold_global_vault_lock:"
  local err="$TEST_ROOT/lock-scope.err"
  if PYTHONPATH="$PLUGIN_DIR/scripts" python3 - "$TEST_ROOT" 2>"$err" <<'PY'
import contextlib
import pathlib
import sqlite3
import sys

import observatory


root = pathlib.Path(sys.argv[1]) / "lock-scope-vault"
root.mkdir()
connection = sqlite3.connect(":memory:")
connection.executescript(
    """
    PRAGMA user_version = 4;
    CREATE TABLE source_events(event_id TEXT);
    CREATE TABLE episodes(
        policy_version TEXT, episode_id TEXT, member_count INTEGER
    );
    CREATE TABLE episode_members(
        policy_version TEXT, episode_id TEXT, event_id TEXT, ordinal INTEGER
    );
    CREATE TABLE deterministic_evidence(
        evidence_id TEXT, source_event_id TEXT
    );
    CREATE TABLE session_atlas_facets(
        policy_version TEXT,
        episode_id TEXT,
        event_lifecycle_state TEXT,
        operation_state TEXT,
        artifact_change_state TEXT
    );
    """
)
inside_lock = False


@contextlib.contextmanager
def tracked_lock(actual_root):
    global inside_lock
    assert actual_root == root
    assert inside_lock is False
    inside_lock = True
    try:
        yield
    finally:
        inside_lock = False


def forgotten(_root):
    assert inside_lock is True
    return set()


def sealed_query(_root, version, query, trusted_policy=None):
    assert inside_lock is True
    return query(connection, {"policy_version": version})


def unlocked_empty(_root):
    assert inside_lock is False
    return []


def unlocked_zero(_root):
    assert inside_lock is False
    return 0


def unlocked_status(_root):
    assert inside_lock is False
    return {
        "schema_version": 1,
        "state": "idle",
        "enabled": False,
        "discovered": 0,
        "matched": 0,
        "ambiguous": 0,
        "missing": 0,
        "active": 0,
        "queued": 0,
        "generated": 0,
        "failed": 0,
        "measured_cost_microusd": 0,
        "diagnostic_code": None,
        "attempt_count": 0,
    }


observatory.vault_lock = tracked_lock
observatory.load_forgotten = forgotten
observatory.read_sealed_query_locked = sealed_query
observatory._inbox_count = unlocked_zero
observatory._stored_receipts = unlocked_empty
observatory._stored_value_records = unlocked_empty
observatory.receipt_automation_status = unlocked_status
observatory.overview(root)
assert inside_lock is False
PY
  then
    pass "sealed snapshot後のunbounded local scanはglobal Vault lockを保持しない"
  else
    cat "$err" >&2
    fail "sealed snapshot後のunbounded local scanはglobal Vault lockを保持しない"
  fi
}

test_render_is_three_question_self_contained_html() {
  echo "test_render_is_three_question_self_contained_html:"
  local err="$TEST_ROOT/render.err"
  if PYTHONPATH="$PLUGIN_DIR/scripts" python3 - 2>"$err" <<'PY'
import observatory


canary = '<script src="https://evil.invalid/raw.js">RAW-CANARY</script>'
value = {
    "schema_version": 1,
    "command": "observatory.overview",
    "recording": {
        "state": "ready",
        "index_schema_version": 4,
        "events": 47342,
        "pending_events": 2088,
    },
    "episode_formation": {
        "episodes": 40098,
        "singleton_episodes": 39770,
        "singleton_basis_points": 9918,
    },
    "comparison_readiness": {
        "comparable_episodes": 225,
        "comparable_basis_points": 56,
    },
    "semantic_coverage": {
        "semantic_receipts": 19,
        "value_cards": 2,
    },
    "receipt_automation": {
        "schema_version": 1,
        "state": "attention",
        "enabled": True,
        "discovered": 671,
        "matched": 39,
        "ambiguous": 511,
        "missing": 80,
        "active": 0,
        "queued": 0,
        "generated": 19,
        "failed": 0,
        "measured_cost_microusd": 3520000,
        "diagnostic_code": None,
        "attempt_count": 19,
    },
    "raw_canary": canary,
}

html = observatory.render_overview_html(value)
lower = html.lower()
assert lower.startswith("<!doctype html>")
assert "記録できているか" in html
assert "仕事単位になっているか" in html
assert "価値比較できるか" in html
assert "47,342" in html
assert "40,098" in html
assert "99.18%" in html
assert "0.56%" in html
assert "Semantic Receipt" in html
assert "Value Card" in html
assert "attempt_count" not in html
assert "measured_cost_microusd" not in html
assert "http://" not in lower
assert "https://" not in lower
assert "<script src" not in lower
assert "<link" not in lower
assert canary not in html
assert "RAW-CANARY" not in html
assert len(html.encode("utf-8")) <= 65536
PY
  then
    pass "HTMLは自己完結し詳細counterやraw値を出さず3問へ圧縮する"
  else
    cat "$err" >&2
    fail "HTMLは自己完結し詳細counterやraw値を出さず3問へ圧縮する"
  fi
}

test_http_routes_methods_hosts_and_headers() {
  echo "test_http_routes_methods_hosts_and_headers:"
  local err="$TEST_ROOT/http.err"
  if PYTHONPATH="$PLUGIN_DIR/scripts" python3 - "$TEST_ROOT" 2>"$err" <<'PY'
import http.client
import json
import pathlib
import socketserver
import sys
import threading

import observatory


root = pathlib.Path(sys.argv[1]) / "http-vault"
root.mkdir()
canary = "RAW-SESSION-HTTP-CANARY"
expected = {
    "schema_version": 1,
    "command": "observatory.overview",
    "recording": {
        "state": "ready",
        "index_schema_version": 4,
        "events": 8,
        "pending_events": 0,
    },
    "episode_formation": {
        "episodes": 4,
        "singleton_episodes": 2,
        "singleton_basis_points": 5000,
    },
    "comparison_readiness": {
        "comparable_episodes": 1,
        "comparable_basis_points": 2500,
    },
    "semantic_coverage": {
        "semantic_receipts": 0,
        "value_cards": 0,
    },
    "receipt_automation": {
        "schema_version": 1,
        "state": "idle",
        "enabled": False,
        "discovered": 0,
        "matched": 0,
        "ambiguous": 0,
        "missing": 0,
        "active": 0,
        "queued": 0,
        "generated": 0,
        "failed": 0,
        "measured_cost_microusd": 0,
        "diagnostic_code": None,
        "attempt_count": 0,
    },
}

loader_calls = []


def loader(actual_root):
    loader_calls.append(actual_root)
    return expected


def request(method, target, host="127.0.0.1", fetch_site=None):
    server = observatory.create_server(root, 0, overview_loader=loader)
    assert server.server_address[0] == "127.0.0.1"
    assert 0 < server.server_port <= 65535
    assert not isinstance(server, socketserver.ThreadingMixIn)
    thread = threading.Thread(target=server.handle_request, daemon=True)
    thread.start()
    connection = http.client.HTTPConnection("127.0.0.1", server.server_port, timeout=2)
    connection.putrequest(method, target, skip_host=True)
    connection.putheader("Host", host.format(port=server.server_port))
    if fetch_site is not None:
        connection.putheader("Sec-Fetch-Site", fetch_site)
    connection.endheaders()
    response = connection.getresponse()
    body = response.read()
    result = (response.status, dict(response.getheaders()), body)
    connection.close()
    thread.join(timeout=2)
    assert not thread.is_alive()
    server.server_close()
    return result


before = len(loader_calls)
status, headers, body = request("GET", "/")
assert status == 200
assert len(loader_calls) == before + 1
assert headers["Content-Type"].startswith("text/html")
assert int(headers["Content-Length"]) == len(body)
assert len(body) <= 65536
assert canary.encode() not in body

status, headers, body = request("GET", "/api/v1/overview", "localhost:{port}")
assert status == 200
assert json.loads(body) == expected
assert canary.encode() not in body
assert headers["Content-Type"] == "application/json; charset=utf-8"
assert int(headers["Content-Length"]) == len(body)
assert len(body) <= 65536

status, headers, body = request("GET", "/healthz")
assert status == 200
assert json.loads(body) == {"status": "ok"}

status, headers, body = request("HEAD", "/api/v1/overview")
assert status == 200
assert body == b""
assert int(headers["Content-Length"]) > 0

for headers in (headers, request("HEAD", "/")[1], request("GET", "/")[1]):
    assert headers["Cache-Control"] == "no-store"
    assert headers["X-Content-Type-Options"] == "nosniff"
    assert headers["Referrer-Policy"] == "no-referrer"
    assert headers["X-Frame-Options"] == "DENY"
    assert "default-src 'none'" in headers["Content-Security-Policy"]
    assert "Access-Control-Allow-Origin" not in headers
    assert "Set-Cookie" not in headers

for method in ("POST", "PUT", "DELETE", "OPTIONS"):
    status, headers, _body = request(method, "/")
    assert status == 405
    assert headers["Allow"] == "GET, HEAD"

for target in ("/unknown", "/?query=forbidden", "/healthz?query=forbidden"):
    assert request("GET", target)[0] == 404

assert request("GET", "http://evil.invalid/")[0] == 400
for host in ("evil.invalid", "127.0.0.1.evil.invalid", "localhost.evil.invalid"):
    assert request("GET", "/", host)[0] == 421

before = len(loader_calls)
assert request("GET", "/", fetch_site="cross-site")[0] == 403
assert len(loader_calls) == before
PY
  then
    pass "HTTPはloopback・exact route・GET/HEAD・安全headerへ閉じる"
  else
    cat "$err" >&2
    fail "HTTPはloopback・exact route・GET/HEAD・安全headerへ閉じる"
  fi
}

test_parser_errors_and_unknown_methods_are_fixed_safe_responses() {
  echo "test_parser_errors_and_unknown_methods_are_fixed_safe_responses:"
  local err="$TEST_ROOT/http-parser.err"
  if PYTHONPATH="$PLUGIN_DIR/scripts" python3 - "$TEST_ROOT" 2>"$err" <<'PY'
import pathlib
import socket
import sys
import threading

import observatory


root = pathlib.Path(sys.argv[1]) / "parser-vault"
root.mkdir()


def raw_request(payload):
    server = observatory.create_server(root, 0, overview_loader=lambda _root: {})
    thread = threading.Thread(target=server.handle_request, daemon=True)
    thread.start()
    client = socket.create_connection(("127.0.0.1", server.server_port), timeout=2)
    client.sendall(payload)
    client.shutdown(socket.SHUT_WR)
    response = bytearray()
    while True:
        part = client.recv(65536)
        if not part:
            break
        response.extend(part)
    client.close()
    thread.join(timeout=2)
    assert not thread.is_alive()
    server.server_close()
    head, separator, body = bytes(response).partition(b"\r\n\r\n")
    assert separator == b"\r\n\r\n"
    lines = head.decode("ascii").split("\r\n")
    headers = {}
    for line in lines[1:]:
        name, value = line.split(":", 1)
        headers[name] = value.strip()
    return lines[0], headers, body, bytes(response)


def assert_safe(headers, body):
    assert headers["Content-Type"] == "text/plain; charset=utf-8"
    assert headers["Cache-Control"] == "no-store"
    assert headers["X-Content-Type-Options"] == "nosniff"
    assert headers["Referrer-Policy"] == "no-referrer"
    assert headers["X-Frame-Options"] == "DENY"
    assert "default-src 'none'" in headers["Content-Security-Policy"]
    assert "Access-Control-Allow-Origin" not in headers
    assert "Set-Cookie" not in headers
    assert int(headers["Content-Length"]) == len(body)


parser_canary = b"RAW-PARSER-TARGET-CANARY"
status, headers, body, response = raw_request(
    b"GET /" + parser_canary + b" HTTP/1.1 EXTRA\r\n"
    b"Host: 127.0.0.1\r\n\r\n"
)
assert status == "HTTP/1.1 400 Bad Request"
assert body == b"Bad Request\n"
assert_safe(headers, body)
assert parser_canary not in response
assert b"EXTRA" not in response

method_canary = b"BREW"
target_canary = b"RAW-METHOD-TARGET-CANARY"
status, headers, body, response = raw_request(
    method_canary + b" /" + target_canary + b" HTTP/1.1\r\n"
    b"Host: 127.0.0.1\r\n\r\n"
)
assert status == "HTTP/1.1 405 Method Not Allowed"
assert headers["Allow"] == "GET, HEAD"
assert body == b"Method Not Allowed\n"
assert_safe(headers, body)
assert method_canary not in response
assert target_canary not in response
PY
  then
    pass "parser errorと未知methodも固定plain body・安全headersで非反射にする"
  else
    cat "$err" >&2
    fail "parser errorと未知methodも固定plain body・安全headersで非反射にする"
  fi
}

test_port_validation_and_graceful_shutdown() {
  echo "test_port_validation_and_graceful_shutdown:"
  local err="$TEST_ROOT/server.err"
  if PYTHONPATH="$PLUGIN_DIR/scripts" python3 - "$TEST_ROOT" 2>"$err" <<'PY'
import pathlib
import sys

import observatory
from vault import VaultError


root = pathlib.Path(sys.argv[1]) / "server-vault"
root.mkdir()

for invalid in (-1, 65536, True, "8080"):
    try:
        observatory.create_server(root, invalid, overview_loader=lambda _root: {})
    except (TypeError, ValueError, VaultError):
        pass
    else:
        raise AssertionError(f"invalid port accepted: {invalid!r}")

server = observatory.create_server(root, 0, overview_loader=lambda _root: {})
assert server.server_address[0] == "127.0.0.1"
assert server.server_port != 0
server.server_close()


class InterruptedServer:
    server_address = ("127.0.0.1", 43210)

    def __init__(self):
        self.closed = False
        self.started = False

    def serve_forever(self):
        self.started = True
        raise KeyboardInterrupt

    def server_close(self):
        self.closed = True


interrupted = InterruptedServer()
original = observatory.create_server
observatory.create_server = lambda actual_root, port: interrupted
try:
    observatory.serve(root, 0)
finally:
    observatory.create_server = original
assert interrupted.started is True
assert interrupted.closed is True
PY
  then
    pass "port 0を許可し範囲外を拒否してKeyboardInterruptでsocketを閉じる"
  else
    cat "$err" >&2
    fail "port 0を許可し範囲外を拒否してKeyboardInterruptでsocketを閉じる"
  fi
}

test_local_scan_limits_fail_before_strict_readers() {
  echo "test_local_scan_limits_fail_before_strict_readers:"
  local err="$TEST_ROOT/scan-limits.err"
  if PYTHONPATH="$PLUGIN_DIR/scripts" python3 - "$TEST_ROOT" 2>"$err" <<'PY'
import pathlib
import sys

import observatory
from vault import VaultError


root = pathlib.Path(sys.argv[1]) / "scan-limit-vault"
root.mkdir()
store = root / "semantic-receipts"
store.mkdir()
(store / "one.json").write_bytes(b"xx")
reader_calls = 0


def reader(_root):
    global reader_calls
    reader_calls += 1
    return []


original_records = observatory.MAX_LOCAL_RECORDS
original_bytes = observatory.MAX_LOCAL_RECORD_BYTES
original_inbox = observatory.MAX_INBOX_BYTES
try:
    observatory.MAX_LOCAL_RECORDS = 0
    try:
        observatory._bounded_local_records(
            root, "semantic-receipts", reader, "Semantic Receipt"
        )
    except VaultError:
        pass
    else:
        raise AssertionError("record-count limit was ignored")
    assert reader_calls == 0

    observatory.MAX_LOCAL_RECORDS = original_records
    observatory.MAX_LOCAL_RECORD_BYTES = 1
    try:
        observatory._bounded_local_records(
            root, "semantic-receipts", reader, "Semantic Receipt"
        )
    except VaultError:
        pass
    else:
        raise AssertionError("record-byte limit was ignored")
    assert reader_calls == 0

    inbox = root / "inbox"
    inbox.mkdir()
    (inbox / "events.jsonl").write_bytes(b"xx")
    observatory.MAX_INBOX_BYTES = 1
    inbox_calls = 0

    def inbox_reader(_root):
        global inbox_calls
        inbox_calls += 1
        return 0

    observatory._inbox_count = inbox_reader
    try:
        observatory._bounded_inbox_count(root)
    except VaultError:
        pass
    else:
        raise AssertionError("inbox-byte limit was ignored")
    assert inbox_calls == 0
finally:
    observatory.MAX_LOCAL_RECORDS = original_records
    observatory.MAX_LOCAL_RECORD_BYTES = original_bytes
    observatory.MAX_INBOX_BYTES = original_inbox
PY
  then
    pass "local scan上限超過はstrict readerを呼ぶ前にfail closedする"
  else
    cat "$err" >&2
    fail "local scan上限超過はstrict readerを呼ぶ前にfail closedする"
  fi
}

test_json_startup_is_canonical_and_machine_readable() {
  echo "test_json_startup_is_canonical_and_machine_readable:"
  local err="$TEST_ROOT/json-startup.err"
  if PYTHONPATH="$PLUGIN_DIR/scripts" python3 - "$TEST_ROOT" 2>"$err" <<'PY'
import contextlib
import io
import pathlib
import sys

import observatory
from chunk_rotation import canonical_json


root = pathlib.Path(sys.argv[1]) / "json-startup-vault"
root.mkdir()


class InterruptedServer:
    server_address = ("127.0.0.1", 43210)

    def serve_forever(self):
        raise KeyboardInterrupt

    def server_close(self):
        return


server = InterruptedServer()
original_create = observatory.create_server
observatory.create_server = lambda actual_root, port: server
output = io.StringIO()
try:
    with contextlib.redirect_stdout(output):
        observatory.serve(root, 0, startup_as_json=True)
finally:
    observatory.create_server = original_create

expected = {
    "schema_version": 1,
    "command": "observatory.serve",
    "url": "http://127.0.0.1:43210/",
}
assert output.getvalue() == canonical_json(expected).decode("utf-8") + "\n"
PY
  then
    pass "observe --json startupはcanonical JSON 1行だけを出す"
  else
    cat "$err" >&2
    fail "observe --json startupはcanonical JSON 1行だけを出す"
  fi
}

test_cli_parser_and_dispatch_are_fixed() {
  echo "test_cli_parser_and_dispatch_are_fixed:"
  local err="$TEST_ROOT/cli.err"
  if PYTHONPATH="$PLUGIN_DIR/scripts" python3 - "$TEST_ROOT" 2>"$err" <<'PY'
import contextlib
import io
import pathlib
import sys
import types

import vault


root = pathlib.Path(sys.argv[1]) / "cli-vault"
root.mkdir()
parser = vault.parser()
args = parser.parse_args(["observe", "--port", "0", "--json"])
assert args.command == "observe"
assert args.port == 0
assert args.json is True
args = parser.parse_args(["observe", "--port", "65535"])
assert args.port == 65535
assert args.json is False

for argv in (
    ["observe"],
    ["observe", "--port", "-1"],
    ["observe", "--port", "65536"],
    ["observe", "--port", "not-a-port"],
    ["observe", "--port", "8080", "--bind", "0.0.0.0"],
    ["observe", "--port", "8080", "--host", "localhost"],
):
    with contextlib.redirect_stderr(io.StringIO()):
        try:
            parser.parse_args(argv)
        except SystemExit as error:
            assert error.code != 0
        else:
            raise AssertionError(f"invalid observe CLI accepted: {argv!r}")

calls = []
fake = types.ModuleType("observatory")
fake.serve = lambda actual_root, port, *, startup_as_json=False: calls.append(
    (actual_root, port, startup_as_json)
)
original_module = sys.modules.get("observatory")
original_argv = sys.argv
original_state_root = vault.state_root
sys.modules["observatory"] = fake
sys.argv = ["flight-recorder", "observe", "--port", "43210", "--json"]
vault.state_root = lambda: root
try:
    assert vault.main() == 0
finally:
    vault.state_root = original_state_root
    sys.argv = original_argv
    if original_module is None:
        sys.modules.pop("observatory", None)
    else:
        sys.modules["observatory"] = original_module
assert calls == [(root, 43210, True)]
PY
  then
    pass "observe CLIはport/jsonだけを受け取りserve(root, port)へ配線する"
  else
    cat "$err" >&2
    fail "observe CLIはport/jsonだけを受け取りserve(root, port)へ配線する"
  fi
}

main() {
  test_overview_is_one_sealed_fixed_projection
  test_overview_uses_strict_local_readers_and_zero_denominator
  test_semantic_coverage_only_counts_current_visible_bindings
  test_unbounded_local_scans_do_not_hold_global_vault_lock
  test_render_is_three_question_self_contained_html
  test_http_routes_methods_hosts_and_headers
  test_parser_errors_and_unknown_methods_are_fixed_safe_responses
  test_port_validation_and_graceful_shutdown
  test_local_scan_limits_fail_before_strict_readers
  test_json_startup_is_canonical_and_machine_readable
  test_cli_parser_and_dispatch_are_fixed
  echo
  echo "$PASS passed, $FAIL failed"
  [[ "$FAIL" -eq 0 ]]
}

main "$@"
