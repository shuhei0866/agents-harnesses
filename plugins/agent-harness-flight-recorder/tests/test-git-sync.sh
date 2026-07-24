#!/usr/bin/env bash
# Manual Git sync contract tests (external dependencies: git and python3).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CLI="$PLUGIN_DIR/scripts/flight-recorder"
RECORDER="$PLUGIN_DIR/scripts/record-event"
FAKE_BIN="$SCRIPT_DIR/fixtures/fake-bin"
FIXTURE="$SCRIPT_DIR/fixtures/claude-code-stop.json"
TEST_ROOT="$(mktemp -d)"
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

record_event() {
  local state="$1" now="$2"
  FLIGHT_RECORDER_STATE_DIR="$state" \
    AGENT_FLIGHT_RECORDER_NOW="$now" \
    "$RECORDER" --harness claude-code <"$FIXTURE" >/dev/null 2>&1
}

init_remote() {
  local remote="$1"
  git init -q --bare "$remote"
  git -C "$remote" symbolic-ref HEAD refs/heads/main
}

init_vault() {
  local state="$1" remote="$2" recovery="$3"
  make_identity "$recovery"
  run_cli "$state" init \
    --remote "$remote" \
    --recovery-recipient "$(recipient_of "$recovery")"
}

count_imports() {
  find "$1/cache/imported" -type f -name '*.jsonl' 2>/dev/null | wc -l | tr -d ' '
}

count_remote_chunks() {
  local remote="$1"
  git --git-dir="$remote" ls-tree -r --name-only main 2>/dev/null \
    | grep -Ec '^devices/[0-9a-f-]+/[0-9]{4}/[0-9]{2}/[0-9]{2}/[0-9a-f]{64}\.jsonl\.age$' \
    || true
}

test_empty_remote_and_idempotent_import() {
  echo "test_empty_remote_and_idempotent_import:"
  local base="$TEST_ROOT/bootstrap"
  local remote="$base/remote.git" state="$base/vault" recovery="$base/recovery.agekey"
  mkdir -p "$base"
  init_remote "$remote"
  init_vault "$state" "$remote" "$recovery" >/dev/null 2>&1
  record_event "$state" "2026-07-25T01:00:00Z"

  if run_cli "$state" sync >/dev/null 2>&1; then
    pass "empty private remoteをbootstrapして同期できる"
  else
    fail "empty private remoteをbootstrapして同期できる"
    return
  fi
  local before_head before_imports after_head after_imports
  before_head="$(git -C "$state" rev-parse HEAD)"
  before_imports="$(count_imports "$state")"
  run_cli "$state" sync >/dev/null 2>&1
  run_cli "$state" sync >/dev/null 2>&1
  after_head="$(git -C "$state" rev-parse HEAD)"
  after_imports="$(count_imports "$state")"

  if [[ "$before_head" == "$after_head" && "$before_imports" == "1" \
    && "$after_imports" == "1" && ! -e "$state/queue/pending-sync.json" ]]; then
    pass "再syncで空commitやimport重複を作らない"
  else
    fail "再syncで空commitやimport重複を作らない"
  fi
  if git --git-dir="$remote" ls-tree -r --name-only main \
    | grep -Eq '(^|/)(hash\.key|device\.agekey|events\.jsonl|pending-sync\.json)$'; then
    fail "remote treeへplaintext/private keyを入れない"
  else
    pass "remote treeへplaintext/private keyを入れない"
  fi
}

test_two_devices_exchange_chunks() {
  echo "test_two_devices_exchange_chunks:"
  local base="$TEST_ROOT/two-devices"
  local remote="$base/remote.git" a="$base/a" b="$base/b"
  local recovery="$base/recovery.agekey" b_identity="$base/b.agekey"
  mkdir -p "$base"
  init_remote "$remote"
  init_vault "$a" "$remote" "$recovery" >/dev/null 2>&1
  make_identity "$b_identity"
  run_cli "$a" device add --recipient "$(recipient_of "$b_identity")" >/dev/null 2>&1
  record_event "$a" "2026-07-25T02:00:00Z"
  run_cli "$a" sync >/dev/null 2>&1 || {
    fail "device Aを初回同期できる"
    return
  }
  git clone -q "$remote" "$b"
  run_cli "$b" device join --identity "$b_identity" >/dev/null 2>&1
  record_event "$b" "2026-07-25T02:01:00Z"
  run_cli "$b" sync >/dev/null 2>&1
  run_cli "$a" sync >/dev/null 2>&1
  run_cli "$b" sync >/dev/null 2>&1

  if [[ "$(count_remote_chunks "$remote")" == "2" \
    && "$(count_imports "$a")" == "2" \
    && "$(count_imports "$b")" == "2" ]]; then
    pass "二端末のdevice-scoped chunkをconflictなく交換・importする"
  else
    fail "二端末のdevice-scoped chunkをconflictなく交換・importする"
  fi
}

test_push_failure_preserves_pending_and_recovers() {
  echo "test_push_failure_preserves_pending_and_recovers:"
  local base="$TEST_ROOT/push-failure"
  local remote="$base/remote.git" state="$base/vault" recovery="$base/recovery.agekey"
  mkdir -p "$base"
  init_remote "$remote"
  init_vault "$state" "$remote" "$recovery" >/dev/null 2>&1
  record_event "$state" "2026-07-25T03:00:00Z"
  printf '%s\n' '#!/bin/sh' 'exit 1' >"$remote/hooks/pre-receive"
  chmod +x "$remote/hooks/pre-receive"

  if run_cli "$state" sync >/dev/null 2>&1; then
    fail "push rejectionを成功扱いしない"
  elif [[ -n "$(find "$state/devices" -type f -name '*.jsonl.age' -print -quit)" \
    && -e "$state/queue/pending-sync.json" \
    && "$(git -C "$state" rev-list --count HEAD)" -ge 1 ]] \
    && python3 - "$state/queue/pending-sync.json" <<'PY' 2>/dev/null
import json
import pathlib
import sys

pending = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert pending["schema_version"] == 1
assert pending["phase"] == "push_pending"
assert pending["last_error_category"] == "remote"
assert pending["attempt_count"] >= 1
assert pending["commit_oid"]
assert len(pending["artifact_paths"]) == 1
PY
  then
    pass "push失敗時に暗号化artifact・commit・pendingを保持する"
  else
    fail "push失敗時に暗号化artifact・commit・pendingを保持する"
  fi

  rm "$remote/hooks/pre-receive"
  if run_cli "$state" sync >/dev/null 2>&1 \
    && [[ "$(count_remote_chunks "$remote")" == "1" \
      && ! -e "$state/queue/pending-sync.json" ]]; then
    pass "再試行で重複なくpushしpendingを解消する"
  else
    fail "再試行で重複なくpushしpendingを解消する"
  fi
}

test_preflight_rejects_tracked_secret() {
  echo "test_preflight_rejects_tracked_secret:"
  local base="$TEST_ROOT/preflight"
  local remote="$base/remote.git" state="$base/vault" recovery="$base/recovery.agekey"
  mkdir -p "$base"
  init_remote "$remote"
  init_vault "$state" "$remote" "$recovery" >/dev/null 2>&1
  run_cli "$state" sync >/dev/null 2>&1 || {
    fail "preflight fixtureを初期同期できる"
    return
  }
  git -C "$state" add -f hash.key
  local before
  before="$(git --git-dir="$remote" rev-parse main)"
  if run_cli "$state" sync >/dev/null 2>&1; then
    fail "tracked private keyをpreflightで拒否する"
  elif [[ "$before" == "$(git --git-dir="$remote" rev-parse main)" ]] \
    && ! git --git-dir="$remote" ls-tree -r --name-only main | grep -qx 'hash.key'; then
    pass "tracked private keyをcommit/push前に拒否する"
  else
    fail "tracked private keyをcommit/push前に拒否する"
  fi
}

test_preflight_validates_ciphertext_before_commit() {
  echo "test_preflight_validates_ciphertext_before_commit:"
  local base="$TEST_ROOT/ciphertext-preflight"
  local remote="$base/remote.git" state="$base/vault" recovery="$base/recovery.agekey"
  mkdir -p "$base"
  init_remote "$remote"
  init_vault "$state" "$remote" "$recovery" >/dev/null 2>&1
  run_cli "$state" sync >/dev/null 2>&1 || {
    fail "ciphertext preflight fixtureを初期同期できる"
    return
  }
  local device path before
  device="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["devices"][0]["device_id"])' "$state/vault.json")"
  path="$state/devices/$device/2026/07/25/$(printf '0%.0s' {1..64}).jsonl.age"
  mkdir -p "$(dirname "$path")"
  printf '%s\n' '{"plaintext":"must-not-enter-a-commit"}' >"$path"
  before="$(git -C "$state" rev-parse HEAD)"

  if run_cli "$state" sync >/dev/null 2>&1; then
    fail "allowed pathに偽装したplaintextを拒否する"
  elif [[ "$before" == "$(git -C "$state" rev-parse HEAD)" ]] \
    && ! git -C "$state" ls-files --error-unmatch \
      "${path#"$state/"}" >/dev/null 2>&1; then
    pass "ciphertextを復号・検証してからだけcommitする"
  else
    fail "ciphertextを復号・検証してからだけcommitする"
  fi
}

test_import_receipt_detects_blob_replacement() {
  echo "test_import_receipt_detects_blob_replacement:"
  local base="$TEST_ROOT/blob-replacement"
  local remote="$base/remote.git" state="$base/vault" recovery="$base/recovery.agekey"
  mkdir -p "$base"
  init_remote "$remote"
  init_vault "$state" "$remote" "$recovery" >/dev/null 2>&1
  record_event "$state" "2026-07-25T04:00:00Z"
  run_cli "$state" sync >/dev/null 2>&1 || {
    fail "blob replacement fixtureを初期同期できる"
    return
  }
  local artifact before
  artifact="$(find "$state/devices" -type f -name '*.jsonl.age' -print -quit)"
  before="$(git -C "$state" rev-parse HEAD)"
  python3 - "$artifact" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
envelope = json.loads(path.read_text(encoding="utf-8"))
envelope["transport_nonce"] = "different-git-blob"
path.write_text(json.dumps(envelope, sort_keys=True), encoding="utf-8")
PY

  if run_cli "$state" sync >/dev/null 2>&1; then
    fail "import済みimmutable artifactのblob置換を拒否する"
  elif [[ "$before" == "$(git -C "$state" rev-parse HEAD)" ]]; then
    pass "receiptのblob OID不一致をcommit前に検出する"
  else
    fail "receiptのblob OID不一致をcommit前に検出する"
  fi
}

test_preflight_rejects_divergent_push_url() {
  echo "test_preflight_rejects_divergent_push_url:"
  local base="$TEST_ROOT/push-url"
  local remote="$base/remote.git" other="$base/other.git"
  local state="$base/vault" recovery="$base/recovery.agekey"
  mkdir -p "$base"
  init_remote "$remote"
  init_remote "$other"
  init_vault "$state" "$remote" "$recovery" >/dev/null 2>&1
  run_cli "$state" sync >/dev/null 2>&1 || {
    fail "push URL fixtureを初期同期できる"
    return
  }
  git -C "$state" remote set-url --push origin "$other"
  record_event "$state" "2026-07-25T05:00:00Z"

  if run_cli "$state" sync >/dev/null 2>&1; then
    fail "vault.jsonと異なるpush URLを拒否する"
  elif ! git --git-dir="$other" show-ref --verify --quiet refs/heads/main; then
    pass "別push URLへ暗号化artifactを送信しない"
  else
    fail "別push URLへ暗号化artifactを送信しない"
  fi
}

test_remote_failure_does_not_block_hook() {
  echo "test_remote_failure_does_not_block_hook:"
  local base="$TEST_ROOT/hook-independence"
  local remote="$base/remote.git" state="$base/vault" recovery="$base/recovery.agekey"
  local marker="$base/network-started" release="$base/network-release"
  mkdir -p "$base"
  init_remote "$remote"
  init_vault "$state" "$remote" "$recovery" >/dev/null 2>&1
  run_cli "$state" sync >/dev/null 2>&1 || {
    fail "hook independence fixtureを初期同期できる"
    return
  }
  record_event "$state" "2026-07-25T06:00:00Z"
  {
    printf '%s\n' '#!/bin/sh'
    printf 'touch "%s"\n' "$marker"
    printf 'while [ ! -e "%s" ]; do sleep 0.01; done\n' "$release"
    printf '%s\n' 'exit 1'
  } >"$remote/hooks/pre-receive"
  chmod +x "$remote/hooks/pre-receive"
  run_cli "$state" sync >/dev/null 2>&1 &
  local sync_pid=$! attempts=0
  while [[ ! -e "$marker" && "$attempts" -lt 200 ]]; do
    sleep 0.01
    attempts=$((attempts + 1))
  done
  if [[ ! -e "$marker" ]]; then
    fail "network failure fixtureがpushへ到達する"
    kill "$sync_pid" 2>/dev/null || true
    return
  fi

  record_event "$state" "2026-07-25T06:01:00Z" &
  local recorder_pid=$!
  sleep 0.5
  if ! kill -0 "$recorder_pid" 2>/dev/null \
    && [[ "$(wc -l <"$state/inbox/events.jsonl" | tr -d ' ')" == "1" ]]; then
    pass "network待機中もhookをblockせず完全なeventを記録する"
  else
    fail "network待機中もhookをblockせず完全なeventを記録する"
  fi
  touch "$release"
  wait "$recorder_pid" 2>/dev/null || true
  if wait "$sync_pid"; then
    fail "remote rejectionをsync成功扱いしない"
  elif [[ -e "$state/queue/pending-sync.json" ]]; then
    pass "remote failureをsyncだけに閉じpendingを保持する"
  else
    fail "remote failureをsyncだけに閉じpendingを保持する"
  fi
}

test_preflight_rejects_allowlisted_metadata_smuggling() {
  echo "test_preflight_rejects_allowlisted_metadata_smuggling:"
  local base="$TEST_ROOT/metadata-smuggling"
  local remote="$base/remote.git" state="$base/vault" recovery="$base/recovery.agekey"
  mkdir -p "$base"
  init_remote "$remote"
  init_vault "$state" "$remote" "$recovery" >/dev/null 2>&1
  run_cli "$state" sync >/dev/null 2>&1 || {
    fail "metadata smuggling fixtureを初期同期できる"
    return
  }
  local before
  before="$(git -C "$state" rev-parse HEAD)"
  cp "$state/keys/device.agekey" "$state/keys/correlation-key.age"
  if run_cli "$state" sync >/dev/null 2>&1; then
    fail "envelope pathへ偽装したprivate keyを拒否する"
  elif [[ "$before" == "$(git -C "$state" rev-parse HEAD)" ]]; then
    pass "envelopeを復号検証してからだけcommitする"
  else
    fail "envelopeを復号検証してからだけcommitする"
  fi

  local remote2="$base/remote2.git" state2="$base/vault2" recovery2="$base/recovery2.agekey"
  init_remote "$remote2"
  init_vault "$state2" "$remote2" "$recovery2" >/dev/null 2>&1
  run_cli "$state2" sync >/dev/null 2>&1
  before="$(git -C "$state2" rev-parse HEAD)"
  python3 - "$state2/vault.json" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
config = json.loads(path.read_text(encoding="utf-8"))
config["secret"] = "must-not-enter-allowlisted-metadata"
path.write_text(json.dumps(config, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
  if run_cli "$state2" sync >/dev/null 2>&1; then
    fail "vault.jsonの未知fieldを拒否する"
  elif [[ "$before" == "$(git -C "$state2" rev-parse HEAD)" ]]; then
    pass "vault schema外のplaintext metadataをcommitしない"
  else
    fail "vault schema外のplaintext metadataをcommitしない"
  fi
}

echo "=== Flight Recorder Manual Git Sync Tests ==="
test_empty_remote_and_idempotent_import
test_two_devices_exchange_chunks
test_push_failure_preserves_pending_and_recovers
test_preflight_rejects_tracked_secret
test_preflight_validates_ciphertext_before_commit
test_import_receipt_detects_blob_replacement
test_preflight_rejects_divergent_push_url
test_remote_failure_does_not_block_hook
test_preflight_rejects_allowlisted_metadata_smuggling
echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
