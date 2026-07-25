#!/usr/bin/env bash
# Chunk rotation contract tests (external dependency: python3 only).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CLI="$PLUGIN_DIR/scripts/flight-recorder"
RECORDER="$PLUGIN_DIR/scripts/record-event"
FAKE_BIN="$SCRIPT_DIR/fixtures/fake-bin"
FIXTURES="$SCRIPT_DIR/fixtures"

PASS=0
FAIL=0
TEST_ROOT="$(mktemp -d)"

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

assert_success() {
  local desc="$1" status="$2"
  if [[ "$status" -eq 0 ]]; then
    pass "$desc"
  else
    fail "${desc}（終了コード: ${status}）"
  fi
}

assert_failure() {
  local desc="$1" status="$2"
  if [[ "$status" -ne 0 && "$status" -ne 126 && "$status" -ne 127 ]]; then
    pass "$desc"
  else
    fail "${desc}（期待した処理失敗にならない: ${status}）"
  fi
}

make_identity() {
  PATH="$FAKE_BIN:$PATH" age-keygen -o "$1" >/dev/null 2>&1
}

recipient_of() {
  PATH="$FAKE_BIN:$PATH" age-keygen -y "$1"
}

run_cli() {
  local state="$1"
  shift
  PATH="$FAKE_BIN:$PATH" FLIGHT_RECORDER_STATE_DIR="$state" "$CLI" "$@"
}

init_vault() {
  local state="$1" recovery="$2"
  make_identity "$recovery"
  run_cli "$state" init \
    --remote "git@github.com:example/private-flight-recorder.git" \
    --recovery-recipient "$(recipient_of "$recovery")"
}

record_fixture() {
  local state="$1" fixture="$2" now="$3"
  FLIGHT_RECORDER_STATE_DIR="$state" \
    AGENT_FLIGHT_RECORDER_NOW="$now" \
    "$RECORDER" --harness claude-code <"$fixture" >/dev/null 2>&1
}

artifact_path() {
  find "$1/devices" -type f -name '*.jsonl.age' -print -quit 2>/dev/null
}

decrypt_artifact() {
  local artifact="$1" identity="$2" output="$3"
  PATH="$FAKE_BIN:$PATH" age -d -i "$identity" "$artifact" >"$output"
}

wait_for_file() {
  local path="$1" attempts=0
  while [[ ! -e "$path" && "$attempts" -lt 100 ]]; do
    sleep 0.02
    attempts=$((attempts + 1))
  done
  [[ -e "$path" ]]
}

test_hook_uses_stable_inbox_lock() {
  echo "test_hook_uses_stable_inbox_lock:"
  local state="$TEST_ROOT/stable-lock/vault"
  local lock="$state/inbox/events.lock"
  local ready="$TEST_ROOT/stable-lock/ready" release="$TEST_ROOT/stable-lock/release"
  local recovery="$TEST_ROOT/stable-lock/recovery.agekey"
  mkdir -p "$(dirname "$state")"
  init_vault "$state" "$recovery" >/dev/null 2>&1 || {
    fail "stable lock用vaultを初期化できる"
    return
  }
  mkdir -p "$state/inbox"

  python3 - "$lock" "$ready" "$release" <<'PY' &
import fcntl
import os
import pathlib
import sys
import time

lock, ready, release = map(pathlib.Path, sys.argv[1:])
descriptor = os.open(lock, os.O_CREAT | os.O_RDWR, 0o600)
with os.fdopen(descriptor, "rb+", closefd=True) as stream:
    fcntl.flock(stream.fileno(), fcntl.LOCK_EX)
    ready.touch()
    while not release.exists():
        time.sleep(0.01)
PY
  local locker_pid=$!
  wait_for_file "$ready" || {
    fail "stable lock helperを開始できる"
    kill "$locker_pid" 2>/dev/null || true
    return
  }

  record_fixture "$state" "$FIXTURES/claude-code-stop.json" \
    "2026-07-24T10:00:00Z" &
  local recorder_pid=$!
  sleep 0.1
  if kill -0 "$recorder_pid" 2>/dev/null \
    && [[ ! -s "$state/inbox/events.jsonl" ]]; then
    pass "hookはdata fileをopenする前にstable lockを待つ"
  else
    fail "hookはdata fileをopenする前にstable lockを待つ"
  fi
  touch "$release"
  wait "$locker_pid"
  wait "$recorder_pid"
  if [[ "$(wc -l <"$state/inbox/events.jsonl" | tr -d ' ')" == "1" ]]; then
    pass "lock解放後に完全な1 eventをinboxへappendする"
  else
    fail "lock解放後に完全な1 eventをinboxへappendする"
  fi
}

test_rotate_valid_events() {
  echo "test_rotate_valid_events:"
  local state="$TEST_ROOT/valid/vault" recovery="$TEST_ROOT/valid/recovery.agekey"
  local plaintext="$TEST_ROOT/valid/chunk.jsonl" artifact status
  mkdir -p "$(dirname "$state")"
  init_vault "$state" "$recovery" >/dev/null 2>&1 || {
    fail "正常系vaultを初期化できる"
    return
  }
  record_fixture "$state" "$FIXTURES/claude-code-session-start.json" \
    "2026-07-24T10:00:00Z"
  record_fixture "$state" "$FIXTURES/claude-code-stop.json" \
    "2026-07-24T10:01:00Z"

  run_cli "$state" rotate >/dev/null 2>&1
  status=$?
  assert_success "2 eventsをimmutable chunkへrotateできる" "$status"
  [[ "$status" -eq 0 ]] || return
  artifact="$(artifact_path "$state")"
  if [[ "$artifact" =~ /devices/[0-9a-f-]+/2026/07/24/[0-9a-f]{64}\.jsonl\.age$ ]]; then
    pass "device/date/content digest pathへpublishする"
  else
    fail "device/date/content digest pathへpublishする"
  fi
  decrypt_artifact "$artifact" "$state/keys/device.agekey" "$plaintext"
  if python3 - "$plaintext" "$state/vault.json" <<'PY' 2>/dev/null
import json
import pathlib
import sys

lines = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
header = json.loads(lines[0])
events = [json.loads(line) for line in lines[1:]]
config = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
assert set(header) == {
    "chunk_id", "created_at", "device_id", "event_count",
    "event_schema_version", "record_type", "schema_version", "vault_id",
}
assert header["record_type"] == "chunk_header"
assert header["schema_version"] == 1
assert header["event_schema_version"] == 2
assert header["event_count"] == 2 == len(events)
assert header["vault_id"] == config["vault_id"]
assert header["created_at"] == events[0]["recorded_at"]
assert header["chunk_id"].startswith("sha256:")
PY
  then
    pass "chunk headerとevent順序がstable schemaに従う"
  else
    fail "chunk headerとevent順序がstable schemaに従う"
  fi
  if [[ ! -s "$state/inbox/events.jsonl" \
    && -z "$(find "$state/queue" -type f -print -quit 2>/dev/null)" ]]; then
    pass "成功後にlive inboxを空にしplaintext retry stateを消す"
  else
    fail "成功後にlive inboxを空にしplaintext retry stateを消す"
  fi
}

test_invalid_events_are_quarantined() {
  echo "test_invalid_events_are_quarantined:"
  local state="$TEST_ROOT/invalid/vault" recovery="$TEST_ROOT/invalid/recovery.agekey"
  local plaintext="$TEST_ROOT/invalid/chunk.jsonl" artifact quarantine status
  mkdir -p "$(dirname "$state")"
  init_vault "$state" "$recovery" >/dev/null 2>&1 || {
    fail "invalid系vaultを初期化できる"
    return
  }
  record_fixture "$state" "$FIXTURES/claude-code-stop.json" \
    "2026-07-24T11:00:00Z"
  mkdir -p "$state/inbox"
  python3 - "$state/inbox/events.jsonl" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
event = json.loads(path.read_text(encoding="utf-8").splitlines()[0])
event["event_id"] = "6b094c18-61bc-48ce-b46b-b27ff6e6e09e"
event["recorded_at"] = "20260724T110000+0000"
with path.open("a", encoding="utf-8") as stream:
    stream.write(json.dumps(event, separators=(",", ":")) + "\n")
PY
  printf '%s\n' '{"not":"complete"' >>"$state/inbox/events.jsonl"
  printf '%s\n' '{"schema_version":99}' >>"$state/inbox/events.jsonl"
  printf '%s' '{"partial":' >>"$state/inbox/events.jsonl"

  run_cli "$state" rotate >/dev/null 2>&1
  status=$?
  assert_success "不正行を含んでも正常eventをrotateできる" "$status"
  [[ "$status" -eq 0 ]] || return
  artifact="$(artifact_path "$state")"
  decrypt_artifact "$artifact" "$state/keys/device.agekey" "$plaintext"
  quarantine="$(find "$state/quarantine" -type f -name '*.jsonl' -print -quit)"
  if python3 - "$plaintext" "$quarantine" <<'PY' 2>/dev/null
import base64
import json
import pathlib
import sys

chunk_lines = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
assert json.loads(chunk_lines[0])["event_count"] == 1
assert len(chunk_lines) == 2
rows = [
    json.loads(line)
    for line in pathlib.Path(sys.argv[2]).read_text(encoding="utf-8").splitlines()
]
assert len(rows) == 4
raw = [base64.b64decode(row["raw_base64"]) for row in rows]
assert any(b"20260724T110000+0000" in item for item in raw)
assert b'{"not":"complete"' in raw
assert b'{"schema_version":99}' in raw
assert b'{"partial":' in raw
assert all(isinstance(row["line_number"], int) and row["reason"] for row in rows)
PY
  then
    pass "invalid JSON/schema/partial bytesを隔離し正常eventだけを保持する"
  else
    fail "invalid JSON/schema/partial bytesを隔離し正常eventだけを保持する"
  fi
}

test_age_failure_retries_idempotently() {
  echo "test_age_failure_retries_idempotently:"
  local state="$TEST_ROOT/retry/vault" recovery="$TEST_ROOT/retry/recovery.agekey"
  local status first_hash second_hash
  mkdir -p "$(dirname "$state")"
  init_vault "$state" "$recovery" >/dev/null 2>&1 || {
    fail "retry系vaultを初期化できる"
    return
  }
  record_fixture "$state" "$FIXTURES/claude-code-stop.json" \
    "2026-07-24T12:00:00Z"

  FAKE_AGE_ENCRYPT_FAIL=1 run_cli "$state" rotate >/dev/null 2>&1
  status=$?
  assert_failure "age失敗を呼び出し元へ返す" "$status"
  if [[ -n "$(find "$state/queue" -type f -name '*.pending' -print -quit 2>/dev/null)" \
    && -z "$(artifact_path "$state")" ]]; then
    pass "暗号化失敗時にplaintext pendingを保持しfinal artifactを作らない"
  else
    fail "暗号化失敗時にplaintext pendingを保持しfinal artifactを作らない"
  fi

  run_cli "$state" rotate >/dev/null 2>&1
  status=$?
  assert_success "pending jobを再実行できる" "$status"
  [[ "$status" -eq 0 ]] || return
  first_hash="$(shasum -a 256 "$(artifact_path "$state")" | awk '{print $1}')"
  run_cli "$state" rotate >/dev/null 2>&1
  status=$?
  second_hash="$(shasum -a 256 "$(artifact_path "$state")" | awk '{print $1}')"
  assert_success "空の再rotateは成功する" "$status"
  if [[ "$first_hash" == "$second_hash" \
    && "$(find "$state/devices" -type f -name '*.jsonl.age' | wc -l | tr -d ' ')" == "1" ]]; then
    pass "retryでartifactを重複・上書きしない"
  else
    fail "retryでartifactを重複・上書きしない"
  fi
}

test_encryption_does_not_block_hook() {
  echo "test_encryption_does_not_block_hook:"
  local state="$TEST_ROOT/nonblocking/vault"
  local recovery="$TEST_ROOT/nonblocking/recovery.agekey"
  local marker="$TEST_ROOT/nonblocking/encrypting"
  local release="$TEST_ROOT/nonblocking/release"
  local rotate_pid recorder_pid recorder_status
  mkdir -p "$(dirname "$state")"
  init_vault "$state" "$recovery" >/dev/null 2>&1 || {
    fail "nonblocking用vaultを初期化できる"
    return
  }
  record_fixture "$state" "$FIXTURES/claude-code-session-start.json" \
    "2026-07-24T12:30:00Z"

  FAKE_AGE_ENCRYPT_MARKER="$marker" \
    FAKE_AGE_ENCRYPT_RELEASE="$release" \
    run_cli "$state" rotate >/dev/null 2>&1 &
  rotate_pid=$!
  if ! wait_for_file "$marker"; then
    fail "rotateが暗号化段階へ到達する"
    kill "$rotate_pid" 2>/dev/null || true
    return
  fi

  record_fixture "$state" "$FIXTURES/claude-code-stop.json" \
    "2026-07-24T12:31:00Z" &
  recorder_pid=$!
  local attempts=0
  while kill -0 "$recorder_pid" 2>/dev/null && [[ "$attempts" -lt 50 ]]; do
    sleep 0.01
    attempts=$((attempts + 1))
  done
  if kill -0 "$recorder_pid" 2>/dev/null; then
    fail "age暗号化中もhookをブロックしない"
    touch "$release"
    wait "$recorder_pid"
  else
    wait "$recorder_pid"
    recorder_status=$?
    if [[ "$recorder_status" -eq 0 \
      && "$(wc -l <"$state/inbox/events.jsonl" | tr -d ' ')" == "1" ]]; then
      pass "age暗号化中もhookをブロックせず新inboxへ記録する"
    else
      fail "age暗号化中もhookをブロックせず新inboxへ記録する"
    fi
  fi

  touch "$release"
  if wait "$rotate_pid"; then
    pass "暗号化解放後にrotateを完了する"
  else
    fail "暗号化解放後にrotateを完了する"
  fi
}

test_legacy_root_inbox_migrates_once() {
  echo "test_legacy_root_inbox_migrates_once:"
  local state="$TEST_ROOT/legacy/vault" recovery="$TEST_ROOT/legacy/recovery.agekey"
  local status
  mkdir -p "$(dirname "$state")"
  init_vault "$state" "$recovery" >/dev/null 2>&1 || {
    fail "legacy migration用vaultを初期化できる"
    return
  }
  AGENT_FLIGHT_RECORDER_PATH="$state/events.jsonl" \
    AGENT_FLIGHT_RECORDER_KEY_PATH="$state/hash.key" \
    AGENT_FLIGHT_RECORDER_NOW="2026-07-24T12:45:00Z" \
    "$RECORDER" --harness claude-code \
    <"$FIXTURES/claude-code-stop.json" >/dev/null 2>&1

  run_cli "$state" rotate >/dev/null 2>&1
  status=$?
  assert_success "旧root events.jsonlをrotateできる" "$status"
  if [[ ! -e "$state/events.jsonl" \
    && "$(find "$state/devices" -type f -name '*.jsonl.age' | wc -l | tr -d ' ')" == "1" ]]; then
    pass "旧plaintextを残さず一度だけimmutable chunkへ移行する"
  else
    fail "旧plaintextを残さず一度だけimmutable chunkへ移行する"
  fi
}

test_unsafe_devices_symlink_preserves_retry() {
  echo "test_unsafe_devices_symlink_preserves_retry:"
  local state="$TEST_ROOT/unsafe/vault" recovery="$TEST_ROOT/unsafe/recovery.agekey"
  local outside="$TEST_ROOT/unsafe/outside" status
  mkdir -p "$(dirname "$state")" "$outside"
  init_vault "$state" "$recovery" >/dev/null 2>&1 || {
    fail "unsafe path用vaultを初期化できる"
    return
  }
  record_fixture "$state" "$FIXTURES/claude-code-stop.json" \
    "2026-07-24T12:50:00Z"
  ln -s "$outside" "$state/devices"

  run_cli "$state" rotate >/dev/null 2>&1
  status=$?
  assert_failure "Vault外へ向くdevices symlinkを拒否する" "$status"
  if [[ -z "$(find "$outside" -mindepth 1 -print -quit)" \
    && -n "$(find "$state/queue" -type f -name '*.pending' -print -quit 2>/dev/null)" ]]; then
    pass "symlink先を変更せずplaintext retry stateを保持する"
  else
    fail "symlink先を変更せずplaintext retry stateを保持する"
  fi
}

test_hook_rejects_symlinked_inbox_fail_open() {
  echo "test_hook_rejects_symlinked_inbox_fail_open:"
  local state="$TEST_ROOT/hook-symlink/vault"
  local recovery="$TEST_ROOT/hook-symlink/recovery.agekey"
  local outside="$TEST_ROOT/hook-symlink/outside" status
  mkdir -p "$(dirname "$state")" "$outside"
  init_vault "$state" "$recovery" >/dev/null 2>&1 || {
    fail "hook symlink用vaultを初期化できる"
    return
  }
  ln -s "$outside" "$state/inbox"

  record_fixture "$state" "$FIXTURES/claude-code-stop.json" \
    "2026-07-24T12:55:00Z"
  status=$?
  assert_success "symlinked inboxでもhookはfail-openする" "$status"
  if [[ -z "$(find "$outside" -mindepth 1 -print -quit)" ]]; then
    pass "hookはsymlink先へeventやlockを書き込まない"
  else
    fail "hookはsymlink先へeventやlockを書き込まない"
  fi
}

test_default_recording_can_initialize_vault() {
  echo "test_default_recording_can_initialize_vault:"
  local state_home="$TEST_ROOT/default-init/state"
  local state="$state_home/agent-harness-flight-recorder"
  local recovery="$TEST_ROOT/default-init/recovery.agekey" status
  mkdir -p "$(dirname "$state_home")"
  make_identity "$recovery"
  XDG_STATE_HOME="$state_home" \
    AGENT_FLIGHT_RECORDER_NOW="2026-07-24T12:58:00Z" \
    "$RECORDER" --harness claude-code \
    <"$FIXTURES/claude-code-stop.json" >/dev/null 2>&1

  PATH="$FAKE_BIN:$PATH" XDG_STATE_HOME="$state_home" "$CLI" init \
    --remote "git@github.com:example/private-flight-recorder.git" \
    --recovery-recipient "$(recipient_of "$recovery")" >/dev/null 2>&1
  status=$?
  assert_success "managed defaultでhook記録後も同じVaultを初期化できる" "$status"
  if [[ -s "$state/vault.json" && ! -e "$state/inbox/hash.key" ]]; then
    pass "default recorderとVaultはroot相関鍵を共有する"
  else
    fail "default recorderとVaultはroot相関鍵を共有する"
  fi
}

test_git_boundary() {
  echo "test_git_boundary:"
  local state="$TEST_ROOT/git/vault" recovery="$TEST_ROOT/git/recovery.agekey"
  mkdir -p "$(dirname "$state")"
  init_vault "$state" "$recovery" >/dev/null 2>&1 || {
    fail "Git境界用vaultを初期化できる"
    return
  }
  record_fixture "$state" "$FIXTURES/claude-code-stop.json" \
    "2026-07-24T13:00:00Z"
  run_cli "$state" rotate >/dev/null 2>&1 || {
    fail "Git境界用chunkを生成できる"
    return
  }
  mkdir -p "$state/queue" "$state/quarantine"
  printf '%s' "pending-canary" >"$state/queue/retry.jsonl.pending"
  printf '%s' "quarantine-canary" >"$state/quarantine/bad.jsonl"
  git -C "$state" init -q
  local eligible
  eligible="$(git -C "$state" ls-files --others --exclude-standard | sort)"
  if [[ "$eligible" == *"devices/"*".jsonl.age"* \
    && "$eligible" != *"events.jsonl"* \
    && "$eligible" != *"pending"* \
    && "$eligible" != *"quarantine"* ]]; then
    pass "event dataのGit候補をdevice-scoped .age artifactだけに限定する"
  else
    fail "event dataのGit候補をdevice-scoped .age artifactだけに限定する"
  fi
  if python3 - "$state/vault.json" <<'PY' 2>/dev/null
import json
import pathlib
import sys

config = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert "devices/**/*.jsonl.age" in config["git_sync_allowlist"]
PY
  then
    pass "sync allowlistにencrypted device chunk patternを明示する"
  else
    fail "sync allowlistにencrypted device chunk patternを明示する"
  fi
}

echo "=== Flight Recorder Chunk Rotation Tests ==="
test_hook_uses_stable_inbox_lock
test_rotate_valid_events
test_invalid_events_are_quarantined
test_age_failure_retries_idempotently
test_encryption_does_not_block_hook
test_legacy_root_inbox_migrates_once
test_unsafe_devices_symlink_preserves_retry
test_hook_rejects_symlinked_inbox_fail_open
test_default_recording_can_initialize_vault
test_git_boundary

echo
echo "Results: ${PASS} passed, ${FAIL} failed"
if [[ "$FAIL" -ne 0 ]]; then
  exit 1
fi
