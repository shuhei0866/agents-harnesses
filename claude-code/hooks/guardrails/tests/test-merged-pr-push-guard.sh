#!/usr/bin/env bash
# Tests for guardrails/merged-pr-push-guard.sh
#
# gh は PATH 先頭に置いた mock で差し替え、MOCK_GH_MODE で挙動を切り替える:
#   merged: branch feat/x の PR #214 が MERGED（他 branch は PR なし。
#           MOCK_MATCH_ANY=1 なら全 branch を MERGED 扱い）
#   open:   PR #300 が OPEN / nopr: PR なし / error: 接続失敗
# gh そのものが無い環境の警告分岐は、PATH から jq/git ごと消さないと再現できないため
# ここでは対象外とする（実装は gh 失敗分岐と同じ warn 文面）。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/../merged-pr-push-guard.sh"

PASS=0
FAIL=0
TMPDIR_TEST="$(mktemp -d)"

cleanup() {
  rm -rf "$TMPDIR_TEST"
}
trap cleanup EXIT

# --- mock gh ---
mkdir -p "$TMPDIR_TEST/bin"
cat > "$TMPDIR_TEST/bin/gh" << 'MOCK'
#!/bin/bash
# args: pr view <branch> --json state,number,url
br="${3:-}"
case "${MOCK_GH_MODE:-nopr}" in
  merged)
    if [ "$br" = "feat/x" ] || [ "${MOCK_MATCH_ANY:-0}" = "1" ]; then
      printf '{"state":"MERGED","number":214,"url":"https://example.com/pull/214"}\n'
    else
      echo 'no pull requests found for branch' >&2
      exit 1
    fi
    ;;
  open)   printf '{"state":"OPEN","number":300,"url":"https://example.com/pull/300"}\n' ;;
  nopr)   echo 'no pull requests found for branch' >&2; exit 1 ;;
  error)  echo 'error connecting to api.github.com' >&2; exit 1 ;;
esac
MOCK
chmod +x "$TMPDIR_TEST/bin/gh"

# --- current branch 解決用の fake git repo（branch: feat/x）---
git init -q "$TMPDIR_TEST/repo"
git -C "$TMPDIR_TEST/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$TMPDIR_TEST/repo" checkout -q -b feat/x

# guard を hermetic に実行する。プロセスの cwd は repo の外に置き、hook 入力の
# cwd フィールドで repo を指す（実運用の入力形と同じ）
OUT=""
ERR=""
STATUS=0
run_guard() {
  local mode="$1" cmd="$2"
  local errf="$TMPDIR_TEST/stderr"
  OUT=$( (cd "$TMPDIR_TEST" && jq -n --arg c "$cmd" --arg cwd "$TMPDIR_TEST/repo" '{tool_input:{command:$c}, cwd:$cwd}' \
    | env -u CLAUDE_PROJECT_DIR -u GUARD_SKIP -u GUARD_LEVEL -u GUARD_FORCE_DENY -u GIT_WORKFLOW \
        PATH="$TMPDIR_TEST/bin:$PATH" MOCK_GH_MODE="$mode" bash "$GUARD" 2>"$errf") )
  STATUS=$?
  ERR=$(cat "$errf" 2>/dev/null || echo "")
}

# cwd フィールド無しで repo 外から実行する変種（cwd に依らない解決の検証用）
run_guard_nocwd() {
  local mode="$1" cmd="$2"
  local errf="$TMPDIR_TEST/stderr"
  OUT=$( (cd "$TMPDIR_TEST" && jq -n --arg c "$cmd" '{tool_input:{command:$c}}' \
    | env -u CLAUDE_PROJECT_DIR -u GUARD_SKIP -u GUARD_LEVEL -u GUARD_FORCE_DENY -u GIT_WORKFLOW \
        PATH="$TMPDIR_TEST/bin:$PATH" MOCK_GH_MODE="$mode" bash "$GUARD" 2>"$errf") )
  STATUS=$?
  ERR=$(cat "$errf" 2>/dev/null || echo "")
}

run_guard_matchany() {
  local mode="$1" cmd="$2"
  local errf="$TMPDIR_TEST/stderr"
  OUT=$( (cd "$TMPDIR_TEST" && jq -n --arg c "$cmd" --arg cwd "$TMPDIR_TEST/repo" '{tool_input:{command:$c}, cwd:$cwd}' \
    | env -u CLAUDE_PROJECT_DIR -u GUARD_SKIP -u GUARD_LEVEL -u GUARD_FORCE_DENY -u GIT_WORKFLOW \
        PATH="$TMPDIR_TEST/bin:$PATH" MOCK_GH_MODE="$mode" MOCK_MATCH_ANY=1 bash "$GUARD" 2>"$errf") )
  STATUS=$?
  ERR=$(cat "$errf" 2>/dev/null || echo "")
}

run_guard_with_skip() {
  local mode="$1" cmd="$2"
  local errf="$TMPDIR_TEST/stderr"
  OUT=$( (cd "$TMPDIR_TEST" && jq -n --arg c "$cmd" --arg cwd "$TMPDIR_TEST/repo" '{tool_input:{command:$c}, cwd:$cwd}' \
    | env -u CLAUDE_PROJECT_DIR -u GUARD_LEVEL -u GUARD_FORCE_DENY -u GIT_WORKFLOW GUARD_SKIP=merged-pr-push-guard \
        PATH="$TMPDIR_TEST/bin:$PATH" MOCK_GH_MODE="$mode" bash "$GUARD" 2>"$errf") )
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
    echo "    expected: deny (exit 0, stderr 無し, valid JSON)"
    echo "    status:   $STATUS"
    echo "    stderr:   ${ERR:-（無し）}"
    echo "    output:   ${OUT:-（出力なし=許可）}"
    FAIL=$((FAIL + 1))
  fi
}

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

assert_contains() {
  local desc="$1" needle="$2"
  if echo "$OUT" | grep -q "$needle"; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc"
    echo "    expected to contain: $needle"
    echo "    output:   ${OUT:-（出力なし）}"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== merged-pr-push-guard: deny されるべきケース（feat/x の PR が MERGED）==="

run_guard merged 'git push origin feat/x'
assert_deny "merge 済み branch への push を deny する"
assert_contains "deny 理由に PR 番号を含む" "#214"

run_guard merged 'git push'
assert_deny "引数なし push も hook 入力の cwd からカレント branch を解決して deny する"

run_guard merged 'git push -u origin feat/x --force-with-lease'
assert_deny "flag 混在の push も deny する"

run_guard merged 'git push origin HEAD'
assert_deny "HEAD 指定もカレント branch に解決して deny する"

run_guard merged 'git push origin safe:feat/x'
assert_deny "src:dst 形式はリモート側 branch で判定して deny する"

run_guard merged 'git commit -m "fix" && git push origin feat/x'
assert_deny "連結コマンド内の git push も deny する"

run_guard merged 'git push origin safe-br && git push origin feat/x'
assert_deny "連結された 2 本目の push も検査して deny する（1 本目で打ち切らない）"

run_guard merged "(cd $TMPDIR_TEST/repo && git push origin feat/x)"
assert_deny "subshell 内の (cd <dir> && git push) も deny する"

run_guard_nocwd merged "git -C $TMPDIR_TEST/repo push origin feat/x"
assert_deny "git -C <dir> push は cwd に依らず deny する"

run_guard merged 'GIT_TRACE=1 git push origin feat/x'
assert_deny "環境変数代入プレフィックス付きの git push も deny する"

run_guard_matchany merged 'git push origin "qq\"br"'
assert_deny "branch 名に二重引用符が含まれても deny 応答が valid JSON である"

echo ""
echo "=== merged-pr-push-guard: allow されるべきケース ==="

run_guard open 'git push origin feat/x'
assert_allow "open PR がある branch への push は許可する"

run_guard nopr 'git push origin feat/x'
assert_allow "PR が無い branch への push は静かに許可する"

run_guard merged 'git push origin safe-br'
assert_allow "merge 済み PR を持たない branch への push は許可する"

run_guard merged 'git push origin main'
assert_allow "trunk（main）への push は対象外（commit-guard の領分）"

run_guard merged 'git push origin --delete feat/x'
assert_allow "--delete は孤児コミットを生まないので許可する"

run_guard merged 'git push origin :feat/x'
assert_allow ":branch（削除 refspec）も許可する"

run_guard merged 'git push --tags'
assert_allow "--tags は branch 更新ではないので許可する"

run_guard merged 'git pull origin feat/x'
assert_allow "git push 以外の git コマンドは対象外"

run_guard merged 'echo "git push origin feat/x"'
assert_allow "引用符内に書かれただけの git push は許可する"

run_guard merged 'gh pr comment 214 --body "done; git push origin feat/x で反映済み"'
assert_allow "引用符内に区切り文字（;）と git push を含む gh コメントを誤 deny しない"

HEREDOC_CMD=$'cat > memo.md <<\'EOF\'\n手順: git push origin feat/x を実行する\nEOF'
run_guard merged "$HEREDOC_CMD"
assert_allow "データ用 heredoc 本文中の git push 記述は許可する"

run_guard_with_skip merged 'git push origin feat/x'
assert_allow "GUARD_SKIP=merged-pr-push-guard（hook 環境）で opt-out できる"

echo ""
echo "=== merged-pr-push-guard: fail-open ==="

run_guard error 'git push origin feat/x'
assert_allow "gh がエラーの時は fail-open で許可する"
assert_contains "fail-open 時は警告を additionalContext に残す" "additionalContext"

echo ""
echo "結果: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
