#!/usr/bin/env bash
# Real-age smoke test. Contract tests use a fake CLI so they remain dependency-free.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CLI="$PLUGIN_DIR/scripts/flight-recorder"

if ! command -v age >/dev/null 2>&1 || ! command -v age-keygen >/dev/null 2>&1; then
  echo "SKIP: age and age-keygen are required for the real encryption E2E"
  exit 0
fi

TEST_ROOT="$(mktemp -d)"
cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

VAULT="$TEST_ROOT/vault"
RECOVERY_IDENTITY="$TEST_ROOT/recovery.agekey"

age-keygen -o "$RECOVERY_IDENTITY" >/dev/null
recovery_recipient="$(age-keygen -y "$RECOVERY_IDENTITY")"

FLIGHT_RECORDER_STATE_DIR="$VAULT" "$CLI" init \
  --remote "git@github.com:example/private-flight-recorder.git" \
  --recovery-recipient "$recovery_recipient"

age -d -i "$VAULT/keys/device.agekey" \
  -o "$TEST_ROOT/device-a.key" "$VAULT/keys/correlation-key.age"
age -d -i "$RECOVERY_IDENTITY" \
  -o "$TEST_ROOT/recovery.key" "$VAULT/keys/correlation-key.age"

test "$(wc -c <"$TEST_ROOT/device-a.key" | tr -d ' ')" = "32"
cmp "$TEST_ROOT/device-a.key" "$TEST_ROOT/recovery.key"

JOINED_VAULT="$TEST_ROOT/joined-vault"
mkdir -p "$JOINED_VAULT/keys"
cp "$VAULT/vault.json" "$JOINED_VAULT/vault.json"
cp "$VAULT/.gitignore" "$JOINED_VAULT/.gitignore"
cp "$VAULT/keys/correlation-key.age" "$JOINED_VAULT/keys/correlation-key.age"
FLIGHT_RECORDER_STATE_DIR="$JOINED_VAULT" "$CLI" device join \
  --identity "$RECOVERY_IDENTITY"

age -d -i "$VAULT/keys/device.agekey" \
  -o "$TEST_ROOT/device-a-after.key" "$JOINED_VAULT/keys/correlation-key.age"
age -d -i "$JOINED_VAULT/keys/device.agekey" \
  -o "$TEST_ROOT/device-b.key" "$JOINED_VAULT/keys/correlation-key.age"
age -d -i "$RECOVERY_IDENTITY" \
  -o "$TEST_ROOT/recovery-after.key" "$JOINED_VAULT/keys/correlation-key.age"

cmp "$TEST_ROOT/device-a.key" "$TEST_ROOT/device-a-after.key"
cmp "$TEST_ROOT/device-a.key" "$TEST_ROOT/device-b.key"
cmp "$TEST_ROOT/device-a.key" "$TEST_ROOT/recovery-after.key"

python3 - "$JOINED_VAULT/hash.key" "$JOINED_VAULT/keys/correlation-key.age" <<'PY'
import pathlib
import sys

key = pathlib.Path(sys.argv[1]).read_bytes()
envelope = pathlib.Path(sys.argv[2]).read_bytes()
assert len(key) == 32
assert key not in envelope
PY

echo "PASS: real age decrypts one envelope for device A, device B, and recovery"
