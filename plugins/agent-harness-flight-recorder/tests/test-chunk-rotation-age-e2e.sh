#!/usr/bin/env bash
# Real-age chunk smoke test. The main contract suite remains dependency-free.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CLI="$PLUGIN_DIR/scripts/flight-recorder"
RECORDER="$PLUGIN_DIR/scripts/record-event"
FIXTURE="$SCRIPT_DIR/fixtures/claude-code-stop.json"

if ! command -v age >/dev/null 2>&1 || ! command -v age-keygen >/dev/null 2>&1; then
  echo "SKIP: age and age-keygen are required for the real chunk encryption E2E"
  exit 0
fi

TEST_ROOT="$(mktemp -d)"
cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

VAULT="$TEST_ROOT/vault"
RECOVERY_IDENTITY="$TEST_ROOT/recovery.agekey"
DEVICE_PLAINTEXT="$TEST_ROOT/device.jsonl"
RECOVERY_PLAINTEXT="$TEST_ROOT/recovery.jsonl"

age-keygen -o "$RECOVERY_IDENTITY" >/dev/null
recovery_recipient="$(age-keygen -y "$RECOVERY_IDENTITY")"
FLIGHT_RECORDER_STATE_DIR="$VAULT" "$CLI" init \
  --remote "git@github.com:example/private-flight-recorder.git" \
  --recovery-recipient "$recovery_recipient"

FLIGHT_RECORDER_STATE_DIR="$VAULT" \
  AGENT_FLIGHT_RECORDER_NOW="2026-07-24T14:00:00Z" \
  "$RECORDER" --harness claude-code <"$FIXTURE"
FLIGHT_RECORDER_STATE_DIR="$VAULT" "$CLI" rotate

artifact="$(find "$VAULT/devices" -type f -name '*.jsonl.age' -print -quit)"
test -n "$artifact"
age -d -i "$VAULT/keys/device.agekey" -o "$DEVICE_PLAINTEXT" "$artifact"
age -d -i "$RECOVERY_IDENTITY" -o "$RECOVERY_PLAINTEXT" "$artifact"
cmp "$DEVICE_PLAINTEXT" "$RECOVERY_PLAINTEXT"

python3 - "$DEVICE_PLAINTEXT" "$VAULT/vault.json" "$artifact" <<'PY'
import hashlib
import json
import pathlib
import sys

plaintext = pathlib.Path(sys.argv[1]).read_bytes()
config = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
artifact = pathlib.Path(sys.argv[3])
lines = plaintext.splitlines(keepends=True)
assert len(lines) == 2
header = json.loads(lines[0])
event = json.loads(lines[1])
assert header["record_type"] == "chunk_header"
assert header["schema_version"] == 1
assert header["event_schema_version"] == 2
assert header["event_count"] == 1
assert header["vault_id"] == config["vault_id"]
assert header["device_id"] == config["devices"][0]["device_id"]
assert header["created_at"] == event["recorded_at"] == "2026-07-24T14:00:00Z"
digest = hashlib.sha256(
    b"agent-harness-flight-recorder/chunk-v1\0"
    + header["vault_id"].encode()
    + b"\0"
    + header["device_id"].encode()
    + b"\0"
    + lines[1]
).hexdigest()
assert header["chunk_id"] == f"sha256:{digest}"
assert artifact.name == f"{digest}.jsonl.age"
assert artifact.parts[-5:-1] == (header["device_id"], "2026", "07", "24")
PY

if grep -a -q 'PROMPT_CANARY_5a82d4' "$artifact"; then
  echo "FAIL: ciphertext contains a plaintext canary" >&2
  exit 1
fi

before_hash="$(shasum -a 256 "$artifact" | awk '{print $1}')"
FLIGHT_RECORDER_STATE_DIR="$VAULT" "$CLI" rotate
after_hash="$(shasum -a 256 "$artifact" | awk '{print $1}')"
test "$before_hash" = "$after_hash"
test "$(find "$VAULT/devices" -type f -name '*.jsonl.age' | wc -l | tr -d ' ')" = "1"

echo "PASS: real age encrypts one immutable chunk for device and recovery identities"
