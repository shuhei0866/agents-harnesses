#!/usr/bin/env bash
# agent-harness-flight-recorder の契約テスト（外部依存: python3 のみ）
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RECORDER="$PLUGIN_DIR/scripts/record-event"
FIXTURES="$SCRIPT_DIR/fixtures"

PASS=0
FAIL=0
TMPDIR_TEST="$(mktemp -d)"

cleanup() {
  rm -rf "$TMPDIR_TEST"
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

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    pass "$desc"
  else
    fail "${desc}（期待: '$expected' / 実際: '$actual'）"
  fi
}

assert_success() {
  local desc="$1" status="$2"
  if [[ "$status" -eq 0 ]]; then
    pass "$desc"
  else
    fail "${desc}（終了コード: ${status}）"
  fi
}

assert_file_absent_or_empty() {
  local desc="$1" path="$2"
  if [[ ! -e "$path" || ! -s "$path" ]]; then
    pass "$desc"
  else
    fail "${desc}（予期しない記録あり: ${path}）"
  fi
}

json_check() {
  local path="$1" expression="$2"
  python3 - "$path" "$expression" <<'PY'
import json
import sys

path, expression = sys.argv[1:]
with open(path, encoding="utf-8") as stream:
    value = json.loads(stream.readline())
if not eval(expression, {"__builtins__": {"sorted": sorted}}, {"v": value}):
    raise SystemExit(1)
PY
}

jsonl_check() {
  local path="$1" expected_count="$2"
  python3 - "$path" "$expected_count" <<'PY'
import json
import sys

path, expected = sys.argv[1], int(sys.argv[2])
with open(path, encoding="utf-8") as stream:
    rows = [json.loads(line) for line in stream if line.strip()]
assert len(rows) == expected, (len(rows), expected)
assert len({row["event_id"] for row in rows}) == expected
PY
}

run_record() {
  local harness="$1" fixture="$2" destination="$3" stdout_file="$4" stderr_file="$5"
  local runtime="${6:-claude-code}"
  local -a runtime_env=(env -u PLUGIN_ROOT)
  if [[ "$runtime" == "codex" ]]; then
    runtime_env=(env PLUGIN_ROOT="$PLUGIN_DIR")
  fi
  "${runtime_env[@]}" AGENT_FLIGHT_RECORDER_PATH="$destination" \
    AGENT_FLIGHT_RECORDER_NOW="2026-07-21T00:00:00Z" \
    "$RECORDER" --harness "$harness" < "$fixture" > "$stdout_file" 2> "$stderr_file"
}

canonical_keys='["event_id", "event_kind", "harness", "metrics", "model", "outcome", "permission_mode", "recorded_at", "schema_version", "session_id_hash", "source_event", "tool", "turn_id_hash", "workspace_id"]'

test_claude_code_schema() {
  echo "test_claude_code_schema:"
  local log="$TMPDIR_TEST/claude.jsonl" out="$TMPDIR_TEST/claude.out" err="$TMPDIR_TEST/claude.err" status
  run_record claude-code "$FIXTURES/claude-code-stop.json" "$log" "$out" "$err"
  status=$?
  assert_success "Claude Codeイベントを記録できる" "$status"
  if json_check "$log" "sorted(v.keys()) == $canonical_keys and v['harness'] == 'claude-code' and v['source_event'] == 'Stop' and v['recorded_at'] == '2026-07-21T00:00:00Z'" 2>/dev/null; then
    pass "canonical schemaへ正規化する"
  else
    fail "canonical schemaへ正規化する"
  fi
}

test_codex_same_schema() {
  echo "test_codex_same_schema:"
  local log="$TMPDIR_TEST/codex.jsonl" out="$TMPDIR_TEST/codex.out" err="$TMPDIR_TEST/codex.err" status
  run_record codex "$FIXTURES/codex-turn-complete.json" "$log" "$out" "$err"
  status=$?
  assert_success "Codexイベントを記録できる" "$status"
  if json_check "$log" "sorted(v.keys()) == $canonical_keys and v['harness'] == 'codex' and v['source_event'] == 'Stop' and v['recorded_at'] == '2026-07-21T00:00:00Z'" 2>/dev/null; then
    pass "Claude Codeと同一のcanonical schemaへ正規化する"
  else
    fail "Claude Codeと同一のcanonical schemaへ正規化する"
  fi
}

test_auto_harness_detection() {
  echo "test_auto_harness_detection:"
  local claude_log="$TMPDIR_TEST/auto-claude.jsonl" codex_log="$TMPDIR_TEST/auto-codex.jsonl"
  local out="$TMPDIR_TEST/auto.out" err="$TMPDIR_TEST/auto.err"
  run_record auto "$FIXTURES/claude-code-session-start.json" "$claude_log" "$out" "$err" claude-code
  run_record auto "$FIXTURES/codex-turn-complete.json" "$codex_log" "$out" "$err" codex
  if json_check "$claude_log" "v['harness'] == 'claude-code'" 2>/dev/null \
    && json_check "$codex_log" "v['harness'] == 'codex'" 2>/dev/null; then
    pass "共有hook定義からハーネスを自動識別する"
  else
    fail "共有hook定義からハーネスを自動識別する"
  fi
}

test_privacy_allowlist() {
  echo "test_privacy_allowlist:"
  local log="$TMPDIR_TEST/privacy.jsonl" out="$TMPDIR_TEST/privacy.out" err="$TMPDIR_TEST/privacy.err" status
  run_record claude-code "$FIXTURES/claude-code-post-tool-use.json" "$log" "$out" "$err"
  status=$?
  assert_success "canary入りイベントでも処理を継続する" "$status"
  if python3 - "$log" <<'PY' 2>/dev/null
import pathlib
import sys

text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
canaries = ("PROMPT_CANARY_5a82d4", "ASSISTANT_CANARY_72f1b9", "CODE_CANARY_e193c7", "OUTPUT_CANARY_b647aa", "UNKNOWN_CANARY_c04f2e")
assert not any(canary in text for canary in canaries)
event = __import__("json").loads(text)
assert event["tool"] == "Bash"
assert event["metrics"] == {"duration_ms": 12}
PY
  then
    pass "本文を捨て、許可済みtoolメタデータだけを保存する"
  else
    fail "本文を捨て、許可済みtoolメタデータだけを保存する"
  fi
}

test_empty_json_fail_open() {
  echo "test_empty_json_fail_open:"
  local log="$TMPDIR_TEST/empty.jsonl" out="$TMPDIR_TEST/empty.out" err="$TMPDIR_TEST/empty.err" status
  AGENT_FLIGHT_RECORDER_PATH="$log" AGENT_FLIGHT_RECORDER_NOW="2026-07-21T00:00:00Z" \
    "$RECORDER" --harness claude-code </dev/null >"$out" 2>"$err"
  status=$?
  assert_success "空入力でもfail-openする" "$status"
  assert_file_absent_or_empty "空入力を記録しない" "$log"
}

test_malformed_json_fail_open() {
  echo "test_malformed_json_fail_open:"
  local log="$TMPDIR_TEST/malformed.jsonl" out="$TMPDIR_TEST/malformed.out" err="$TMPDIR_TEST/malformed.err" input="$TMPDIR_TEST/malformed-input.json" status
  printf '%s' '{"event_kind":"turn.completed","session_id":' > "$input"
  run_record claude-code "$input" "$log" "$out" "$err"
  status=$?
  assert_success "壊れたJSONでもfail-openする" "$status"
  assert_file_absent_or_empty "壊れたJSONを記録しない" "$log"
}

test_storage_failure_fail_open() {
  echo "test_storage_failure_fail_open:"
  local blocker="$TMPDIR_TEST/not-a-directory" log out="$TMPDIR_TEST/storage.out" err="$TMPDIR_TEST/storage.err" status
  : > "$blocker"
  log="$blocker/events.jsonl"
  run_record claude-code "$FIXTURES/claude-code-stop.json" "$log" "$out" "$err"
  status=$?
  assert_success "保存失敗でもfail-openする" "$status"
  assert_eq "保存失敗時のstdoutは空" "0" "$(wc -c < "$out" | tr -d ' ')"
}

test_concurrent_append() {
  echo "test_concurrent_append:"
  local log="$TMPDIR_TEST/concurrent.jsonl" failures="$TMPDIR_TEST/concurrent.failures"
  : > "$failures"
  local index
  for index in $(seq 1 50); do
    (
      AGENT_FLIGHT_RECORDER_PATH="$log" \
        AGENT_FLIGHT_RECORDER_NOW="2026-07-21T00:00:00Z" \
        "$RECORDER" --harness codex < "$FIXTURES/codex-turn-complete.json" >/dev/null 2>/dev/null || echo "$index" >> "$failures"
    ) &
  done
  wait
  assert_eq "並行50プロセスがfail-open契約を守る" "0" "$(wc -l < "$failures" | tr -d ' ')"
  if jsonl_check "$log" 50 2>/dev/null; then
    pass "並行appendで50行すべてが有効かつ一意なJSONになる"
  else
    fail "並行appendで50行すべてが有効かつ一意なJSONになる"
  fi
}

test_optional_fields_default_to_null() {
  echo "test_optional_fields_default_to_null:"
  local log="$TMPDIR_TEST/optional.jsonl" out="$TMPDIR_TEST/optional.out" err="$TMPDIR_TEST/optional.err" input="$TMPDIR_TEST/optional-input.json" status
  printf '%s' '{"hook_event_name":"Stop","session_id":"minimal-session-123","turn_id":"minimal-turn-456","cwd":"/Users/alice/work/minimal"}' > "$input"
  run_record claude-code "$input" "$log" "$out" "$err"
  status=$?
  assert_success "optionalフィールド欠落時も記録できる" "$status"
  if json_check "$log" "v['model'] is None and v['permission_mode'] is None and v['tool'] is None and v['metrics'] is None and v['outcome'] is None" 2>/dev/null; then
    pass "欠落したoptionalフィールドをnullで固定する"
  else
    fail "欠落したoptionalフィールドをnullで固定する"
  fi
}

test_hmac_correlation_key() {
  echo "test_hmac_correlation_key:"
  local log="$TMPDIR_TEST/hmac/events.jsonl" out="$TMPDIR_TEST/hmac.out" err="$TMPDIR_TEST/hmac.err" key="$TMPDIR_TEST/hmac/hash.key"
  run_record claude-code "$FIXTURES/claude-code-stop.json" "$log" "$out" "$err"
  run_record claude-code "$FIXTURES/claude-code-stop.json" "$log" "$out" "$err"
  if python3 - "$log" "$key" <<'PY' 2>/dev/null
import hashlib
import json
import stat
import sys

log_path, key_path = sys.argv[1:]
with open(log_path, encoding="utf-8") as stream:
    rows = [json.loads(line) for line in stream]
with open(key_path, "rb") as stream:
    key = stream.read()
assert len(key) == 32
assert stat.S_IMODE(__import__("os").stat(key_path).st_mode) == 0o600
assert rows[0]["workspace_id"] == rows[1]["workspace_id"]
plain = "sha256:" + hashlib.sha256(b"/Users/alice/work/acme-api").hexdigest()[:24]
assert rows[0]["workspace_id"] != plain
PY
  then
    pass "install-local keyで安定したHMAC相関IDを生成する"
  else
    fail "install-local keyで安定したHMAC相関IDを生成する"
  fi
}

test_oversized_input_fail_open() {
  echo "test_oversized_input_fail_open:"
  local log="$TMPDIR_TEST/oversized.jsonl" out="$TMPDIR_TEST/oversized.out" err="$TMPDIR_TEST/oversized.err" input="$TMPDIR_TEST/oversized-input.json" status
  head -c 1048577 /dev/zero | tr '\0' 'x' > "$input"
  run_record claude-code "$input" "$log" "$out" "$err"
  status=$?
  assert_success "1 MiB超の入力でもfail-openする" "$status"
  assert_file_absent_or_empty "1 MiB超の入力を記録しない" "$log"
}

echo "=== agent-harness-flight-recorder tests ==="
test_claude_code_schema
test_codex_same_schema
test_auto_harness_detection
test_privacy_allowlist
test_empty_json_fail_open
test_malformed_json_fail_open
test_storage_failure_fail_open
test_concurrent_append
test_optional_fields_default_to_null
test_hmac_correlation_key
test_oversized_input_fail_open

echo ""
echo "結果: PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
