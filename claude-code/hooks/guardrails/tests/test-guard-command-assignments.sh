#!/usr/bin/env bash
# Tests for _guard-common.sh — 同一コマンド内の literal 代入の展開
#
# `WT=/path; git -C "$WT" commit` のような書き方は、Claude Code の Bash ツールが
# シェル状態を呼び出し間で保持しないため、実際に動く形では必ず代入が同じコマンド
# 文字列に含まれる。ガードはその文字列を唯一の入力として読んでいるので、代入を
# 記録して展開できる。ここではリテラル形と変数形が同じ判定になること、および
# 展開できない場合に従来どおり fail closed へ倒れることを固定する。
#
# 判定の向きが逆転していないことを確かめるため、通す例と止める例を対で置く。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMIT_GUARD="$SCRIPT_DIR/../commit-guard.sh"
GH_GUARD="$SCRIPT_DIR/../gh-guard.sh"

PASS=0
FAIL=0
TMPDIR_TEST="$(mktemp -d)"

cleanup() {
  rm -rf "$TMPDIR_TEST"
}
trap cleanup EXIT

# --- fixture: worktree-pr の repo を 2 つ作る ---
# main_repo   … メインワークツリーが main にいる（commit は止まるべき）
# branch_repo … feature ブランチにいる（commit は通るべき）
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

# hook の cwd は「対象と無関係な場所」にしておく。
# cwd フォールバックで通ってしまう実装だと、この配置で必ず崩れる。
NEUTRAL="$TMPDIR_TEST/neutral"
mkdir -p "$NEUTRAL"

# --- mock gh ---
# repos/owner/name/branches/develop だけ 404（develop 無し）を返す。
# selector の $VAR が展開できないと別パスになり、develop あり扱いで警告が出る。
mkdir -p "$TMPDIR_TEST/bin"
cat > "$TMPDIR_TEST/bin/gh" << 'MOCK'
#!/bin/bash
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "view" ]; then
  printf 'main\n'
  exit 0
fi
if [ "${1:-}" = "api" ]; then
  case "${2:-}" in
    repos/owner/name/branches/develop)
      echo 'gh: Not Found (HTTP 404)' >&2
      exit 1
      ;;
    *)
      printf 'develop\n'
      exit 0
      ;;
  esac
fi
exit 0
MOCK
chmod +x "$TMPDIR_TEST/bin/gh"

OUT=""
STATUS=0
run_guard() {
  local guard="$1" cmd="$2"
  OUT=$(jq -n --arg c "$cmd" --arg cwd "$NEUTRAL" '{tool_input:{command:$c}, cwd:$cwd}' \
    | env -u CLAUDE_PROJECT_DIR -u GUARD_SKIP -u GUARD_LEVEL -u GUARD_FORCE_DENY -u GIT_WORKFLOW -u CLAUDE_CLOUD -u GH_REPO \
        PATH="$TMPDIR_TEST/bin:$PATH" bash "$guard" 2>/dev/null)
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

echo "commit-guard: 変数形はリテラル形と同じく通る"
run_guard "$COMMIT_GUARD" "git -C $BRANCH_REPO commit -m x"
assert_silent_allow "リテラル形は feature ブランチなので通す"

run_guard "$COMMIT_GUARD" "D=$BRANCH_REPO; git -C \"\$D\" commit -m x"
assert_silent_allow "\$VAR 形も同じく通す"

run_guard "$COMMIT_GUARD" "D=$BRANCH_REPO && git -C \"\$D\" commit -m x"
assert_silent_allow "&& で繋いだ代入も通す"

run_guard "$COMMIT_GUARD" "D=$BRANCH_REPO; git -C \"\${D}\" commit -m x"
assert_silent_allow "\${VAR} 形も通す"

run_guard "$COMMIT_GUARD" "D=$TMPDIR_TEST; git -C \"\$D/branch_repo\" commit -m x"
assert_silent_allow "\$VAR/rest 形も通す"

echo "commit-guard: 変数形でも止めるべきものは止まる（fail-open していない）"
run_guard "$COMMIT_GUARD" "git -C $MAIN_REPO commit -m x"
assert_context_matches "リテラル形の main 直接コミットは止まる" "メインワークツリー"

run_guard "$COMMIT_GUARD" "D=$MAIN_REPO; git -C \"\$D\" commit -m x"
assert_context_matches "\$VAR 形の main 直接コミットも止まる" "メインワークツリー"

run_guard "$COMMIT_GUARD" "D=$TMPDIR_TEST; git -C \"\$D/main_repo\" commit -m x"
assert_context_matches "\$VAR/rest 形の main 直接コミットも止まる" "メインワークツリー"

echo "commit-guard: 展開できない場合は従来どおり advisory へ倒す"
run_guard "$COMMIT_GUARD" "git -C \"\$D\" commit -m x"
assert_context_matches "同一コマンド内に代入が無ければ解決しない" "一意に確認できませんでした"

run_guard "$COMMIT_GUARD" "D=\$(pwd); git -C \"\$D\" commit -m x"
assert_context_matches "値に置換が残る代入は記録しない" "一意に確認できませんでした"

run_guard "$COMMIT_GUARD" "D=; git -C \"\$D\" commit -m x"
assert_context_matches "値が空の代入は記録しない" "一意に確認できませんでした"

# command prefix 代入（`VAR=v cmd`）は実 shell では引数展開の後に効くため、
# 記録すると実挙動と逆の判定になる。記録しないことを固定する。
run_guard "$COMMIT_GUARD" "D=$BRANCH_REPO git -C \"\$D\" commit -m x"
assert_context_matches "command prefix 代入は展開に使わない" "一意に確認できませんでした"

echo "gh-guard: --repo の \$VAR も同じ扱いになる"
run_guard "$GH_GUARD" "gh pr merge 1 --repo owner/name --merge"
assert_silent_allow "リテラル形は develop 無し repo として通す"

run_guard "$GH_GUARD" "R=owner/name; gh pr merge 1 --repo \"\$R\" --merge"
assert_silent_allow "\$VAR 形も同じく通す"

run_guard "$GH_GUARD" "R=other/repo; gh pr merge 1 --repo \"\$R\" --merge"
assert_context_matches "develop を持つ repo なら変数形でも警告する" "WARNING"

echo
echo "PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
