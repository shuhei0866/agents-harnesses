#!/usr/bin/env bash
# Tests for repository-local hygiene rules.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"

PASS=0
FAIL=0

assert_ignored() {
  local path="$1" desc="$2"
  if git -C "$REPO_ROOT" check-ignore -q --no-index -- "$path"; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc"
    FAIL=$((FAIL + 1))
  fi
}

assert_not_ignored() {
  local path="$1" desc="$2"
  if git -C "$REPO_ROOT" check-ignore -q --no-index -- "$path"; then
    echo "  FAIL: $desc"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  fi
}

echo "=== repository hygiene: local worktree paths ==="

assert_ignored ".worktrees/probe" ".worktrees/ 配下を ignore する"
assert_not_ignored ".worktrees-not/probe" "類似名 .worktrees-not/ は ignore しない"

echo ""
echo "結果: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
