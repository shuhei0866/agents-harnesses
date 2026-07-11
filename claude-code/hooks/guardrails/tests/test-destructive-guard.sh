#!/usr/bin/env bash
# Tests for guardrails/destructive-guard.sh
# （heredoc 本文除去の採用と、root/home 対象判定の \b 修正の回帰を固定する）
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/../destructive-guard.sh"

PASS=0
FAIL=0
TMPDIR_TEST="$(mktemp -d)"

cleanup() {
  rm -rf "$TMPDIR_TEST"
}
trap cleanup EXIT

OUT=""
ERR=""
STATUS=0
run_guard() {
  local cmd="$1"
  local errf="$TMPDIR_TEST/stderr"
  OUT=$( (cd "$TMPDIR_TEST" && jq -n --arg c "$cmd" '{tool_input:{command:$c}}' \
    | env -u CLAUDE_PROJECT_DIR -u GUARD_SKIP -u GUARD_LEVEL -u GUARD_FORCE_DENY bash "$GUARD" 2>"$errf") )
  STATUS=$?
  ERR=$(cat "$errf" 2>/dev/null || echo "")
}

assert_deny() {
  local desc="$1"
  if [ "$STATUS" -eq 0 ] && [ -z "$ERR" ] \
     && echo "$OUT" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc"
    echo "    expected: deny / status: $STATUS / stderr: ${ERR:-無し} / output: ${OUT:-（出力なし）}"
    FAIL=$((FAIL + 1))
  fi
}

assert_warn_allow() {
  local desc="$1"
  if [ "$STATUS" -eq 0 ] && [ -z "$ERR" ] \
     && echo "$OUT" | jq -e '.hookSpecificOutput.permissionDecision == "allow"' >/dev/null 2>&1 \
     && echo "$OUT" | grep -q "WARNING"; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc"
    echo "    expected: allow + WARNING / status: $STATUS / stderr: ${ERR:-無し} / output: ${OUT:-（出力なし）}"
    FAIL=$((FAIL + 1))
  fi
}

assert_silent_allow() {
  local desc="$1"
  if [ "$STATUS" -eq 0 ] && [ -z "$ERR" ] && [ -z "$OUT" ]; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc"
    echo "    expected: 出力なしの許可 / status: $STATUS / stderr: ${ERR:-無し} / output: ${OUT:-（出力なし）}"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== destructive-guard: critical deny（root/home/システム）==="

run_guard 'rm -rf /'
assert_deny "rm -rf / を critical deny する（\\b では / の後に語境界が立たない回帰）"

run_guard 'rm -rf ~'
assert_deny "rm -rf ~ を critical deny する"

run_guard 'rm -rf ~/'
assert_deny "rm -rf ~/ を critical deny する"

run_guard 'rm -rf $HOME'
assert_deny "rm -rf \$HOME を critical deny する"

run_guard 'rm -rf /etc/nginx'
assert_deny "rm -rf /etc 配下を critical deny する"

EXEC_HD=$'bash <<\'EOF\'\nrm -rf /etc\nEOF'
run_guard "$EXEC_HD"
assert_deny "bash <<EOF で実行される heredoc 本文内の rm -rf /etc を deny する（本文除去の除外規則）"

PHANTOM=$'echo \'see <<EOF usage\'\nrm -rf /etc'
run_guard "$PHANTOM"
assert_deny "引用符内の <<EOF 言及を偽 opener と誤認して後続の rm -rf /etc を見逃さない"

echo ""
echo "=== destructive-guard: advisory（デフォルト GUARD_LEVEL=warn では警告のみ）==="

run_guard 'rm -rf /tmp/foo'
assert_warn_allow "一般ディレクトリへの rm -rf は警告つきで許可する"

run_guard 'git reset --hard'
assert_warn_allow "git reset --hard は警告つきで許可する"

echo ""
echo "=== destructive-guard: 誤検出しないケース ==="

DATA_HD=$'gh issue create --body "$(cat <<\'EOF\'\n説明: rm -rf の危険性について\nEOF\n)"'
run_guard "$DATA_HD"
assert_silent_allow "データ用 heredoc 本文中の rm -rf 記述には反応しない（誤発火の回帰）"

run_guard 'ls -la /etc'
assert_silent_allow "破壊的でないコマンドには反応しない"

echo ""
echo "結果: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
