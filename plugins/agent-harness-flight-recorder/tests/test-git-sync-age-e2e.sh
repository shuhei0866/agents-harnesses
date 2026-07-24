#!/usr/bin/env bash
# Real-age, local-bare-remote E2E for manual Git synchronization.
set -euo pipefail

if ! command -v age >/dev/null 2>&1 \
  || ! command -v age-keygen >/dev/null 2>&1; then
  echo "SKIP: age and age-keygen are required"
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CLI="$PLUGIN_DIR/scripts/flight-recorder"
RECORDER="$PLUGIN_DIR/scripts/record-event"
FIXTURE="$SCRIPT_DIR/fixtures/claude-code-stop.json"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

REMOTE="$TEST_ROOT/remote.git"
DEVICE_A="$TEST_ROOT/device-a"
DEVICE_B="$TEST_ROOT/device-b"
RECOVERY="$TEST_ROOT/recovery.agekey"
DEVICE_B_BOOTSTRAP="$TEST_ROOT/device-b.agekey"

git init -q --bare "$REMOTE"
git -C "$REMOTE" symbolic-ref HEAD refs/heads/main
age-keygen -o "$RECOVERY" >/dev/null 2>&1
age-keygen -o "$DEVICE_B_BOOTSTRAP" >/dev/null 2>&1

FLIGHT_RECORDER_STATE_DIR="$DEVICE_A" "$CLI" init \
  --remote "$REMOTE" \
  --recovery-recipient "$(age-keygen -y "$RECOVERY")"
FLIGHT_RECORDER_STATE_DIR="$DEVICE_A" "$CLI" device add \
  --recipient "$(age-keygen -y "$DEVICE_B_BOOTSTRAP")"
FLIGHT_RECORDER_STATE_DIR="$DEVICE_A" \
  AGENT_FLIGHT_RECORDER_NOW="2026-07-25T06:00:00Z" \
  "$RECORDER" --harness claude-code <"$FIXTURE"
FLIGHT_RECORDER_STATE_DIR="$DEVICE_A" "$CLI" sync

git clone -q "$REMOTE" "$DEVICE_B"
FLIGHT_RECORDER_STATE_DIR="$DEVICE_B" "$CLI" device join \
  --identity "$DEVICE_B_BOOTSTRAP"
FLIGHT_RECORDER_STATE_DIR="$DEVICE_B" \
  AGENT_FLIGHT_RECORDER_NOW="2026-07-25T06:01:00Z" \
  "$RECORDER" --harness codex <"$FIXTURE"
FLIGHT_RECORDER_STATE_DIR="$DEVICE_B" "$CLI" sync
FLIGHT_RECORDER_STATE_DIR="$DEVICE_A" "$CLI" sync

[[ "$(find "$DEVICE_A/devices" -type f -name '*.jsonl.age' | wc -l | tr -d ' ')" == "2" ]]
while IFS= read -r artifact; do
  age -d -i "$DEVICE_A/keys/device.agekey" "$artifact" >/dev/null
  age -d -i "$DEVICE_B/keys/device.agekey" "$artifact" >/dev/null
done < <(find "$DEVICE_A/devices" -type f -name '*.jsonl.age' | sort)

[[ "$(find "$DEVICE_A/cache/imported" -type f -name '*.jsonl' | wc -l | tr -d ' ')" == "2" ]]
[[ "$(find "$DEVICE_B/cache/imported" -type f -name '*.jsonl' | wc -l | tr -d ' ')" == "2" ]]

if git --git-dir="$REMOTE" log --all --format='%H' \
  | while read -r commit; do
      git --git-dir="$REMOTE" ls-tree -r --name-only "$commit"
    done \
  | grep -Eq '(^|/)(hash\.key|device\.agekey|events\.jsonl|pending-sync\.json)$'; then
  echo "FAIL: remote history contains local-only state" >&2
  exit 1
fi

echo "PASS: real age two-device Git sync and import"
