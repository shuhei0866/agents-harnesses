#!/usr/bin/env bash
# Production Claude CLI Semantic Receipt evaluator adapter contract.
# The Claude provider is always a local fixture; network access is not required.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ADAPTER="$PLUGIN_DIR/scripts/flight-recorder-claude-semantic-evaluator"
FAKE_CLAUDE_BIN="$SCRIPT_DIR/fixtures/fake-claude-bin"
TEST_ROOT="$(mktemp -d)" || exit 1
[[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]] || exit 1
REQUEST="$TEST_ROOT/request.json"
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

write_request() {
  local destination="$1"
  local budget="${2:-50000}"
  local model="${3:-claude-sonnet-fixture}"
  python3 - "$destination" "$budget" "$model" <<'PY'
import json
import pathlib
import sys

path, budget, model = sys.argv[1:]
value = {
    "schema_version": 2,
    "model": model,
    "rubric": {
        "schema_version": 1,
        "rubric_version": "semantic-receipt-v1",
        "criteria": {
            "goal_achievement": "Whether the requested goal was achieved.",
            "quality": "Whether the result meets the requested quality bar.",
            "efficiency": "Whether execution used reasonable effort.",
        },
        "allowed_states": ["supported", "unsupported", "unknown"],
    },
    "episode": {
        "episode_id": "sha256:" + "0" * 64,
        "time": {
            "first_recorded_at": "2026-07-26T00:00:00Z",
            "last_recorded_at": "2026-07-26T00:00:01Z",
        },
        "event_count": 1,
        "harnesses": ["claude-code"],
        "model_coverage": {
            "state": "complete",
            "models": ["fixture-worker-model"],
        },
        "elapsed_ms": 1000,
        "measured_duration_ms": {"state": "complete", "value": 1000},
        "measured_cost_usd": {"state": "not_recorded", "value": None},
        "retry_count": {"state": "complete", "value": 0},
        "deterministic_outcomes": {
            "success": 1,
            "failure": 0,
            "unknown": 0,
            "not_recorded": 0,
        },
        "deterministic_evidence": [
            {
                "evidence_id": "sha256:" + "1" * 64,
                "evidence_type": "outcome",
                "state": "observed",
                "value": "success",
            },
            {
                "evidence_id": "sha256:" + "0" * 64,
                "evidence_type": "outcome",
                "state": "observed",
                "value": "success",
            },
        ],
    },
    "source": {
        "adapter": "claude-code",
        "start_line": 2,
        "end_line": 5,
        "content_sha256": "sha256:" + "2" * 64,
        "span_sha256": "sha256:" + "3" * 64,
        "content": "RAW_SOURCE_CANARY_iam178\nA bounded private source span.",
    },
    "remaining_cost_microusd": int(budget),
}
pathlib.Path(path).write_text(
    json.dumps(value, sort_keys=True, separators=(",", ":")),
    encoding="utf-8",
)
PY
  local status=$?
  if [[ "$status" -ne 0 ]]; then
    fail "テストfixture生成に失敗した: $destination"
    exit 1
  fi
}

run_adapter() {
  local mode="$1" capture="$2" stdin_path="$3"
  shift 3
  mkdir -p "$capture/bin"
  cp "$FAKE_CLAUDE_BIN/claude" "$capture/bin/claude"
  PATH="$FAKE_CLAUDE_BIN:/usr/bin:/bin" \
    FLIGHT_RECORDER_TEST_HARNESS=1 \
    FLIGHT_RECORDER_TEST_CLAUDE_EXECUTABLE="$capture/bin/claude" \
    FLIGHT_RECORDER_TEST_CLAUDE_CAPTURE_DIR="$capture" \
    FLIGHT_RECORDER_TEST_CLAUDE_MODE="$mode" \
    "$@" "$ADAPTER" <"$stdin_path"
}

assert_fail_closed() {
  local description="$1" mode="$2" stdin_path="$3"
  local suffix="$4"
  local provider_expected="${5:-yes}"
  local capture="$TEST_ROOT/capture-$suffix"
  local output="$TEST_ROOT/$suffix.out"
  local error="$TEST_ROOT/$suffix.err"
  local status=0
  run_adapter "$mode" "$capture" "$stdin_path" \
    >"$output" 2>"$error" || status=$?
  local provider_observed=no
  [[ -f "$capture/argv.json" ]] && provider_observed=yes
  if [[ "$status" -ne 0 && ! -s "$output" ]] \
    && ! grep -q "Traceback" "$error" \
    && ! grep -q "RAW_SOURCE_CANARY_iam178" "$error" \
    && [[ "$provider_observed" == "$provider_expected" ]]; then
    pass "$description"
  else
    fail "$description"
  fi
}

test_protocol_v2_and_safe_claude_invocation() {
  echo "test_protocol_v2_and_safe_claude_invocation:"
  local capture="$TEST_ROOT/capture-valid"
  local output="$TEST_ROOT/valid.out"
  local error="$TEST_ROOT/valid.err"
  write_request "$REQUEST"
  if run_adapter valid "$capture" "$REQUEST" \
      >"$output" 2>"$error" \
    && [[ ! -s "$error" ]] \
    && python3 - "$output" "$capture" "$REQUEST" <<'PY'
import decimal
import json
import os
import pathlib
import pwd
import sys

output_path, capture_path, request_path = map(pathlib.Path, sys.argv[1:])
value = json.loads(output_path.read_text(encoding="utf-8"))
argv = json.loads((capture_path / "argv.json").read_text(encoding="utf-8"))
child_env = json.loads(
    (capture_path / "env.json").read_text(encoding="utf-8")
)
provider_stdin = (capture_path / "stdin.txt").read_text(encoding="utf-8")
request = json.loads(request_path.read_text(encoding="utf-8"))

assert set(value) == {
    "schema_version",
    "measured_cost_microusd",
    "task",
    "execution",
    "result",
    "assessment",
}
assert value["schema_version"] == 2
# 0.012345000001 USD is 12345.000001 micro-USD: always round upward.
assert value["measured_cost_microusd"] == 12346
assert value["task"]["type"] == "bug_fix"
assert value["assessment"]["confidence"] == "high"
serialized = json.dumps(value, sort_keys=True)
assert "RAW_SOURCE_CANARY_iam178" not in serialized
assert str(request_path) not in serialized

def option(name):
    index = argv.index(name)
    return argv[index + 1]

assert "--print" in argv or "-p" in argv
assert option("--output-format") == "json"
assert "--safe-mode" in argv
assert child_env["FLIGHT_RECORDER_EVALUATOR_CHILD"] == "1"
assert child_env["USER"] == pwd.getpwuid(os.geteuid()).pw_name
assert child_env["LOGNAME"] == child_env["USER"]
assert option("--tools") == ""
assert "--no-session-persistence" in argv
assert "--disable-slash-commands" in argv
assert "--strict-mcp-config" in argv
assert option("--model") == request["model"]
budget_usd = decimal.Decimal(option("--max-budget-usd"))
assert budget_usd * decimal.Decimal(1_000_000) <= decimal.Decimal(
    request["remaining_cost_microusd"]
)
assert budget_usd == decimal.Decimal("0.05")
schema = json.loads(option("--json-schema"))
assert schema["type"] == "object"
assert schema["additionalProperties"] is False
assert set(schema["required"]) == {
    "schema_version", "task", "execution", "result", "assessment",
}
assert schema["properties"]["schema_version"]["const"] == 1
assert schema["properties"]["execution"]["properties"]["model"]["pattern"].startswith(
    "^[A-Za-z0-9]"
)
provider_request = json.loads(provider_stdin)
assert provider_request["source"]["content"] == request["source"]["content"]
assert provider_request["model"] == request["model"]
assert request["source"]["content"] not in json.dumps(argv)
PY
  then
    pass "request v2をsafe/tool-less/nonpersistent Claude JSON schema呼出しへ変換する"
    pass "provider実測USD costをinteger micro-USDへ上向き丸めする"
    pass "raw sourceをresponse・argvへechoしない"
  else
    cat "$error" >&2
    fail "request v2をsafe/tool-less/nonpersistent Claude JSON schema呼出しへ変換する"
    fail "provider実測USD costをinteger micro-USDへ上向き丸めする"
    fail "raw sourceをresponse・argvへechoしない"
  fi
}

test_invalid_and_oversized_input_fail_closed() {
  echo "test_invalid_and_oversized_input_fail_closed:"
  local malformed="$TEST_ROOT/malformed.json"
  local v1="$TEST_ROOT/v1.json"
  local zero="$TEST_ROOT/zero-budget.json"
  local unsafe_model="$TEST_ROOT/unsafe-model.json"
  local oversized="$TEST_ROOT/oversized.json"
  printf '%s' '{"schema_version":2,"source":' >"$malformed"
  write_request "$v1"
  python3 - "$v1" <<'PY'
import json
import pathlib
import sys
path = pathlib.Path(sys.argv[1])
value = json.loads(path.read_text())
value["schema_version"] = 1
path.write_text(json.dumps(value))
PY
  write_request "$zero" 0
  write_request "$unsafe_model" 50000 "--dangerously-skip-permissions"
  python3 - "$oversized" <<'PY'
import pathlib
import sys
pathlib.Path(sys.argv[1]).write_bytes(b"{" + b"x" * (2 * 1024 * 1024))
PY
  assert_fail_closed "malformed requestをprovider実行前に拒否する" \
    valid "$malformed" malformed-input no
  assert_fail_closed "protocol v1 requestをprovider実行前に拒否する" \
    valid "$v1" protocol-v1 no
  assert_fail_closed "zero budgetをprovider実行前に拒否する" \
    valid "$zero" zero-budget no
  assert_fail_closed "option形式のmodelをprovider実行前に拒否する" \
    valid "$unsafe_model" unsafe-model no
  assert_fail_closed "oversized requestをbounded readで拒否する" \
    valid "$oversized" oversized-input no
}

test_normalizes_worker_contract_fields() {
  echo "test_normalizes_worker_contract_fields:"
  local capture="$TEST_ROOT/capture-normalized"
  local output="$TEST_ROOT/normalized.out"
  local error="$TEST_ROOT/normalized.err"
  write_request "$REQUEST"
  if run_adapter unordered-references "$capture" "$REQUEST" \
      >"$output" 2>"$error" \
    && python3 - "$output" <<'PY'
import json
import pathlib
import sys

value = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
for criterion in value["assessment"]["criteria"].values():
    references = criterion["evidence_references"]
    assert references == sorted(set(references))
PY
  then
    pass "evidence referencesをworker契約のcanonical順へ正規化する"
  else
    cat "$error" >&2
    fail "evidence referencesをworker契約のcanonical順へ正規化する"
  fi
  assert_fail_closed "unsafeなexecution modelをpaid responseとして返さない" \
    unsafe-execution-model "$REQUEST" unsafe-execution-model
}

test_provider_failures_and_budget_fail_closed() {
  echo "test_provider_failures_and_budget_fail_closed:"
  write_request "$REQUEST"
  assert_fail_closed "provider nonzeroをraw stderr非公開で拒否する" \
    nonzero "$REQUEST" provider-nonzero
  assert_fail_closed "provider invalid JSONを拒否する" \
    invalid-json "$REQUEST" provider-invalid-json
  assert_fail_closed "provider schema違反を拒否する" \
    invalid-schema "$REQUEST" provider-invalid-schema
  assert_fail_closed "provider oversized stdoutをbounded readで拒否する" \
    oversized "$REQUEST" provider-oversized
  assert_fail_closed "provider invalid cost typeを拒否する" \
    invalid-cost "$REQUEST" provider-invalid-cost
  assert_fail_closed "providerの実測over-budgetを安全側で拒否する" \
    over-budget "$REQUEST" provider-over-budget
  assert_fail_closed "providerによるraw source echoを拒否する" \
    echo-source "$REQUEST" provider-source-echo
}

echo "=== Flight Recorder Claude Semantic Evaluator Adapter Tests ==="
if [[ ! -x "$ADAPTER" ]]; then
  fail "production Claude semantic evaluator adapterが実行可能である"
  echo
  echo "Results: $PASS passed, $FAIL failed"
  exit 1
fi
test_protocol_v2_and_safe_claude_invocation
test_invalid_and_oversized_input_fail_closed
test_normalizes_worker_contract_fields
test_provider_failures_and_budget_fail_closed

echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
