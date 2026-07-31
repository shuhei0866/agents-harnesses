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
    "source_event": "PostToolUse",
    "event_kind": "tool.completed",
    "session_id_hash": "sha256:" + "a" * 24,
    "turn_id_hash": "sha256:" + "b" * 24,
    "workspace_id": "sha256:" + "c" * 24,
    "model": "fixture-worker-model",
    "permission_mode": None,
    "tool": "Bash",
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
    "packet_evidence_ids",
    "evaluator_model",
    "evaluator_adapter",
    "evaluator_adapter_sha256",
    "evaluator_runtime_sha256",
    "policy_version",
    "source_event_ids",
    "source_span",
    "generated_at",
    "measured_cost_microusd",
    "latency_ms",
}
assert provenance["contract_version"] == "meaning-card-v1"
assert provenance["packet_sha256"] == request["packet"]["packet_sha256"]
assert provenance["packet_evidence_ids"] == sorted(evidence_ids)
assert provenance["evaluator_model"] == "meaning-model-a"
assert provenance["evaluator_adapter"] == evaluator.name
assert provenance["evaluator_adapter_sha256"] == (
    "sha256:" + hashlib.sha256(evaluator.read_bytes()).hexdigest()
)
assert provenance["evaluator_runtime_sha256"] == (
    provenance["evaluator_adapter_sha256"]
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
  local inspect="$TEST_ROOT/meaning-inspect.json"
  local episode
  episode="$(episode_id)"
  if run_cli inspect "$episode" --json >"$inspect" 2>/dev/null \
    && python3 - "$output" "$inspect" <<'PY'
import json
import pathlib
import sys

value = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
episode = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
card = episode["card"]
baseline = value["baseline"]
comparison = value["comparison"]
questions = {
    "intent",
    "deliverable",
    "verification_and_outcome",
    "reusable_learning",
    "time_and_api_cost",
}
assert set(baseline["answers"]) == questions
assert set(comparison["questions"]) == questions
assert baseline["score"] == sum(
    {"covered": 1.0, "partial": 0.5, "uncovered": 0.0}[
        answer["state"]
    ]
    for answer in baseline["answers"].values()
)
evidence = card["deterministic_evidence"]
evidence_ids = {item["evidence_id"] for item in evidence}
verification_ids = {
    item["evidence_id"]
    for item in evidence
    if item["evidence_type"] in {"test", "build", "lint", "typecheck"}
    and item["state"] == "success"
}
assert card["task_type"] is None
assert card["deterministic_outcomes"] == {
    "success": 1,
    "failure": 0,
    "unknown": 0,
    "not_recorded": 0,
    "evidence": card["deterministic_outcomes"]["evidence"],
}
assert baseline["answers"]["intent"] == {
    "state": "uncovered", "evidence_references": []
}
assert baseline["answers"]["deliverable"] == {
    "state": "uncovered", "evidence_references": []
}
assert baseline["answers"]["verification_and_outcome"]["state"] == "covered"
assert set(
    baseline["answers"]["verification_and_outcome"]["evidence_references"]
) == verification_ids
assert baseline["answers"]["reusable_learning"] == {
    "state": "uncovered", "evidence_references": []
}
assert baseline["answers"]["time_and_api_cost"] == {
    "state": "partial", "evidence_references": []
}
assert baseline["score"] == 1.5
assert comparison["baseline_score"] == baseline["score"]
assert comparison["meaning_score"] == 5.0
assert comparison["score_lift"] == 3.5
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

test_unknown_outcome_is_partial_not_covered() {
  echo "test_unknown_outcome_is_partial_not_covered:"
  local register="$TEST_ROOT/source-register.json"
  local capture="$TEST_ROOT/meaning-requests.jsonl"
  local counter="$TEST_ROOT/meaning-evaluator-count"
  local output="$TEST_ROOT/meaning-unknown.json"
  local episode source_ref status=0
  episode="$(episode_id)"
  source_ref="$(
    python3 - "$register" <<'PY'
import json
import pathlib
import sys
print(json.loads(pathlib.Path(sys.argv[1]).read_text())["source_ref"])
PY
  )"
  FLIGHT_RECORDER_NOW="2026-07-31T01:02:03Z" \
    FLIGHT_RECORDER_TEST_MEANING_CAPTURE="$capture" \
    FLIGHT_RECORDER_TEST_MEANING_COUNT="$counter" \
    FLIGHT_RECORDER_TEST_MEANING_COST=7000 \
    FLIGHT_RECORDER_TEST_MEANING_OUTCOME=unknown \
    run_cli meaning generate "$episode" \
      --source-ref "$source_ref" \
      --span-start-line 1 --span-end-line 6 \
      --evaluator flight-recorder-meaning-evaluator \
      --model meaning-model-unknown \
      --max-cost-microusd 50000 --timeout 240 --json \
      >"$output" 2>"$TEST_ROOT/meaning-unknown.err" || status=$?
  if [[ "$status" -eq 0 ]] \
    && python3 - "$output" <<'PY'
import json
import pathlib
import sys

value = json.loads(pathlib.Path(sys.argv[1]).read_text())
outcome = value["meaning_card"]["outcome"]
comparison = value["comparison"]
assert outcome["state"] == "unknown"
assert outcome["summary"] and outcome["evidence_references"]
assert comparison["questions"]["deliverable"]["meaning"] == "partial"
assert comparison["questions"]["verification_and_outcome"]["meaning"] == (
    "partial"
)
assert comparison["questions"]["intent"]["meaning"] == "covered"
assert comparison["questions"]["reusable_learning"]["meaning"] == "covered"
assert comparison["questions"]["time_and_api_cost"]["meaning"] == "covered"
assert comparison["meaning_score"] == 4.0
assert comparison["score_lift"] == (
    4.0 - comparison["baseline_score"]
)
PY
  then
    pass "summary+refsがあってもunknown outcomeはpartialとして数える"
  else
    cat "$TEST_ROOT/meaning-unknown.err" >&2
    fail "summary+refsがあってもunknown outcomeはpartialとして数える"
  fi
}

test_raw_packet_fragment_echo_fails_closed() {
  echo "test_raw_packet_fragment_echo_fails_closed:"
  local register="$TEST_ROOT/source-register.json"
  local output="$TEST_ROOT/meaning-fragment-echo.out"
  local error="$TEST_ROOT/meaning-fragment-echo.err"
  local episode source_ref status=0
  episode="$(episode_id)"
  source_ref="$(
    python3 - "$register" <<'PY'
import json
import pathlib
import sys
print(json.loads(pathlib.Path(sys.argv[1]).read_text())["source_ref"])
PY
  )"
  FLIGHT_RECORDER_TEST_MEANING_ECHO_FRAGMENT=1 \
    run_cli meaning generate "$episode" \
      --source-ref "$source_ref" \
      --span-start-line 1 --span-end-line 6 \
      --evaluator flight-recorder-meaning-evaluator \
      --model meaning-model-fragment-echo \
      --max-cost-microusd 50000 --timeout 240 --json \
      >"$output" 2>"$error" || status=$?
  if [[ "$status" -ne 0 && ! -s "$output" ]] \
    && ! grep -q "Traceback" "$error" \
    && ! grep -q "MEANING_INTENT_CANARY" "$error"; then
    pass "safe packet fragmentをsummaryへ丸写ししたresponseをfail closedする"
  else
    fail "safe packet fragmentをsummaryへ丸写ししたresponseをfail closedする"
  fi
}

test_bundled_meaning_evaluator_requires_240_second_outer_timeout() {
  echo "test_bundled_meaning_evaluator_requires_240_second_outer_timeout:"
  local register="$TEST_ROOT/source-register.json"
  local output="$TEST_ROOT/meaning-short-timeout.out"
  local error="$TEST_ROOT/meaning-short-timeout.err"
  local episode source_ref status=0
  episode="$(episode_id)"
  source_ref="$(
    python3 - "$register" <<'PY'
import json
import pathlib
import sys
print(json.loads(pathlib.Path(sys.argv[1]).read_text())["source_ref"])
PY
  )"
  PATH="$PLUGIN_DIR/scripts:$FAKE_BIN:$PATH" \
    FLIGHT_RECORDER_STATE_DIR="$STATE" \
    "$CLI" meaning generate "$episode" \
      --source-ref "$source_ref" \
      --span-start-line 1 --span-end-line 6 \
      --evaluator flight-recorder-claude-meaning-evaluator \
      --model claude-sonnet-fixture \
      --max-cost-microusd 50000 --timeout 239 --json \
      >"$output" 2>"$error" || status=$?
  if [[ "$status" -ne 0 && ! -s "$output" ]] \
    && grep -Fq "at least 240 seconds" "$error" \
    && ! grep -q "Traceback" "$error"; then
    pass "bundled Meaning evaluatorのouter timeoutを240秒未満にできない"
  else
    fail "bundled Meaning evaluatorのouter timeoutを240秒未満にできない"
  fi
}

test_rejects_multi_task_span_before_provider() {
  echo "test_rejects_multi_task_span_before_provider:"
  local source="$TEST_ROOT/multi-task.jsonl"
  local register="$TEST_ROOT/multi-task-register.json"
  local output="$TEST_ROOT/multi-task.out"
  local error="$TEST_ROOT/multi-task.err"
  local counter="$TEST_ROOT/meaning-evaluator-count"
  local before_count source_ref episode status=0
  before_count="$(cat "$counter")"
  python3 - "$source" <<'PY'
import json
import pathlib
import sys

rows = []
for turn in ("turn-a", "turn-b"):
    rows.extend(
        [
            {
                "type": "event_msg",
                "payload": {"turn_id": turn, "type": "task_started"},
            },
            {
                "type": "response_item",
                "payload": {
                    "role": "user",
                    "type": "message",
                    "content": [{"type": "input_text", "text": f"Do {turn}."}],
                },
            },
            {
                "type": "response_item",
                "payload": {
                    "role": "assistant",
                    "type": "message",
                    "content": [
                        {"type": "output_text", "text": f"Finished {turn}."}
                    ],
                },
            },
            {
                "type": "event_msg",
                "payload": {"turn_id": turn, "type": "task_complete"},
            },
        ]
    )
pathlib.Path(sys.argv[1]).write_text(
    "".join(
        json.dumps(row, sort_keys=True, separators=(",", ":")) + "\n"
        for row in rows
    ),
    encoding="utf-8",
)
PY
  run_cli source register \
    --adapter codex --path "$source" --json >"$register" 2>"$error"
  source_ref="$(
    python3 - "$register" <<'PY'
import json
import pathlib
import sys
print(json.loads(pathlib.Path(sys.argv[1]).read_text())["source_ref"])
PY
  )"
  episode="$(episode_id)"
  FLIGHT_RECORDER_TEST_MEANING_COUNT="$counter" \
    run_cli meaning generate "$episode" \
      --source-ref "$source_ref" \
      --span-start-line 1 --span-end-line 8 \
      --evaluator flight-recorder-meaning-evaluator \
      --model meaning-model-multi-task \
      --max-cost-microusd 50000 --timeout 240 --json \
      >"$output" 2>"$error" || status=$?
  if [[ "$status" -ne 0 && ! -s "$output" ]] \
    && [[ "$(cat "$counter")" == "$before_count" ]] \
    && grep -Fq "not one exact completed task" "$error" \
    && ! grep -q "Traceback" "$error"; then
    pass "複数taskを含むspanをprovider実行前に拒否する"
  else
    fail "複数taskを含むspanをprovider実行前に拒否する"
  fi
}

test_rehashed_tampered_card_is_rejected() {
  echo "test_rehashed_tampered_card_is_rejected:"
  local first="$TEST_ROOT/meaning-a.json"
  local register="$TEST_ROOT/source-register.json"
  local output="$TEST_ROOT/meaning-tampered.out"
  local error="$TEST_ROOT/meaning-tampered.err"
  local episode source_ref status=0
  episode="$(episode_id)"
  source_ref="$(
    python3 - "$register" <<'PY'
import json
import pathlib
import sys
print(json.loads(pathlib.Path(sys.argv[1]).read_text())["source_ref"])
PY
  )"
  python3 - "$STATE" "$first" <<'PY'
import hashlib
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
output = json.loads(pathlib.Path(sys.argv[2]).read_text())
old_id = output["meaning_card"]["meaning_card_id"].removeprefix("sha256:")
old_path = root / "meaning-cards" / f"{old_id}.json"
card = json.loads(old_path.read_text())
card["intent"]["summary"] = "/Users/customer/raw/source/transcript.jsonl"
body = {key: value for key, value in card.items() if key != "meaning_card_id"}
canonical = json.dumps(body, sort_keys=True, separators=(",", ":")).encode()
card["meaning_card_id"] = "sha256:" + hashlib.sha256(canonical).hexdigest()
new_path = root / "meaning-cards" / (
    card["meaning_card_id"].removeprefix("sha256:") + ".json"
)
new_path.write_text(
    json.dumps(card, sort_keys=True, separators=(",", ":")) + "\n",
    encoding="utf-8",
)
new_path.chmod(0o600)
old_path.unlink()
PY
  generate_meaning \
    "$episode" "$source_ref" meaning-model-a "$output" \
    "$TEST_ROOT/meaning-requests.jsonl" \
    "$TEST_ROOT/meaning-evaluator-count" 2>"$error" || status=$?
  if [[ "$status" -ne 0 && ! -s "$output" ]] \
    && ! grep -q "Traceback" "$error"; then
    pass "public IDを再hashした改ざんMeaning Cardもstrictに拒否する"
  else
    fail "public IDを再hashした改ざんMeaning Cardもstrictに拒否する"
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
  test_unknown_outcome_is_partial_not_covered
  test_raw_packet_fragment_echo_fails_closed
  test_bundled_meaning_evaluator_requires_240_second_outer_timeout
  test_rejects_multi_task_span_before_provider
  test_rehashed_tampered_card_is_rejected
fi

echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
