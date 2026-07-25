#!/usr/bin/env bash
# Metadata-only background evaluation contract tests.
# External dependencies: git and python3. Network access is not required.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CLI="$PLUGIN_DIR/scripts/flight-recorder"
FAKE_BIN="$SCRIPT_DIR/fixtures/fake-bin"
TEST_ROOT="$(mktemp -d)" || exit 1
[[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]] || {
  echo "failed to create temporary directory" >&2
  exit 1
}
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

init_fixture() {
  local remote="$TEST_ROOT/remote.git"
  local recovery="$TEST_ROOT/recovery.agekey"
  git init -q --bare "$remote"
  git -C "$remote" symbolic-ref HEAD refs/heads/main
  PATH="$FAKE_BIN:$PATH" age-keygen -o "$recovery" >/dev/null 2>&1
  run_cli init \
    --remote "$remote" \
    --recovery-recipient \
    "$(PATH="$FAKE_BIN:$PATH" age-keygen -y "$recovery")" \
    >/dev/null 2>&1
  mkdir -p "$STATE/inbox"
  python3 - "$STATE/inbox/events.jsonl" <<'PY'
import datetime as dt
import json
import pathlib
import sys

now = dt.datetime.now(dt.timezone.utc).replace(microsecond=0)
events = []
for index, task in enumerate(("1", "1", "2"), start=1):
    events.append({
        "schema_version": 2,
        "event_id": f"51000000-0000-4000-8000-{index:012d}",
        "recorded_at": (
            now - dt.timedelta(seconds=400 - index * 100)
        ).isoformat().replace("+00:00", "Z"),
        "harness": "codex" if index > 1 else "claude-code",
        "source_event": "Stop",
        "event_kind": "turn.completed",
        "session_id_hash": "sha256:" + "a" * 24,
        "turn_id_hash": None,
        "workspace_id": "sha256:" + "b" * 24,
        "model": "fixture-model",
        "permission_mode": None,
        "tool": None,
        "metrics": None,
        "outcome": {"status": "success", "exit_code": 0},
        "relationship_context": {
            "task_id_hash": "sha256:" + task * 24,
            "task_source": "payload",
            "branch_or_worktree_id": "sha256:" + "c" * 24,
            "changed_file_fingerprints": ["sha256:" + task * 24],
            "changed_files_state": "complete",
        },
    })
pathlib.Path(sys.argv[1]).write_text(
    "".join(
        json.dumps(item, sort_keys=True, separators=(",", ":")) + "\n"
        for item in events
    ),
    encoding="utf-8",
)
PY
  run_cli sync >/dev/null 2>&1
  run_cli rebuild-index >/dev/null 2>&1
}

test_run_selects_metadata_only_candidates_idempotently() {
  echo "test_run_selects_metadata_only_candidates_idempotently:"
  local output="$TEST_ROOT/run.json"
  local capture="$TEST_ROOT/request.json"
  local counter="$TEST_ROOT/evaluator-count"
  run_cli auto-evaluation configure \
    --evaluator flight-recorder-background-evaluator \
    --model evaluator-test-model \
    --policy-version default-v1 \
    --uncertainty-score-below 700 \
    --max-evaluations-per-run 2 \
    --max-cost-microusd-per-run 50000 \
    --json >/dev/null 2>&1 || {
      fail "background run policyを構成できる"
      return
    }
  if FLIGHT_RECORDER_TEST_EVALUATOR_CAPTURE="$capture" \
    FLIGHT_RECORDER_TEST_EVALUATOR_COUNT="$counter" \
    FLIGHT_RECORDER_TEST_EVALUATOR_COST=12000 \
    run_cli auto-evaluation run --json \
      >"$output" 2>"$TEST_ROOT/run.err" \
    && python3 - "$output" "$capture" "$counter" "$STATE" <<'PY'
import json
import pathlib
import sys

value = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
request = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
count = int(pathlib.Path(sys.argv[3]).read_text(encoding="utf-8"))
root = pathlib.Path(sys.argv[4])
assert value["command"] == "auto-evaluation run"
assert value["state"] == "completed"
assert value["candidate_count"] == 1
assert value["evaluated_count"] == 1
assert value["measured_cost_microusd"] == 12000
assert count == 1
assert request["metadata_only"] is True
assert request["artifacts"] == []
assert request["trigger"] == "background"
assert request["remaining_cost_microusd"] == 50000
records = [
    json.loads(path.read_text(encoding="utf-8"))
    for path in (root / "evaluations").glob("*.json")
]
assert len(records) == 1
assert records[0]["trigger"] == "background"
assert records[0]["measured_cost_microusd"] == 12000
PY
  then
    pass "低confidence候補だけをmetadata-onlyでbudget内評価する"
  else
    cat "$TEST_ROOT/run.err" >&2
    fail "低confidence候補だけをmetadata-onlyでbudget内評価する"
    return
  fi

  if FLIGHT_RECORDER_TEST_EVALUATOR_COUNT="$counter" \
    run_cli auto-evaluation run --json \
      >"$output" 2>"$TEST_ROOT/run-repeat.err" \
    && [[ "$(cat "$counter")" == "1" ]] \
    && python3 - "$output" <<'PY'
import json
import pathlib
import sys

value = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert value["evaluated_count"] == 0
assert value["idempotent_skip_count"] == 1
PY
  then
    pass "同じpolicy/model/evidence fingerprintを自動再評価しない"
  else
    fail "同じpolicy/model/evidence fingerprintを自動再評価しない"
  fi
}

test_failure_is_fail_open_and_attempt_bounded() {
  echo "test_failure_is_fail_open_and_attempt_bounded:"
  local output="$TEST_ROOT/failure.json"
  local counter="$TEST_ROOT/failure-count"
  run_cli auto-evaluation configure \
    --evaluator flight-recorder-background-evaluator \
    --model evaluator-failure-model \
    --policy-version default-v1 \
    --uncertainty-score-below 700 \
    --max-evaluations-per-run 2 \
    --max-cost-microusd-per-run 50000 \
    --json >/dev/null 2>&1 || {
      fail "failure policyを構成できる"
      return
    }
  if FLIGHT_RECORDER_TEST_EVALUATOR_COUNT="$counter" \
    FLIGHT_RECORDER_TEST_EVALUATOR_FAIL=1 \
    run_cli auto-evaluation run --json \
      >"$output" 2>"$TEST_ROOT/failure.err" \
    && [[ "$(cat "$counter")" == "1" ]] \
    && python3 - "$output" "$STATE" <<'PY'
import json
import pathlib
import sys

value = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
root = pathlib.Path(sys.argv[2])
assert value["state"] == "error"
assert value["diagnostic_code"] == "evaluator_failed"
assert value["evaluated_count"] == 0
status = json.loads(
    (root / "auto-evaluation/status.json").read_text(encoding="utf-8")
)
assert status["diagnostic_code"] == "evaluator_failed"
assert status["attempt_count"] == 1
assert "error" not in status
PY
  then
    pass "background evaluator失敗をsafe stateへ閉じCLIをfail-openにする"
  else
    cat "$TEST_ROOT/failure.err" >&2
    fail "background evaluator失敗をsafe stateへ閉じCLIをfail-openにする"
    return
  fi

  if FLIGHT_RECORDER_TEST_EVALUATOR_COUNT="$counter" \
    FLIGHT_RECORDER_TEST_EVALUATOR_FAIL=1 \
    run_cli auto-evaluation run --json \
      >"$output" 2>"$TEST_ROOT/failure-repeat.err" \
    && [[ "$(cat "$counter")" == "1" ]] \
    && python3 - "$output" <<'PY'
import json
import pathlib
import sys

value = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert value["attempt_skip_count"] == 1
assert value["evaluated_count"] == 0
PY
  then
    pass "失敗した同一fingerprintをscheduler周期ごとに無制限再試行しない"
  else
    fail "失敗した同一fingerprintをscheduler周期ごとに無制限再試行しない"
  fi
}

test_measured_cost_never_exceeds_run_cap() {
  echo "test_measured_cost_never_exceeds_run_cap:"
  local output="$TEST_ROOT/cost-cap.json"
  local capture="$TEST_ROOT/cost-cap-request.json"
  local counter="$TEST_ROOT/cost-cap-count"
  run_cli auto-evaluation configure \
    --evaluator flight-recorder-background-evaluator \
    --model evaluator-cost-cap-model \
    --policy-version default-v1 \
    --uncertainty-score-below 2000 \
    --max-evaluations-per-run 10 \
    --max-cost-microusd-per-run 20000 \
    --json >/dev/null 2>&1 || {
      fail "cost cap policyを構成できる"
      return
    }
  if FLIGHT_RECORDER_TEST_EVALUATOR_CAPTURE="$capture" \
    FLIGHT_RECORDER_TEST_EVALUATOR_COUNT="$counter" \
    FLIGHT_RECORDER_TEST_EVALUATOR_COST=12000 \
    run_cli auto-evaluation run --json \
      >"$output" 2>"$TEST_ROOT/cost-cap.err" \
    && python3 - "$output" "$capture" "$counter" <<'PY'
import json
import pathlib
import sys

value = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
request = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
count = int(pathlib.Path(sys.argv[3]).read_text(encoding="utf-8"))
assert value["candidate_count"] == 2
assert value["evaluated_count"] == 2
assert value["measured_cost_microusd"] == 20000
assert count == 2
assert request["remaining_cost_microusd"] == 8000
PY
  then
    pass "実測costを加算しremaining capを評価器へ強制する"
  else
    cat "$TEST_ROOT/cost-cap.err" >&2
    fail "実測costを加算しremaining capを評価器へ強制する"
  fi
}

test_scheduler_sync_health_is_independent() {
  echo "test_scheduler_sync_health_is_independent:"
  local counter="$TEST_ROOT/scheduler-evaluator-count"
  run_cli auto-evaluation configure \
    --evaluator flight-recorder-background-evaluator \
    --model evaluator-scheduler-failure-model \
    --policy-version default-v1 \
    --uncertainty-score-below 700 \
    --max-evaluations-per-run 1 \
    --max-cost-microusd-per-run 50000 \
    --json >/dev/null 2>&1 || {
      fail "scheduler policyを構成できる"
      return
    }
  rm -f "$STATE/scheduler/state.json"
  if FLIGHT_RECORDER_TEST_EVALUATOR_COUNT="$counter" \
    FLIGHT_RECORDER_TEST_EVALUATOR_FAIL=1 \
    run_cli scheduler run \
      >"$TEST_ROOT/scheduler-run.out" \
      2>"$TEST_ROOT/scheduler-run.err" \
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
    (root / "auto-evaluation/status.json").read_text(encoding="utf-8")
)
assert sync["last_success_at"] is not None
assert sync["last_error_category"] is None
assert automatic["state"] == "error"
assert automatic["diagnostic_code"] == "evaluator_failed"
PY
  then
    pass "background失敗をscheduler sync healthとexitから分離する"
  else
    cat "$TEST_ROOT/scheduler-run.err" >&2
    fail "background失敗をscheduler sync healthとexitから分離する"
  fi
}

test_configure_is_strict_local_policy() {
  echo "test_configure_is_strict_local_policy:"
  local output="$TEST_ROOT/configure.json"
  if run_cli auto-evaluation configure \
    --evaluator flight-recorder-evaluator \
    --model evaluator-test-model \
    --policy-version default-v1 \
    --uncertainty-score-below 700 \
    --max-evaluations-per-run 2 \
    --max-cost-microusd-per-run 50000 \
    --json >"$output" 2>"$TEST_ROOT/configure.err" \
    && python3 - "$output" "$STATE" <<'PY'
import json
import pathlib
import stat
import sys

output = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
root = pathlib.Path(sys.argv[2])
path = root / "auto-evaluation/config.json"
config = json.loads(path.read_text(encoding="utf-8"))
expected = {
    "schema_version": 1,
    "enabled": True,
    "evaluator": "flight-recorder-evaluator",
    "model": "evaluator-test-model",
    "policy_version": "default-v1",
    "policy_path": None,
    "uncertainty_score_below": 700,
    "max_evaluations_per_run": 2,
    "max_cost_microusd_per_run": 50000,
}
assert config == expected
assert output == {
    "schema_version": 1,
    "command": "auto-evaluation configure",
    "config": expected,
}
assert stat.S_IMODE(path.stat().st_mode) == 0o600
assert stat.S_IMODE(path.parent.stat().st_mode) == 0o700
assert "/auto-evaluation/\n" in (
    root / ".gitignore"
).read_text(encoding="utf-8")
PY
  then
    pass "自動評価policyをstrictなowner-only・Git除外local stateへ保存する"
  else
    cat "$TEST_ROOT/configure.err" >&2
    fail "自動評価policyをstrictなowner-only・Git除外local stateへ保存する"
  fi
}

test_invalid_policy_does_not_mutate_config() {
  echo "test_invalid_policy_does_not_mutate_config:"
  local config="$STATE/auto-evaluation/config.json"
  local before status=0 failures=0
  before="$(shasum -a 256 "$config")"
  for arguments in \
    "--uncertainty-score-below -1 --max-evaluations-per-run 2 --max-cost-microusd-per-run 50000" \
    "--uncertainty-score-below 700 --max-evaluations-per-run 0 --max-cost-microusd-per-run 50000" \
    "--uncertainty-score-below 700 --max-evaluations-per-run 2 --max-cost-microusd-per-run -1"
  do
    status=0
    # shellcheck disable=SC2086
    run_cli auto-evaluation configure \
      --evaluator flight-recorder-evaluator \
      --model evaluator-test-model \
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
    pass "invalidなthreshold・件数・cost budgetをatomicに拒否する"
  else
    fail "invalidなthreshold・件数・cost budgetをatomicに拒否する"
  fi
}

test_budget_requires_explicit_v2_cost() {
  echo "test_budget_requires_explicit_v2_cost:"
  local mode output status failures=0
  for mode in v1 no-cost; do
    run_cli auto-evaluation configure \
      --evaluator flight-recorder-background-evaluator \
      --model "budget-$mode-model" \
      --policy-version default-v1 \
      --uncertainty-score-below 700 \
      --max-evaluations-per-run 1 \
      --max-cost-microusd-per-run 50000 \
      --json >/dev/null 2>&1 || {
        failures=$((failures + 1))
        continue
      }
    output="$TEST_ROOT/budget-$mode.json"
    status=0
    if [[ "$mode" == "v1" ]]; then
      FLIGHT_RECORDER_TEST_EVALUATOR_V1=1 \
        run_cli auto-evaluation run --json >"$output" \
        2>"$TEST_ROOT/budget-$mode.err" || status=$?
    else
      FLIGHT_RECORDER_TEST_EVALUATOR_NO_COST=1 \
        run_cli auto-evaluation run --json >"$output" \
        2>"$TEST_ROOT/budget-$mode.err" || status=$?
    fi
    if [[ "$status" -ne 0 ]] || ! python3 - "$output" <<'PY'
import json
import pathlib
import sys

value = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert value["state"] == "error"
assert value["diagnostic_code"] == "evaluator_failed"
assert value["evaluated_count"] == 0
assert value["measured_cost_microusd"] == 0
PY
    then
      failures=$((failures + 1))
    fi
  done
  if [[ "$failures" -eq 0 ]]; then
    pass "budgeted評価は明示cost付きprotocol v2だけを受理する"
  else
    fail "budgeted評価は明示cost付きprotocol v2だけを受理する"
  fi
}

test_custom_policy_requires_owner_file() {
  echo "test_custom_policy_requires_owner_file:"
  local policy="$TEST_ROOT/automatic-policy.json"
  local output="$TEST_ROOT/custom-policy-run.json"
  python3 - "$policy" <<'PY'
import json
import pathlib
import sys

pathlib.Path(sys.argv[1]).write_text(json.dumps({
    "schema_version": 1,
    "policy_version": "automatic-test-v1",
    "threshold": 500,
    "weights": {
        "explicit_task_match": 600,
        "workspace_match": 100,
        "branch_or_worktree_match": 150,
        "changed_file_overlap": 150,
    },
    "time_buckets": [
        {"max_seconds": 300, "contribution": 100},
        {"max_seconds": 3600, "contribution": 25},
    ],
    "time_window_seconds": 3600,
    "hard_veto": {"contradictory_task_ids": True},
}, sort_keys=True, separators=(",", ":")), encoding="utf-8")
PY
  local status=0
  run_cli auto-evaluation configure \
    --evaluator flight-recorder-background-evaluator \
    --model rejected-custom-policy \
    --policy-version automatic-test-v1 \
    --uncertainty-score-below 700 \
    --max-evaluations-per-run 1 \
    --max-cost-microusd-per-run 50000 \
    >"$TEST_ROOT/custom-version.out" \
    2>"$TEST_ROOT/custom-version.err" || status=$?
  if [[ "$status" -ne 0 && ! -s "$TEST_ROOT/custom-version.out" ]] \
    && run_cli rebuild-relationships --policy "$policy" >/dev/null 2>&1 \
    && run_cli auto-evaluation configure \
      --evaluator flight-recorder-background-evaluator \
      --model accepted-custom-policy \
      --policy "$policy" \
      --uncertainty-score-below 700 \
      --max-evaluations-per-run 1 \
      --max-cost-microusd-per-run 50000 \
      --json >/dev/null 2>&1 \
    && run_cli auto-evaluation run --json >"$output" \
      2>"$TEST_ROOT/custom-policy-run.err" \
    && python3 - "$output" "$STATE" "$policy" <<'PY'
import json
import pathlib
import sys

value = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
config = json.loads(
    (pathlib.Path(sys.argv[2]) / "auto-evaluation/config.json").read_text()
)
assert config["policy_version"] == "automatic-test-v1"
assert config["policy_path"] == str(pathlib.Path(sys.argv[3]).absolute())
assert value["state"] == "completed"
assert value["evaluated_count"] == 1
PY
  then
    pass "custom policyはowner-held fileを真正性の根拠にする"
  else
    fail "custom policyはowner-held fileを真正性の根拠にする"
  fi
}

test_run_reservation_and_configuration_are_serialized() {
  echo "test_run_reservation_and_configuration_are_serialized:"
  local ready="$TEST_ROOT/gate.ready"
  local release="$TEST_ROOT/gate.release"
  local counter="$TEST_ROOT/gate.count"
  local capture="$TEST_ROOT/gate.request.json"
  local run_pid configure_pid blocked=0
  run_cli auto-evaluation configure \
    --evaluator flight-recorder-background-evaluator \
    --model serialized-old-model \
    --policy-version default-v1 \
    --uncertainty-score-below 700 \
    --max-evaluations-per-run 1 \
    --max-cost-microusd-per-run 50000 \
    --json >/dev/null 2>&1 || {
      fail "run/configure serialization fixtureを構成できる"
      return
    }
  FLIGHT_RECORDER_TEST_EVALUATOR_READY="$ready" \
    FLIGHT_RECORDER_TEST_EVALUATOR_RELEASE="$release" \
    FLIGHT_RECORDER_TEST_EVALUATOR_COUNT="$counter" \
    FLIGHT_RECORDER_TEST_EVALUATOR_CAPTURE="$capture" \
    run_cli auto-evaluation run --json >"$TEST_ROOT/gated-run.json" \
    2>"$TEST_ROOT/gated-run.err" &
  run_pid=$!
  for _ in {1..500}; do
    [[ -f "$ready" ]] && break
    sleep 0.01
  done
  run_cli auto-evaluation run --json >"$TEST_ROOT/gated-busy.json" \
    2>"$TEST_ROOT/gated-busy.err"
  run_cli auto-evaluation configure \
    --evaluator flight-recorder-background-evaluator \
    --model serialized-new-model \
    --policy-version default-v1 \
    --uncertainty-score-below 700 \
    --max-evaluations-per-run 1 \
    --max-cost-microusd-per-run 50000 \
    --json >"$TEST_ROOT/gated-configure.json" \
    2>"$TEST_ROOT/gated-configure.err" &
  configure_pid=$!
  sleep 0.1
  if kill -0 "$configure_pid" 2>/dev/null \
    && python3 - "$TEST_ROOT/gated-busy.json" "$STATE" \
      "$capture" <<'PY'
import hashlib
import json
import pathlib
import sys

assert json.loads(pathlib.Path(sys.argv[1]).read_text())["state"] == "busy"
request = json.loads(pathlib.Path(sys.argv[3]).read_text())
ledger = json.loads(
    (pathlib.Path(sys.argv[2]) / "auto-evaluation/attempts.json").read_text()
)
assert ledger["schema_version"] == 2
assert len(ledger["attempts"]) == 1
assert ledger["attempts"][0]["state"] == "pending"
fingerprint_source = {
    "policy_version": "default-v1",
    "episode_id": request["episode"]["episode_id"],
    "evaluator": "flight-recorder-background-evaluator",
    "model": "serialized-old-model",
    "source_evidence_ids": sorted(
        fact["evidence_id"]
        for fact in request["episode"]["deterministic_evidence"]
    ),
}
encoded = json.dumps(
    fingerprint_source, sort_keys=True, separators=(",", ":")
).encode()
assert ledger["attempts"][0]["fingerprint"] == (
    "sha256:" + hashlib.sha256(encoded).hexdigest()
)
PY
  then
    blocked=1
  fi
  touch "$release"
  wait "$run_pid"
  wait "$configure_pid"
  if [[ "$blocked" -eq 1 ]] \
    && python3 - "$STATE" <<'PY'
import json
import pathlib
import sys

config = json.loads(
    (pathlib.Path(sys.argv[1]) / "auto-evaluation/config.json").read_text()
)
assert config["model"] == "serialized-new-model"
assert not (pathlib.Path(sys.argv[1]) / "auto-evaluation/attempts.json").exists()
PY
  then
    pass "実行前reservationを永続化しconfigureをactive runと直列化する"
  else
    fail "実行前reservationを永続化しconfigureをactive runと直列化する"
  fi
}

test_crash_leaves_charge_suppressing_reservation() {
  echo "test_crash_leaves_charge_suppressing_reservation:"
  local ready="$TEST_ROOT/crash.ready"
  local release="$TEST_ROOT/crash.release"
  local counter="$TEST_ROOT/crash.count"
  local output="$TEST_ROOT/crash-retry.json"
  local run_pid
  run_cli auto-evaluation configure \
    --evaluator flight-recorder-background-evaluator \
    --model crash-reservation-model \
    --policy-version default-v1 \
    --uncertainty-score-below 700 \
    --max-evaluations-per-run 1 \
    --max-cost-microusd-per-run 50000 \
    --json >/dev/null 2>&1 || {
      fail "crash reservation fixtureを構成できる"
      return
    }
  FLIGHT_RECORDER_TEST_EVALUATOR_READY="$ready" \
    FLIGHT_RECORDER_TEST_EVALUATOR_RELEASE="$release" \
    FLIGHT_RECORDER_TEST_EVALUATOR_COUNT="$counter" \
    PATH="$FAKE_BIN:$PATH" FLIGHT_RECORDER_STATE_DIR="$STATE" \
    "$CLI" auto-evaluation run --json >"$TEST_ROOT/crash-run.json" \
    2>"$TEST_ROOT/crash-run.err" &
  run_pid=$!
  for _ in {1..500}; do
    [[ -f "$ready" ]] && break
    sleep 0.01
  done
  kill -KILL "$run_pid" 2>/dev/null || true
  touch "$release"
  wait "$run_pid" 2>/dev/null || true
  sleep 0.1
  if FLIGHT_RECORDER_TEST_EVALUATOR_COUNT="$counter" \
    run_cli auto-evaluation run --json >"$output" \
      2>"$TEST_ROOT/crash-retry.err" \
    && [[ "$(cat "$counter")" == "1" ]] \
    && python3 - "$output" "$STATE" <<'PY'
import json
import pathlib
import sys

value = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
ledger = json.loads(
    (pathlib.Path(sys.argv[2]) / "auto-evaluation/attempts.json").read_text()
)
assert value["evaluated_count"] == 0
assert value["attempt_skip_count"] == 1
assert ledger["attempts"][0]["state"] == "pending"
PY
  then
    pass "provider応答前のprocess crash後も同一requestを再課金しない"
  else
    fail "provider応答前のprocess crash後も同一requestを再課金しない"
  fi
}

test_malformed_state_and_unsafe_lock_fail_cleanly() {
  echo "test_malformed_state_and_unsafe_lock_fail_cleanly:"
  local attempts="$STATE/auto-evaluation/attempts.json"
  local lock="$TEST_ROOT/.vault.auto-evaluation.lock"
  local status=0
  run_cli auto-evaluation configure \
    --evaluator flight-recorder-background-evaluator \
    --model malformed-state-model \
    --policy-version default-v1 \
    --uncertainty-score-below 700 \
    --max-evaluations-per-run 1 \
    --max-cost-microusd-per-run 50000 \
    --json >/dev/null 2>&1 || {
      fail "malformed state fixtureを構成できる"
      return
    }
  printf '%s\n' '[]' >"$attempts"
  chmod 600 "$attempts"
  run_cli auto-evaluation run --json >"$TEST_ROOT/malformed.out" \
    2>"$TEST_ROOT/malformed.err" || status=$?
  local malformed_ok=0
  if [[ "$status" -ne 0 && ! -s "$TEST_ROOT/malformed.out" ]] \
    && grep -Fq "attempts are invalid" "$TEST_ROOT/malformed.err" \
    && ! grep -q "Traceback" "$TEST_ROOT/malformed.err"; then
    malformed_ok=1
  fi

  rm -f "$attempts" "$lock"
  mkdir "$lock"
  status=0
  run_cli auto-evaluation run --json >"$TEST_ROOT/unsafe-lock.out" \
    2>"$TEST_ROOT/unsafe-lock.err" || status=$?
  rmdir "$lock"
  if [[ "$malformed_ok" -eq 1 && "$status" -ne 0 \
    && ! -s "$TEST_ROOT/unsafe-lock.out" ]] \
    && grep -Fq "run lock is unavailable or unsafe" \
      "$TEST_ROOT/unsafe-lock.err" \
    && ! grep -q "Traceback" "$TEST_ROOT/unsafe-lock.err"; then
    pass "malformed ledgerとunsafe lockをtracebackなしで拒否する"
  else
    fail "malformed ledgerとunsafe lockをtracebackなしで拒否する"
  fi
}

echo "=== Flight Recorder Background Evaluation Tests ==="
if ! init_fixture; then
  echo "fixture setup failed" >&2
  exit 1
fi
test_configure_is_strict_local_policy
if [[ -f "$STATE/auto-evaluation/config.json" ]]; then
  test_invalid_policy_does_not_mutate_config
  test_run_selects_metadata_only_candidates_idempotently
  test_measured_cost_never_exceeds_run_cap
  test_budget_requires_explicit_v2_cost
  test_custom_policy_requires_owner_file
  test_failure_is_fail_open_and_attempt_bounded
  test_run_reservation_and_configuration_are_serialized
  test_crash_leaves_charge_suppressing_reservation
  test_malformed_state_and_unsafe_lock_fail_cleanly
  test_scheduler_sync_health_is_independent
fi
echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
