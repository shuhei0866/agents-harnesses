#!/usr/bin/env bash
# Automatic Semantic Receipt discovery/matching contract tests.
# External dependencies: git and python3. Network access is not required.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CLI="$PLUGIN_DIR/scripts/flight-recorder"
RECORDER="$PLUGIN_DIR/scripts/record-event"
FIXTURES="$SCRIPT_DIR/fixtures"
FAKE_BIN="$FIXTURES/fake-bin"
FAKE_CLAUDE_BIN="$FIXTURES/fake-claude-bin"
RUBRIC="$PLUGIN_DIR/rubrics/semantic-receipt-v1.json"
TEST_ROOT="$(mktemp -d)" || exit 1
STATE="$TEST_ROOT/vault"
CLAUDE_ROOT="$TEST_ROOT/claude-sessions"
CODEX_ROOT="$TEST_ROOT/codex-sessions"
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

init_fixture() {
  local remote="$TEST_ROOT/remote.git"
  local recovery="$TEST_ROOT/recovery.agekey"
  mkdir -p "$CLAUDE_ROOT" "$CODEX_ROOT"
  git init -q --bare "$remote"
  git -C "$remote" symbolic-ref HEAD refs/heads/main
  PATH="$FAKE_BIN:$PATH" age-keygen -o "$recovery" >/dev/null 2>&1
  run_cli init \
    --remote "$remote" \
    --recovery-recipient \
    "$(PATH="$FAKE_BIN:$PATH" age-keygen -y "$recovery")" >/dev/null 2>&1
}

configure_auto() {
  local quiescence="${1:-0}"
  local max_receipts="${2:-5}"
  local max_cost="${3:-50000}"
  local model="${4:-semantic-auto-model}"
  run_cli receipt-auto configure \
    --claude-code-root "$CLAUDE_ROOT" \
    --codex-root "$CODEX_ROOT" \
    --evaluator flight-recorder-auto-semantic-evaluator \
    --model "$model" \
    --rubric "$RUBRIC" \
    --policy-version default-v1 \
    --quiescence-seconds "$quiescence" \
    --max-receipts-per-run "$max_receipts" \
    --max-cost-microusd-per-run "$max_cost" \
    --json
}

record_stop() {
  local harness="$1" session_id="$2" turn_id="$3" source_path="$4"
  local payload="$TEST_ROOT/stop-${harness}-${session_id}.json"
  python3 - "$payload" "$session_id" "$turn_id" "$source_path" <<'PY'
import json
import pathlib
import sys

path, session_id, turn_id, source_path = sys.argv[1:]
value = {
    "hook_event_name": "Stop",
    "session_id": session_id,
    "transcript_path": source_path,
    "cwd": "/tmp/flight-recorder-generic-workspace",
    "model": "fixture-worker-model",
    "permission_mode": "default",
}
if turn_id:
    value["turn_id"] = turn_id
pathlib.Path(path).write_text(json.dumps(value), encoding="utf-8")
PY
  FLIGHT_RECORDER_STATE_DIR="$STATE" \
    AGENT_FLIGHT_RECORDER_NOW="2026-07-26T00:00:00Z" \
    "$RECORDER" --harness "$harness" <"$payload" >/dev/null 2>&1
}

test_configure_is_strict_atomic_and_content_free() {
  echo "test_configure_is_strict_atomic_and_content_free:"
  local output="$TEST_ROOT/configure.json"
  local err="$TEST_ROOT/configure.err"
  if configure_auto 0 5 50000 >"$output" 2>"$err" \
    && python3 - "$output" "$STATE" "$CLAUDE_ROOT" "$CODEX_ROOT" "$RUBRIC" <<'PY'
import json
import pathlib
import stat
import sys

output_path, state, claude_root, codex_root, rubric = sys.argv[1:]
output = json.loads(pathlib.Path(output_path).read_text(encoding="utf-8"))
root = pathlib.Path(state)
path = root / "receipt-automation/config.json"
config = json.loads(path.read_text(encoding="utf-8"))
assert config == {
    "schema_version": 1,
    "enabled": True,
    "claude_code_root": str(pathlib.Path(claude_root).absolute()),
    "codex_root": str(pathlib.Path(codex_root).absolute()),
    "evaluator": "flight-recorder-auto-semantic-evaluator",
    "model": "semantic-auto-model",
    "rubric_path": str(pathlib.Path(rubric).absolute()),
    "policy_version": "default-v1",
    "quiescence_seconds": 0,
    "max_receipts_per_run": 5,
    "max_cost_microusd_per_run": 50000,
}
serialized = json.dumps(output, sort_keys=True)
assert output["schema_version"] == 1
assert output["command"] == "receipt-auto configure"
assert output["config"]["enabled"] is True
assert output["config"]["claude_code_root_configured"] is True
assert output["config"]["codex_root_configured"] is True
assert output["config"]["rubric_configured"] is True
assert claude_root not in serialized
assert codex_root not in serialized
assert rubric not in serialized
assert stat.S_IMODE(path.stat().st_mode) == 0o600
assert stat.S_IMODE(path.parent.stat().st_mode) == 0o700
assert "/receipt-automation/\n" in (
    root / ".gitignore"
).read_text(encoding="utf-8")
PY
  then
    pass "自動生成policyをowner-only local stateへ保存しpathを出力しない"
  else
    cat "$err" >&2
    fail "自動生成policyをowner-only local stateへ保存しpathを出力しない"
    return
  fi

  local config="$STATE/receipt-automation/config.json"
  local before status=0 failures=0
  before="$(shasum -a 256 "$config")"
  for arguments in \
    "--quiescence-seconds -1 --max-receipts-per-run 5 --max-cost-microusd-per-run 50000" \
    "--quiescence-seconds 0 --max-receipts-per-run 0 --max-cost-microusd-per-run 50000" \
    "--quiescence-seconds 0 --max-receipts-per-run 5 --max-cost-microusd-per-run -1"
  do
    status=0
    # shellcheck disable=SC2086
    run_cli receipt-auto configure \
      --claude-code-root "$CLAUDE_ROOT" \
      --codex-root "$CODEX_ROOT" \
      --evaluator flight-recorder-auto-semantic-evaluator \
      --model semantic-auto-model \
      --rubric "$RUBRIC" \
      --policy-version default-v1 \
      $arguments >"$TEST_ROOT/invalid.out" \
      2>"$TEST_ROOT/invalid.err" || status=$?
    if [[ "$status" -eq 0 || -s "$TEST_ROOT/invalid.out" ]] \
      || grep -q "Traceback" "$TEST_ROOT/invalid.err" \
      || [[ "$before" != "$(shasum -a 256 "$config")" ]]; then
      failures=$((failures + 1))
    fi
  done
  if [[ "$failures" -eq 0 ]]; then
    pass "invalidなquiescence・件数・cost budgetをatomicに拒否する"
  else
    fail "invalidなquiescence・件数・cost budgetをatomicに拒否する"
  fi
}

test_stop_hook_writes_bounded_local_hint_fail_open() {
  echo "test_stop_hook_writes_bounded_local_hint_fail_open:"
  local source="$CLAUDE_ROOT/exact-session.jsonl"
  local hints="$STATE/receipt-automation/hints.jsonl"
  local events="$STATE/inbox/events.jsonl"
  cp "$FIXTURES/claude-code-auto-session.jsonl" "$source"
  record_stop claude-code claude-auto-session "" "$source"
  if python3 - "$hints" "$events" "$source" <<'PY' 2>/dev/null
import json
import pathlib
import stat
import sys

hints_path, events_path, source_path = map(pathlib.Path, sys.argv[1:])
hints = [
    json.loads(line)
    for line in hints_path.read_text(encoding="utf-8").splitlines()
    if line.strip()
]
events = [
    json.loads(line)
    for line in events_path.read_text(encoding="utf-8").splitlines()
    if line.strip()
]
assert len(hints) == 1
hint = hints[0]
event = events[-1]
assert hint["schema_version"] == 1
assert hint["event_id"] == event["event_id"]
assert hint["harness"] == "claude-code"
assert hint["source_path"] == str(source_path)
assert hint["captured_size_bytes"] == source_path.stat().st_size
assert hint["session_id_hash"] == event["session_id_hash"]
assert hint["turn_id_hash"] is None
assert hint["source_identity"]["device"] == source_path.stat().st_dev
assert hint["source_identity"]["inode"] == source_path.stat().st_ino
assert stat.S_IMODE(hints_path.stat().st_mode) == 0o600
serialized = json.dumps(hint, sort_keys=True)
assert "claude-auto-session" not in serialized
assert "CLAUDE_AUTO_SELECTED" not in serialized
PY
  then
    pass "Stopをevent_id・captured byte境界付きlocal-only hintへ結ぶ"
  else
    fail "Stopをevent_id・captured byte境界付きlocal-only hintへ結ぶ"
  fi

  local before after backup="$TEST_ROOT/hints.backup"
  before="$(wc -l <"$events" | tr -d ' ')"
  mv "$hints" "$backup"
  mkdir "$hints"
  record_stop claude-code claude-auto-session "" "$source"
  after="$(wc -l <"$events" | tr -d ' ')"
  rmdir "$hints"
  mv "$backup" "$hints"
  if [[ "$after" -eq $((before + 1)) ]]; then
    pass "hint保存失敗でもhook event記録をfail-openで継続する"
  else
    fail "hint保存失敗でもhook event記録をfail-openで継続する"
  fi
}

test_exact_claude_and_codex_generate_bounded_receipts_idempotently() {
  echo "test_exact_claude_and_codex_generate_bounded_receipts_idempotently:"
  local claude_source="$CLAUDE_ROOT/exact-session.jsonl"
  local codex_source="$CODEX_ROOT/exact-session.jsonl"
  local capture="$TEST_ROOT/auto-evaluator-requests.jsonl"
  local counter="$TEST_ROOT/auto-evaluator-count"
  local output="$TEST_ROOT/auto-run.json"
  local repeat="$TEST_ROOT/auto-run-repeat.json"
  local err="$TEST_ROOT/auto-run.err"

  cp "$FIXTURES/codex-auto-session.jsonl" "$codex_source"
  record_stop codex codex-auto-session codex-auto-turn "$codex_source"
  printf '%s\n' \
    '{"type":"event_msg","payload":{"message":"CODEX_AUTO_OUTSIDE_AFTER_CANARY"}}' \
    >>"$codex_source"
  printf '%s\n' \
    '{"type":"assistant","uuid":"after-stop","parentUuid":"assistant-2","sessionId":"claude-auto-session","message":{"role":"assistant","content":"CLAUDE_AUTO_OUTSIDE_AFTER_CANARY"}}' \
    >>"$claude_source"
  run_cli sync >/dev/null 2>&1
  run_cli rebuild-index >/dev/null 2>&1

  if FLIGHT_RECORDER_TEST_AUTO_SEMANTIC_CAPTURE="$capture" \
    FLIGHT_RECORDER_TEST_AUTO_SEMANTIC_COUNT="$counter" \
    FLIGHT_RECORDER_TEST_AUTO_SEMANTIC_COST=12000 \
    run_cli receipt-auto run --json >"$output" 2>"$err" \
    && python3 - "$output" "$capture" "$counter" "$STATE" <<'PY'
import json
import pathlib
import sys

output_path, capture_path, counter_path, state = sys.argv[1:]
value = json.loads(pathlib.Path(output_path).read_text(encoding="utf-8"))
requests = [
    json.loads(line)
    for line in pathlib.Path(capture_path).read_text(encoding="utf-8").splitlines()
    if line.strip()
]
assert value["schema_version"] == 1
assert value["command"] == "receipt-auto run"
assert value["state"] == "completed"
assert value["matched_count"] == 2
assert value["generated_count"] == 2
assert value["measured_cost_microusd"] == 24000
assert int(pathlib.Path(counter_path).read_text(encoding="utf-8")) == 2
assert len(requests) == 2
assert all(request["schema_version"] == 2 for request in requests)
assert [request["remaining_cost_microusd"] for request in requests] == [
    50000, 38000
]
contents = [request["source"]["content"] for request in requests]
serialized = json.dumps(contents, sort_keys=True)
assert "CLAUDE_AUTO_SELECTED_USER_CANARY" in serialized
assert "CLAUDE_AUTO_SELECTED_FINAL_CANARY" in serialized
assert "CLAUDE_OUTSIDE_BEFORE_CANARY" not in serialized
assert "CLAUDE_AUTO_OUTSIDE_AFTER_CANARY" not in serialized
assert "CODEX_AUTO_SELECTED_USER_CANARY" in serialized
assert "CODEX_AUTO_SELECTED_ASSISTANT_CANARY" in serialized
assert "CODEX_AUTO_OUTSIDE_AFTER_CANARY" not in serialized
receipts = list((pathlib.Path(state) / "semantic-receipts").glob("*.json"))
assert len(receipts) == 2
assert all(
    json.loads(path.read_text(encoding="utf-8"))["schema_version"] == 1
    for path in receipts
)
PY
  then
    pass "Claude chainとCodex turnのcaptured spanだけでReceiptを生成する"
  else
    cat "$err" >&2
    fail "Claude chainとCodex turnのcaptured spanだけでReceiptを生成する"
    return
  fi

  if FLIGHT_RECORDER_TEST_AUTO_SEMANTIC_CAPTURE="$capture" \
    FLIGHT_RECORDER_TEST_AUTO_SEMANTIC_COUNT="$counter" \
    run_cli receipt-auto run --json >"$repeat" \
      2>"$TEST_ROOT/auto-run-repeat.err" \
    && [[ "$(cat "$counter")" == "2" ]] \
    && python3 - "$repeat" <<'PY'
import json
import pathlib
import sys

value = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert value["generated_count"] == 0
assert value["idempotent_skip_count"] == 2
assert value["measured_cost_microusd"] == 0
PY
  then
    pass "同一event/source/model/rubric fingerprintを再評価しない"
  else
    fail "同一event/source/model/rubric fingerprintを再評価しない"
  fi
}

test_classifies_ambiguous_missing_and_active_without_evaluation() {
  echo "test_classifies_ambiguous_missing_and_active_without_evaluation:"
  local ambiguous="$CLAUDE_ROOT/ambiguous.jsonl"
  local missing="$CODEX_ROOT/missing.jsonl"
  local active="$CODEX_ROOT/active.jsonl"
  local output="$TEST_ROOT/classification.json"
  local counter="$TEST_ROOT/auto-evaluator-count"
  local err="$TEST_ROOT/classification.err"
  cp "$FIXTURES/claude-code-auto-ambiguous.jsonl" "$ambiguous"
  cp "$FIXTURES/codex-auto-session.jsonl" "$missing"
  cp "$FIXTURES/codex-auto-session.jsonl" "$active"
  python3 - "$ambiguous" "$missing" <<'PY'
import os
import sys
import time

old = time.time() - 7200
for path in sys.argv[1:]:
    os.utime(path, (old, old))
PY
  record_stop claude-code claude-ambiguous-session "" "$ambiguous"
  record_stop codex codex-auto-session codex-auto-turn "$missing"
  rm "$missing"
  record_stop codex codex-auto-session codex-auto-turn "$active"
  configure_auto 3600 5 50000 >/dev/null 2>&1
  run_cli sync >/dev/null 2>&1
  run_cli rebuild-index >/dev/null 2>&1

  if FLIGHT_RECORDER_TEST_AUTO_SEMANTIC_COUNT="$counter" \
    run_cli receipt-auto run --json >"$output" 2>"$err" \
    && [[ "$(cat "$counter")" == "2" ]] \
    && python3 - "$output" <<'PY'
import json
import pathlib
import sys

value = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert value["ambiguous_count"] >= 1
assert value["missing_count"] >= 1
assert value["active_count"] >= 1
assert value["generated_count"] == 0
assert value["failed_count"] == 0
PY
  then
    pass "ambiguous・missing・activeを有限分類しexact以外を評価しない"
  else
    cat "$err" >&2
    fail "ambiguous・missing・activeを有限分類しexact以外を評価しない"
  fi
}

test_measured_cost_is_capped() {
  echo "test_measured_cost_is_capped:"
  local output="$TEST_ROOT/cost-cap.json"
  local capture="$TEST_ROOT/cost-cap-requests.jsonl"
  local counter="$TEST_ROOT/cost-cap-count"
  local err="$TEST_ROOT/cost-cap.err"
  configure_auto 0 10 15000 semantic-cost-cap-model >/dev/null 2>&1
  if FLIGHT_RECORDER_TEST_AUTO_SEMANTIC_CAPTURE="$capture" \
    FLIGHT_RECORDER_TEST_AUTO_SEMANTIC_COUNT="$counter" \
    FLIGHT_RECORDER_TEST_AUTO_SEMANTIC_COST=12000 \
    run_cli receipt-auto run --json >"$output" 2>"$err" \
    && python3 - "$output" "$capture" "$counter" <<'PY'
import json
import pathlib
import sys

value = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
requests = [
    json.loads(line)
    for line in pathlib.Path(sys.argv[2]).read_text(encoding="utf-8").splitlines()
    if line.strip()
]
count = int(pathlib.Path(sys.argv[3]).read_text(encoding="utf-8"))
assert count == 2
assert value["generated_count"] == 2
assert value["measured_cost_microusd"] == 15000
assert value["measured_cost_microusd"] <= 15000
assert [request["remaining_cost_microusd"] for request in requests] == [
    15000, 3000
]
PY
  then
    pass "実測costを加算しremaining capをprotocol v2で強制する"
  else
    cat "$err" >&2
    fail "実測costを加算しremaining capをprotocol v2で強制する"
  fi
}

test_paid_invalid_response_stops_the_run() {
  echo "test_paid_invalid_response_stops_the_run:"
  local output="$TEST_ROOT/paid-invalid.json"
  local counter="$TEST_ROOT/paid-invalid-count"
  local err="$TEST_ROOT/paid-invalid.err"
  configure_auto 0 10 15000 semantic-paid-invalid-model >/dev/null 2>&1
  if FLIGHT_RECORDER_TEST_AUTO_SEMANTIC_COUNT="$counter" \
    FLIGHT_RECORDER_TEST_AUTO_SEMANTIC_COST=12000 \
    FLIGHT_RECORDER_TEST_AUTO_SEMANTIC_INVALID=1 \
    run_cli receipt-auto run --json >"$output" 2>"$err" \
    && [[ "$(cat "$counter")" == "1" ]] \
    && python3 - "$output" <<'PY'
import json
import pathlib
import sys

value = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert value["failed_count"] == 1
assert value["generated_count"] == 0
assert value["measured_cost_microusd"] == 0
PY
  then
    pass "課金後のinvalid payloadでは後続評価を止めrun capを守る"
  else
    cat "$err" >&2
    fail "課金後のinvalid payloadでは後続評価を止めrun capを守る"
  fi
}

test_production_claude_adapter_offline_e2e() {
  echo "test_production_claude_adapter_offline_e2e:"
  local output="$TEST_ROOT/production-adapter.json"
  local repeat="$TEST_ROOT/production-adapter-repeat.json"
  local capture="$TEST_ROOT/production-adapter-capture"
  mkdir -p "$capture/bin"
  cp "$FAKE_CLAUDE_BIN/claude" "$capture/bin/claude"
  local configure_err="$TEST_ROOT/production-adapter-configure.err"
  if ! PATH="$FAKE_CLAUDE_BIN:$FAKE_BIN:$PATH" \
    FLIGHT_RECORDER_STATE_DIR="$STATE" \
    "$CLI" receipt-auto configure \
      --claude-code-root "$CLAUDE_ROOT" \
      --codex-root "$CODEX_ROOT" \
      --evaluator flight-recorder-claude-semantic-evaluator \
      --model claude-sonnet-fixture \
      --rubric "$RUBRIC" \
      --policy-version default-v1 \
      --quiescence-seconds 0 \
      --max-receipts-per-run 10 \
      --max-cost-microusd-per-run 50000 \
      --json >/dev/null 2>"$configure_err"; then
    cat "$configure_err" >&2
    fail "production adapterをworkerへ接続しofflineでReceiptを生成する"
    fail "production adapter経由でも同一fingerprintを再評価しない"
    return 1
  fi
  if PATH="$FAKE_CLAUDE_BIN:$PATH" \
      FLIGHT_RECORDER_TEST_HARNESS=1 \
      FLIGHT_RECORDER_TEST_CLAUDE_EXECUTABLE="$capture/bin/claude" \
      FLIGHT_RECORDER_TEST_CLAUDE_CAPTURE_DIR="$capture" \
      FLIGHT_RECORDER_TEST_CLAUDE_MODE=valid \
      run_cli receipt-auto run --json >"$output" \
        2>"$TEST_ROOT/production-adapter.err" \
    && PATH="$FAKE_CLAUDE_BIN:$PATH" \
      FLIGHT_RECORDER_TEST_HARNESS=1 \
      FLIGHT_RECORDER_TEST_CLAUDE_EXECUTABLE="$capture/bin/claude" \
      FLIGHT_RECORDER_TEST_CLAUDE_CAPTURE_DIR="$capture" \
      FLIGHT_RECORDER_TEST_CLAUDE_MODE=nonzero \
      run_cli receipt-auto run --json >"$repeat" \
        2>"$TEST_ROOT/production-adapter-repeat.err" \
    && python3 - "$output" "$repeat" "$capture" <<'PY'
import json
import pathlib
import sys

output_path, repeat_path, capture_path = map(pathlib.Path, sys.argv[1:])
value = json.loads(output_path.read_text(encoding="utf-8"))
repeat = json.loads(repeat_path.read_text(encoding="utf-8"))
argv = json.loads((capture_path / "argv.json").read_text(encoding="utf-8"))
assert value["generated_count"] >= 2
assert value["failed_count"] == 0
assert value["measured_cost_microusd"] == value["generated_count"] * 12346
assert repeat["generated_count"] == 0
assert repeat["failed_count"] == 0
assert repeat["idempotent_skip_count"] == value["generated_count"]
assert "--safe-mode" in argv
assert "--no-session-persistence" in argv
PY
  then
    pass "production adapterをworkerへ接続しofflineでReceiptを生成する"
    pass "production adapter経由でも同一fingerprintを再評価しない"
  else
    cat "$output" >&2
    cat "$repeat" >&2
    cat "$TEST_ROOT/production-adapter.err" >&2
    cat "$TEST_ROOT/production-adapter-repeat.err" >&2
    fail "production adapterをworkerへ接続しofflineでReceiptを生成する"
    fail "production adapter経由でも同一fingerprintを再評価しない"
  fi
}

test_scheduler_failure_is_sync_independent_and_not_recharged() {
  echo "test_scheduler_failure_is_sync_independent_and_not_recharged:"
  local hints="$STATE/receipt-automation/hints.jsonl"
  local backup="$TEST_ROOT/all-hints.jsonl"
  local counter="$TEST_ROOT/scheduler-auto-evaluator-count"
  local retry="$TEST_ROOT/scheduler-failure-retry.json"
  cp "$hints" "$backup"
  python3 - "$hints" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
rows = [
    json.loads(line)
    for line in path.read_text(encoding="utf-8").splitlines()
    if line.strip()
]
selected = next(
    row
    for row in rows
    if row["harness"] == "claude-code"
    and row["source_path"].endswith("/exact-session.jsonl")
)
path.write_text(
    json.dumps(selected, sort_keys=True, separators=(",", ":")) + "\n",
    encoding="utf-8",
)
PY
  configure_auto 0 1 50000 semantic-scheduler-failure-model >/dev/null 2>&1
  rm -f "$STATE/scheduler/state.json"
  if FLIGHT_RECORDER_TEST_AUTO_SEMANTIC_COUNT="$counter" \
    FLIGHT_RECORDER_TEST_AUTO_SEMANTIC_FAIL=1 \
    run_cli scheduler run >"$TEST_ROOT/scheduler.out" \
      2>"$TEST_ROOT/scheduler.err" \
    && [[ "$(cat "$counter")" == "1" ]] \
    && python3 - "$STATE" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
sync = json.loads(
    (root / "scheduler/state.json").read_text(encoding="utf-8")
)
automatic = json.loads(
    (root / "receipt-automation/status.json").read_text(encoding="utf-8")
)
assert sync["last_success_at"] is not None
assert sync["last_error_category"] is None
assert automatic["state"] == "error"
assert automatic["diagnostic_code"] == "evaluator_failed"
assert automatic["attempt_count"] == 1
assert "error" not in automatic
PY
  then
    pass "evaluator失敗をscheduler sync healthとexitから分離する"
  else
    cat "$TEST_ROOT/scheduler.err" >&2
    fail "evaluator失敗をscheduler sync healthとexitから分離する"
    mv "$backup" "$hints"
    return
  fi

  if FLIGHT_RECORDER_TEST_AUTO_SEMANTIC_COUNT="$counter" \
    FLIGHT_RECORDER_TEST_AUTO_SEMANTIC_FAIL=1 \
    run_cli receipt-auto run --json >"$retry" \
      2>"$TEST_ROOT/scheduler-failure-retry.err" \
    && [[ "$(cat "$counter")" == "1" ]] \
    && python3 - "$retry" <<'PY'
import json
import pathlib
import sys

value = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert value["attempt_skip_count"] == 1
assert value["generated_count"] == 0
assert value["measured_cost_microusd"] == 0
PY
  then
    pass "失敗した同一fingerprintをscheduler周期ごとに再課金しない"
  else
    fail "失敗した同一fingerprintをscheduler周期ごとに再課金しない"
  fi
  mv "$backup" "$hints"
}

test_status_is_content_free() {
  echo "test_status_is_content_free:"
  local output="$TEST_ROOT/status.json"
  if run_cli status --json >"$output" 2>"$TEST_ROOT/status.err" \
    && python3 - "$output" "$TEST_ROOT" <<'PY'
import json
import pathlib
import sys

path, private_root = sys.argv[1:]
value = json.loads(pathlib.Path(path).read_text(encoding="utf-8"))
component = value["receipt_automation"]
assert value["schema_version"] == 4
assert component["enabled"] is True
assert component["state"] in {"idle", "completed", "attention", "error"}
for field in (
    "discovered", "matched", "ambiguous", "missing", "active",
    "queued", "generated", "failed", "measured_cost_microusd",
):
    assert isinstance(component[field], int)
serialized = json.dumps(value, sort_keys=True)
assert private_root not in serialized
assert "claude-sessions" not in serialized
assert "codex-sessions" not in serialized
assert "SELECTED" not in serialized
assert "CANARY" not in serialized
PY
  then
    pass "global statusへ集計だけを公開しpath・本文を漏らさない"
  else
    cat "$TEST_ROOT/status.err" >&2
    fail "global statusへ集計だけを公開しpath・本文を漏らさない"
  fi
}

test_provider_parsers_select_latest_closed_turn() {
  echo "test_provider_parsers_select_latest_closed_turn:"
  if PYTHONPATH="$PLUGIN_DIR/scripts" python3 - <<'PY'
from receipt_automation import _claude_span, _codex_span
from record_event import hash_identifier

key = b"k" * 32
claude_session = "claude-multi-turn"
claude_rows = [
    {
        "type": "user",
        "uuid": "prompt-1",
        "parentUuid": None,
        "sessionId": claude_session,
        "message": {"role": "user", "content": "first prompt"},
    },
    {
        "type": "assistant",
        "uuid": "answer-1",
        "parentUuid": "prompt-1",
        "sessionId": claude_session,
        "message": {"role": "assistant", "content": "first answer"},
    },
    {
        "type": "last-prompt",
        "sessionId": claude_session,
        "leafUuid": "answer-1",
    },
    {
        "type": "user",
        "uuid": "prompt-2",
        "parentUuid": "answer-1",
        "sessionId": claude_session,
        "message": {"role": "user", "content": "second prompt"},
    },
    {
        "type": "assistant",
        "uuid": "answer-2",
        "parentUuid": "prompt-2",
        "sessionId": claude_session,
        "message": {"role": "assistant", "content": "second answer"},
    },
    {
        "type": "last-prompt",
        "sessionId": claude_session,
        "leafUuid": "answer-2",
    },
]
assert _claude_span(
    claude_rows,
    {"session_id_hash": hash_identifier(claude_session, key)},
    key,
) == ("exact", 4, 5)

codex_session = "codex-session-id-field"
codex_turn = "codex-turn"
codex_rows = [
    {
        "type": "session_meta",
        "payload": {"session_id": codex_session},
    },
    {
        "type": "event_msg",
        "payload": {"type": "task_started", "turn_id": codex_turn},
    },
    {
        "type": "event_msg",
        "payload": {"type": "task_complete", "turn_id": codex_turn},
    },
]
assert _codex_span(
    codex_rows,
    {
        "session_id_hash": hash_identifier(codex_session, key),
        "turn_id_hash": hash_identifier(codex_turn, key),
    },
    key,
) == ("exact", 2, 3)
PY
  then
    pass "複数turnのClaudeは最新promptだけ、Codexはsession_id fieldで照合する"
  else
    fail "複数turnのClaudeは最新promptだけ、Codexはsession_id fieldで照合する"
  fi
}

test_episode_members_require_complete_correlation() {
  echo "test_episode_members_require_complete_correlation:"
  if PLUGIN_DIR="$PLUGIN_DIR" python3 - <<'PY'
import os
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(os.environ["PLUGIN_DIR"]) / "scripts"))
import receipt_automation as automatic
import reporting

episode = {
    "episode_id": "sha256:" + "1" * 64,
    "members": [
        ("event-stop", "claude-code", "Stop", None, None),
    ],
    "evidence_ids": [],
}
reporting._authenticated_query = lambda *_args: episode
state, _value = automatic._episode_for_event(
    pathlib.Path("/unused"),
    "event-stop",
    "default-v1",
    {
        "harness": "claude-code",
        "session_id_hash": "sha256:" + "2" * 64,
        "turn_id_hash": None,
    },
)
assert state == "ambiguous"

episode["members"] = [
    (
        "event-stop",
        "codex",
        "Stop",
        "sha256:" + "2" * 64,
        None,
    ),
]
state, _value = automatic._episode_for_event(
    pathlib.Path("/unused"),
    "event-stop",
    "default-v1",
    {
        "harness": "codex",
        "session_id_hash": "sha256:" + "2" * 64,
        "turn_id_hash": "sha256:" + "3" * 64,
    },
)
assert state == "ambiguous"
PY
  then
    pass "Episode全memberにsession/turn相関hashの完全一致を要求する"
  else
    fail "Episode全memberにsession/turn相関hashの完全一致を要求する"
  fi
}

test_run_authenticates_graph_only_for_required_stages() {
  echo "test_run_authenticates_graph_only_for_required_stages:"
  local batch_root="$TEST_ROOT/batch-auth-vault"
  local batch_claude_root="$TEST_ROOT/batch-auth-claude-sessions"
  local batch_codex_root="$TEST_ROOT/batch-auth-codex-sessions"
  local batch_remote="$TEST_ROOT/batch-auth-remote.git"
  local batch_recovery="$TEST_ROOT/batch-auth-recovery.agekey"
  local exact_claude="$batch_claude_root/exact.jsonl"
  local exact_codex="$batch_codex_root/exact.jsonl"
  local ambiguous_claude="$batch_claude_root/ambiguous.jsonl"
  local missing_codex="$batch_codex_root/missing.jsonl"
  local err="$TEST_ROOT/batch-auth.err"

  if (
    local STATE="$batch_root"
    local CLAUDE_ROOT="$batch_claude_root"
    local CODEX_ROOT="$batch_codex_root"
    mkdir -p "$CLAUDE_ROOT" "$CODEX_ROOT"
    git init -q --bare "$batch_remote"
    git -C "$batch_remote" symbolic-ref HEAD refs/heads/main
    PATH="$FAKE_BIN:$PATH" age-keygen -o "$batch_recovery" \
      >/dev/null 2>&1
    run_cli init \
      --remote "$batch_remote" \
      --recovery-recipient \
      "$(PATH="$FAKE_BIN:$PATH" age-keygen -y "$batch_recovery")" \
      >/dev/null 2>&1 \
      || exit 1
    configure_auto 0 10 50000 batch-auth-model >/dev/null 2>&1 \
      || exit 1

    cp "$FIXTURES/claude-code-auto-session.jsonl" "$exact_claude"
    cp "$FIXTURES/codex-auto-session.jsonl" "$exact_codex"
    cp "$FIXTURES/claude-code-auto-ambiguous.jsonl" "$ambiguous_claude"
    cp "$FIXTURES/codex-auto-session.jsonl" "$missing_codex"
    record_stop claude-code claude-auto-session "" "$exact_claude"
    record_stop codex codex-auto-session codex-auto-turn "$exact_codex"
    record_stop claude-code claude-ambiguous-session "" "$ambiguous_claude"
    record_stop codex codex-auto-session codex-auto-turn "$missing_codex"
    rm "$missing_codex"
    run_cli sync >/dev/null 2>&1
    run_cli rebuild-index >/dev/null 2>&1

    PATH="$FAKE_BIN:$PATH" \
      PYTHONPATH="$PLUGIN_DIR/scripts" \
      python3 - "$STATE" <<'PY'
import json
import pathlib
import sys

import receipt_automation
import reporting

root = pathlib.Path(sys.argv[1])
sealed_query = reporting.read_sealed_query_locked
verify_count = 0


def counting_sealed_query(*args, **kwargs):
    global verify_count
    verify_count += 1
    return sealed_query(*args, **kwargs)


reporting.read_sealed_query_locked = counting_sealed_query
try:
    result = receipt_automation.run(root)
    generated_verify_count = verify_count
    verify_count = 0
    repeat = receipt_automation.run(root)
    unstaged_verify_count = verify_count

    hints_path = root / "receipt-automation/hints.jsonl"
    hints = [
        json.loads(line)
        for line in hints_path.read_text(encoding="utf-8").splitlines()
        if line.strip()
    ]
    hints_path.write_text(
        "".join(
            json.dumps(
                hint, sort_keys=True, separators=(",", ":")
            ) + "\n"
            for hint in hints
            if not str(hint.get("source_path", "")).endswith("/exact.jsonl")
        ),
        encoding="utf-8",
    )
    verify_count = 0
    no_candidate = receipt_automation.run(root)
    no_candidate_verify_count = verify_count
finally:
    reporting.read_sealed_query_locked = sealed_query

assert result["matched_count"] == 2
assert result["generated_count"] == 2
assert result["missing_count"] == 1
assert result["ambiguous_count"] == 1
assert generated_verify_count == 2
assert repeat["generated_count"] == 0
assert repeat["idempotent_skip_count"] == 2
assert unstaged_verify_count == 1
assert no_candidate["generated_count"] == 0
assert no_candidate["matched_count"] == 0
assert no_candidate["missing_count"] == 1
assert no_candidate["ambiguous_count"] == 1
assert no_candidate_verify_count == 0
PY
  ) 2>"$err"
  then
    pass "生成時2回・stageなし1回・候補なし0回だけsealed indexを認証する"
  else
    cat "$err" >&2
    fail "生成時2回・stageなし1回・候補なし0回だけsealed indexを認証する"
  fi
}

test_final_authentication_failures_are_retryable() {
  echo "test_final_authentication_failures_are_retryable:"
  local scenario failures=0
  for scenario in forget graph; do
    if ! (
      local STATE="$TEST_ROOT/deferred-$scenario-vault"
      local CLAUDE_ROOT="$TEST_ROOT/deferred-$scenario-claude-sessions"
      local CODEX_ROOT="$TEST_ROOT/deferred-$scenario-codex-sessions"
      local remote="$TEST_ROOT/deferred-$scenario-remote.git"
      local recovery="$TEST_ROOT/deferred-$scenario-recovery.agekey"
      local source="$CLAUDE_ROOT/exact.jsonl"
      mkdir -p "$CLAUDE_ROOT" "$CODEX_ROOT"
      git init -q --bare "$remote"
      git -C "$remote" symbolic-ref HEAD refs/heads/main
      PATH="$FAKE_BIN:$PATH" age-keygen -o "$recovery" >/dev/null 2>&1
      run_cli init \
        --remote "$remote" \
        --recovery-recipient \
        "$(PATH="$FAKE_BIN:$PATH" age-keygen -y "$recovery")" \
        >/dev/null 2>&1
      configure_auto 0 10 50000 "deferred-$scenario-model" \
        >/dev/null 2>&1
      cp "$FIXTURES/claude-code-auto-session.jsonl" "$source"
      record_stop claude-code claude-auto-session "" "$source"
      run_cli sync >/dev/null 2>&1
      run_cli rebuild-index >/dev/null 2>&1
      python3 - "$STATE/receipt-automation/hints.jsonl" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
with path.open("a", encoding="utf-8") as stream:
    for index in range(99):
        stream.write(json.dumps({
            "schema_version": 1,
            "event_id": f"deferred-terminal-invalid-{index}",
        }, sort_keys=True, separators=(",", ":")) + "\n")
PY

      PATH="$FAKE_BIN:$PATH" \
        PYTHONPATH="$PLUGIN_DIR/scripts" \
        python3 - "$STATE" "$scenario" <<'PY'
import json
import pathlib
import shutil
import sqlite3
import sys

import receipt_automation
from retention_state import store_forgotten

root = pathlib.Path(sys.argv[1])
scenario = sys.argv[2]
prepare_receipt = receipt_automation._prepare_receipt
database = root / "index/vault.sqlite"
database_backup = root / "index/vault.sqlite.before-final-auth"
mutated = False
evaluator_count = 0


def mutate_before_final_authentication(*args, **kwargs):
    global evaluator_count, mutated
    evaluator_count += 1
    prepared = prepare_receipt(*args, **kwargs)
    if mutated:
        return prepared
    mutated = True
    episode_id = prepared["result"]["receipt"]["episode_id"]
    policy = prepared["snapshot"]["policy_version"]
    if scenario == "forget":
        store_forgotten(root, {(policy, episode_id)})
    else:
        shutil.copy2(database, database_backup)
        connection = sqlite3.connect(database)
        try:
            connection.execute(
                "DELETE FROM episode_members WHERE episode_id = ?",
                (episode_id,),
            )
            connection.commit()
        finally:
            connection.close()
    return prepared


receipt_automation._prepare_receipt = mutate_before_final_authentication
try:
    first = receipt_automation.run(root)
    receipt_paths = list((root / "semantic-receipts").glob("*.json"))
    attempts = json.loads(
        (root / "receipt-automation/attempts.json").read_text(encoding="utf-8")
    )["items"]
    hints_path = root / "receipt-automation/hints.jsonl"
    hints = [
        json.loads(line)
        for line in hints_path.read_text(encoding="utf-8").splitlines()
        if line.strip()
    ]

    if scenario == "forget":
        store_forgotten(root, set())
    else:
        shutil.copy2(database_backup, database)

    second = receipt_automation.run(root)
finally:
    receipt_automation._prepare_receipt = prepare_receipt

after_retry_receipts = list((root / "semantic-receipts").glob("*.json"))
after_retry_attempts = json.loads(
    (root / "receipt-automation/attempts.json").read_text(encoding="utf-8")
)["items"]

assert first["generated_count"] == 0
assert first["measured_cost_microusd"] == 1000
assert receipt_paths == []
assert len(attempts) == 1
assert attempts[0]["state"] == "prepared"
assert len(hints) == 1
assert hints[0].get("source_path", "").endswith("/exact.jsonl")
assert second["generated_count"] == 1
assert second["failed_count"] == 0
assert second["measured_cost_microusd"] == 0
assert evaluator_count == 1
assert len(after_retry_receipts) == 1
assert [item["state"] for item in after_retry_attempts] == ["completed"]
PY
    ) 2>"$TEST_ROOT/deferred-$scenario.err"
    then
      cat "$TEST_ROOT/deferred-$scenario.err" >&2
      failures=$((failures + 1))
    fi
  done
  if [[ "$failures" -eq 0 ]]; then
    pass "最終認証でforget・graph変化を検知し副作用なしで再試行できる"
  else
    fail "最終認証でforget・graph変化を検知し副作用なしで再試行できる"
  fi
}

test_purge_waits_for_inflight_evaluator_without_resurrection() {
  echo "test_purge_waits_for_inflight_evaluator_without_resurrection:"
  local STATE="$TEST_ROOT/purge-race-vault"
  local CLAUDE_ROOT="$TEST_ROOT/purge-race-claude-sessions"
  local CODEX_ROOT="$TEST_ROOT/purge-race-codex-sessions"
  local remote="$TEST_ROOT/purge-race-remote.git"
  local recovery="$TEST_ROOT/purge-race-recovery.agekey"
  local source="$CLAUDE_ROOT/exact.jsonl"
  local database="$STATE/index/vault.sqlite"
  local episode control="$TEST_ROOT/purge-race-evaluator"
  local err="$TEST_ROOT/purge-race.err"
  mkdir -p "$CLAUDE_ROOT" "$CODEX_ROOT"
  git init -q --bare "$remote"
  git -C "$remote" symbolic-ref HEAD refs/heads/main
  PATH="$FAKE_BIN:$PATH" age-keygen -o "$recovery" >/dev/null 2>&1
  if ! run_cli init \
      --remote "$remote" \
      --recovery-recipient \
      "$(PATH="$FAKE_BIN:$PATH" age-keygen -y "$recovery")" \
      >/dev/null 2>&1 \
    || ! configure_auto 0 10 50000 purge-race-model >/dev/null 2>&1; then
    fail "purge競合fixtureを初期化できる"
    return
  fi
  cp "$FIXTURES/claude-code-auto-session.jsonl" "$source"
  record_stop claude-code claude-auto-session "" "$source"
  run_cli sync >/dev/null 2>&1
  run_cli rebuild-index >/dev/null 2>&1
  episode="$(
    python3 - "$database" <<'PY'
import sqlite3
import sys

connection = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
row = connection.execute(
    "SELECT m.episode_id FROM episode_members AS m "
    "JOIN source_events AS e ON e.event_id = m.event_id "
    "WHERE m.policy_version = 'default-v1' AND e.source_event = 'Stop' "
    "LIMIT 1"
).fetchone()
assert row is not None
print(row[0])
PY
  )"

  if PATH="$FAKE_BIN:$PATH" PYTHONPATH="$PLUGIN_DIR/scripts" \
    python3 - "$CLI" "$STATE" "$episode" "$control" <<'PY' 2>"$err"
import json
import os
import pathlib
import sqlite3
import subprocess
import sys
import time

cli, state_value, episode, control_value = sys.argv[1:]
root = pathlib.Path(state_value)
control = pathlib.Path(control_value)
ready = control.with_suffix(".ready")
release = control.with_suffix(".release")
environment = dict(os.environ)
environment["FLIGHT_RECORDER_STATE_DIR"] = str(root)
environment["FLIGHT_RECORDER_TEST_AUTO_SEMANTIC_BLOCK"] = str(control)

automatic = subprocess.Popen(
    [cli, "receipt-auto", "run", "--json"],
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
    env=environment,
)
purge = None
try:
    deadline = time.monotonic() + 10
    while not ready.exists() and automatic.poll() is None:
        if time.monotonic() >= deadline:
            raise AssertionError("evaluator did not reach the blocking point")
        time.sleep(0.05)
    assert ready.exists()
    purge = subprocess.Popen(
        [cli, "purge", episode, "--apply"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=environment,
    )
    time.sleep(0.5)
    purge_waited_for_evaluator = purge.poll() is None
    release.write_text("release\n", encoding="utf-8")
    automatic_stdout, automatic_stderr = automatic.communicate(timeout=30)
    purge_stdout, purge_stderr = purge.communicate(timeout=30)
finally:
    release.write_text("release\n", encoding="utf-8")
    for process in (automatic, purge):
        if process is not None and process.poll() is None:
            process.kill()
            process.communicate()

assert purge_waited_for_evaluator
assert automatic.returncode == 0, automatic_stderr
assert purge.returncode == 0, purge_stderr
automatic_result = json.loads(automatic_stdout)
assert automatic_result["generated_count"] == 1

receipts = []
directory = root / "semantic-receipts"
if directory.is_dir():
    receipts = [
        json.loads(path.read_text(encoding="utf-8"))
        for path in directory.glob("*.json")
    ]
assert not any(item.get("episode_id") == episode for item in receipts)
attempt_path = root / "receipt-automation/attempts.json"
if attempt_path.exists():
    attempts = json.loads(attempt_path.read_text(encoding="utf-8"))["items"]
    assert attempts == []
connection = sqlite3.connect(
    f"file:{root / 'index/vault.sqlite'}?mode=ro", uri=True
)
remaining = connection.execute(
    "SELECT COUNT(*) FROM episode_members WHERE episode_id = ?", (episode,)
).fetchone()[0]
connection.close()
assert remaining == 0
PY
  then
    pass "purgeは実行中evaluatorをbounded待機しtarget状態を復活させない"
  else
    cat "$err" >&2
    fail "purgeは実行中evaluatorをbounded待機しtarget状態を復活させない"
  fi
}

test_attempt_capacity_is_reserved_before_provider_call() {
  echo "test_attempt_capacity_is_reserved_before_provider_call:"
  local STATE="$TEST_ROOT/capacity-vault"
  local CLAUDE_ROOT="$TEST_ROOT/capacity-claude-sessions"
  local CODEX_ROOT="$TEST_ROOT/capacity-codex-sessions"
  local remote="$TEST_ROOT/capacity-remote.git"
  local recovery="$TEST_ROOT/capacity-recovery.agekey"
  local source="$CLAUDE_ROOT/exact.jsonl"
  local counter="$TEST_ROOT/capacity-provider-count"
  local err="$TEST_ROOT/capacity.err"
  mkdir -p "$CLAUDE_ROOT" "$CODEX_ROOT"
  git init -q --bare "$remote"
  git -C "$remote" symbolic-ref HEAD refs/heads/main
  PATH="$FAKE_BIN:$PATH" age-keygen -o "$recovery" >/dev/null 2>&1
  if ! run_cli init \
      --remote "$remote" \
      --recovery-recipient \
      "$(PATH="$FAKE_BIN:$PATH" age-keygen -y "$recovery")" \
      >/dev/null 2>&1 \
    || ! configure_auto 0 10 50000 capacity-model >/dev/null 2>&1; then
    fail "attempt capacity fixtureを初期化できる"
    return
  fi
  cp "$FIXTURES/claude-code-auto-session.jsonl" "$source"
  record_stop claude-code claude-auto-session "" "$source"
  run_cli sync >/dev/null 2>&1
  run_cli rebuild-index >/dev/null 2>&1

  if PATH="$FAKE_BIN:$PATH" PYTHONPATH="$PLUGIN_DIR/scripts" \
    FLIGHT_RECORDER_TEST_AUTO_SEMANTIC_COUNT="$counter" \
    python3 - "$STATE" "$counter" <<'PY' 2>"$err"
import pathlib
import sys

from chunk_rotation import canonical_json
import receipt_automation
from semantic_receipts import MAX_STORED_RECEIPT_BYTES
from vault import VaultError

root = pathlib.Path(sys.argv[1])
counter = pathlib.Path(sys.argv[2])
path = root / "receipt-automation/attempts.json"
path.write_bytes(canonical_json({
    "schema_version": 1,
    "items": [{
        "fingerprint": "sha256:" + "9" * 64,
        "state": "completed",
    }],
}) + b"\n")
path.chmod(0o600)
before = path.read_bytes()
source_event_ids = [f"event-{index:032x}" for index in range(10_000)]
evidence_ids = ["sha256:" + f"{index:064x}" for index in range(10_000)]
identifier_bytes = len(canonical_json({
    "source_event_ids": source_event_ids,
    "evidence_ids": evidence_ids,
}))
legal_prepared_upper_bound = (
    2 * MAX_STORED_RECEIPT_BYTES
    + len(canonical_json(evidence_ids))
    + 64 * 1024
)
assert identifier_bytes > MAX_STORED_RECEIPT_BYTES
assert legal_prepared_upper_bound < 2 * 1024 * 1024
assert receipt_automation.MAX_PREPARED_ATTEMPT_BYTES == 4 * 1024 * 1024
assert legal_prepared_upper_bound <= receipt_automation.MAX_PREPARED_ATTEMPT_BYTES
receipt_automation.MAX_ATTEMPTS = 2
receipt_automation.MAX_STATE_BYTES = legal_prepared_upper_bound
error = None
try:
    result = receipt_automation.run(root)
except VaultError as caught:
    error = str(caught)
    result = None

provider_count = int(counter.read_text()) if counter.exists() else 0
assert provider_count == 0
assert path.read_bytes() == before
assert not list((root / "semantic-receipts").glob("*.json"))
assert result is None or result["generated_count"] == 0
assert error is None or "prepared capacity" in error
PY
  then
    pass "prepared予約余地不足をprovider前に拒否しledgerと課金を残さない"
  else
    cat "$err" >&2
    fail "prepared予約余地不足をprovider前に拒否しledgerと課金を残さない"
  fi
}

test_maximum_legal_prepared_attempt_is_below_four_mib() {
  echo "test_maximum_legal_prepared_attempt_is_below_four_mib:"
  local STATE="$TEST_ROOT/maximum-prepared-vault"
  local CLAUDE_ROOT="$TEST_ROOT/maximum-prepared-claude-sessions"
  local CODEX_ROOT="$TEST_ROOT/maximum-prepared-codex-sessions"
  local remote="$TEST_ROOT/maximum-prepared-remote.git"
  local recovery="$TEST_ROOT/maximum-prepared-recovery.agekey"
  local source="$CLAUDE_ROOT/exact.jsonl"
  local err="$TEST_ROOT/maximum-prepared.err"
  mkdir -p "$CLAUDE_ROOT" "$CODEX_ROOT"
  git init -q --bare "$remote"
  git -C "$remote" symbolic-ref HEAD refs/heads/main
  PATH="$FAKE_BIN:$PATH" age-keygen -o "$recovery" >/dev/null 2>&1
  if ! run_cli init \
      --remote "$remote" \
      --recovery-recipient \
      "$(PATH="$FAKE_BIN:$PATH" age-keygen -y "$recovery")" \
      >/dev/null 2>&1 \
    || ! configure_auto 0 10 50000 maximum-prepared-model \
      >/dev/null 2>&1; then
    fail "maximum prepared fixtureを初期化できる"
    return
  fi
  cp "$FIXTURES/claude-code-auto-session.jsonl" "$source"
  record_stop claude-code claude-auto-session "" "$source"
  run_cli sync >/dev/null 2>&1
  run_cli rebuild-index >/dev/null 2>&1
  if ! run_cli receipt-auto run --json \
      >"$TEST_ROOT/maximum-prepared-run.json" 2>"$err"; then
    cat "$err" >&2
    fail "maximum prepared用base Receiptを生成できる"
    return
  fi

  if PYTHONPATH="$PLUGIN_DIR/scripts" \
      python3 - "$STATE" <<'PY' 2>"$err"
import hashlib
import json
import pathlib
import sys

from chunk_rotation import canonical_json
from receipt_automation import MAX_PREPARED_ATTEMPT_BYTES, _validate_attempt_item
from semantic_receipts import MAX_STORED_RECEIPT_BYTES, _validate_prepared_record

root = pathlib.Path(sys.argv[1])
receipt_path = next((root / "semantic-receipts").glob("*.json"))
receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
maximum_source_ids = [f"{index:x}" for index in range(10_000)]
receipt_evidence_ids = receipt["provenance"]["evidence_ids"]
additional_evidence_ids = [
    f"sha256:{index:064x}"
    for index in range(10_000)
    if f"sha256:{index:064x}" not in receipt_evidence_ids
]
maximum_evidence_ids = (
    receipt_evidence_ids + additional_evidence_ids
)[:10_000]
receipt["provenance"]["source_event_ids"] = maximum_source_ids
receipt["receipt_id"] = "sha256:" + hashlib.sha256(canonical_json({
    key: value for key, value in receipt.items() if key != "receipt_id"
})).hexdigest()
assert len(canonical_json(receipt) + b"\n") <= MAX_STORED_RECEIPT_BYTES
span = receipt["provenance"]["source_spans"][0]
prepared = {
    "result": {
        "schema_version": 1,
        "command": "receipt generate",
        "receipt": receipt,
        "measured_cost_microusd": 0,
    },
    "snapshot": {
        "policy_version": receipt["provenance"]["policy_version"],
        "source_event_ids": maximum_source_ids,
        "evidence_ids": maximum_evidence_ids,
    },
    "source": {
        "source_ref": span["source_ref"],
        "start_line": span["start_line"],
        "end_line": span["end_line"],
        "span_sha256": span["span_sha256"],
    },
}
checked = _validate_prepared_record(prepared)
attempt = {
    "fingerprint": "sha256:" + "f" * 64,
    "state": "prepared",
    "event_id": maximum_source_ids[0],
    "episode_id": receipt["episode_id"],
    "prepared": checked,
}
checked_attempt = _validate_attempt_item(attempt)
encoded_size = len(canonical_json(checked_attempt))
strict_upper_bound = (
    2 * MAX_STORED_RECEIPT_BYTES
    + len(canonical_json(maximum_evidence_ids))
    + 64 * 1024
)
assert len(maximum_source_ids) == 10_000
assert len(maximum_evidence_ids) == 10_000
assert len(canonical_json(receipt) + b"\n") <= MAX_STORED_RECEIPT_BYTES
assert encoded_size < strict_upper_bound
assert strict_upper_bound < 2 * 1024 * 1024
assert strict_upper_bound <= MAX_PREPARED_ATTEMPT_BYTES
assert MAX_PREPARED_ATTEMPT_BYTES == 4 * 1024 * 1024
PY
  then
    pass "各1万IDの合法prepared実測と厳密上界は2MiB未満に収まる"
  else
    cat "$err" >&2
    fail "各1万IDの合法prepared実測と厳密上界は2MiB未満に収まる"
  fi
}

test_blocking_run_lock_has_a_retry_bound() {
  echo "test_blocking_run_lock_has_a_retry_bound:"
  local err="$TEST_ROOT/blocking-run-lock.err"
  if PYTHONPATH="$PLUGIN_DIR/scripts" python3 - "$STATE" <<'PY' \
    2>"$err"
import os
import pathlib
import time
import sys

import receipt_automation
from vault import VaultError

root = pathlib.Path(sys.argv[1])
marker = root.parent / "receipt-lock-held"
release = root.parent / "receipt-lock-release"
pid = os.fork()
if pid == 0:
    try:
        with receipt_automation.run_lock(root, blocking=False) as acquired:
            if not acquired:
                os._exit(2)
            marker.write_text("held", encoding="utf-8")
            deadline = time.monotonic() + 5
            while not release.exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            os._exit(0 if release.exists() else 3)
    except BaseException:
        os._exit(4)

try:
    deadline = time.monotonic() + 5
    while not marker.exists() and time.monotonic() < deadline:
        time.sleep(0.01)
    assert marker.exists(), "lock holder did not start"
    receipt_automation.MAX_BLOCKING_LOCK_WAIT_SECONDS = 0.05
    started = time.monotonic()
    try:
        with receipt_automation.run_lock(root, blocking=True):
            raise AssertionError("blocking lock unexpectedly acquired")
    except VaultError as error:
        assert "retry" in str(error)
    assert time.monotonic() - started < 1
finally:
    release.write_text("release", encoding="utf-8")
    _pid, status = os.waitpid(pid, 0)
    assert os.waitstatus_to_exitcode(status) == 0
PY
  then
    pass "purge用blocking lockは上限後にretry可能なエラーを返す"
  else
    cat "$err" >&2
    fail "purge用blocking lockは上限後にretry可能なエラーを返す"
  fi
}

test_terminal_hints_are_compacted_before_the_limit() {
  echo "test_terminal_hints_are_compacted_before_the_limit:"
  local hints="$STATE/receipt-automation/hints.jsonl"
  local output="$TEST_ROOT/hint-compaction.json"
  python3 - "$hints" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
with path.open("a", encoding="utf-8") as stream:
    for index in range(101):
        stream.write(json.dumps({
            "schema_version": 1,
            "event_id": f"terminal-invalid-{index}",
        }, sort_keys=True, separators=(",", ":")) + "\n")
PY
  if run_cli receipt-auto run --json >"$output" \
      2>"$TEST_ROOT/hint-compaction.err" \
    && python3 - "$hints" <<'PY'
import json
import pathlib
import sys

rows = [
    json.loads(line)
    for line in pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
    if line.strip()
]
assert not any(
    str(row.get("event_id", "")).startswith("terminal-invalid-")
    for row in rows
)
assert len(rows) < 100
PY
  then
    pass "終端済みhintを安全に圧縮して上限到達を予防する"
  else
    cat "$TEST_ROOT/hint-compaction.err" >&2
    fail "終端済みhintを安全に圧縮して上限到達を予防する"
  fi
}

test_recursive_privacy_failure_closes_attempt() {
  echo "test_recursive_privacy_failure_closes_attempt:"
  local STATE="$TEST_ROOT/recursive-privacy-vault"
  local CLAUDE_ROOT="$TEST_ROOT/recursive-privacy-claude"
  local CODEX_ROOT="$TEST_ROOT/recursive-privacy-codex"
  local remote="$TEST_ROOT/recursive-privacy-remote.git"
  local recovery="$TEST_ROOT/recursive-privacy-recovery.agekey"
  local source="$CLAUDE_ROOT/claude-auto-session.jsonl"
  local capture="$TEST_ROOT/recursive-privacy-capture"
  local output="$TEST_ROOT/recursive-privacy.json"
  local error="$TEST_ROOT/recursive-privacy.err"
  mkdir -p "$CLAUDE_ROOT" "$CODEX_ROOT" "$capture/bin"
  git init -q --bare "$remote"
  git -C "$remote" symbolic-ref HEAD refs/heads/main
  PATH="$FAKE_BIN:$PATH" age-keygen -o "$recovery" >/dev/null 2>&1
  if ! run_cli init \
      --remote "$remote" \
      --recovery-recipient \
      "$(PATH="$FAKE_BIN:$PATH" age-keygen -y "$recovery")" \
      >/dev/null 2>&1; then
    fail "再帰超過attempt fixtureを初期化する"
    return
  fi
  if ! PATH="$FAKE_CLAUDE_BIN:$FAKE_BIN:$PATH" \
      FLIGHT_RECORDER_STATE_DIR="$STATE" \
      "$CLI" receipt-auto configure \
        --claude-code-root "$CLAUDE_ROOT" \
        --codex-root "$CODEX_ROOT" \
        --evaluator flight-recorder-claude-semantic-evaluator \
        --model claude-sonnet-fixture \
        --rubric "$RUBRIC" \
        --policy-version default-v1 \
        --quiescence-seconds 0 \
        --max-receipts-per-run 1 \
        --max-cost-microusd-per-run 50000 \
        --json >/dev/null 2>"$TEST_ROOT/recursive-privacy-config.err"; then
    fail "再帰超過attempt fixtureを構成する"
    return
  fi
  cp "$FAKE_CLAUDE_BIN/claude" "$capture/bin/claude"
  python3 - "$FIXTURES/claude-code-auto-session.jsonl" "$source" <<'PY'
import pathlib
import sys

fixture, destination = map(pathlib.Path, sys.argv[1:])
lines = fixture.read_text(encoding="utf-8").splitlines()
deep_object = '{"padding":' * 2000 + '"PRIVATE"' + '}' * 2000
# Keep every top-level row an object so Claude span discovery remains exact.
# The privacy validator must still reject the deeply nested selected row.
lines.insert(4, deep_object)
destination.write_text("\n".join(lines) + "\n", encoding="utf-8")
PY
  record_stop claude-code claude-auto-session "" "$source"
  run_cli sync >/dev/null 2>&1
  run_cli rebuild-index >/dev/null 2>&1
  if PATH="$FAKE_CLAUDE_BIN:$PATH" \
      FLIGHT_RECORDER_TEST_HARNESS=1 \
      FLIGHT_RECORDER_TEST_CLAUDE_EXECUTABLE="$capture/bin/claude" \
      FLIGHT_RECORDER_TEST_CLAUDE_CAPTURE_DIR="$capture" \
      FLIGHT_RECORDER_TEST_CLAUDE_MODE=valid \
      run_cli receipt-auto run --json >"$output" 2>"$error" \
    && python3 - "$output" "$STATE" <<'PY'
import json
import pathlib
import sys

output_path = pathlib.Path(sys.argv[1])
root = pathlib.Path(sys.argv[2])
value = json.loads(output_path.read_text(encoding="utf-8"))
attempts = json.loads(
    (root / "receipt-automation/attempts.json").read_text(encoding="utf-8")
)["items"]
assert value["failed_count"] == 1
assert value["generated_count"] == 0
assert len(attempts) == 1
assert attempts[0]["state"] == "failed"
assert not any(item["state"] == "pending" for item in attempts)
assert not list((root / "semantic-receipts").glob("*.json"))
PY
  then
    pass "再帰超過をfailed attemptへ閉じ永久pendingを残さない"
  else
    cat "$output" >&2
    cat "$error" >&2
    fail "再帰超過をfailed attemptへ閉じ永久pendingを残さない"
  fi
}

echo "=== Flight Recorder Automatic Semantic Receipt Tests ==="
if ! init_fixture; then
  echo "fixture setup failed" >&2
  exit 1
fi
if [[ "${FLIGHT_RECORDER_TEST_RECURSIVE_PRIVACY_ONLY:-0}" == "1" ]]; then
  test_recursive_privacy_failure_closes_attempt
  echo
  echo "Results: $PASS passed, $FAIL failed"
  [[ "$FAIL" -eq 0 ]]
  exit
fi
test_configure_is_strict_atomic_and_content_free
if [[ -f "$STATE/receipt-automation/config.json" ]]; then
  test_stop_hook_writes_bounded_local_hint_fail_open
  test_exact_claude_and_codex_generate_bounded_receipts_idempotently
  test_classifies_ambiguous_missing_and_active_without_evaluation
  test_measured_cost_is_capped
  test_paid_invalid_response_stops_the_run
  test_production_claude_adapter_offline_e2e
  test_scheduler_failure_is_sync_independent_and_not_recharged
  test_status_is_content_free
  test_provider_parsers_select_latest_closed_turn
  test_episode_members_require_complete_correlation
  test_run_authenticates_graph_only_for_required_stages
  test_final_authentication_failures_are_retryable
  test_purge_waits_for_inflight_evaluator_without_resurrection
  test_attempt_capacity_is_reserved_before_provider_call
  test_maximum_legal_prepared_attempt_is_below_four_mib
  test_blocking_run_lock_has_a_retry_bound
  test_terminal_hints_are_compacted_before_the_limit
  test_recursive_privacy_failure_closes_attempt
fi

echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
