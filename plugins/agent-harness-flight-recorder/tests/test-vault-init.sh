#!/usr/bin/env bash
# Vault init / recipient rotation contract tests (external dependency: python3 only)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CLI="$PLUGIN_DIR/scripts/flight-recorder"
FAKE_BIN="$SCRIPT_DIR/fixtures/fake-bin"

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
  elif [[ "$status" -eq 126 || "$status" -eq 127 ]]; then
    fail "${desc}（CLIを実行できない: 終了コード ${status}）"
  else
    fail "${desc}（失敗すべき処理が成功）"
  fi
}

stat_mode() {
  python3 - "$1" <<'PY'
import os
import stat
import sys

print(f"{stat.S_IMODE(os.stat(sys.argv[1]).st_mode):03o}")
PY
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
  local state="$1" recovery_identity="$2"
  make_identity "$recovery_identity"
  run_cli "$state" init \
    --remote "git@github.com:example/private-flight-recorder.git" \
    --recovery-recipient "$(recipient_of "$recovery_identity")"
}

snapshot_tree() {
  local root="$1"
  python3 - "$root" <<'PY'
import hashlib
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
for path in sorted(p for p in root.rglob("*") if p.is_file() and ".git" not in p.parts):
    print(path.relative_to(root), hashlib.sha256(path.read_bytes()).hexdigest())
PY
}

assert_same_plaintext() {
  local desc="$1" envelope="$2"
  shift 2
  local reference="" identity decrypted
  for identity in "$@"; do
    if ! decrypted="$(PATH="$FAKE_BIN:$PATH" age -d -i "$identity" "$envelope" 2>/dev/null)"; then
      fail "$desc"
      return
    fi
    if [[ -z "$reference" ]]; then
      reference="$decrypted"
    elif [[ "$reference" != "$decrypted" ]]; then
      fail "$desc"
      return
    fi
  done
  if [[ "$(printf '%s' "$reference" | wc -c | tr -d ' ')" == "32" ]]; then
    pass "$desc"
  else
    fail "${desc}（復号結果が32 bytesではない）"
  fi
}

assert_uuid_config() {
  local config="$1" remote="$2"
  python3 - "$config" "$remote" <<'PY'
import json
import pathlib
import re
import sys

value = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
serialized = json.dumps(value, sort_keys=True)
uuids = set(re.findall(
    r"\b[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\b",
    serialized,
    re.I,
))
assert len(uuids) >= 2, uuids
assert len({candidate for candidate in uuids}) >= 2
assert sys.argv[2] in serialized
PY
}

test_init_and_recovery_contract() {
  echo "test_init_and_recovery_contract:"
  local state="$TMPDIR_TEST/init/vault" recovery="$TMPDIR_TEST/init/recovery.agekey"
  local out="$TMPDIR_TEST/init.out" err="$TMPDIR_TEST/init.err" status
  mkdir -p "$(dirname "$state")"
  init_vault "$state" "$recovery" >"$out" 2>"$err"
  status=$?
  assert_success "remoteとrecovery recipientでvaultを初期化できる" "$status"
  [[ "$status" -eq 0 ]] || return

  if assert_uuid_config "$state/vault.json" "git@github.com:example/private-flight-recorder.git" 2>/dev/null; then
    pass "vault_idとdevice_idは異なるランダムUUIDとして保存される"
  else
    fail "vault_idとdevice_idは異なるランダムUUIDとして保存される"
  fi
  assert_same_plaintext "deviceとrecoveryが同じ32-byte相関鍵を復号できる" \
    "$state/keys/correlation-key.age" "$state/keys/device.agekey" "$recovery"

  if [[ "$(stat_mode "$state/keys/device.agekey")" == "600" \
    && "$(stat_mode "$state/hash.key")" == "600" \
    && "$(stat_mode "$state")" == "700" ]]; then
    pass "ローカル秘密ファイルとstate rootを最小権限にする"
  else
    fail "ローカル秘密ファイルとstate rootを最小権限にする"
  fi

  if python3 - "$state" <<'PY' 2>/dev/null
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
key = (root / "hash.key").read_bytes()
excluded = {
    root / "hash.key",
    root / "keys/device.agekey",
    root / "keys/correlation-key.age",
}
for path in root.rglob("*"):
    if path.is_file() and path not in excluded:
        assert key not in path.read_bytes(), path
PY
  then
    pass "平文相関鍵の余分なコピーを永続化しない"
  else
    fail "平文相関鍵の余分なコピーを永続化しない"
  fi
}

test_reinit_is_noop() {
  echo "test_reinit_is_noop:"
  local state="$TMPDIR_TEST/reinit/vault" recovery="$TMPDIR_TEST/reinit/recovery.agekey"
  mkdir -p "$(dirname "$state")"
  init_vault "$state" "$recovery" >/dev/null 2>&1 || {
    fail "事前のvault初期化に成功する"
    return
  }
  local before after status
  before="$(snapshot_tree "$state")"
  run_cli "$state" init \
    --remote "git@github.com:example/private-flight-recorder.git" \
    --recovery-recipient "$(recipient_of "$recovery")" >/dev/null 2>&1
  status=$?
  after="$(snapshot_tree "$state")"
  assert_success "同じ引数の再initは成功する" "$status"
  if [[ "$before" == "$after" ]]; then
    pass "再initでdevice identityやvault内容を上書きしない"
  else
    fail "再initでdevice identityやvault内容を上書きしない"
  fi
}

test_reinit_rejects_diverged_local_key() {
  echo "test_reinit_rejects_diverged_local_key:"
  local state="$TMPDIR_TEST/reinit-diverged/vault"
  local recovery="$TMPDIR_TEST/reinit-diverged/recovery.agekey"
  local before after status
  mkdir -p "$(dirname "$state")"
  init_vault "$state" "$recovery" >/dev/null 2>&1 || {
    fail "divergenceテスト用vaultを初期化できる"
    return
  }
  printf '%s' "fedcba9876543210fedcba9876543210" >"$state/hash.key"
  before="$(snapshot_tree "$state")"
  init_vault "$state" "$recovery" >/dev/null 2>&1
  status=$?
  after="$(snapshot_tree "$state")"
  assert_failure "envelopeと異なるlocal相関鍵で再initを拒否する" "$status"
  if [[ "$before" == "$after" ]]; then
    pass "不一致検出時にidentity/envelope/configを変更しない"
  else
    fail "不一致検出時にidentity/envelope/configを変更しない"
  fi
}

test_init_adopts_existing_recorder_key() {
  echo "test_init_adopts_existing_recorder_key:"
  local state="$TMPDIR_TEST/adopt/vault"
  local recovery="$TMPDIR_TEST/adopt/recovery.agekey"
  mkdir -p "$state"
  printf '%s' "0123456789abcdef0123456789abcdef" >"$state/hash.key"
  chmod 0644 "$state/hash.key"
  make_identity "$recovery"

  init_vault "$state" "$recovery" >/dev/null 2>&1
  local status=$?
  assert_success "既存recorderの32-byte相関鍵を採用できる" "$status"
  [[ "$status" -eq 0 ]] || return
  if [[ "$(cat "$state/hash.key")" == "0123456789abcdef0123456789abcdef" \
    && "$(stat_mode "$state/hash.key")" == "600" ]]; then
    pass "既存相関鍵を変更せずpermissionだけを0600へ強化する"
  else
    fail "既存相関鍵を変更せずpermissionだけを0600へ強化する"
  fi
  assert_same_plaintext "採用した既存相関鍵をdevice/recoveryへ暗号化する" \
    "$state/keys/correlation-key.age" "$state/keys/device.agekey" "$recovery"
}

test_init_rolls_back_on_dependency_failure() {
  echo "test_init_rolls_back_on_dependency_failure:"
  local state_keygen="$TMPDIR_TEST/rollback-keygen/vault"
  local state_encrypt="$TMPDIR_TEST/rollback-encrypt/vault"
  local recovery="$TMPDIR_TEST/rollback-recovery.agekey" status
  make_identity "$recovery"

  FAKE_AGE_KEYGEN_FAIL=1 run_cli "$state_keygen" init \
    --remote "git@github.com:example/private-flight-recorder.git" \
    --recovery-recipient "$(recipient_of "$recovery")" >/dev/null 2>&1
  status=$?
  assert_failure "age-keygen失敗を呼び出し元へ返す" "$status"
  if [[ ! -d "$state_keygen" || -z "$(find "$state_keygen" -type f -print -quit)" ]]; then
    pass "age-keygen失敗時に部分的vaultを残さない"
  else
    fail "age-keygen失敗時に部分的vaultを残さない"
  fi

  FAKE_AGE_ENCRYPT_FAIL=1 run_cli "$state_encrypt" init \
    --remote "git@github.com:example/private-flight-recorder.git" \
    --recovery-recipient "$(recipient_of "$recovery")" >/dev/null 2>&1
  status=$?
  assert_failure "age暗号化失敗を呼び出し元へ返す" "$status"
  if [[ ! -d "$state_encrypt" || -z "$(find "$state_encrypt" -type f -print -quit)" ]]; then
    pass "暗号化失敗時に秘密鍵や平文鍵を残さない"
  else
    fail "暗号化失敗時に秘密鍵や平文鍵を残さない"
  fi
}

test_init_recovers_interrupted_commit() {
  echo "test_init_recovers_interrupted_commit:"
  local state="$TMPDIR_TEST/interrupted/vault"
  local recovery="$TMPDIR_TEST/interrupted/recovery.agekey" status
  mkdir -p "$state/keys"
  printf '%s' "0123456789abcdef0123456789abcdef" >"$state/hash.key"
  printf '%s' '{"created_hash_key":false}' >"$state/.init-in-progress"
  printf '%s' "partial-identity" >"$state/keys/device.agekey"
  printf '%s' "partial-envelope" >"$state/keys/correlation-key.age"
  printf '%s' "partial-config" >"$state/vault.json"
  printf '%s' "partial-ignore" >"$state/.gitignore"
  make_identity "$recovery"

  init_vault "$state" "$recovery" >/dev/null 2>&1
  status=$?
  assert_success "中断markerからpartial initを自動復旧できる" "$status"
  [[ "$status" -eq 0 ]] || return
  if [[ ! -e "$state/.init-in-progress" \
    && "$(cat "$state/hash.key")" == "0123456789abcdef0123456789abcdef" ]]; then
    pass "既存recorder鍵を保ったまま中断stateを確定する"
  else
    fail "既存recorder鍵を保ったまま中断stateを確定する"
  fi
  assert_same_plaintext "復旧後envelopeをdevice/recoveryから復号できる" \
    "$state/keys/correlation-key.age" "$state/keys/device.agekey" "$recovery"
}

test_rejects_invalid_recipient() {
  echo "test_rejects_invalid_recipient:"
  local state="$TMPDIR_TEST/invalid/vault" status
  run_cli "$state" init \
    --remote "git@github.com:example/private-flight-recorder.git" \
    --recovery-recipient "not-a-recipient" >/dev/null 2>&1
  status=$?
  assert_failure "age形式でないrecovery recipientを拒否する" "$status"
  if [[ ! -d "$state" || -z "$(find "$state" -type f -print -quit)" ]]; then
    pass "不正recipientでvault内容を作らない"
  else
    fail "不正recipientでvault内容を作らない"
  fi
}

test_rejects_relative_state_root() {
  echo "test_rejects_relative_state_root:"
  local sandbox="$TMPDIR_TEST/relative-state"
  local recovery="$TMPDIR_TEST/relative-state-recovery.agekey" status
  mkdir -p "$sandbox"
  make_identity "$recovery"
  (
    cd "$sandbox" || exit 1
    PATH="$FAKE_BIN:$PATH" FLIGHT_RECORDER_STATE_DIR="relative-vault" \
      "$CLI" init \
      --remote "git@github.com:example/private-flight-recorder.git" \
      --recovery-recipient "$(recipient_of "$recovery")" >/dev/null 2>&1
  )
  status=$?
  assert_failure "相対FLIGHT_RECORDER_STATE_DIRを拒否する" "$status"
  if [[ ! -e "$sandbox/relative-vault" ]]; then
    pass "cwd依存の分岐Vaultを作らない"
  else
    fail "cwd依存の分岐Vaultを作らない"
  fi
}

test_rejects_symlinked_keys_directory() {
  echo "test_rejects_symlinked_keys_directory:"
  local state="$TMPDIR_TEST/symlink/vault"
  local outside="$TMPDIR_TEST/symlink/outside"
  local recovery="$TMPDIR_TEST/symlink/recovery.agekey" status
  mkdir -p "$state" "$outside"
  printf '%s' "outside-canary" >"$outside/canary"
  ln -s "$outside" "$state/keys"
  make_identity "$recovery"

  run_cli "$state" init \
    --remote "git@github.com:example/private-flight-recorder.git" \
    --recovery-recipient "$(recipient_of "$recovery")" >/dev/null 2>&1
  status=$?
  assert_failure "Vault外へ向くkeys symlinkを拒否する" "$status"
  if [[ "$(cat "$outside/canary")" == "outside-canary" \
    && ! -e "$outside/device.agekey" \
    && ! -e "$outside/correlation-key.age" ]]; then
    pass "keys symlink先のファイルを変更しない"
  else
    fail "keys symlink先のファイルを変更しない"
  fi
}

test_concurrent_init_is_consistent() {
  echo "test_concurrent_init_is_consistent:"
  local state="$TMPDIR_TEST/concurrent-init/vault"
  local recovery="$TMPDIR_TEST/concurrent-init/recovery.agekey"
  local statuses="$TMPDIR_TEST/concurrent-init/statuses"
  mkdir -p "$(dirname "$state")"
  make_identity "$recovery"
  : >"$statuses"

  local index
  for index in 1 2; do
    (
      run_cli "$state" init \
        --remote "git@github.com:example/private-flight-recorder.git" \
        --recovery-recipient "$(recipient_of "$recovery")" >/dev/null 2>&1
      echo "$?" >>"$statuses"
    ) &
  done
  wait

  if [[ "$(sort "$statuses" | tr -d '\n')" == "00" ]]; then
    pass "同時initを直列化して両呼び出しを安全な成功にする"
  else
    fail "同時initを直列化して両呼び出しを安全な成功にする"
  fi
  assert_same_plaintext "同時init後もdevice/recovery/envelopeが同一系列になる" \
    "$state/keys/correlation-key.age" "$state/keys/device.agekey" "$recovery"
}

test_device_add_and_recovery_rotation() {
  echo "test_device_add_and_recovery_rotation:"
  local state="$TMPDIR_TEST/add/vault" recovery="$TMPDIR_TEST/add/recovery.agekey"
  local device_b="$TMPDIR_TEST/add/device-b.agekey" status
  mkdir -p "$(dirname "$state")"
  init_vault "$state" "$recovery" >/dev/null 2>&1 || {
    fail "事前のvault初期化に成功する"
    return
  }
  make_identity "$device_b"
  run_cli "$state" device add --recipient "$(recipient_of "$device_b")" >/dev/null 2>&1
  status=$?
  assert_success "既存device identityでdevice Bを追加できる" "$status"
  [[ "$status" -eq 0 ]] || return
  assert_same_plaintext "A/B/recoveryが再暗号化後も同じ鍵を復号できる" \
    "$state/keys/correlation-key.age" "$state/keys/device.agekey" "$device_b" "$recovery"

  local state_recovery="$TMPDIR_TEST/add-recovery/vault"
  local recovery_2="$TMPDIR_TEST/add-recovery/recovery.agekey"
  local device_c="$TMPDIR_TEST/add-recovery/device-c.agekey"
  mkdir -p "$(dirname "$state_recovery")"
  init_vault "$state_recovery" "$recovery_2" >/dev/null 2>&1 || {
    fail "recovery経由テスト用vaultを初期化できる"
    return
  }
  make_identity "$device_c"
  run_cli "$state_recovery" device add \
    --identity "$recovery_2" \
    --recipient "$(recipient_of "$device_c")" >/dev/null 2>&1
  status=$?
  assert_success "recovery identityを明示してdeviceを追加できる" "$status"
  [[ "$status" -eq 0 ]] || return
  assert_same_plaintext "recovery経由追加後も既存device/recovery/new deviceが復号できる" \
    "$state_recovery/keys/correlation-key.age" \
    "$state_recovery/keys/device.agekey" "$recovery_2" "$device_c"
}

test_device_join_bootstraps_synced_vault() {
  echo "test_device_join_bootstraps_synced_vault:"
  local source="$TMPDIR_TEST/join/source"
  local joined="$TMPDIR_TEST/join/joined"
  local recovery="$TMPDIR_TEST/join/recovery.agekey" status
  mkdir -p "$(dirname "$source")" "$joined/keys"
  init_vault "$source" "$recovery" >/dev/null 2>&1 || {
    fail "join元vaultを初期化できる"
    return
  }
  cp "$source/vault.json" "$joined/vault.json"
  cp "$source/.gitignore" "$joined/.gitignore"
  cp "$source/keys/correlation-key.age" "$joined/keys/correlation-key.age"

  run_cli "$joined" device join --identity "$recovery" >/dev/null 2>&1
  status=$?
  assert_success "同期済み公開Vaultへrecovery identityでjoinできる" "$status"
  [[ "$status" -eq 0 ]] || return
  if [[ -s "$joined/keys/device.agekey" \
    && "$(wc -c <"$joined/hash.key" | tr -d ' ')" == "32" ]]; then
    pass "join先にdevice identityとローカル相関鍵をmaterializeする"
  else
    fail "join先にdevice identityとローカル相関鍵をmaterializeする"
  fi
  assert_same_plaintext "join端末とrecoveryが同じVault相関鍵を復号できる" \
    "$joined/keys/correlation-key.age" "$joined/keys/device.agekey" "$recovery"
  if python3 - "$source/vault.json" "$joined/vault.json" <<'PY' 2>/dev/null
import json
import pathlib
import sys

before, after = [
    json.loads(pathlib.Path(path).read_text(encoding="utf-8"))
    for path in sys.argv[1:]
]
assert before["vault_id"] == after["vault_id"]
assert len(after["devices"]) == len(before["devices"]) + 1
assert len({device["device_id"] for device in after["devices"]}) == len(after["devices"])
assert len({device["recipient"] for device in after["devices"]}) == len(after["devices"])
PY
  then
    pass "join時にVault IDを維持して新しいdevice IDを登録する"
  else
    fail "join時にVault IDを維持して新しいdevice IDを登録する"
  fi
}

test_device_join_adopts_preenrolled_identity() {
  echo "test_device_join_adopts_preenrolled_identity:"
  local source="$TMPDIR_TEST/join-pre/source"
  local joined="$TMPDIR_TEST/join-pre/joined"
  local recovery="$TMPDIR_TEST/join-pre/recovery.agekey"
  local device_b="$TMPDIR_TEST/join-pre/device-b.agekey" status
  mkdir -p "$(dirname "$source")" "$joined/keys"
  init_vault "$source" "$recovery" >/dev/null 2>&1 || {
    fail "pre-enroll元vaultを初期化できる"
    return
  }
  make_identity "$device_b"
  run_cli "$source" device add --recipient "$(recipient_of "$device_b")" \
    >/dev/null 2>&1 || {
    fail "device Bをpre-enrollできる"
    return
  }
  cp "$source/vault.json" "$joined/vault.json"
  cp "$source/.gitignore" "$joined/.gitignore"
  cp "$source/keys/correlation-key.age" "$joined/keys/correlation-key.age"

  run_cli "$joined" device join --identity "$device_b" >/dev/null 2>&1
  status=$?
  assert_success "pre-enroll済みidentityでjoinできる" "$status"
  [[ "$status" -eq 0 ]] || return
  if [[ "$(recipient_of "$joined/keys/device.agekey")" == "$(recipient_of "$device_b")" ]]; then
    pass "pre-enroll済みidentityをlocal device identityとして採用する"
  else
    fail "pre-enroll済みidentityをlocal device identityとして採用する"
  fi
  if python3 - "$source/vault.json" "$joined/vault.json" <<'PY' 2>/dev/null
import json
import pathlib
import sys

before, after = [
    json.loads(pathlib.Path(path).read_text(encoding="utf-8"))
    for path in sys.argv[1:]
]
assert before["devices"] == after["devices"]
PY
  then
    pass "pre-enroll joinでdevice IDやrecipientを二重登録しない"
  else
    fail "pre-enroll joinでdevice IDやrecipientを二重登録しない"
  fi
  assert_same_plaintext "pre-enroll端末/recoveryが同じ鍵を復号できる" \
    "$joined/keys/correlation-key.age" "$joined/keys/device.agekey" "$recovery"
}

test_device_add_is_atomic() {
  echo "test_device_add_is_atomic:"
  local state="$TMPDIR_TEST/add-atomic/vault" recovery="$TMPDIR_TEST/add-atomic/recovery.agekey"
  local unauthorized="$TMPDIR_TEST/add-atomic/unauthorized.agekey"
  local target="$TMPDIR_TEST/add-atomic/target.agekey" before after status
  mkdir -p "$(dirname "$state")"
  init_vault "$state" "$recovery" >/dev/null 2>&1 || {
    fail "事前のvault初期化に成功する"
    return
  }
  make_identity "$unauthorized"
  make_identity "$target"
  before="$(snapshot_tree "$state")"
  run_cli "$state" device add --identity "$unauthorized" \
    --recipient "$(recipient_of "$target")" >/dev/null 2>&1
  status=$?
  after="$(snapshot_tree "$state")"
  assert_failure "未認可identityによるdevice追加を拒否する" "$status"
  if [[ "$before" == "$after" ]]; then
    pass "未認可identity失敗時にvaultを変更しない"
  else
    fail "未認可identity失敗時にvaultを変更しない"
  fi

  FAKE_AGE_ENCRYPT_FAIL=1 run_cli "$state" device add \
    --recipient "$(recipient_of "$target")" >/dev/null 2>&1
  status=$?
  after="$(snapshot_tree "$state")"
  assert_failure "再暗号化失敗を呼び出し元へ返す" "$status"
  if [[ "$before" == "$after" ]]; then
    pass "再暗号化失敗時にenvelope/configを原状維持する"
  else
    fail "再暗号化失敗時にenvelope/configを原状維持する"
  fi
}

test_rejects_tampered_recipient_registry() {
  echo "test_rejects_tampered_recipient_registry:"
  local state="$TMPDIR_TEST/tamper/vault" recovery="$TMPDIR_TEST/tamper/recovery.agekey"
  local injected="$TMPDIR_TEST/tamper/injected.agekey"
  local target="$TMPDIR_TEST/tamper/target.agekey" before after status
  mkdir -p "$(dirname "$state")"
  init_vault "$state" "$recovery" >/dev/null 2>&1 || {
    fail "tamperテスト用vaultを初期化できる"
    return
  }
  make_identity "$injected"
  make_identity "$target"
  python3 - "$state/vault.json" "$(recipient_of "$injected")" <<'PY'
import json
import pathlib
import sys
import uuid

path = pathlib.Path(sys.argv[1])
config = json.loads(path.read_text(encoding="utf-8"))
config["devices"].append({"device_id": str(uuid.uuid4()), "recipient": sys.argv[2]})
path.write_text(json.dumps(config, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
  before="$(snapshot_tree "$state")"
  run_cli "$state" device add --recipient "$(recipient_of "$target")" >/dev/null 2>&1
  status=$?
  after="$(snapshot_tree "$state")"
  assert_failure "HMACと一致しないrecipient台帳を拒否する" "$status"
  if [[ "$before" == "$after" ]]; then
    pass "改ざんrecipientへ鍵を再暗号化せずVaultを変更しない"
  else
    fail "改ざんrecipientへ鍵を再暗号化せずVaultを変更しない"
  fi
}

test_git_eligibility_boundary() {
  echo "test_git_eligibility_boundary:"
  local state="$TMPDIR_TEST/git/vault" recovery="$TMPDIR_TEST/git/recovery.agekey"
  mkdir -p "$(dirname "$state")"
  init_vault "$state" "$recovery" >/dev/null 2>&1 || {
    fail "事前のvault初期化に成功する"
    return
  }
  mkdir -p "$state/chunks/device-a/2026/07/24"
  printf '%s\n' '{"plaintext":"must-not-sync"}' \
    >"$state/chunks/device-a/2026/07/24/chunk.jsonl"
  git -C "$state" init -q
  if git -C "$state" check-ignore -q hash.key \
    && git -C "$state" check-ignore -q keys/device.agekey \
    && git -C "$state" check-ignore -q events.jsonl \
    && git -C "$state" check-ignore -q chunks/device-a/2026/07/24/chunk.jsonl; then
    pass "平文鍵・device秘密鍵・イベントログをGit対象外にする"
  else
    fail "平文鍵・device秘密鍵・イベントログをGit対象外にする"
  fi
  if ! git -C "$state" check-ignore -q vault.json \
    && ! git -C "$state" check-ignore -q keys/correlation-key.age; then
    pass "公開設定と暗号化envelopeだけをGit同期可能にする"
  else
    fail "公開設定と暗号化envelopeだけをGit同期可能にする"
  fi

  local eligible
  eligible="$(git -C "$state" ls-files --others --exclude-standard | sort)"
  if [[ "$eligible" == *".gitignore"* \
    && "$eligible" == *"vault.json"* \
    && "$eligible" == *"keys/correlation-key.age"* \
    && "$eligible" != *"hash.key"* \
    && "$eligible" != *"device.agekey"* ]]; then
    pass "Git eligible集合に秘密情報を含めない"
  else
    fail "Git eligible集合に秘密情報を含めない"
  fi
}

echo "=== Flight Recorder Vault Tests ==="
test_init_and_recovery_contract
test_reinit_is_noop
test_reinit_rejects_diverged_local_key
test_init_adopts_existing_recorder_key
test_init_rolls_back_on_dependency_failure
test_init_recovers_interrupted_commit
test_rejects_invalid_recipient
test_rejects_relative_state_root
test_rejects_symlinked_keys_directory
test_concurrent_init_is_consistent
test_device_add_and_recovery_rotation
test_device_join_bootstraps_synced_vault
test_device_join_adopts_preenrolled_identity
test_device_add_is_atomic
test_rejects_tampered_recipient_registry
test_git_eligibility_boundary

echo
echo "Results: ${PASS} passed, ${FAIL} failed"
if [[ "$FAIL" -ne 0 ]]; then
  exit 1
fi
