#!/usr/bin/env bash
# End-to-end checks using synthetic user and device paths only.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/../pii-guard.sh"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/repo" "$TEST_ROOT/home"
git -C "$TEST_ROOT/repo" init -q

check_path() {
  local prefix="$1" account="$2" expected="$3" output
  printf '/%s/%s/project/file.txt\n' "$prefix" "$account" > "$TEST_ROOT/repo/example.txt"
  git -C "$TEST_ROOT/repo" add example.txt
  output=$(cd "$TEST_ROOT/repo" && printf '%s\n' '{"tool_input":{"command":"git commit -m example"}}' |
    env -u CLAUDE_PROJECT_DIR -u GUARD_SKIP -u GUARD_FORCE_DENY -u GIT_WORKFLOW \
      HOME="$TEST_ROOT/home" GUARD_LEVEL=deny bash "$GUARD")
  if [ "$expected" = deny ]; then
    printf '%s\n' "$output" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null
  else
    test -z "$output"
  fi
  printf 'PASS: %s/%s => %s\n' "$prefix" "$account" "$expected"
}

check_path Users customer123 deny
check_path home buildnode42 deny
check_path Users username123 deny
check_path home examplecorp deny
check_path Users example allow
check_path home user allow
