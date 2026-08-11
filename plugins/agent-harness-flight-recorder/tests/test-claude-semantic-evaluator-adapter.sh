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
  local forbidden="${6:-RAW_SOURCE_CANARY_iam178}"
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
    && ! grep -Fq "$forbidden" "$error" \
    && [[ "$provider_observed" == "$provider_expected" ]]; then
    pass "$description"
  else
    fail "$description"
  fi
}

write_nested_jsonl_request() {
  local destination="$1"
  write_request "$destination"
  python3 - "$destination" <<'PY'
import hashlib
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
value = json.loads(path.read_text())
user_text = (
    "Please preserve the existing retry boundary while correcting this "
    "specific nested fixture behavior."
)
assistant_text = (
    "The bounded implementation now preserves retries and verifies the "
    "nested fixture behavior."
)
rows = [
    {
        "type": "response_item",
        "payload": {
            "role": "user",
            "content": [{"type": "input_text", "text": user_text}],
        },
    },
    {
        "type": "response_item",
        "payload": {
            "role": "assistant",
            "content": [{"type": "output_text", "text": assistant_text}],
        },
    },
]
content = "\n".join(
    json.dumps(row, sort_keys=True, separators=(",", ":")) for row in rows
)
value["source"]["content"] = content
value["source"]["content_sha256"] = (
    "sha256:" + hashlib.sha256(content.encode()).hexdigest()
)
value["source"]["span_sha256"] = value["source"]["content_sha256"]
path.write_text(json.dumps(value, sort_keys=True, separators=(",", ":")))
PY
}

write_trimmed_nested_jsonl_request() {
  local destination="$1"
  write_request "$destination"
  python3 - "$destination" <<'PY'
import hashlib
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
value = json.loads(path.read_text())
dict_fragment = "D" * 32
list_fragment = "L" * 32
primitive_fragment = "P" * 32
short_fragment = "S" * 31
rows = [
    {
        "nested": {
            "items": [
                {"text": f"   {dict_fragment}   "},
                {"short": f"   {short_fragment}   "},
            ],
        },
    },
    ["metadata", {"assistant": f"   {list_fragment}   "}],
    f"   {primitive_fragment}   ",
]
content = "\n".join(
    json.dumps(row, sort_keys=True, separators=(",", ":")) for row in rows
)
value["source"]["content"] = content
digest = "sha256:" + hashlib.sha256(content.encode()).hexdigest()
value["source"]["content_sha256"] = digest
value["source"]["span_sha256"] = digest
path.write_text(json.dumps(value, sort_keys=True, separators=(",", ":")))
PY
}

write_recursive_jsonl_request() {
  local destination="$1"
  write_request "$destination"
  python3 - "$destination" <<'PY'
import hashlib
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
value = json.loads(path.read_text())
fragment = "R" * 32
content = "[" * 2000 + json.dumps(fragment) + "]" * 2000
value["source"]["content"] = content
digest = "sha256:" + hashlib.sha256(content.encode()).hexdigest()
value["source"]["content_sha256"] = digest
value["source"]["span_sha256"] = digest
path.write_text(json.dumps(value, sort_keys=True, separators=(",", ":")))
PY
}

write_non_json_privacy_request() {
  local destination="$1"
  write_request "$destination"
  python3 - "$destination" <<'PY'
import hashlib
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
value = json.loads(path.read_text())
content = "NOT_JSON_PRIVATE_FRAGMENT_" + "N" * 40
value["source"]["content"] = content
digest = "sha256:" + hashlib.sha256(content.encode()).hexdigest()
value["source"]["content_sha256"] = digest
value["source"]["span_sha256"] = digest
path.write_text(json.dumps(value, sort_keys=True, separators=(",", ":")))
PY
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
system_prompt = option("--system-prompt")
assert "32 or more characters" in system_prompt
assert "JSONL" in system_prompt
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

test_nested_jsonl_source_copy_fails_at_adapter_boundary() {
  echo "test_nested_jsonl_source_copy_fails_at_adapter_boundary:"
  local request="$TEST_ROOT/nested-jsonl-request.json"
  local copied=(
    "Please preserve the existing retry boundary while correcting this specific nested fixture behavior."
  )
  local capture="$TEST_ROOT/capture-nested-jsonl-paraphrase"
  local output="$TEST_ROOT/nested-jsonl-paraphrase.out"
  local error="$TEST_ROOT/nested-jsonl-paraphrase.err"
  write_nested_jsonl_request "$request"
  assert_fail_closed \
    "JSONL nested user/assistant文字列のcopyをadapter段階で拒否する" \
    nested-jsonl-copy "$request" nested-jsonl-copy yes "$copied"

  if run_adapter valid "$capture" "$request" >"$output" 2>"$error" \
    && [[ ! -s "$error" ]] \
    && python3 - "$output" "$request" <<'PY'
import json
import pathlib
import sys

output = json.loads(pathlib.Path(sys.argv[1]).read_text())
request = json.loads(pathlib.Path(sys.argv[2]).read_text())
serialized = json.dumps(output, sort_keys=True)
for line in request["source"]["content"].splitlines():
    decoded = json.loads(line)
    for item in decoded["payload"]["content"]:
        assert item["text"] not in serialized
assert output["result"]["summary"] == (
    "The bounded generic failure was corrected."
)
PY
  then
    pass "JSONL sourceのparaphrase responseは既存どおり通過する"
  else
    cat "$error" >&2
    fail "JSONL sourceのparaphrase responseは既存どおり通過する"
  fi
}

test_trimmed_nested_jsonl_fragments_share_privacy_boundary() {
  echo "test_trimmed_nested_jsonl_fragments_share_privacy_boundary:"
  local request="$TEST_ROOT/trimmed-nested-jsonl-request.json"
  local mode prefix description
  local capture="$TEST_ROOT/capture-trimmed-jsonl-short"
  local output="$TEST_ROOT/trimmed-jsonl-short.out"
  local error="$TEST_ROOT/trimmed-jsonl-short.err"
  write_trimmed_nested_jsonl_request "$request"
  for mode in dict list primitive; do
    case "$mode" in
      dict) prefix="$(printf 'D%.0s' {1..32})" ;;
      list) prefix="$(printf 'L%.0s' {1..32})" ;;
      primitive) prefix="$(printf 'P%.0s' {1..32})" ;;
    esac
    description="前後空白付きJSONL $mode nested 32文字のtrimmed copyを拒否する"
    assert_fail_closed "$description" \
      "trimmed-jsonl-$mode-copy" "$request" \
      "trimmed-jsonl-$mode-copy" yes "$prefix"
  done

  if run_adapter trimmed-jsonl-short-copy "$capture" "$request" \
      >"$output" 2>"$error" \
    && [[ ! -s "$error" ]] \
    && python3 - "$output" <<'PY'
import json
import pathlib
import sys

value = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert value["result"]["summary"] == "S" * 31
PY
  then
    pass "trimmed 31文字はprivacy fragment閾値では拒否しない"
  else
    cat "$error" >&2
    fail "trimmed 31文字はprivacy fragment閾値では拒否しない"
  fi

  if PYTHONPATH="$PLUGIN_DIR/scripts" python3 - "$request" <<'PY'
import json
import pathlib
import sys

from semantic_receipts import _validate_response
from vault import VaultError

request = json.loads(pathlib.Path(sys.argv[1]).read_text())
evidence = "sha256:" + "1" * 64
rubric = request["rubric"]
base = {
    "schema_version": 1,
    "task": {
        "type": "bug_fix",
        "intent": "A bounded paraphrase of the requested work.",
        "deliverable": "A verified bounded repository change.",
        "constraints": ["Preserve existing behavior."],
        "difficulty": "medium",
    },
    "execution": {
        "harness": "claude-code",
        "model": "fixture-worker-model",
        "duration_ms": 1200,
        "tool_count": 0,
        "retry_count": 0,
    },
    "result": {
        "summary": "placeholder",
        "artifacts": ["test-result"],
        "outcome": "success",
    },
    "assessment": {
        "criteria": {
            name: {
                "state": "supported",
                "evidence_references": [evidence],
            }
            for name in rubric["criteria"]
        },
        "confidence": "high",
    },
}

for fragment in ("D" * 32, "L" * 32, "P" * 32):
    response = json.loads(json.dumps(base))
    response["result"]["summary"] = fragment
    try:
        _validate_response(
            json.dumps(response, sort_keys=True, separators=(",", ":")).encode(),
            {evidence},
            rubric,
            request["source"]["content"],
            "/private/fixture/session.jsonl",
            "claude-code",
        )
    except VaultError as error:
        assert "copied raw source content" in str(error)
    else:
        raise AssertionError(f"Recorder accepted trimmed source fragment: {fragment[0]}")
PY
  then
    pass "RecorderもJSONL nested trimmed 32文字copyを拒否する"
  else
    fail "RecorderもJSONL nested trimmed 32文字copyを拒否する"
  fi
}

test_recursive_jsonl_privacy_fails_closed_without_breaking_non_json() {
  echo "test_recursive_jsonl_privacy_fails_closed_without_breaking_non_json:"
  local recursive="$TEST_ROOT/recursive-jsonl-request.json"
  local non_json="$TEST_ROOT/non-json-privacy-request.json"
  local capture="$TEST_ROOT/capture-recursive-jsonl"
  local output="$TEST_ROOT/recursive-jsonl.out"
  local error="$TEST_ROOT/recursive-jsonl.err"
  local status=0
  write_recursive_jsonl_request "$recursive"
  run_adapter valid "$capture" "$recursive" >"$output" 2>"$error" \
    || status=$?
  if [[ "$status" -eq 1 && ! -s "$output" ]] \
    && [[ -f "$capture/argv.json" ]] \
    && [[ "$(cat "$error")" == \
      "flight recorder Claude evaluator failed" ]]; then
    pass "深いvalid JSONLをadapter固定stderrでfail closedする"
  else
    fail "深いvalid JSONLをadapter固定stderrでfail closedする"
  fi

  write_non_json_privacy_request "$non_json"
  capture="$TEST_ROOT/capture-non-json-privacy"
  output="$TEST_ROOT/non-json-privacy.out"
  error="$TEST_ROOT/non-json-privacy.err"
  if run_adapter valid "$capture" "$non_json" >"$output" 2>"$error" \
    && [[ ! -s "$error" ]] \
    && python3 - "$output" <<'PY'
import json
import pathlib
import sys

value = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert value["result"]["summary"] == (
    "The bounded generic failure was corrected."
)
PY
  then
    pass "非JSON行はwhole-line検査のみでparaphraseを通す"
  else
    cat "$error" >&2
    fail "非JSON行はwhole-line検査のみでparaphraseを通す"
  fi

  if PYTHONPATH="$PLUGIN_DIR/scripts" python3 - "$recursive" "$non_json" <<'PY'
import json
import pathlib
import sys

from semantic_receipts import _validate_response
from vault import VaultError

recursive_request = json.loads(pathlib.Path(sys.argv[1]).read_text())
non_json_request = json.loads(pathlib.Path(sys.argv[2]).read_text())
evidence = "sha256:" + "1" * 64
rubric = recursive_request["rubric"]
response = {
    "schema_version": 1,
    "task": {
        "type": "bug_fix",
        "intent": "A bounded paraphrase of the requested work.",
        "deliverable": "A verified bounded repository change.",
        "constraints": ["Preserve existing behavior."],
        "difficulty": "medium",
    },
    "execution": {
        "harness": "claude-code",
        "model": "fixture-worker-model",
        "duration_ms": 1200,
        "tool_count": 0,
        "retry_count": 0,
    },
    "result": {
        "summary": "The bounded generic failure was corrected.",
        "artifacts": ["test-result"],
        "outcome": "success",
    },
    "assessment": {
        "criteria": {
            name: {
                "state": "supported",
                "evidence_references": [evidence],
            }
            for name in rubric["criteria"]
        },
        "confidence": "high",
    },
}
raw = json.dumps(response, sort_keys=True, separators=(",", ":")).encode()
try:
    _validate_response(
        raw,
        {evidence},
        rubric,
        recursive_request["source"]["content"],
        "/private/fixture/session.jsonl",
        "claude-code",
    )
except VaultError as error:
    assert str(error) == "semantic evaluator source content is invalid"
    assert isinstance(error.__cause__, RecursionError)
except RecursionError as error:
    raise AssertionError("raw RecursionError escaped Recorder") from error
else:
    raise AssertionError("Recorder accepted excessively nested JSONL")

validated, references = _validate_response(
    raw,
    {evidence},
    rubric,
    non_json_request["source"]["content"],
    "/private/fixture/session.jsonl",
    "claude-code",
)
assert validated["result"]["summary"] == response["result"]["summary"]
assert references == [evidence]
PY
  then
    pass "Recorderは再帰超過を固定VaultErrorへ閉じ非JSON paraphraseを維持する"
  else
    fail "Recorderは再帰超過を固定VaultErrorへ閉じ非JSON paraphraseを維持する"
  fi
}

test_timeout_budget_contract() {
  echo "test_timeout_budget_contract:"
  if python3 - "$ADAPTER" "$PLUGIN_DIR/scripts/receipt_automation.py" \
    2>/dev/null <<'PY'
import ast
import pathlib
import sys

adapter_path, worker_path = map(pathlib.Path, sys.argv[1:])
sys.path.insert(0, str(worker_path.parent))

def integer_constant(tree, name):
    for node in tree.body:
        if (
            isinstance(node, ast.Assign)
            and len(node.targets) == 1
            and isinstance(node.targets[0], ast.Name)
            and node.targets[0].id == name
            and isinstance(node.value, ast.Constant)
            and isinstance(node.value.value, int)
        ):
            return node.value.value
    raise AssertionError(f"missing integer constant: {name}")

adapter_tree = ast.parse(adapter_path.read_text(encoding="utf-8"))
worker_tree = ast.parse(worker_path.read_text(encoding="utf-8"))
inner = integer_constant(adapter_tree, "DEFAULT_TIMEOUT_SECONDS")
outer = integer_constant(
    worker_tree, "BUNDLED_EVALUATOR_TIMEOUT_SECONDS"
)
default_outer = integer_constant(
    worker_tree, "DEFAULT_EVALUATOR_TIMEOUT_SECONDS"
)
assert inner == 180
assert outer == 240
assert default_outer == 60
assert inner < outer
assert outer - inner >= 60
assert outer <= 300

calls = [
    node
    for node in ast.walk(worker_tree)
    if isinstance(node, ast.Call)
    and isinstance(node.func, ast.Name)
    and node.func.id == "_prepare_receipt"
]
assert len(calls) == 1
timeout_argument = calls[0].args[9]
assert isinstance(timeout_argument, ast.Call)
assert isinstance(timeout_argument.func, ast.Name)
assert timeout_argument.func.id == "_evaluator_timeout_seconds"
assert len(timeout_argument.args) == 1
assert isinstance(timeout_argument.args[0], ast.Name)
assert timeout_argument.args[0].id == "evaluator_path"

namespace = {"__file__": str(worker_path)}
exec(compile(worker_tree, str(worker_path), "exec"), namespace)
timeout_for = namespace["_evaluator_timeout_seconds"]
bundled_path = (
    worker_path.parent / "flight-recorder-claude-semantic-evaluator"
).resolve()
assert timeout_for(bundled_path) == outer
assert timeout_for(pathlib.Path("/tmp/custom-evaluator")) == default_outer

identity = namespace["_executable_identity"]
resolved_bundled, _digest = identity(str(bundled_path))
assert resolved_bundled == bundled_path
assert timeout_for(resolved_bundled) == outer
PY
  then
    pass "bundledだけinner=180・outer=240、custom=60秒を固定する"
  else
    fail "bundledだけinner=180・outer=240、custom=60秒を固定する"
  fi
}

test_timeout_override_is_harness_only() {
  echo "test_timeout_override_is_harness_only:"
  local contract_status=0
  local process_status=0
  local capture="$TEST_ROOT/capture-invalid-timeout"
  local output="$TEST_ROOT/invalid-timeout.out"
  local error="$TEST_ROOT/invalid-timeout.err"
  python3 - "$ADAPTER" 2>/dev/null <<'PY' || contract_status=$?
import os
import runpy
import sys

namespace = runpy.run_path(sys.argv[1])
timeout_seconds = namespace["_timeout_seconds"]
adapter_error = namespace["AdapterError"]
default = namespace["DEFAULT_TIMEOUT_SECONDS"]
assert default == 180

saved = {
    name: os.environ.get(name)
    for name in (
        "FLIGHT_RECORDER_TEST_HARNESS",
        "FLIGHT_RECORDER_TEST_CLAUDE_TIMEOUT_SECONDS",
    )
}
try:
    os.environ.pop("FLIGHT_RECORDER_TEST_HARNESS", None)
    os.environ.pop("FLIGHT_RECORDER_TEST_CLAUDE_TIMEOUT_SECONDS", None)
    assert timeout_seconds() == default

    # Ambient overrideだけではproduction defaultを変えない。
    os.environ["FLIGHT_RECORDER_TEST_CLAUDE_TIMEOUT_SECONDS"] = "1"
    assert timeout_seconds() == default
    os.environ["FLIGHT_RECORDER_TEST_HARNESS"] = "0"
    assert timeout_seconds() == default

    # 明示test harnessだけが短縮を許可する。
    os.environ["FLIGHT_RECORDER_TEST_HARNESS"] = "1"
    assert timeout_seconds() == 1
    for invalid in ("0", "181", "invalid"):
        os.environ["FLIGHT_RECORDER_TEST_CLAUDE_TIMEOUT_SECONDS"] = invalid
        try:
            timeout_seconds()
        except adapter_error:
            pass
        else:
            raise AssertionError("invalid harness timeout must fail closed")

    # 無効値もambientなら無視してdefaultを使う。
    os.environ.pop("FLIGHT_RECORDER_TEST_HARNESS", None)
    assert timeout_seconds() == default
finally:
    for name, value in saved.items():
        if value is None:
            os.environ.pop(name, None)
        else:
            os.environ[name] = value
PY
  write_request "$REQUEST"
  run_adapter valid "$capture" "$REQUEST" \
    env FLIGHT_RECORDER_TEST_CLAUDE_TIMEOUT_SECONDS=invalid \
    >"$output" 2>"$error" || process_status=$?
  if [[ "$contract_status" -eq 0 && "$process_status" -eq 1 ]] \
    && [[ ! -s "$output" && ! -e "$capture/argv.json" ]] \
    && [[ "$(cat "$error")" == \
      "flight recorder Claude evaluator failed" ]]; then
    pass "timeout短縮overrideを明示test harnessだけに限定する"
  else
    fail "timeout短縮overrideを明示test harnessだけに限定する"
  fi
}

test_slow_provider_times_out_cleanly() {
  echo "test_slow_provider_times_out_cleanly:"
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
      "flight recorder Claude evaluator failed" ]]; then
    pass "slow providerのprocess groupを停止し固定stderrだけを返す"
  else
    fail "slow providerのprocess groupを停止し固定stderrだけを返す"
  fi
}

echo "=== Flight Recorder Claude Semantic Evaluator Adapter Tests ==="
if [[ ! -x "$ADAPTER" ]]; then
  fail "production Claude semantic evaluator adapterが実行可能である"
  echo
  echo "Results: $PASS passed, $FAIL failed"
  exit 1
fi
if [[ "${FLIGHT_RECORDER_TEST_NESTED_JSONL_ONLY:-0}" == "1" ]]; then
  test_nested_jsonl_source_copy_fails_at_adapter_boundary
elif [[ "${FLIGHT_RECORDER_TEST_TRIMMED_JSONL_ONLY:-0}" == "1" ]]; then
  test_trimmed_nested_jsonl_fragments_share_privacy_boundary
elif [[ "${FLIGHT_RECORDER_TEST_RECURSIVE_JSONL_ONLY:-0}" == "1" ]]; then
  test_recursive_jsonl_privacy_fails_closed_without_breaking_non_json
else
  test_protocol_v2_and_safe_claude_invocation
  test_invalid_and_oversized_input_fail_closed
  test_normalizes_worker_contract_fields
  test_provider_failures_and_budget_fail_closed
  test_nested_jsonl_source_copy_fails_at_adapter_boundary
  test_trimmed_nested_jsonl_fragments_share_privacy_boundary
  test_recursive_jsonl_privacy_fails_closed_without_breaking_non_json
  test_timeout_budget_contract
  test_timeout_override_is_harness_only
  test_slow_provider_times_out_cleanly
fi

echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
