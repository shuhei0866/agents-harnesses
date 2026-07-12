#!/usr/bin/env bash
# Tests for guardrails/worktree-rm-guard.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/../worktree-rm-guard.sh"

PASS=0
FAIL=0
TMPDIR_TEST="$(mktemp -d)"

cleanup() {
  rm -rf "$TMPDIR_TEST"
}
trap cleanup EXIT

# guard を hermetic に実行する: 非 git ディレクトリで、セッション由来の環境変数を
# 落として起動し、stdout / stderr / exit status を分けて捕捉する
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

run_guard_with_skip() {
  local cmd="$1"
  local errf="$TMPDIR_TEST/stderr"
  OUT=$( (cd "$TMPDIR_TEST" && jq -n --arg c "$cmd" '{tool_input:{command:$c}}' \
    | env -u CLAUDE_PROJECT_DIR -u GUARD_LEVEL -u GUARD_FORCE_DENY -u GIT_WORKFLOW GUARD_SKIP=worktree-rm-guard bash "$GUARD" 2>"$errf") )
  STATUS=$?
  ERR=$(cat "$errf" 2>/dev/null || echo "")
}

# deny 判定: exit 0 かつ stderr 無しかつ、出力が valid JSON で permissionDecision=deny
assert_deny() {
  local desc="$1"
  if [ "$STATUS" -eq 0 ] && [ -z "$ERR" ] \
     && echo "$OUT" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc"
    echo "    expected: deny (exit 0, stderr 無し, valid JSON)"
    echo "    status:   $STATUS"
    echo "    stderr:   ${ERR:-（無し）}"
    echo "    output:   ${OUT:-（出力なし=許可）}"
    FAIL=$((FAIL + 1))
  fi
}

# allow 判定: exit 0 かつ stderr 無しかつ、出力が空（沈黙の許可）または valid JSON の allow。
# クラッシュ由来の空出力を PASS と誤認しないよう exit status と stderr も検査する
assert_allow() {
  local desc="$1"
  local ok=0
  if [ "$STATUS" -eq 0 ] && [ -z "$ERR" ]; then
    if [ -z "$OUT" ]; then
      ok=1
    elif echo "$OUT" | jq -e '.hookSpecificOutput.permissionDecision == "allow"' >/dev/null 2>&1; then
      ok=1
    fi
  fi
  if [ "$ok" -eq 1 ]; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc"
    echo "    expected: allow (exit 0, stderr 無し)"
    echo "    status:   $STATUS"
    echo "    stderr:   ${ERR:-（無し）}"
    echo "    output:   ${OUT:-（出力なし）}"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== worktree-rm-guard: deny されるべきケース ==="

run_guard 'rm -rf .worktrees/foo'
assert_deny "rm -rf .worktrees/foo を deny する"

run_guard 'rm -fr ".worktrees/foo"'
assert_deny "引用符付きパスの rm -fr も deny する"

run_guard 'rm -r .worktrees/foo'
assert_deny "-f 無しの再帰 rm も deny する"

run_guard 'sudo rm -rf .worktrees/foo'
assert_deny "sudo 前置の rm -rf も deny する"

run_guard 'LC_ALL=C rm -rf .worktrees/foo'
assert_deny "環境変数代入プレフィックス付きの rm -rf も deny する"

run_guard 'rm -rf /Users/x/repo/.worktrees/foo'
assert_deny "絶対パス配下の .worktrees も deny する"

run_guard 'cd ~/repo && rm -rf .worktrees/foo'
assert_deny "cd 連結後のセグメントでも deny する"

run_guard 'cd .worktrees && rm -rf foo'
assert_deny "cd で .worktrees に入った後の相対パス削除も deny する"

run_guard 'cd .worktrees/foo && rm -rf .'
assert_deny "cd で worktree 内に入った後の rm -rf . も deny する"

run_guard '(rm -rf .worktrees/foo)'
assert_deny "subshell 内の rm -rf も deny する"

run_guard 'rm -rf .worktrees/foo &'
assert_deny "バックグラウンド実行（&）でも deny する"

run_guard 'true & rm -rf .worktrees/foo'
assert_deny "単独 & で連結された 2 コマンド目も deny する"

run_guard 'find .worktrees/foo -name "*.pyc" -exec rm -rf {} +'
assert_deny "find -exec rm -rf も deny する"

run_guard 'ls .worktrees | xargs rm -rf'
assert_deny "xargs 経由の再帰 rm も deny する（対象が stdin 越しでも）"

run_guard 'ls .worktrees | xargs -I {} rm -rf {}'
assert_deny "xargs -I {} 形式（オプション値が別トークン）も deny する"

run_guard 'ls .worktrees | xargs -n 1 rm -rf'
assert_deny "xargs -n 1 形式も deny する"

run_guard 'find .worktrees/old -delete'
assert_deny "find -delete も deny する"

CONT_CMD=$'rm -rf \\\n.worktrees/foo'
run_guard "$CONT_CMD"
assert_deny "行継続（backslash + 改行）で分割された rm -rf も deny する"

HS_CMD=$'true <<< marker\nrm -rf .worktrees/foo'
run_guard "$HS_CMD"
assert_deny "here-string（<<<）を偽 heredoc と誤認して後続の rm を見逃さない"

QM_CMD=$'echo \'see <<EOF usage\'\nrm -rf .worktrees/foo'
run_guard "$QM_CMD"
assert_deny "引用符内の <<EOF 言及を偽 opener と誤認して後続の rm を見逃さない"

EXEC_HD_CMD=$'bash <<\'EOF\'\nrm -rf .worktrees/foo\nEOF'
run_guard "$EXEC_HD_CMD"
assert_deny "bash <<EOF で実行される heredoc 本文内の rm -rf は deny する"

echo ""
echo "=== worktree-rm-guard: allow されるべきケース ==="

run_guard 'rm -rf /tmp/foo'
assert_allow ".worktrees を含まない rm -rf は対象外（destructive-guard の領分）"

run_guard 'rm .worktrees/foo/file.txt'
assert_allow "worktree 内の単一ファイル削除（非再帰）は許可する"

run_guard 'git worktree remove .worktrees/foo'
assert_allow "正規の削除手段 git worktree remove は許可する"

run_guard 'echo "rm -rf .worktrees/foo"'
assert_allow "echo の引数に書かれただけの rm -rf は許可する"

run_guard 'ls .worktrees && rm -rf /tmp/x'
assert_allow "別セグメントの rm -rf（.worktrees は ls 側）は許可する"

run_guard 'ls /tmp/scratch | xargs rm -rf && ls .worktrees'
assert_allow "xargs の判定はパイプライン単位（別セグメントの .worktrees を根拠にしない）"

run_guard 'grep -r "pattern" .worktrees/foo'
assert_allow "grep -r（rm ではない再帰 flag）は許可する"

# 回帰テスト: issue 起票時に本文の説明文へ反応した誤発火。
# データとして流し込む heredoc 本文に rm -rf .worktrees と書いてあるだけで deny してはいけない
HEREDOC_CMD=$'gh issue create --title "t" --body "$(cat <<\'EOF\'\n## 背景\n.worktrees/ 配下への rm -rf を deny し、git worktree remove 経由に強制する\nEOF\n)"'
run_guard "$HEREDOC_CMD"
assert_allow "データ用 heredoc 本文中の rm -rf 記述は許可する（誤発火の回帰）"

# 素の << はタブ字下げの終端を認めない（本文中の \tEOF 行で早期終端しない）
TAB_CMD=$'cat > notes.md <<EOF\n\tEOF\nrm -rf .worktrees/foo\nEOF'
run_guard "$TAB_CMD"
assert_allow "素の << の本文中のタブ字下げ EOF 行で早期終端せず、本文の rm 記述を許可する"

run_guard_with_skip 'rm -rf .worktrees/foo'
assert_allow "GUARD_SKIP=worktree-rm-guard（hook 環境）で opt-out できる"

echo ""
echo "結果: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
