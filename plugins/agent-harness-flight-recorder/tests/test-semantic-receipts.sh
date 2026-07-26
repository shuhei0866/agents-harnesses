#!/usr/bin/env bash
# Semantic Receipt v1 happy-path contract test.
# External dependencies: git and python3. Network access is not required.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CLI="$PLUGIN_DIR/scripts/flight-recorder"
FIXTURES="$SCRIPT_DIR/fixtures"
FAKE_BIN="$FIXTURES/fake-bin"
EVALUATOR="$FAKE_BIN/flight-recorder-semantic-evaluator"
RUBRIC="$FIXTURES/semantic-receipt-rubric-v1.json"
TEST_ROOT="$(mktemp -d)" || exit 1
STATE="$TEST_ROOT/vault"
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
  PATH="$FAKE_BIN:$PATH" FLIGHT_RECORDER_STATE_DIR="$STATE" "$CLI" "$@"
}

build_fixture() {
  local remote="$TEST_ROOT/remote.git"
  local recovery="$TEST_ROOT/recovery.agekey"
  git init -q --bare "$remote"
  git -C "$remote" symbolic-ref HEAD refs/heads/main
  PATH="$FAKE_BIN:$PATH" age-keygen -o "$recovery" >/dev/null 2>&1
  run_cli init \
    --remote "$remote" \
    --recovery-recipient \
    "$(PATH="$FAKE_BIN:$PATH" age-keygen -y "$recovery")" >/dev/null 2>&1
  mkdir -p "$STATE/inbox"
  python3 - "$STATE/inbox/events.jsonl" <<'PY'
import json
import pathlib
import sys

event = {
    "schema_version": 3,
    "event_id": "73000000-0000-4000-8000-000000000001",
    "recorded_at": "2026-01-01T00:00:00Z",
    "harness": "codex",
    "source_event": "PostToolUse",
    "event_kind": "tool.completed",
    "session_id_hash": "sha256:" + "a" * 24,
    "turn_id_hash": "sha256:" + "b" * 24,
    "workspace_id": "sha256:" + "c" * 24,
    "model": "fixture-worker-model",
    "permission_mode": None,
    "tool": "Bash",
    "metrics": {"duration_ms": 1250, "retry_count": 0},
    "outcome": {"status": "success", "exit_code": 0},
    "relationship_context": {
        "task_id_hash": "sha256:" + "d" * 24,
        "task_source": "payload",
        "branch_or_worktree_id": "sha256:" + "e" * 24,
        "changed_file_fingerprints": ["sha256:" + "1" * 24],
        "changed_files_state": "complete",
    },
    "operation_kind": "test",
}
pathlib.Path(sys.argv[1]).write_text(
    json.dumps(event, sort_keys=True, separators=(",", ":")) + "\n",
    encoding="utf-8",
)
PY
  run_cli sync >/dev/null 2>&1
  run_cli rebuild-index >/dev/null 2>&1
}

episode_id() {
  python3 - "$STATE/index/vault.sqlite" <<'PY'
import sqlite3
import sys

connection = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
row = connection.execute(
    "SELECT episode_id FROM episode_members "
    "WHERE policy_version = 'default-v1' AND event_id = ?",
    ("73000000-0000-4000-8000-000000000001",),
).fetchone()
assert row is not None
print(row[0])
PY
}

test_generates_complete_semantic_receipt_v1() {
  echo "test_generates_complete_semantic_receipt_v1:"
  local raw="$TEST_ROOT/codex-session.jsonl"
  local register="$TEST_ROOT/register.json"
  local capture="$TEST_ROOT/evaluator-input.json"
  local output="$TEST_ROOT/receipt.json"
  local repeat="$TEST_ROOT/receipt-repeat.json"
  local version_b="$TEST_ROOT/receipt-version-b.json"
  local inspect_json="$TEST_ROOT/receipt-inspect.json"
  local inspect_human="$TEST_ROOT/receipt-inspect.txt"
  local purge_preview="$TEST_ROOT/receipt-purge-preview.json"
  local err="$TEST_ROOT/receipt.err"
  local source_ref episode

  # Keep the Red failure attributable to the missing receipt command even
  # before source registration is implemented.
  if ! run_cli receipt --help >/dev/null 2>"$err"; then
    cat "$err" >&2
    fail "receipt generate CLI is available"
    return
  fi

  cp "$FIXTURES/codex-session.jsonl" "$raw"
  if ! run_cli source register \
    --adapter codex --path "$raw" --json >"$register" 2>"$err"; then
    cat "$err" >&2
    fail "codex source can be registered for receipt generation"
    return
  fi
  source_ref="$(
    python3 - "$register" <<'PY'
import json
import pathlib
import sys
print(json.loads(pathlib.Path(sys.argv[1]).read_text())["source_ref"])
PY
  )"
  episode="$(episode_id)"

  if FLIGHT_RECORDER_NOW="2026-01-02T03:04:05Z" \
    FLIGHT_RECORDER_TEST_SEMANTIC_CAPTURE="$capture" \
    run_cli receipt generate "$episode" \
      --source-ref "$source_ref" \
      --span-start-line 2 \
      --span-end-line 2 \
      --evaluator flight-recorder-semantic-evaluator \
      --model semantic-evaluator-model-a \
      --rubric "$RUBRIC" \
      --json >"$output" 2>"$err" \
    && FLIGHT_RECORDER_NOW="2026-01-02T03:04:05Z" \
      run_cli receipt generate "$episode" \
        --source-ref "$source_ref" \
        --span-start-line 2 \
        --span-end-line 2 \
        --evaluator flight-recorder-semantic-evaluator \
        --model semantic-evaluator-model-a \
        --rubric "$RUBRIC" \
        --json >"$repeat" 2>>"$err" \
    && FLIGHT_RECORDER_NOW="2026-01-02T03:04:06Z" \
      run_cli receipt generate "$episode" \
        --source-ref "$source_ref" \
        --span-start-line 2 \
        --span-end-line 2 \
        --evaluator flight-recorder-semantic-evaluator \
        --model semantic-evaluator-model-b \
        --rubric "$RUBRIC" \
        --json >"$version_b" 2>>"$err" \
    && run_cli inspect "$episode" --json >"$inspect_json" 2>>"$err" \
    && run_cli inspect "$episode" >"$inspect_human" 2>>"$err" \
    && run_cli purge "$episode" --json >"$purge_preview" 2>>"$err" \
    && python3 - \
      "$output" "$repeat" "$version_b" "$inspect_json" "$inspect_human" \
      "$purge_preview" "$capture" "$raw" "$EVALUATOR" "$episode" "$STATE" <<'PY'
import datetime as dt
import hashlib
import json
import pathlib
import re
import sys

(
    output,
    repeat,
    version_b,
    inspect_json,
    inspect_human,
    purge_preview,
    capture,
    raw_path,
    evaluator_path,
    episode_id,
    state_path,
) = sys.argv[1:]
value = json.loads(pathlib.Path(output).read_text(encoding="utf-8"))
repeat_value = json.loads(pathlib.Path(repeat).read_text(encoding="utf-8"))
version_b_value = json.loads(pathlib.Path(version_b).read_text(encoding="utf-8"))
inspect_value = json.loads(pathlib.Path(inspect_json).read_text(encoding="utf-8"))
inspect_text = pathlib.Path(inspect_human).read_text(encoding="utf-8")
purge_value = json.loads(pathlib.Path(purge_preview).read_text(encoding="utf-8"))
request = json.loads(pathlib.Path(capture).read_text(encoding="utf-8"))
receipt = value["receipt"]

assert repeat_value == value
assert version_b_value["receipt"]["receipt_id"] != receipt["receipt_id"]
assert version_b_value["receipt"]["provenance"]["evaluator_model"] == (
    "semantic-evaluator-model-b"
)
assert value["schema_version"] == 1
assert value["command"] == "receipt generate"
assert set(receipt) == {
    "schema_version", "receipt_id", "episode_id", "task", "execution",
    "result", "assessment", "provenance",
}
assert receipt["schema_version"] == 1
assert receipt["episode_id"] == episode_id
assert re.fullmatch(r"sha256:[0-9a-f]{64}", receipt["receipt_id"])
assert receipt["task"]["difficulty"] == "medium"
assert receipt["result"]["outcome"] == "success"
assert receipt["assessment"]["confidence"] == "high"

provenance = receipt["provenance"]
assert provenance["evaluator_model"] == "semantic-evaluator-model-a"
assert provenance["evaluator_adapter_sha256"] == (
    "sha256:" + hashlib.sha256(pathlib.Path(evaluator_path).read_bytes()).hexdigest()
)
assert provenance["rubric_version"] == "semantic-receipt-v1"
assert provenance["source_event_ids"] == [
    "73000000-0000-4000-8000-000000000001"
]
assert provenance["evidence_ids"]
assert len(provenance["source_spans"]) == 1
span = provenance["source_spans"][0]
raw = pathlib.Path(raw_path).read_bytes()
selected = raw.splitlines(keepends=True)[1]
assert span["content_sha256"] == "sha256:" + hashlib.sha256(raw).hexdigest()
assert span["span_sha256"] == "sha256:" + hashlib.sha256(selected).hexdigest()
assert span["start_line"] == 2 and span["end_line"] == 2
assert provenance["generated_at"] == "2026-01-02T03:04:05Z"
dt.datetime.fromisoformat(provenance["generated_at"].replace("Z", "+00:00"))

evaluator_input = json.dumps(request, sort_keys=True)
assert "CODEX_SELECTED_SPAN_CANARY" in evaluator_input
assert "CODEX_OUTSIDE_AFTER_CANARY" not in evaluator_input
assert raw_path not in evaluator_input
# The fake evaluator returns no provenance; the Recorder must create it.
assert "provenance" not in request.get("expected_output", {})

stored = list((pathlib.Path(state_path) / "semantic-receipts").glob("*.json"))
assert len(stored) == 2
stored_values = [
    json.loads(path.read_text(encoding="utf-8")) for path in stored
]
assert receipt in stored_values
serialized_receipt = json.dumps(stored_values, sort_keys=True)
assert raw_path not in serialized_receipt
assert "CODEX_SELECTED_SPAN_CANARY" not in serialized_receipt
assert "CODEX_OUTSIDE_AFTER_CANARY" not in serialized_receipt

assert inspect_value["schema_version"] == 4
assert inspect_value["card"]["task_type"] is None
assert len(inspect_value["semantic_receipts"]) == 2
assert {
    item["provenance"]["evaluator_model"]
    for item in inspect_value["semantic_receipts"]
} == {"semantic-evaluator-model-a", "semantic-evaluator-model-b"}
assert "Model-derived semantic receipts:" in inspect_text
assert "Diagnose and correct a generic failing test." in inspect_text
assert "outcome=success" in inspect_text
assert "confidence=high" in inspect_text
assert purge_value["apply"] is False
assert purge_value["semantic_receipt_record_count"] == 2
PY
  then
    pass "選択spanからcontent-addressedなSemantic Receipt v1を生成する"
  else
    cat "$err" >&2
    fail "選択spanからcontent-addressedなSemantic Receipt v1を生成する"
  fi
}

test_rejects_changed_registered_source() {
  echo "test_rejects_changed_registered_source:"
  local raw="$TEST_ROOT/mutable-codex-session.jsonl"
  local register="$TEST_ROOT/mutable-register.json"
  local output="$TEST_ROOT/mutable-receipt.json"
  local err="$TEST_ROOT/mutable-receipt.err"
  local source_ref episode

  cp "$FIXTURES/codex-session.jsonl" "$raw"
  run_cli source register \
    --adapter codex --path "$raw" --json >"$register" 2>"$err"
  source_ref="$(
    python3 - "$register" <<'PY'
import json
import pathlib
import sys
print(json.loads(pathlib.Path(sys.argv[1]).read_text())["source_ref"])
PY
  )"
  episode="$(episode_id)"
  python3 - "$raw" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
path.write_bytes(path.read_bytes() + b'{"changed":true}\n')
PY

  if run_cli receipt generate "$episode" \
    --source-ref "$source_ref" \
    --span-start-line 2 \
    --span-end-line 2 \
    --evaluator flight-recorder-semantic-evaluator \
    --model semantic-evaluator-model-a \
    --rubric "$RUBRIC" \
    --json >"$output" 2>"$err"; then
    fail "登録後に変更されたsourceを拒否する"
  elif grep -q "registered session source changed" "$err"; then
    pass "登録後に変更されたsourceを拒否する"
  else
    cat "$err" >&2
    fail "変更sourceの拒否理由が安定している"
  fi
}

test_rejects_tampered_semantic_receipt() {
  echo "test_rejects_tampered_semantic_receipt:"
  local episode receipt backup="$TEST_ROOT/receipt-backup.json"
  local output="$TEST_ROOT/tampered-inspect.json"
  local err="$TEST_ROOT/tampered-inspect.err"
  episode="$(episode_id)"
  receipt="$(find "$STATE/semantic-receipts" -type f -name '*.json' | head -n 1)"
  cp "$receipt" "$backup"
  python3 - "$receipt" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
value = json.loads(path.read_text(encoding="utf-8"))
value["result"]["summary"] = "tampered"
path.write_text(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n")
PY

  if run_cli inspect "$episode" --json >"$output" 2>"$err"; then
    fail "改ざんSemantic Receiptを拒否する"
  elif [[ -s "$output" ]] || grep -q "Traceback" "$err"; then
    fail "改ざんReceiptをcontent-freeかつcleanに拒否する"
  elif grep -q "stored Semantic Receipt ID is invalid" "$err"; then
    pass "改ざんSemantic Receiptをfail closedで拒否する"
  else
    cat "$err" >&2
    fail "改ざんReceiptの拒否理由が安定している"
  fi
  cp "$backup" "$receipt"
}

test_purge_removes_semantic_receipts() {
  echo "test_purge_removes_semantic_receipts:"
  local episode
  local err="$TEST_ROOT/receipt-purge-apply.err"
  episode="$(episode_id)"

  if run_cli purge "$episode" --apply --json >/dev/null 2>"$err" \
    && python3 - "$STATE" <<'PY'
import pathlib
import sys

directory = pathlib.Path(sys.argv[1]) / "semantic-receipts"
assert list(directory.glob("*.json")) == []
PY
  then
    pass "purge applyで対象Semantic Receiptを削除する"
  else
    cat "$err" >&2
    fail "purge applyで対象Semantic Receiptを削除する"
  fi
}

echo "=== Flight Recorder Semantic Receipt Tests ==="
if ! build_fixture; then
  echo "fixture setup failed" >&2
  exit 1
fi
test_generates_complete_semantic_receipt_v1
test_rejects_tampered_semantic_receipt
test_rejects_changed_registered_source
test_purge_removes_semantic_receipts

echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
