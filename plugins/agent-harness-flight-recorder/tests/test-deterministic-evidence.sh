#!/usr/bin/env bash
# Privacy-safe deterministic evidence collection and aggregation contracts.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RECORDER="$PLUGIN_DIR/scripts/record-event"
CLI="$PLUGIN_DIR/scripts/flight-recorder"
FAKE_BIN="$SCRIPT_DIR/fixtures/fake-bin"
TEST_ROOT="$(mktemp -d)"
PASS=0
FAIL=0

cleanup() {
  rm -rf "$TEST_ROOT"
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

run_cli() {
  PATH="$FAKE_BIN:$PATH" FLIGHT_RECORDER_STATE_DIR="$1" \
    "$CLI" "${@:2}"
}

make_identity() {
  PATH="$FAKE_BIN:$PATH" age-keygen -o "$1" >/dev/null 2>&1
}

recipient_of() {
  PATH="$FAKE_BIN:$PATH" age-keygen -y "$1"
}

test_recorder_classifies_only_allowlisted_facts() {
  echo "test_recorder_classifies_only_allowlisted_facts:"
  local input="$TEST_ROOT/classifier-input.jsonl"
  local output="$TEST_ROOT/classifier-events.jsonl"
  python3 - "$input" <<'PY'
import json
import pathlib
import sys

canary = "PRIVATE_CANARY_iam115"
payloads = [
    {
        "hook_event_name": "PostToolUse",
        "tool_name": "Bash",
        "tool_input": {"command": f"pytest -q {canary}"},
        "tool_response": {"success": True, "exit_code": 0, "output": canary},
    },
    {
        "hook_event_name": "PostToolUse",
        "tool_name": "Bash",
        "tool_input": {"command": f"npm run build -- {canary}"},
        "tool_response": {"success": False, "exit_code": 2, "output": canary},
    },
    {
        "hook_event_name": "PostToolUse",
        "tool_name": "Bash",
        "tool_input": {"command": f"ruff check {canary}"},
        "tool_response": {"output": canary},
    },
    {
        "hook_event_name": "PostToolUse",
        "tool_name": "Bash",
        "tool_input": {"command": f"git commit -m {canary}"},
        "tool_response": {"success": True},
    },
    {
        "hook_event_name": "PostToolUse",
        "tool_name": "Bash",
        "tool_input": {"command": f"gh pr create --title {canary}"},
        "tool_response": {"success": True},
    },
    {
        "hook_event_name": "PostToolUse",
        "tool_name": "mcp__github__create_pull_request",
        "tool_input": {"body": canary},
        "tool_response": {"success": True, "url": canary},
    },
    {
        "hook_event_name": "PostToolUse",
        "tool_name": "Bash",
        "tool_input": {"command": "pytest -h"},
        "tool_response": {"success": True},
    },
    {
        "hook_event_name": "PostToolUse",
        "tool_name": "Bash",
        "tool_input": {"command": f"printf {canary} && pytest"},
        "tool_response": {"success": True},
    },
]
pathlib.Path(sys.argv[1]).write_text(
    "\n".join(json.dumps(item) for item in payloads) + "\n",
    encoding="utf-8",
)
PY
  while IFS= read -r payload; do
    AGENT_FLIGHT_RECORDER_PATH="$output" \
      AGENT_FLIGHT_RECORDER_HASH_KEY="iam115-classifier-key" \
      AGENT_FLIGHT_RECORDER_NOW="2026-07-25T11:00:00Z" \
      "$RECORDER" --harness claude-code <<<"$payload" >/dev/null 2>&1
  done <"$input"

  if python3 - "$output" <<'PY' 2>/dev/null
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
assert "PRIVATE_CANARY_iam115" not in text
events = [json.loads(line) for line in text.splitlines()]
assert len(events) == 8
assert {event["schema_version"] for event in events} == {3}
assert [event["operation_kind"] for event in events] == [
    "test", "build", "lint", "git_commit", "pull_request", "pull_request", None, None
]
assert events[0]["outcome"] == {"status": "success", "exit_code": 0}
assert events[1]["outcome"] == {"status": "failure", "exit_code": 2}
assert events[2]["outcome"] is None
assert events[3]["outcome"] == {"status": "success"}
assert events[4]["outcome"] == {"status": "success"}
assert events[5]["outcome"] == {"status": "success"}
assert events[6]["outcome"] == {"status": "success"}
assert events[7]["outcome"] == {"status": "success"}
assert all("tool_input" not in event and "tool_response" not in event for event in events)
PY
  then
    pass "raw command/outputを捨てallowlisted operationとoutcomeだけをEvent v3へ残す"
  else
    fail "raw command/outputを捨てallowlisted operationとoutcomeだけをEvent v3へ残す"
  fi
}

build_vault_fixture() {
  local state="$1"
  local remote="$2"
  local recovery="$3"
  git init -q --bare "$remote"
  git -C "$remote" symbolic-ref HEAD refs/heads/main
  make_identity "$recovery"
  run_cli "$state" init \
    --remote "$remote" \
    --recovery-recipient "$(recipient_of "$recovery")" >/dev/null 2>&1
  mkdir -p "$state/inbox"
  python3 - "$state/inbox/events.jsonl" <<'PY'
import datetime as dt
import json
import pathlib
import sys

task = "sha256:" + "1" * 24
workspace = "sha256:" + "2" * 24
branch = "sha256:" + "3" * 24


def event(event_id, recorded_at, operation, metrics, outcome):
    return {
        "schema_version": 3,
        "event_id": event_id,
        "recorded_at": recorded_at,
        "harness": "codex",
        "source_event": "PostToolUse",
        "event_kind": "tool.completed",
        "session_id_hash": "sha256:" + "4" * 24,
        "turn_id_hash": None,
        "workspace_id": workspace,
        "model": "test-model",
        "permission_mode": None,
        "tool": "Bash",
        "metrics": metrics,
        "outcome": outcome,
        "relationship_context": {
            "task_id_hash": task,
            "task_source": "payload",
            "branch_or_worktree_id": branch,
            "changed_file_fingerprints": ["sha256:" + "5" * 24],
            "changed_files_state": "complete",
        },
        "operation_kind": operation,
    }


now = dt.datetime.now(dt.timezone.utc).replace(microsecond=0)


def timestamp(seconds):
    return (now - dt.timedelta(seconds=seconds)).isoformat().replace("+00:00", "Z")


events = [
    event(
        "40000000-0000-4000-8000-000000000001",
        timestamp(20),
        "test",
        {
            "duration_ms": 1200,
            "input_tokens": 10,
            "output_tokens": 4,
            "total_cost_usd": 0.01,
            "retry_count": 1,
        },
        {"status": "success", "exit_code": 0},
    ),
    event(
        "40000000-0000-4000-8000-000000000002",
        timestamp(10),
        "build",
        {"duration_ms": 200},
        {"status": "failure", "exit_code": 2},
    ),
    event(
        "40000000-0000-4000-8000-000000000003",
        timestamp(0),
        "lint",
        None,
        None,
    ),
]
pathlib.Path(sys.argv[1]).write_text(
    "".join(
        json.dumps(item, sort_keys=True, separators=(",", ":")) + "\n"
        for item in events
    ),
    encoding="utf-8",
)
PY
  run_cli "$state" sync >/dev/null 2>&1
  run_cli "$state" rebuild-index >/dev/null 2>&1
}

episode_id() {
  python3 - "$1/index/vault.sqlite" <<'PY'
import sqlite3
import sys

connection = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
value = connection.execute(
    "SELECT episode_id FROM episode_members "
    "WHERE policy_version = 'default-v1' ORDER BY episode_id LIMIT 1"
).fetchone()
assert value is not None
print(value[0])
PY
}

test_index_aggregates_provenance_idempotently() {
  echo "test_index_aggregates_provenance_idempotently:"
  local state="$TEST_ROOT/vault"
  local remote="$TEST_ROOT/remote.git"
  local recovery="$TEST_ROOT/recovery.agekey"
  local before="$TEST_ROOT/evidence-before.json"
  local after="$TEST_ROOT/evidence-after.json"
  build_vault_fixture "$state" "$remote" "$recovery"

  python3 - "$state/index/vault.sqlite" "$before" <<'PY'
import json
import pathlib
import sqlite3
import sys

connection = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
assert connection.execute("PRAGMA user_version").fetchone()[0] == 4
metadata = dict(connection.execute("SELECT key, value FROM schema_metadata"))
assert metadata["event_schema_versions"] == "1,2,3"
rows = list(connection.execute(
    "SELECT evidence_id, source_event_id, collector_version, collected_at, "
    "evidence_type, state, value_json "
    "FROM deterministic_evidence ORDER BY evidence_id"
))
assert len(rows) == 11, rows
assert len({row[0] for row in rows}) == len(rows)
assert all(row[0].startswith("sha256:") and len(row[0]) == 71 for row in rows)
assert {row[2] for row in rows} == {"deterministic-v1"}
assert {row[1] for row in rows} == {
    "40000000-0000-4000-8000-000000000001",
    "40000000-0000-4000-8000-000000000002",
    "40000000-0000-4000-8000-000000000003",
}
states = {(row[4], row[5]) for row in rows}
assert ("test", "success") in states
assert ("build", "failure") in states
assert ("lint", "missing") in states
assert ("retry_count", "present") in states
assert ("total_cost_usd", "present") in states
pathlib.Path(sys.argv[2]).write_text(json.dumps(rows), encoding="utf-8")
PY
  run_cli "$state" rebuild-index --incremental >/dev/null 2>&1
  run_cli "$state" rebuild-index --incremental >/dev/null 2>&1
  python3 - "$state/index/vault.sqlite" "$after" <<'PY'
import json
import pathlib
import sqlite3
import sys

connection = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
rows = list(connection.execute(
    "SELECT evidence_id, source_event_id, collector_version, collected_at, "
    "evidence_type, state, value_json "
    "FROM deterministic_evidence ORDER BY evidence_id"
))
pathlib.Path(sys.argv[2]).write_text(json.dumps(rows), encoding="utf-8")
PY
  if cmp -s "$before" "$after"; then
    pass "同じsourceからの再集約がstable evidence IDでidempotentになる"
  else
    fail "同じsourceからの再集約がstable evidence IDでidempotentになる"
  fi
}

test_evidence_card_traces_facts_and_rejects_tamper() {
  echo "test_evidence_card_traces_facts_and_rejects_tamper:"
  local state="$TEST_ROOT/vault"
  local episode report inspect
  episode="$(episode_id "$state")"
  report="$TEST_ROOT/report.json"
  inspect="$TEST_ROOT/inspect.json"
  if run_cli "$state" report --last 1w --json >"$report" \
    && run_cli "$state" inspect "$episode" --json >"$inspect" \
    && python3 - "$report" "$inspect" <<'PY'
import json
import pathlib
import sys

report = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
inspect = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
assert report["schema_version"] == 4
card = inspect["card"]
assert card["schema_version"] == 3
facts = card["deterministic_evidence"]
assert len(facts) == 11, facts
assert all(set(fact) == {
    "evidence_id", "source_event_id", "collector_version", "collected_at",
    "evidence_type", "state", "value",
} for fact in facts)
assert {fact["evidence_type"] for fact in facts} >= {
    "test", "build", "lint", "duration_ms", "input_tokens",
    "output_tokens", "total_cost_usd", "retry_count", "exit_status",
}
assert {fact["source_event_id"] for fact in facts}.issubset(
    set(card["source_event_ids"])
)
assert card["retry_count"] == {
    "value": 1,
    "state": "partial",
    "aggregation": "sum_of_recorded_values",
    "known_event_count": 1,
    "total_event_count": 3,
}
assert card["deterministic_outcomes"]["success"] == 1
assert card["deterministic_outcomes"]["failure"] == 1
assert card["deterministic_outcomes"]["not_recorded"] == 1
assert report["cards"][0]["deterministic_evidence"] == facts
PY
  then
    pass "Evidence Cardからcollector provenance・source event・evidence IDを辿れる"
  else
    fail "Evidence Cardからcollector provenance・source event・evidence IDを辿れる"
  fi

  python3 - "$state/index/vault.sqlite" <<'PY'
import sqlite3
import sys

connection = sqlite3.connect(sys.argv[1])
connection.execute(
    "UPDATE deterministic_evidence SET state = 'missing' "
    "WHERE evidence_type = 'test'"
)
connection.commit()
PY
  if run_cli "$state" inspect "$episode" --json >/dev/null 2>&1; then
    fail "改竄されたderived evidenceをgrounded cardとして返さない"
  else
    pass "改竄されたderived evidenceをgrounded cardとして返さない"
  fi
}

echo "=== Flight Recorder Deterministic Evidence Tests ==="
test_recorder_classifies_only_allowlisted_facts
test_index_aggregates_provenance_idempotently
test_evidence_card_traces_facts_and_rejects_tamper
echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
