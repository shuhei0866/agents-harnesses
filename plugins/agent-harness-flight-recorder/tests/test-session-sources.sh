#!/usr/bin/env bash
# Local raw-session source registration contract test.
# External dependencies: git and python3. Network access is not required.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CLI="$PLUGIN_DIR/scripts/flight-recorder"
FIXTURES="$SCRIPT_DIR/fixtures"
FAKE_BIN="$FIXTURES/fake-bin"
TEST_ROOT="$(mktemp -d)" || exit 1
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
}

test_registers_supported_sources_safely_and_idempotently() {
  echo "test_registers_supported_sources_safely_and_idempotently:"
  local adapter raw output repeat err
  for adapter in claude-code codex; do
    raw="$TEST_ROOT/${adapter}-session.jsonl"
    output="$TEST_ROOT/${adapter}-register.json"
    repeat="$TEST_ROOT/${adapter}-repeat.json"
    err="$TEST_ROOT/${adapter}-register.err"
    cp "$FIXTURES/${adapter}-session.jsonl" "$raw"

    if ! run_cli source register \
      --adapter "$adapter" --path "$raw" --json >"$output" 2>"$err"; then
      cat "$err" >&2
      fail "$adapter source register CLI is available"
      return
    fi
    if ! run_cli source register \
      --adapter "$adapter" --path "$raw" --json >"$repeat" 2>>"$err"; then
      cat "$err" >&2
      fail "$adapter source registration is idempotent"
      return
    fi

    if python3 - "$adapter" "$raw" "$output" "$repeat" "$err" "$STATE" <<'PY'
import hashlib
import json
import pathlib
import re
import sys

adapter, raw_path, output_path, repeat_path, error_path, state_path = sys.argv[1:]
raw = pathlib.Path(raw_path)
value = json.loads(pathlib.Path(output_path).read_text(encoding="utf-8"))
repeat = json.loads(pathlib.Path(repeat_path).read_text(encoding="utf-8"))
stderr = pathlib.Path(error_path).read_text(encoding="utf-8")

assert value["schema_version"] == 1
assert value["command"] == "source register"
assert value["adapter"] == adapter
assert value["source_ref"] == repeat["source_ref"]
assert re.fullmatch(r"[A-Za-z0-9:._-]{16,256}", value["source_ref"])
assert value["content_sha256"] == (
    "sha256:" + hashlib.sha256(raw.read_bytes()).hexdigest()
)
assert value["size_bytes"] == raw.stat().st_size

visible = json.dumps(value) + json.dumps(repeat) + stderr
assert str(raw) not in visible
for canary in (
    "CLAUDE_SELECTED_SPAN_CANARY",
    "CLAUDE_OUTSIDE_BEFORE_CANARY",
    "CLAUDE_OUTSIDE_AFTER_CANARY",
    "CODEX_SELECTED_SPAN_CANARY",
    "CODEX_OUTSIDE_AFTER_CANARY",
):
    assert canary not in visible

raw_digest = hashlib.sha256(raw.read_bytes()).digest()
for candidate in pathlib.Path(state_path).rglob("*"):
    if candidate.is_file():
        assert hashlib.sha256(candidate.read_bytes()).digest() != raw_digest

gitignore = (pathlib.Path(state_path) / ".gitignore").read_text(encoding="utf-8")
assert "/session-sources/" in gitignore
assert "/semantic-receipts/" in gitignore
PY
    then
      pass "$adapter sourceをcontent-freeかつidempotentに登録する"
    else
      fail "$adapter sourceをcontent-freeかつidempotentに登録する"
      return
    fi
  done
}

test_rejects_symlink_and_hardlink_sources() {
  echo "test_rejects_symlink_and_hardlink_sources:"
  local raw="$TEST_ROOT/unsafe-source.jsonl"
  local symlink="$TEST_ROOT/unsafe-source-symlink.jsonl"
  local hardlink="$TEST_ROOT/unsafe-source-hardlink.jsonl"
  cp "$FIXTURES/codex-session.jsonl" "$raw"
  ln -s "$raw" "$symlink"

  if run_cli source register \
    --adapter codex --path "$symlink" --json >/dev/null 2>&1; then
    fail "symlink sourceを拒否する"
    return
  else
    pass "symlink sourceを拒否する"
  fi

  ln "$raw" "$hardlink"
  if run_cli source register \
    --adapter codex --path "$raw" --json >/dev/null 2>&1; then
    fail "hardlink sourceを拒否する"
    return
  else
    pass "hardlink sourceを拒否する"
  fi
}

echo "=== Flight Recorder Local Session Source Tests ==="
if ! build_fixture; then
  echo "fixture setup failed" >&2
  exit 1
fi
test_registers_supported_sources_safely_and_idempotently
test_rejects_symlink_and_hardlink_sources

echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
