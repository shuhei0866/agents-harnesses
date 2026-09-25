#!/usr/bin/env bash
# Tests for guardrails/lpass-guard.sh
# （lpass の直接実行を止め、claude-profile 経由と単なる言及は通すことを固定する）
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/../lpass-guard.sh"

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
    | env -u CLAUDE_PROJECT_DIR -u GUARD_SKIP -u GUARD_LEVEL -u GUARD_FORCE_DENY -u GIT_WORKFLOW bash "$GUARD" 2>"$errf") )
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

assert_pass() {
  local desc="$1"
  if [ "$STATUS" -eq 0 ] && [ -z "$ERR" ] && [ -z "$OUT" ]; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc"
    echo "    expected: 素通し / status: $STATUS / stderr: ${ERR:-無し} / output: ${OUT:-（出力なし）}"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== lpass の直接実行はブロックする ==="
run_guard 'lpass show "Personal/Bank"';                 assert_deny "lpass show"
run_guard 'lpass ls';                                   assert_deny "lpass ls"
run_guard 'lpass export > /tmp/vault.csv';              assert_deny "lpass export"
run_guard '/usr/local/bin/lpass show --password x';     assert_deny "絶対パスの lpass"
run_guard 'cd /tmp && lpass show x';                    assert_deny "cd の後ろの lpass"
run_guard 'lpass status; lpass show x';                 assert_deny "status の後ろに続く show"
run_guard 'echo $(lpass show --password x)';            assert_deny "\$( ) の中の lpass"
run_guard 'echo `lpass show x`';                        assert_deny "バッククォートの中の lpass"
run_guard "bash -c 'lpass show x'";                     assert_deny "bash -c の中の lpass"
run_guard "eval 'lpass show x'";                        assert_deny "eval の中の lpass"
run_guard "python3 - <<'EOF'
import subprocess
subprocess.run(['lpass', 'show', 'x'])
EOF";                                                   assert_deny "python の heredoc で lpass を呼ぶ"

echo ""
echo "=== 読める範囲を広げない操作と、単なる言及は通す ==="
run_guard 'lpass status';                               assert_pass "lpass status"
run_guard 'lpass --version';                            assert_pass "lpass --version"
run_guard '~/agents-harnesses/claude-code/scripts/claude-profile get 電話番号'; assert_pass "claude-profile get"
run_guard 'git commit -m "add lpass guard"';            assert_pass "コミットメッセージ中の言及"
run_guard 'echo "lpass is a CLI"';                      assert_pass "引用符の中の言及"
run_guard 'ls ~/.lpass/upload-queue';                   assert_pass "~/.lpass のパス"
run_guard 'brew install lastpass-cli';                  assert_pass "lastpass-cli のインストール"
run_guard "cat <<'EOF'
lpass show x
EOF";                                                   assert_pass "cat に流す heredoc 本文"
run_guard 'git status';                                 assert_pass "無関係なコマンド"

echo ""
echo "=== 結果: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
