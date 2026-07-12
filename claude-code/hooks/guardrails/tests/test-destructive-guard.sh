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

run_guard 'rm -rf "/etc/nginx"'
assert_deny "double quote された /etc 配下も critical deny する"

run_guard "rm -rf '/usr/local'"
assert_deny "single quote された /usr 配下も critical deny する"

run_guard 'rm -rf "/var/lib/app"'
assert_deny "double quote された /var 配下も critical deny する"

run_guard 'rm -rf "/"'
assert_deny "double quote された / も critical deny する"

run_guard 'rm -rf "$HOME"'
assert_deny "double quote 内で展開される \$HOME も critical deny する"

run_guard '/bin/rm -rf "/etc/nginx"'
assert_deny "absolute path の rm でも quote された /etc 配下を critical deny する"

run_guard 'env rm -rf "/etc/nginx"'
assert_deny "env 経由でも quote された /etc 配下を critical deny する"

run_guard 'sudo -n rm -rf "/etc/nginx"'
assert_deny "sudo option 付きでも quote された /etc 配下を critical deny する"

run_guard 'if true; then rm -rf "/etc/nginx"; fi'
assert_deny "shell control word 後の quote 付き system rm も critical deny する"

run_guard 'if true; then A=x rm -rf "/etc/nginx"; fi'
assert_deny "shell control word 後の環境変数付き system rm も critical deny する"

run_guard 'sudo env rm -rf "/etc/nginx"'
assert_deny "sudo と env の組み合わせでも quote 付き system rm を critical deny する"

run_guard 'sudo -u root rm -rf "/etc/nginx"'
assert_deny "値を取る sudo option 付きでも quote 付き system rm を critical deny する"

run_guard 'sudo --user=root rm -rf "/etc/nginx"'
assert_deny "equals 形式の sudo user option 付きでも system rm を critical deny する"

run_guard 'command -p rm -rf "/etc/nginx"'
assert_deny "command の実行 option 経由でも quote 付き system rm を critical deny する"

run_guard 'rm -rf /"etc"/nginx'
assert_deny "shell word 内で quote 連結された /etc 配下も critical deny する"

run_guard 'rm -rf "/"etc'
assert_deny "quote された root と隣接 token の連結で /etc になるパスも critical deny する"

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

run_guard 'rm -rf "/tmp/foo"'
assert_warn_allow "quote された一般ディレクトリへの rm -rf は警告つきで許可する"

run_guard 'echo rm -rf "/etc/nginx"'
assert_warn_allow "echo の引数中にある quote 付き system path を critical deny に昇格しない"

run_guard 'echo /bin/rm -rf "/etc/nginx"'
assert_warn_allow "echo の引数中にある absolute rm も critical deny に昇格しない"

run_guard 'command -v rm -rf "/etc/nginx"'
assert_warn_allow "command lookup mode の引数を system rm 実行と誤認しない"

run_guard 'sudo --list rm -rf "/etc/nginx"'
assert_warn_allow "sudo query mode の引数を system rm 実行と誤認しない"

run_guard 'rm -rf "~"'
assert_warn_allow "double quote 内では展開されない ~ は一般パスとして扱う"

run_guard $'rm -rf \'$HOME\''
assert_warn_allow "single quote 内では展開されない \$HOME は一般パスとして扱う"

run_guard $'rm -rf \'"/etc"\''
assert_warn_allow "single quote 内の literal double quote 付き /etc は一般パスとして扱う"

run_guard 'rm -rf "/usr"local'
assert_warn_allow "quote 連結後も system directory ではない /usrlocal は一般パスとして扱う"

run_guard 'rm -rf __AH_GUARD_CRITICAL_BEGIN_7F3A__/etc__AH_GUARD_CRITICAL_END_7F3A__'
assert_warn_allow "marker と同名の literal relative path を critical deny にしない"

run_guard 'git reset --hard'
assert_warn_allow "git reset --hard は警告つきで許可する"

echo ""
echo "=== destructive-guard: 誤検出しないケース ==="

DATA_HD=$'gh issue create --body "$(cat <<\'EOF\'\n説明: rm -rf の危険性について\nEOF\n)"'
run_guard "$DATA_HD"
assert_silent_allow "データ用 heredoc 本文中の rm -rf 記述には反応しない（誤発火の回帰）"

run_guard $'echo \'rm -rf "/etc/nginx"\''
assert_silent_allow "echo の引数中にある quote 付き system rm には反応しない"

QUOTED_DATA_HD=$'gh issue create --body "$(cat <<\'EOF\'\n例: rm -rf "/etc/nginx"\nEOF\n)"'
run_guard "$QUOTED_DATA_HD"
assert_silent_allow "データ用 heredoc 本文中の quote 付き system rm には反応しない"

run_guard 'ls -la /etc'
assert_silent_allow "破壊的でないコマンドには反応しない"

echo ""
echo "結果: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
