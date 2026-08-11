#!/usr/bin/env bash
# Production Claude CLI Value Compiler evaluator adapter contract.
# Claude is always a local fixture; network access is not required.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ADAPTER="$PLUGIN_DIR/scripts/flight-recorder-claude-value-evaluator"
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
anchor = "sha256:" + "a" * 64
receipt = "sha256:" + "b" * 64
evidence = [
    {
        "evidence_id": "sha256:" + "1" * 64,
        "source": "meaning_card",
        "anchor_id": anchor,
        "field": "meaning.outcome",
        "content": {
            "state": "success",
            "summary": "The requested bounded change completed successfully.",
        },
    },
    {
        "evidence_id": "sha256:" + "2" * 64,
        "source": "meaning_card",
        "anchor_id": anchor,
        "field": "meaning.verification",
        "content": {
            "summary": "PRIVATE_VALUE_COPY_CANARY_verified_exactly_once_123456789",
        },
    },
    {
        "evidence_id": "sha256:" + "3" * 64,
        "source": "meaning_card",
        "anchor_id": anchor,
        "field": "meaning.reusable_learning",
        "content": {
            "summary": "A bounded evidence packet improves repeatable evaluation.",
        },
    },
    {
        "evidence_id": "sha256:" + "4" * 64,
        "source": "meaning_card",
        "anchor_id": anchor,
        "field": "meaning.deliverable",
        "content": {"summary": "A verified repository change."},
    },
    {
        "evidence_id": "sha256:" + "5" * 64,
        "source": "semantic_receipt",
        "anchor_id": receipt,
        "field": "receipt.assessment.efficiency",
        "content": {"state": "supported"},
    },
    {
        "evidence_id": "sha256:" + "6" * 64,
        "source": "semantic_receipt",
        "anchor_id": receipt,
        "field": "receipt.task.deliverable",
        "content": "A bounded implementation with verified behavior.",
    },
]
observations = {
    "measured_duration_ms": {
        "value": 1200,
        "state": "complete",
        "aggregation": "sum_of_recorded_values",
        "known_event_count": 1,
        "total_event_count": 1,
    },
    "measured_cost_usd": {
        "value": None,
        "state": "missing",
        "aggregation": "sum_of_recorded_values",
        "known_event_count": 0,
        "total_event_count": 1,
    },
    "deterministic_outcomes": {
        "success": 1,
        "failure": 0,
        "unknown": 0,
        "not_recorded": 0,
        "evidence": [
            {
                "event_id": "12345678-1234-4234-8234-123456789abc",
                "status": "success",
                "exit_code": 0,
            },
        ],
    },
    "deterministic_evidence": [
        {
            "evidence_id": "sha256:" + "9" * 64,
            "evidence_type": "outcome",
            "state": "success",
        },
    ],
}
body = {
    "contract_version": "value-compiler-packet-v1",
    "episode_id": "sha256:" + "0" * 64,
    "anchor_ids": [anchor, receipt],
    "evidence": evidence,
    "observations": observations,
}
packet = {
    **body,
    "packet_sha256": "sha256:" + hashlib.sha256(
        json.dumps(body, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest(),
}
if variant == "bad-packet-hash":
    packet["packet_sha256"] = "sha256:" + "f" * 64
value = {
    "schema_version": 1,
    "model": "claude-sonnet-fixture",
    "packet": packet,
    "remaining_cost_microusd": int(budget),
}
if variant == "extra-request-field":
    value["prompt"] = "unsafe ambient instruction"
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
  local description="$1" mode="$2" stdin_path="$3" suffix="$4"
  local provider_expected="${5:-yes}"
  local capture="$TEST_ROOT/capture-$suffix"
  local output="$TEST_ROOT/$suffix.out"
  local error="$TEST_ROOT/$suffix.err"
  local status=0 provider_observed=no
  run_adapter "$mode" "$capture" "$stdin_path" \
    >"$output" 2>"$error" || status=$?
  [[ -f "$capture/argv.json" ]] && provider_observed=yes
  if [[ "$status" -ne 0 && ! -s "$output" ]] \
    && [[ "$(cat "$error")" == \
      "flight recorder Claude value evaluator failed" ]] \
    && ! grep -q "Traceback" "$error" \
    && ! grep -q "PRIVATE_VALUE_COPY_CANARY" "$error" \
    && [[ "$provider_observed" == "$provider_expected" ]]; then
    pass "$description"
  else
    fail "$description"
  fi
}

test_bundled_evaluator_registration() {
  echo "test_bundled_evaluator_registration:"
  if PYTHONPATH="$PLUGIN_DIR/scripts" python3 - "$ADAPTER" <<'PY'
import pathlib
import sys

from evaluation import BUNDLED_EVALUATORS, _executable_identity

expected = pathlib.Path(sys.argv[1]).resolve()
name = "flight-recorder-claude-value-evaluator"
assert name in BUNDLED_EVALUATORS
resolved, digest = _executable_identity(name)
assert resolved == expected
assert digest.startswith("sha256:") and len(digest) == 71
PY
  then
    pass "Claude Value evaluatorをbundled identityとして解決する"
  else
    fail "Claude Value evaluatorをbundled identityとして解決する"
  fi
}

test_value_compile_timeout_layers_enclose_inner_provider() {
  echo "test_value_compile_timeout_layers_enclose_inner_provider:"
  if PYTHONPATH="$PLUGIN_DIR/scripts" python3 - \
      "$PLUGIN_DIR/scripts/flight-recorder-claude-semantic-evaluator" <<'PY'
import ast
import pathlib
import sys

from vault import parser

shared_path = pathlib.Path(sys.argv[1])
tree = ast.parse(shared_path.read_text(encoding="utf-8"))
inner = None
for node in tree.body:
    if (
        isinstance(node, ast.Assign)
        and len(node.targets) == 1
        and isinstance(node.targets[0], ast.Name)
        and node.targets[0].id == "DEFAULT_TIMEOUT_SECONDS"
        and isinstance(node.value, ast.Constant)
        and isinstance(node.value.value, int)
    ):
        inner = node.value.value
        break
assert inner == 180
args = parser().parse_args([
    "value", "compile",
    "--evaluator", "flight-recorder-claude-value-evaluator",
    "--model", "claude-sonnet-fixture",
    "--max-episodes", "1",
    "--max-cost-microusd", "50000",
])
outer = args.timeout
assert outer == 240
assert inner < outer <= 300
assert outer - inner >= 60
PY
  then
    pass "value compile outer=240秒をshared provider inner=180秒の後に置く"
  else
    fail "value compile outer=240秒をshared provider inner=180秒の後に置く"
  fi
}

test_shared_helper_tamper_fails_before_provider_and_binds_fingerprint() {
  echo "test_shared_helper_tamper_fails_before_provider_and_binds_fingerprint:"
  local isolated="$TEST_ROOT/isolated-shared-helper"
  local capture="$TEST_ROOT/capture-shared-helper-tamper"
  local copied_adapter="$isolated/flight-recorder-claude-value-evaluator"
  local copied_helper="$isolated/flight-recorder-claude-semantic-evaluator"
  local output="$TEST_ROOT/shared-helper-tamper.out"
  local error="$TEST_ROOT/shared-helper-tamper.err"
  local status=0
  mkdir -p "$isolated" "$capture/bin"
  cp "$ADAPTER" "$copied_adapter"
  cp "$PLUGIN_DIR/scripts/flight-recorder-claude-semantic-evaluator" \
    "$copied_helper"
  cp "$FAKE_CLAUDE_BIN/claude" "$capture/bin/claude"
  python3 - "$copied_helper" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
path.write_bytes(path.read_bytes() + b"\n# isolated helper tamper\n")
PY
  write_request "$REQUEST"
  PATH="$FAKE_CLAUDE_BIN:/usr/bin:/bin" \
    FLIGHT_RECORDER_TEST_HARNESS=1 \
    FLIGHT_RECORDER_TEST_CLAUDE_EXECUTABLE="$capture/bin/claude" \
    FLIGHT_RECORDER_TEST_CLAUDE_CAPTURE_DIR="$capture" \
    FLIGHT_RECORDER_TEST_CLAUDE_MODE=value-valid \
    "$copied_adapter" <"$REQUEST" >"$output" 2>"$error" || status=$?
  if [[ "$status" -eq 1 && ! -s "$output" ]] \
    && [[ ! -e "$capture/argv.json" ]] \
    && [[ "$(cat "$error")" == \
      "flight recorder Claude value evaluator failed" ]]; then
    pass "shared helper改変をprovider前に固定stderrでfail closedする"
  else
    fail "shared helper改変をprovider前に固定stderrでfail closedする"
  fi

  if PYTHONPATH="$PLUGIN_DIR/scripts" python3 - \
      "$ADAPTER" \
      "$PLUGIN_DIR/scripts/flight-recorder-claude-semantic-evaluator" \
      "$copied_helper" "$isolated" <<'PY'
import ast
import hashlib
import pathlib
import stat
import sys

from evaluation import _executable_identity

adapter, helper, changed_helper, isolated = map(pathlib.Path, sys.argv[1:])
tree = ast.parse(adapter.read_text(encoding="utf-8"))
declared = None
for node in tree.body:
    if (
        isinstance(node, ast.Assign)
        and len(node.targets) == 1
        and isinstance(node.targets[0], ast.Name)
        and node.targets[0].id == "SHARED_ADAPTER_SHA256"
    ):
        declared = ast.literal_eval(node.value)
        break
assert isinstance(declared, str) and len(declared) == 64
current_helper_digest = hashlib.sha256(helper.read_bytes()).hexdigest()
changed_helper_digest = hashlib.sha256(changed_helper.read_bytes()).hexdigest()
assert declared == current_helper_digest
assert changed_helper_digest != declared

original_bytes = adapter.read_bytes()
assert original_bytes.count(declared.encode()) == 1
updated_bytes = original_bytes.replace(
    declared.encode(), changed_helper_digest.encode(), 1
)
updated = isolated / "simulated-updated-value-evaluator"
updated.write_bytes(updated_bytes)
updated.chmod(stat.S_IMODE(adapter.stat().st_mode))
_original_path, original_fingerprint = _executable_identity(str(adapter))
_updated_path, updated_fingerprint = _executable_identity(str(updated))
assert original_fingerprint != updated_fingerprint
PY
  then
    pass "helper hash更新をValue adapter fingerprint変更へ間接拘束する"
  else
    fail "helper hash更新をValue adapter fingerprint変更へ間接拘束する"
  fi
}

test_verified_helper_bytes_are_the_only_executed_source() {
  echo "test_verified_helper_bytes_are_the_only_executed_source:"
  local isolated="$TEST_ROOT/isolated-helper-toctou"
  local marker="$TEST_ROOT/unverified-helper-executed"
  mkdir -p "$isolated"
  cp "$ADAPTER" "$isolated/flight-recorder-claude-value-evaluator"
  cp "$PLUGIN_DIR/scripts/flight-recorder-claude-semantic-evaluator" \
    "$isolated/flight-recorder-claude-semantic-evaluator"
  if python3 - \
      "$isolated/flight-recorder-claude-value-evaluator" \
      "$isolated/flight-recorder-claude-semantic-evaluator" \
      "$marker" <<'PY'
import os
import importlib.machinery
import pathlib
import runpy
import sys

adapter, helper, marker = map(pathlib.Path, sys.argv[1:])
verified = helper.read_bytes()
replacement = helper.with_name(helper.name + ".replacement")
replacement.write_bytes(
    verified
    + (
        "\nimport pathlib as _value_test_pathlib\n"
        f"_value_test_pathlib.Path({str(marker)!r}).write_text("
        "'unverified path bytes executed', encoding='utf-8')\n"
    ).encode("utf-8")
)
original_exec_module = importlib.machinery.SourceFileLoader.exec_module


def swap_before_loader_rereads_path(loader, module):
    if pathlib.Path(loader.path).resolve() == helper.resolve():
        os.replace(replacement, helper)
    return original_exec_module(loader, module)


importlib.machinery.SourceFileLoader.exec_module = swap_before_loader_rereads_path
try:
    namespace = runpy.run_path(str(adapter), run_name="_isolated_value_adapter")
    shared = namespace["_shared_adapter"]()
finally:
    importlib.machinery.SourceFileLoader.exec_module = original_exec_module
assert shared.AdapterError is not None
assert not marker.exists(), "helper path was reopened after digest verification"
PY
  then
    pass "digest検証済みhelper bytesだけをcompileしてpath差替えを実行しない"
  else
    fail "digest検証済みhelper bytesだけをcompileしてpath差替えを実行しない"
  fi
}

test_short_enum_tokens_do_not_trigger_raw_prose_copy_rule() {
  echo "test_short_enum_tokens_do_not_trigger_raw_prose_copy_rule:"
  local capture="$TEST_ROOT/capture-enum-prose"
  local output="$TEST_ROOT/enum-prose.out"
  local error="$TEST_ROOT/enum-prose.err"
  write_request "$REQUEST"
  if run_adapter value-enum-prose "$capture" "$REQUEST" \
      >"$output" 2>"$error" \
    && [[ ! -s "$error" ]] \
    && python3 - "$output" <<'PY'
import json
import pathlib
import sys

value = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
goal = value["primitives"]["goal_achievement"]["summary"]
quality = value["primitives"]["deliverable_quality"]["summary"]
assert "success" in goal
assert "supported" in quality
PY
  then
    pass "enum state success/supportedを正当なparaphrase summary内で許容する"
  else
    cat "$error" >&2
    fail "enum state success/supportedを正当なparaphrase summary内で許容する"
  fi
}

test_deliverable_quality_matches_compiler_evidence_allowlist() {
  echo "test_deliverable_quality_matches_compiler_evidence_allowlist:"
  local capture="$TEST_ROOT/capture-deliverable-parity"
  local output="$TEST_ROOT/deliverable-parity.out"
  local error="$TEST_ROOT/deliverable-parity.err"
  write_request "$REQUEST"
  if run_adapter value-deliverable-parity "$capture" "$REQUEST" \
      >"$output" 2>"$error" \
    && [[ ! -s "$error" ]] \
    && python3 - "$output" "$capture" "$REQUEST" <<'PY'
import json
import pathlib
import sys

output_path, capture_path, request_path = map(pathlib.Path, sys.argv[1:])
value = json.loads(output_path.read_text(encoding="utf-8"))
request = json.loads(request_path.read_text(encoding="utf-8"))
argv = json.loads((capture_path / "argv.json").read_text(encoding="utf-8"))
schema = json.loads(argv[argv.index("--json-schema") + 1])
ids = {
    item["field"]: item["evidence_id"]
    for item in request["packet"]["evidence"]
}
expected = {
    ids["meaning.deliverable"],
    ids["meaning.verification"],
    ids["receipt.task.deliverable"],
}
quality_schema = schema["properties"]["primitives"]["properties"][
    "deliverable_quality"
]
encoded = json.dumps(quality_schema, sort_keys=True)
assert all(reference in encoded for reference in expected)
refs = value["primitives"]["deliverable_quality"]["evidence_references"]
assert refs == sorted({
    ids["meaning.deliverable"], ids["receipt.task.deliverable"],
})
PY
  then
    pass "deliverable quality schema/validatorをCompiler evidence allowlistへ揃える"
  else
    cat "$error" >&2
    fail "deliverable quality schema/validatorをCompiler evidence allowlistへ揃える"
  fi
}

test_value_packet_becomes_safe_axis_grounded_call() {
  echo "test_value_packet_becomes_safe_axis_grounded_call:"
  local capture="$TEST_ROOT/capture-valid"
  local output="$TEST_ROOT/valid.out"
  local error="$TEST_ROOT/valid.err"
  write_request "$REQUEST"
  if run_adapter value-valid "$capture" "$REQUEST" \
      >"$output" 2>"$error" \
    && [[ ! -s "$error" ]] \
    && python3 - "$output" "$capture" "$REQUEST" <<'PY'
import decimal
import json
import pathlib
import sys

output_path, capture_path, request_path = map(pathlib.Path, sys.argv[1:])
value = json.loads(output_path.read_text(encoding="utf-8"))
request = json.loads(request_path.read_text(encoding="utf-8"))
argv = json.loads((capture_path / "argv.json").read_text(encoding="utf-8"))
child_env = json.loads((capture_path / "env.json").read_text(encoding="utf-8"))
provider_request = json.loads(
    (capture_path / "stdin.txt").read_text(encoding="utf-8")
)
axes = {
    "goal_achievement",
    "deliverable_quality",
    "risk_reduction",
    "learning",
    "reuse_potential",
    "decision_leverage",
    "attention_saved",
    "rework",
}
assert set(value) == {"schema_version", "primitives", "measured_cost_microusd"}
assert value["schema_version"] == 1
assert value["measured_cost_microusd"] == 12346
assert set(value["primitives"]) == axes
for item in value["primitives"].values():
    assert set(item) == {
        "state", "summary", "confidence", "evidence_references",
    }
    assert "basis" not in item
for axis in {
    "risk_reduction", "decision_leverage", "attention_saved", "rework",
}:
    assert value["primitives"][axis]["state"] == "unknown"
    assert value["primitives"][axis]["evidence_references"] == []

def option(name):
    return argv[argv.index(name) + 1]

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
assert provider_request == request
schema = json.loads(option("--json-schema"))
assert schema["type"] == "object"
assert schema["additionalProperties"] is False
assert set(schema["required"]) == {"schema_version", "primitives"}
assert schema["properties"]["schema_version"]["const"] == 1
primitive_schemas = schema["properties"]["primitives"]["properties"]
assert set(primitive_schemas) == axes
evidence_by_field = {
    item["field"]: item["evidence_id"]
    for item in request["packet"]["evidence"]
}
allowed = {
    "goal_achievement": {evidence_by_field["meaning.outcome"]},
    "deliverable_quality": {
        evidence_by_field["meaning.deliverable"],
        evidence_by_field["meaning.verification"],
        evidence_by_field["receipt.task.deliverable"],
    },
    "risk_reduction": set(),
    "learning": {evidence_by_field["meaning.reusable_learning"]},
    "reuse_potential": {evidence_by_field["meaning.reusable_learning"]},
    "decision_leverage": set(),
    "attention_saved": set(),
    "rework": set(),
}
all_ids = set(evidence_by_field.values())
for axis, expected in allowed.items():
    encoded = json.dumps(primitive_schemas[axis], sort_keys=True)
    present = {item for item in all_ids if item in encoded}
    assert present == expected, (axis, present, expected)
    if not expected:
        assert '"const": "unknown"' in encoded
assert "PRIVATE_VALUE_COPY_CANARY" not in json.dumps(value)
assert "PRIVATE_VALUE_COPY_CANARY" not in json.dumps(argv)
PY
  then
    pass "Value packetをsafe/tool-less/nonpersistentな8軸schema呼出しへ変換する"
    pass "basisなしprovider fields・専用signalなしunknown・実測costだけを返す"
  else
    cat "$error" >&2
    fail "Value packetをsafe/tool-less/nonpersistentな8軸schema呼出しへ変換する"
    fail "basisなしprovider fields・専用signalなしunknown・実測costだけを返す"
  fi
}

test_request_bounds_fail_before_provider() {
  echo "test_request_bounds_fail_before_provider:"
  local malformed="$TEST_ROOT/malformed.json"
  local oversized="$TEST_ROOT/oversized.json"
  local bad_hash="$TEST_ROOT/bad-hash.json"
  local extra="$TEST_ROOT/extra.json"
  local over_cap="$TEST_ROOT/over-cap.json"
  printf '%s' '{"schema_version":1,"packet":' >"$malformed"
  python3 - "$oversized" <<'PY'
import pathlib
import sys
pathlib.Path(sys.argv[1]).write_bytes(b"{" + b"x" * (8 * 1024 * 1024 + 1))
PY
  write_request "$bad_hash" 50000 bad-packet-hash
  write_request "$extra" 50000 extra-request-field
  write_request "$over_cap" 10000001
  assert_fail_closed "malformed requestをprovider前に拒否する" \
    value-valid "$malformed" malformed no
  assert_fail_closed "oversized requestをbounded readで拒否する" \
    value-valid "$oversized" oversized no
  assert_fail_closed "packet hash不一致をprovider前に拒否する" \
    value-valid "$bad_hash" bad-hash no
  assert_fail_closed "request追加fieldをprovider前に拒否する" \
    value-valid "$extra" extra no
  assert_fail_closed "Compiler上限超過budgetをprovider前に拒否する" \
    value-valid "$over_cap" over-cap no
}

test_response_grounding_privacy_and_cost_fail_closed() {
  echo "test_response_grounding_privacy_and_cost_fail_closed:"
  write_request "$REQUEST"
  assert_fail_closed "provider nonzeroを固定stderrで拒否する" \
    nonzero "$REQUEST" provider-nonzero
  assert_fail_closed "provider malformed JSONを拒否する" \
    invalid-json "$REQUEST" provider-invalid-json
  assert_fail_closed "provider oversized stdoutを拒否する" \
    oversized "$REQUEST" provider-oversized
  assert_fail_closed "8軸schema欠落を拒否する" \
    value-invalid-schema "$REQUEST" invalid-schema
  assert_fail_closed "packet外referenceを拒否する" \
    value-invalid-ref "$REQUEST" invalid-ref
  assert_fail_closed "axis違いreferenceを拒否する" \
    value-wrong-axis-ref "$REQUEST" wrong-axis
  assert_fail_closed "専用signalなし軸のnonunknownを拒否する" \
    value-unsupported-axis-positive "$REQUEST" unsupported-axis
  assert_fail_closed "unknown軸のreferenceを拒否する" \
    value-unknown-with-ref "$REQUEST" unknown-ref
  assert_fail_closed "nonunknown軸の空referenceを拒否する" \
    value-positive-without-ref "$REQUEST" empty-ref
  assert_fail_closed "provider実測over-budgetを拒否する" \
    value-over-budget "$REQUEST" over-budget
  assert_fail_closed "evidence summaryのraw copyを拒否する" \
    value-raw-copy "$REQUEST" raw-copy
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
      "flight recorder Claude value evaluator failed" ]]; then
    pass "timeoutでprovider process groupを停止し固定stderrだけを返す"
  else
    fail "timeoutでprovider process groupを停止し固定stderrだけを返す"
  fi
}

echo "=== Flight Recorder Claude Value Evaluator Adapter Tests ==="
if [[ ! -x "$ADAPTER" ]]; then
  fail "production Claude Value evaluator adapterが実行可能である"
  echo
  echo "Results: $PASS passed, $FAIL failed"
  exit 1
fi
test_bundled_evaluator_registration
test_value_compile_timeout_layers_enclose_inner_provider
test_shared_helper_tamper_fails_before_provider_and_binds_fingerprint
test_verified_helper_bytes_are_the_only_executed_source
test_value_packet_becomes_safe_axis_grounded_call
test_short_enum_tokens_do_not_trigger_raw_prose_copy_rule
test_deliverable_quality_matches_compiler_evidence_allowlist
test_request_bounds_fail_before_provider
test_response_grounding_privacy_and_cost_fail_closed
test_timeout_kills_provider_process_group

echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
