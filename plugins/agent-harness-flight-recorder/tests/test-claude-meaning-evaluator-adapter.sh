#!/usr/bin/env bash
# Production Claude CLI Meaning Card evaluator adapter contract.
# Claude is always a local fixture; network access is not required.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ADAPTER="$PLUGIN_DIR/scripts/flight-recorder-claude-meaning-evaluator"
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
  local variant="${3:-valid}"
  python3 - "$destination" "$budget" "$variant" <<'PY'
import hashlib
import json
import pathlib
import sys

path, budget, variant = sys.argv[1:]
evidence = [
    {
        "evidence_id": "sha256:" + "1" * 64,
        "kind": "intent_prompt",
        "content": "Diagnose the bounded failing behavior.",
    },
    {
        "evidence_id": "sha256:" + "2" * 64,
        "kind": "final_response",
        "content": "The bounded change and verification completed.",
    },
]
if variant == "too-many-evidence":
    evidence = [
        {
            "evidence_id": "sha256:" + format(index + 1, "064x"),
            "kind": "deterministic_fact",
            "content": f"fact-{index}",
        }
        for index in range(9)
    ]
elif variant == "long-content":
    evidence[0]["content"] = "x" * 2049
elif variant == "private":
    evidence[0]["content"] = (
        "/Users/private/customer-project "
        "sk-test-secret-meaning-adapter"
    )

packet_body = {
    "schema_version": 1,
    "contract_version": "meaning-packet-v1",
    "adapter": "codex",
    "evidence": evidence,
}
packet = {
    **packet_body,
    "packet_sha256": (
        "sha256:"
        + hashlib.sha256(
            json.dumps(
                packet_body, sort_keys=True, separators=(",", ":")
            ).encode()
        ).hexdigest()
    ),
}
value = {
    "schema_version": 2,
    "model": "claude-sonnet-fixture",
    "packet": packet,
    "remaining_cost_microusd": int(budget),
}
pathlib.Path(path).write_text(
    json.dumps(value, sort_keys=True, separators=(",", ":")),
    encoding="utf-8",
)
PY
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
  local status=0 provider_observed=no
  run_adapter "$mode" "$capture" "$stdin_path" \
    >"$output" 2>"$error" || status=$?
  [[ -f "$capture/argv.json" ]] && provider_observed=yes
  if [[ "$status" -ne 0 && ! -s "$output" ]] \
    && ! grep -q "Traceback" "$error" \
    && ! grep -q "/Users/private" "$error" \
    && ! grep -q "sk-test-secret-meaning-adapter" "$error" \
    && [[ "$provider_observed" == "$provider_expected" ]]; then
    pass "$description"
  else
    fail "$description"
  fi
}

test_packet_v2_becomes_safe_compact_meaning_call() {
  echo "test_packet_v2_becomes_safe_compact_meaning_call:"
  local capture="$TEST_ROOT/capture-valid"
  local output="$TEST_ROOT/valid.out"
  local error="$TEST_ROOT/valid.err"
  write_request "$REQUEST"
  if run_adapter meaning-valid "$capture" "$REQUEST" \
      >"$output" 2>"$error" \
    && [[ ! -s "$error" ]] \
    && python3 - "$output" "$capture" "$REQUEST" <<'PY'
import decimal
import json
import pathlib
import sys

output_path, capture_path, request_path = map(pathlib.Path, sys.argv[1:])
value = json.loads(output_path.read_text(encoding="utf-8"))
argv = json.loads((capture_path / "argv.json").read_text(encoding="utf-8"))
child_env = json.loads(
    (capture_path / "env.json").read_text(encoding="utf-8")
)
provider_request = json.loads(
    (capture_path / "stdin.txt").read_text(encoding="utf-8")
)
request = json.loads(request_path.read_text(encoding="utf-8"))
meaning_fields = {
    "intent", "deliverable", "verification", "outcome", "reusable_learning"
}
assert set(value) == {
    "schema_version",
    *meaning_fields,
    "confidence",
    "measured_cost_microusd",
}
assert value["schema_version"] == 2
assert value["measured_cost_microusd"] == 12346
assert value["confidence"] in {"low", "medium", "high"}
packet_evidence_ids = {
    item["evidence_id"] for item in request["packet"]["evidence"]
}
for name in meaning_fields:
    expected = (
        {"state", "summary", "evidence_references"}
        if name == "outcome"
        else {"summary", "evidence_references"}
    )
    assert set(value[name]) == expected
    assert set(value[name]["evidence_references"]).issubset(
        packet_evidence_ids
    )

def option(name):
    index = argv.index(name)
    return argv[index + 1]

assert "--print" in argv or "-p" in argv
assert "--safe-mode" in argv
assert option("--tools") == ""
assert "--no-session-persistence" in argv
assert "--disable-slash-commands" in argv
assert "--strict-mcp-config" in argv
assert option("--output-format") == "json"
assert option("--model") == request["model"]
assert child_env["FLIGHT_RECORDER_EVALUATOR_CHILD"] == "1"
assert decimal.Decimal(option("--max-budget-usd")) == decimal.Decimal("0.05")
schema = json.loads(option("--json-schema"))
assert schema["type"] == "object"
assert schema["additionalProperties"] is False
assert set(schema["required"]) == {
    "schema_version",
    *meaning_fields,
    "confidence",
}
assert schema["properties"]["schema_version"]["const"] == 1
for name in meaning_fields:
    references = schema["properties"][name]["properties"][
        "evidence_references"
    ]
    assert set(references["items"]["enum"]) == packet_evidence_ids
assert set(provider_request) == {
    "schema_version",
    "model",
    "packet",
    "remaining_cost_microusd",
}
assert provider_request == request
assert request["packet"]["evidence"][0]["content"] not in json.dumps(argv)
PY
  then
    pass "packet-only v2をsafe/tool-less/nonpersistent Meaning schema呼出しへ変換する"
    pass "固定5意味字段・confidence・実測costだけをresponse v2へ返す"
  else
    cat "$error" >&2
    fail "packet-only v2をsafe/tool-less/nonpersistent Meaning schema呼出しへ変換する"
    fail "固定5意味字段・confidence・実測costだけをresponse v2へ返す"
  fi
}

test_bounds_references_and_budget_fail_closed() {
  echo "test_bounds_references_and_budget_fail_closed:"
  local malformed="$TEST_ROOT/malformed.json"
  local oversized="$TEST_ROOT/oversized.json"
  local too_many="$TEST_ROOT/too-many.json"
  local long_content="$TEST_ROOT/long-content.json"
  printf '%s' '{"schema_version":2,"packet":' >"$malformed"
  python3 - "$oversized" <<'PY'
import pathlib
import sys
pathlib.Path(sys.argv[1]).write_bytes(b"{" + b"x" * (2 * 1024 * 1024))
PY
  write_request "$too_many" 50000 too-many-evidence
  write_request "$long_content" 50000 long-content
  assert_fail_closed "malformed requestをprovider前に拒否する" \
    meaning-valid "$malformed" malformed no
  assert_fail_closed "oversized requestをbounded readで拒否する" \
    meaning-valid "$oversized" oversized no
  assert_fail_closed "9件超のpacket evidenceをprovider前に拒否する" \
    meaning-valid "$too_many" too-many no
  assert_fail_closed "2048文字超のpacket contentをprovider前に拒否する" \
    meaning-valid "$long_content" long-content no
  write_request "$REQUEST"
  assert_fail_closed "packet外evidence referenceを拒否する" \
    meaning-invalid-ref "$REQUEST" invalid-ref
  assert_fail_closed "providerの実測over-budgetを拒否する" \
    meaning-over-budget "$REQUEST" over-budget
}

test_private_values_never_reach_argv_stdout_or_stderr() {
  echo "test_private_values_never_reach_argv_stdout_or_stderr:"
  local private_request="$TEST_ROOT/private.json"
  local capture="$TEST_ROOT/capture-private"
  local output="$TEST_ROOT/private.out"
  local error="$TEST_ROOT/private.err"
  local status=0
  write_request "$private_request" 50000 private
  run_adapter nonzero "$capture" "$private_request" \
    >"$output" 2>"$error" || status=$?
  if [[ "$status" -ne 0 && ! -s "$output" ]] \
    && [[ "$(cat "$error")" == \
      "flight recorder Claude meaning evaluator failed" ]] \
    && { [[ ! -f "$capture/argv.json" ]] \
      || ! grep -Eq \
        '/Users/private|sk-test-secret-meaning-adapter' \
        "$capture/argv.json"; }; then
    pass "raw path/secretをargv・stdout・stderrへ公開しない"
  else
    fail "raw path/secretをargv・stdout・stderrへ公開しない"
  fi
  write_request "$REQUEST"
  assert_fail_closed "providerによるraw path/secret echoを拒否する" \
    meaning-echo "$REQUEST" meaning-echo
}

test_timeout_kills_provider_process_group() {
  echo "test_timeout_kills_provider_process_group:"
  local capture="$TEST_ROOT/capture-timeout"
  local output="$TEST_ROOT/timeout.out"
  local error="$TEST_ROOT/timeout.err"
  local status=0
  write_request "$REQUEST"
  run_adapter slow "$capture" "$REQUEST" \
    env FLIGHT_RECORDER_TEST_CLAUDE_TIMEOUT_SECONDS=1 \
    >"$output" 2>"$error" || status=$?
  sleep 3
  if [[ "$status" -eq 1 && ! -s "$output" ]] \
    && [[ ! -e "$capture/slow-child-finished" ]] \
    && [[ "$(cat "$error")" == \
      "flight recorder Claude meaning evaluator failed" ]]; then
    pass "timeoutでprovider process groupを停止し固定stderrだけを返す"
  else
    fail "timeoutでprovider process groupを停止し固定stderrだけを返す"
  fi
}

echo "=== Flight Recorder Claude Meaning Evaluator Adapter Tests ==="
if [[ ! -x "$ADAPTER" ]]; then
  fail "production Claude Meaning evaluator adapterが実行可能である"
  echo
  echo "Results: $PASS passed, $FAIL failed"
  exit 1
fi
test_packet_v2_becomes_safe_compact_meaning_call
test_bounds_references_and_budget_fail_closed
test_private_values_never_reach_argv_stdout_or_stderr
test_timeout_kills_provider_process_group

echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
