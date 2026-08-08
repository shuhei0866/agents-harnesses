#!/usr/bin/env bash
# Tests for guardrails/commit-guard.sh — 対象リポジトリを特定できないときの advisory 文言
#
# ガードはコマンド文字列だけを読むので、`git -C "$WT" commit` のように変数で渡された
# パスは解決できない。この判定自体は fail closed として正しいが、従来の文言は
# 「`git -C <path>` で対象リポジトリを明示してください」と案内していた。指示どおり
# `git -C` を使っているのにそう言われるため従いようがなく、警告を読み飛ばす癖を作る。
#
# ここでは (1) 変数を渡したときの文言が実行可能な指示になっていること、
# (2) 文言を変えただけで判定の向きは一切変わっていないこと、の 2 つを固定する。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/../commit-guard.sh"

PASS=0
FAIL=0
TMPDIR_TEST="$(mktemp -d)" || exit 1
FIXTURE_MARKER=".commit-guard-advisory-fixture"
: > "$TMPDIR_TEST/$FIXTURE_MARKER"

cleanup() {
  [ -n "$TMPDIR_TEST" ] || return 0
  [ -f "$TMPDIR_TEST/$FIXTURE_MARKER" ] || return 0
  rm -rf "$TMPDIR_TEST"
}
trap cleanup EXIT

# --- fixture: worktree-pr の repo を 2 つ作る ---
make_repo() {
  local dir="$1" branch="$2"
  mkdir -p "$dir/.claude"
  printf 'GIT_WORKFLOW="worktree-pr"\n' > "$dir/.claude/harness.config"
  git init -q "$dir"
  git -C "$dir" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  git -C "$dir" symbolic-ref HEAD "refs/heads/$branch"
  git -C "$dir" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "on $branch"
}

MAIN_REPO="$TMPDIR_TEST/main_repo"
BRANCH_REPO="$TMPDIR_TEST/branch_repo"
make_repo "$MAIN_REPO" main
make_repo "$BRANCH_REPO" feature/work

NEUTRAL="$TMPDIR_TEST/neutral"
mkdir -p "$NEUTRAL"

OUT=""
STATUS=0
run_guard() {
  local cmd="$1"
  OUT=$(jq -n --arg c "$cmd" --arg cwd "$NEUTRAL" '{tool_input:{command:$c}, cwd:$cwd}' \
    | env -u CLAUDE_PROJECT_DIR -u GUARD_SKIP -u GUARD_LEVEL -u GUARD_FORCE_DENY -u GIT_WORKFLOW -u CLAUDE_CLOUD \
        bash "$GUARD" 2>/dev/null)
  STATUS=$?
}

context_of() {
  printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null || printf ''
}

assert_context_matches() {
  local desc="$1" pattern="$2" context=""
  context=$(context_of)
  if [ "$STATUS" -eq 0 ] && printf '%s' "$context" | grep -q "$pattern"; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc"
    echo "    expected: additionalContext に /$pattern/"
    echo "    status:   $STATUS"
    echo "    context:  ${context:-（出力なし＝許可）}"
    FAIL=$((FAIL + 1))
  fi
}

assert_context_lacks() {
  local desc="$1" pattern="$2" context=""
  context=$(context_of)
  if printf '%s' "$context" | grep -q "$pattern"; then
    echo "  FAIL: $desc"
    echo "    expected: additionalContext に /$pattern/ が無いこと"
    echo "    context:  $context"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  fi
}

assert_denied() {
  local desc="$1" decision=""
  decision=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // ""' 2>/dev/null || printf '')
  if [ "$decision" = "deny" ]; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc"
    echo "    expected: permissionDecision=deny"
    echo "    decision: ${decision:-（出力なし）}"
    FAIL=$((FAIL + 1))
  fi
}

assert_silent_allow() {
  local desc="$1"
  if [ "$STATUS" -eq 0 ] && [ -z "$OUT" ]; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc"
    echo "    expected: 無言で許可（exit 0・出力無し）"
    echo "    status:   $STATUS"
    echo "    output:   ${OUT:-（出力なし）}"
    FAIL=$((FAIL + 1))
  fi
}

echo "commit-guard: 変数で渡したパスの advisory は実行可能な指示になっている"
run_guard 'git -C "$WT" commit -m x'
assert_context_matches "変数が解決できない理由を述べる" "変数で渡されたパス"
assert_context_matches "リテラルのパスを書く選択肢を示す" "リテラルのパス"
assert_context_matches "cd してから実行する選択肢を示す" "cd してから実行"

# 従来の文言は「`git -C <path>` で明示してください」と案内していた。指示どおり
# git -C を使っている入力に対してこれを出すと従いようがないので、出さないことを固定する。
assert_context_lacks "既に git -C を使っている入力へ git -C を勧め直さない" "\`git -C <path>\` で対象リポジトリを明示"

echo "commit-guard: 判定の向きは変えていない"
run_guard "git -C $MAIN_REPO commit -m x"
assert_context_matches "リテラル形の main 直接コミットは止まる" "メインワークツリー"

run_guard "git -C $BRANCH_REPO commit -m x"
assert_silent_allow "リテラル形の feature ブランチは通す"

# push --force は advisory ではなく critical の deny 経路で扱われる。文言の変更が
# そちらへ波及していないことを確かめる（deny は additionalContext を持たない）。
run_guard 'git -C "$WT" push --force'
assert_denied "変数を渡した push --force は従来どおり deny のまま"

echo
echo "PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
