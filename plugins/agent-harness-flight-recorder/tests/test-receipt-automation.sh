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
  PATH="$FAKE_CLAUDE_BIN:$FAKE_BIN:$PATH" \
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
      --json >/dev/null 2>&1
  if PATH="$FAKE_CLAUDE_BIN:$PATH" \
      FLIGHT_RECORDER_TEST_CLAUDE_EXECUTABLE="$FAKE_CLAUDE_BIN/claude" \
      FLIGHT_RECORDER_TEST_CLAUDE_CAPTURE_DIR="$capture" \
      FLIGHT_RECORDER_TEST_CLAUDE_MODE=valid \
      run_cli receipt-auto run --json >"$output" \
        2>"$TEST_ROOT/production-adapter.err" \
    && PATH="$FAKE_CLAUDE_BIN:$PATH" \
      FLIGHT_RECORDER_TEST_CLAUDE_EXECUTABLE="$FAKE_CLAUDE_BIN/claude" \
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

echo "=== Flight Recorder Automatic Semantic Receipt Tests ==="
if ! init_fixture; then
  echo "fixture setup failed" >&2
  exit 1
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
  test_terminal_hints_are_compacted_before_the_limit
fi

echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
