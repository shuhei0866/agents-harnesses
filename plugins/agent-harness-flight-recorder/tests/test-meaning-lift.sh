#!/usr/bin/env bash
# Bounded Meaning Lift pilot contract tests.
# External dependencies: git and python3. Network access is not required.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CLI="$PLUGIN_DIR/scripts/flight-recorder"
FIXTURES="$SCRIPT_DIR/fixtures"
FAKE_BIN="$FIXTURES/fake-bin"
EVALUATOR="$FAKE_BIN/flight-recorder-meaning-evaluator"
TEST_ROOT="$(mktemp -d)" || exit 1
STATE="$TEST_ROOT/vault"
PASS=0
FAIL=0

cleanup() {
  [[ -n "${TEST_ROOT:-}" && -d "$TEST_ROOT" ]] \
    && rm -rf -- "$TEST_ROOT"
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
    "event_id": "74000000-0000-4000-8000-000000000001",
    "recorded_at": "2026-07-31T00:00:00Z",
    "harness": "codex",
    "source_event": "Stop",
    "event_kind": "turn.completed",
    "session_id_hash": "sha256:" + "a" * 24,
    "turn_id_hash": "sha256:" + "b" * 24,
    "workspace_id": "sha256:" + "c" * 24,
    "model": "fixture-worker-model",
    "permission_mode": None,
    "tool": None,
    "metrics": {"duration_ms": 1500, "retry_count": 0},
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
    ("74000000-0000-4000-8000-000000000001",),
).fetchone()
assert row is not None
print(row[0])
PY
}

make_source() {
  local source="$1"
  python3 - "$source" <<'PY'
import json
import pathlib
import sys

rows = [
    {
        "type": "session_meta",
        "payload": {
            "id": "meaning-session",
            "cwd": "/Users/private/customer-project",
            "credential": "sk-test-secret-meaning-lift",
        },
    },
    {
        "type": "event_msg",
        "payload": {"turn_id": "meaning-turn", "type": "task_started"},
    },
    {
        "type": "response_item",
        "payload": {
            "role": "user",
            "type": "message",
            "content": [
                {
                    "type": "input_text",
                    "text": (
                        "MEANING_INTENT_CANARY: diagnose the bounded "
                        "failing behavior"
                    ),
                },
            ],
        },
    },
    {
        "type": "response_item",
        "payload": {
            "role": "tool",
            "type": "function_call_output",
            "content": (
                "TOOL_OUTPUT_CANARY must never enter the packet; "
                "token=sk-test-secret-meaning-lift; "
                "path=/Users/private/customer-project/private.py"
            ),
        },
    },
    {
        "type": "response_item",
        "payload": {
            "role": "assistant",
            "type": "message",
            "content": [
                {
                    "type": "output_text",
                    "text": (
                        "MEANING_RESULT_CANARY: the bounded change and "
                        "verification completed successfully"
                    ),
                },
            ],
        },
    },
    {
        "type": "event_msg",
        "payload": {"turn_id": "meaning-turn", "type": "task_complete"},
    },
]
pathlib.Path(sys.argv[1]).write_text(
    "".join(
        json.dumps(row, sort_keys=True, separators=(",", ":")) + "\n"
        for row in rows
    ),
    encoding="utf-8",
)
PY
}

generate_meaning() {
  local episode="$1" source_ref="$2" model="$3" output="$4"
  local capture="$5" counter="$6"
  FLIGHT_RECORDER_NOW="2026-07-31T01:02:03Z" \
    FLIGHT_RECORDER_TEST_MEANING_CAPTURE="$capture" \
    FLIGHT_RECORDER_TEST_MEANING_COUNT="$counter" \
    FLIGHT_RECORDER_TEST_MEANING_COST=7000 \
    run_cli meaning generate "$episode" \
      --source-ref "$source_ref" \
      --span-start-line 1 \
      --span-end-line 6 \
      --evaluator flight-recorder-meaning-evaluator \
      --model "$model" \
      --max-cost-microusd 50000 \
      --timeout 240 \
      --json >"$output"
}

test_transient_packet_is_deterministic_bounded_and_minimized() {
  echo "test_transient_packet_is_deterministic_bounded_and_minimized:"
  local raw="$TEST_ROOT/meaning-session.jsonl"
  local register="$TEST_ROOT/source-register.json"
  local capture="$TEST_ROOT/meaning-requests.jsonl"
  local counter="$TEST_ROOT/meaning-evaluator-count"
  local output_a="$TEST_ROOT/meaning-a.json"
  local output_b="$TEST_ROOT/meaning-b.json"
  local err="$TEST_ROOT/meaning-generate.err"
  local source_ref episode
  make_source "$raw"
  if ! run_cli meaning --help >/dev/null 2>"$err"; then
    cat "$err" >&2
    fail "meaning generate CLIが利用できる"
    return
  fi
  if ! run_cli source register \
    --adapter codex --path "$raw" --json >"$register" 2>"$err"; then
    cat "$err" >&2
    fail "Meaning Lift用sourceを登録できる"
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
  if generate_meaning \
      "$episode" "$source_ref" meaning-model-a "$output_a" \
      "$capture" "$counter" 2>"$err" \
    && generate_meaning \
      "$episode" "$source_ref" meaning-model-b "$output_b" \
      "$capture" "$counter" 2>>"$err" \
    && python3 - "$capture" "$raw" <<'PY'
import hashlib
import json
import pathlib
import re
import sys

capture, raw_path = map(pathlib.Path, sys.argv[1:])
requests = [
    json.loads(line)
    for line in capture.read_text(encoding="utf-8").splitlines()
    if line.strip()
]
assert len(requests) == 2
packets = [request["packet"] for request in requests]
assert packets[0] == packets[1]
packet = packets[0]
assert packet["schema_version"] == 1
assert packet["contract_version"] == "meaning-packet-v1"
assert re.fullmatch(r"sha256:[0-9a-f]{64}", packet["packet_sha256"])
canonical = json.dumps(
    {
        key: value
        for key, value in packet.items()
        if key != "packet_sha256"
    },
    sort_keys=True,
    separators=(",", ":"),
).encode()
assert packet["packet_sha256"] == (
    "sha256:" + hashlib.sha256(canonical).hexdigest()
)
assert len(json.dumps(packet, separators=(",", ":")).encode()) <= 16 * 1024
evidence = packet["evidence"]
assert 1 <= len(evidence) <= 8
assert all(
    set(item) == {"evidence_id", "kind", "content"}
    and re.fullmatch(r"sha256:[0-9a-f]{64}", item["evidence_id"])
    and len(item["content"]) <= 2048
    for item in evidence
)
serialized = json.dumps(packet, sort_keys=True)
assert "MEANING_INTENT_CANARY" in serialized
assert "MEANING_RESULT_CANARY" in serialized
assert "TOOL_OUTPUT_CANARY" not in serialized
assert "sk-test-secret-meaning-lift" not in serialized
assert "/Users/private" not in serialized
assert str(raw_path) not in serialized
PY
  then
    pass "transient packetを決定的・bounded・path/secret/tool-outputなしで作る"
  else
    cat "$err" >&2
    fail "transient packetを決定的・bounded・path/secret/tool-outputなしで作る"
  fi
}

test_compact_card_has_five_meaning_fields_and_recorder_provenance() {
  echo "test_compact_card_has_five_meaning_fields_and_recorder_provenance:"
  local output="$TEST_ROOT/meaning-a.json"
  local capture="$TEST_ROOT/meaning-requests.jsonl"
  if python3 - "$output" "$capture" "$EVALUATOR" <<'PY'
import hashlib
import json
import pathlib
import re
import sys

output, capture, evaluator = map(pathlib.Path, sys.argv[1:])
value = json.loads(output.read_text(encoding="utf-8"))
request = json.loads(capture.read_text(encoding="utf-8").splitlines()[0])
card = value["meaning_card"]
assert value["schema_version"] == 1
assert value["command"] == "meaning generate"
assert set(card) == {
    "schema_version",
    "meaning_card_id",
    "episode_id",
    "intent",
    "deliverable",
    "verification",
    "outcome",
    "reusable_learning",
    "confidence",
    "provenance",
}
assert card["schema_version"] == 1
assert re.fullmatch(r"sha256:[0-9a-f]{64}", card["meaning_card_id"])
meaning_fields = {
    "intent", "deliverable", "verification", "outcome", "reusable_learning"
}
evidence_ids = {
    item["evidence_id"] for item in request["packet"]["evidence"]
}
for name in meaning_fields:
    field = card[name]
    expected = (
        {"state", "summary", "evidence_references"}
        if name == "outcome"
        else {"summary", "evidence_references"}
    )
    assert set(field) == expected
    assert 1 <= len(field["summary"]) <= 512
    assert set(field["evidence_references"]).issubset(evidence_ids)
assert card["outcome"]["state"] in {
    "success", "failure", "mixed", "unknown"
}
assert card["confidence"] in {"low", "medium", "high"}
provenance = card["provenance"]
assert set(provenance) == {
    "contract_version",
    "packet_sha256",
    "evaluator_model",
    "evaluator_adapter",
    "evaluator_adapter_sha256",
    "policy_version",
    "source_event_ids",
    "source_span",
    "generated_at",
    "measured_cost_microusd",
    "latency_ms",
}
assert provenance["contract_version"] == "meaning-card-v1"
assert provenance["packet_sha256"] == request["packet"]["packet_sha256"]
assert provenance["evaluator_model"] == "meaning-model-a"
assert provenance["evaluator_adapter"] == evaluator.name
assert provenance["evaluator_adapter_sha256"] == (
    "sha256:" + hashlib.sha256(evaluator.read_bytes()).hexdigest()
)
assert provenance["policy_version"] == "default-v1"
assert provenance["source_event_ids"] == [
    "74000000-0000-4000-8000-000000000001"
]
assert provenance["measured_cost_microusd"] == 7000
assert isinstance(provenance["latency_ms"], int)
assert provenance["latency_ms"] >= 0
assert "provenance" not in request
PY
  then
    pass "compact Meaning Cardへ固定5意味フィールドとrecorder provenanceを持つ"
  else
    fail "compact Meaning Cardへ固定5意味フィールドとrecorder provenanceを持つ"
  fi
}

test_baseline_to_meaning_uses_same_five_question_coverage() {
  echo "test_baseline_to_meaning_uses_same_five_question_coverage:"
  local output="$TEST_ROOT/meaning-a.json"
  if python3 - "$output" <<'PY'
import json
import pathlib
import sys

value = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
baseline = value["baseline"]
comparison = value["comparison"]
questions = {
    "intent", "deliverable", "verification", "outcome", "reusable_learning"
}
assert set(baseline["answers"]) == questions
assert set(comparison["questions"]) == questions
assert set(value["meaning_card"]).issuperset(questions)
assert baseline["covered_count"] == sum(
    answer["state"] == "covered"
    for answer in baseline["answers"].values()
)
assert comparison["baseline_covered_count"] == baseline["covered_count"]
assert comparison["meaning_covered_count"] == 5
assert comparison["coverage_lift"] == (
    comparison["meaning_covered_count"]
    - comparison["baseline_covered_count"]
)
assert comparison["coverage_lift"] > 0
for question, states in comparison["questions"].items():
    assert states["baseline"] == baseline["answers"][question]["state"]
    assert states["meaning"] == "covered"
PY
  then
    pass "baselineとMeaning Cardを同一5問で比較しcoverage liftを算出する"
  else
    fail "baselineとMeaning Cardを同一5問で比較しcoverage liftを算出する"
  fi
}

test_cards_are_local_content_free_and_idempotent() {
  echo "test_cards_are_local_content_free_and_idempotent:"
  local first="$TEST_ROOT/meaning-a.json"
  local repeat="$TEST_ROOT/meaning-a-repeat.json"
  local capture="$TEST_ROOT/meaning-requests.jsonl"
  local counter="$TEST_ROOT/meaning-evaluator-count"
  local register="$TEST_ROOT/source-register.json"
  local episode source_ref
  episode="$(episode_id)"
  source_ref="$(
    python3 - "$register" <<'PY'
import json
import pathlib
import sys
print(json.loads(pathlib.Path(sys.argv[1]).read_text())["source_ref"])
PY
  )"
  if generate_meaning \
      "$episode" "$source_ref" meaning-model-a "$repeat" \
      "$capture" "$counter" 2>"$TEST_ROOT/meaning-repeat.err" \
    && [[ "$(cat "$counter")" == "2" ]] \
    && python3 - "$STATE" "$first" "$repeat" "$TEST_ROOT" <<'PY'
import json
import pathlib
import stat
import sys

root = pathlib.Path(sys.argv[1])
first = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
repeat = json.loads(pathlib.Path(sys.argv[3]).read_text(encoding="utf-8"))
private_root = sys.argv[4]
directory = root / "meaning-cards"
paths = sorted(directory.glob("*.json"))
assert len(paths) == 2
assert first["meaning_card"] == repeat["meaning_card"]
assert stat.S_IMODE(directory.stat().st_mode) == 0o700
assert all(stat.S_IMODE(path.stat().st_mode) == 0o600 for path in paths)
assert "/meaning-cards/\n" in (
    root / ".gitignore"
).read_text(encoding="utf-8")
serialized = "".join(
    path.read_text(encoding="utf-8") for path in paths
)
for forbidden in (
    private_root,
    "/Users/private",
    "sk-test-secret-meaning-lift",
    "TOOL_OUTPUT_CANARY",
    "MEANING_INTENT_CANARY",
    "MEANING_RESULT_CANARY",
):
    assert forbidden not in serialized
PY
  then
    pass "Meaning Cardをlocal-only content-freeに保存し同一生成を冪等化する"
  else
    cat "$TEST_ROOT/meaning-repeat.err" >&2
    fail "Meaning Cardをlocal-only content-freeに保存し同一生成を冪等化する"
  fi
}

echo "=== Flight Recorder Meaning Lift Tests ==="
if ! build_fixture; then
  echo "fixture setup failed" >&2
  exit 1
fi
test_transient_packet_is_deterministic_bounded_and_minimized
if [[ -f "$TEST_ROOT/meaning-a.json" && -s "$TEST_ROOT/meaning-a.json" ]]; then
  test_compact_card_has_five_meaning_fields_and_recorder_provenance
  test_baseline_to_meaning_uses_same_five_question_coverage
  test_cards_are_local_content_free_and_idempotent
fi

echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
