#!/usr/bin/env bash
# Tests for guardrails の advisory 検出文言 — 「ブロック」の宣言と実際の判定を一致させる
#
# commit-guard（メインワークツリーでの直接コミット・checkout/switch・main への直接マージ・
# stash pop/apply）、heredoc-guard、worktree-guard の検出はすべて advisory であり、
# 既定の GUARD_LEVEL=warn では permissionDecision=allow を返す。従来はそのときも
# 「ブロックされています」と書いていたため、読んだ人や agent は操作が実行されなかったと
# 信じ、実際には通っていた操作を再試行しかねなかった（gh-guard と同じ問題）。
#
# test-gh-guard-block-wording.sh と同じく harness を最小限に模す: hook の出力が deny なら
# 何もしない、それ以外なら操作を実際に行う（Bash ならコマンドを実行し、Write なら
# ファイルを書く）。そのうえで「ブロックと書いた ⇔ 操作が行われなかった」を
# ケースごとに確かめ、判定そのもの（warn → allow / deny → deny）も表明する。
set -uo pipefail

for required_cmd in bash dirname mktemp mkdir rm git jq env grep; do
  command -v "$required_cmd" >/dev/null 2>&1 || {
    printf 'required command is unavailable: %s\n' "$required_cmd" >&2
    exit 1
  }
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMIT_GUARD="$SCRIPT_DIR/../commit-guard.sh"
HEREDOC_GUARD="$SCRIPT_DIR/../heredoc-guard.sh"
WORKTREE_GUARD="$SCRIPT_DIR/../worktree-guard.sh"

PASS=0
FAIL=0
# macOS の一時ディレクトリは /var が /private/var へのシンボリックリンクで、worktree-guard の
# realpath -m（GNU のみ）による正規化が効かない。文言の検証がパス解決に左右されないよう、
# 物理パスで作る（ガード側の正規化が macOS で効かない問題は別に扱う）。
TMPDIR_TEST="$(cd "$(mktemp -d)" && pwd -P)" || exit 1
FIXTURE_MARKER=".advisory-guards-wording-fixture"
: > "$TMPDIR_TEST/$FIXTURE_MARKER"

cleanup() {
  [ -n "$TMPDIR_TEST" ] || return 0
  [ -f "$TMPDIR_TEST/$FIXTURE_MARKER" ] || return 0
  rm -rf "$TMPDIR_TEST"
}
trap cleanup EXIT

NEUTRAL="$TMPDIR_TEST/neutral"
mkdir -p "$NEUTRAL"
REPO="$TMPDIR_TEST/repo"

GIT_ID=(-c user.email=t@t -c user.name=t)

# --- fixture: worktree-pr のメインワークツリー（main）を毎回作り直す ---
# feat ブランチ（main より 1 コミット進んでいる）と stash を 1 つ持たせ、
# commit / switch / merge / stash pop がいずれも実行可能な状態にする。
make_repo() {
  rm -rf "$REPO"
  mkdir -p "$REPO/.claude"
  printf 'GIT_WORKFLOW="worktree-pr"\n' > "$REPO/.claude/harness.config"
  git init -q "$REPO"
  git -C "$REPO" symbolic-ref HEAD refs/heads/main
  printf 'base\n' > "$REPO/tracked.txt"
  git -C "$REPO" add tracked.txt
  git -C "$REPO" "${GIT_ID[@]}" commit -q -m init
  git -C "$REPO" branch feat
  git -C "$REPO" checkout -q feat
  git -C "$REPO" "${GIT_ID[@]}" commit -q --allow-empty -m "on feat"
  git -C "$REPO" checkout -q main
  printf 'dirty\n' >> "$REPO/tracked.txt"
  git -C "$REPO" "${GIT_ID[@]}" stash -q
}

repo_state() {
  printf '%s %s %s' \
    "$(git -C "$REPO" rev-parse HEAD 2>/dev/null)" \
    "$(git -C "$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null)" \
    "$(git -C "$REPO" stash list 2>/dev/null | wc -l | tr -d ' ')"
}

OUT=""
DECISION=""
TEXT=""
EXECUTED=0

guard_env() {
  local level="$1" force="$2"
  GUARD_ENVS=()
  [ -n "$level" ] && GUARD_ENVS+=(GUARD_LEVEL="$level")
  [ -n "$force" ] && GUARD_ENVS+=(GUARD_FORCE_DENY="$force")
  return 0
}

parse_out() {
  DECISION=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // ""' 2>/dev/null || printf '')
  TEXT=$(printf '%s' "$OUT" | jq -r '(.hookSpecificOutput.permissionDecisionReason // "") + (.hookSpecificOutput.additionalContext // "")' 2>/dev/null || printf '')
}

# run_bash_case <guard> <GUARD_LEVEL|""> <GUARD_FORCE_DENY|""> <cmd>
#   Bash hook を走らせ、deny 以外ならコマンドを fixture repo で実際に実行する。
#   EXECUTED は fixture repo の状態（HEAD / ブランチ / stash 数）が変わったかで判定する。
run_bash_case() {
  local guard="$1" level="$2" force="$3" cmd="$4" before="" after=""
  guard_env "$level" "$force"
  make_repo
  before=$(repo_state)
  OUT=$(jq -n --arg c "$cmd" --arg cwd "$NEUTRAL" '{tool_input:{command:$c}, cwd:$cwd}' \
    | env -u CLAUDE_PROJECT_DIR -u GUARD_SKIP -u GUARD_LEVEL -u GUARD_FORCE_DENY -u GIT_WORKFLOW -u CLAUDE_CLOUD \
        ${GUARD_ENVS[@]+"${GUARD_ENVS[@]}"} bash "$guard" 2>/dev/null)
  parse_out

  # harness の模倣: deny 以外ならコマンドを実行する。
  if [ "$DECISION" != "deny" ]; then
    (cd "$NEUTRAL" && GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
      bash -c "$cmd" >/dev/null 2>&1) || true
  fi
  after=$(repo_state)
  EXECUTED=0
  [ "$before" != "$after" ] && EXECUTED=1
  return 0
}

# run_heredoc_case <GUARD_LEVEL|""> <GUARD_FORCE_DENY|"">
#   heredoc でファイルを書くコマンドを走らせ、ファイルができたかで実行を判定する。
HEREDOC_OUT_FILE="$TMPDIR_TEST/heredoc-out.txt"
run_heredoc_case() {
  local level="$1" force="$2" cmd=""
  guard_env "$level" "$force"
  rm -f "$HEREDOC_OUT_FILE"
  cmd="cat > \"$HEREDOC_OUT_FILE\" <<EOF
hello
EOF"
  OUT=$(jq -n --arg c "$cmd" --arg cwd "$NEUTRAL" '{tool_input:{command:$c}, cwd:$cwd}' \
    | env -u CLAUDE_PROJECT_DIR -u GUARD_SKIP -u GUARD_LEVEL -u GUARD_FORCE_DENY -u GIT_WORKFLOW -u CLAUDE_CLOUD \
        ${GUARD_ENVS[@]+"${GUARD_ENVS[@]}"} bash "$HEREDOC_GUARD" 2>/dev/null)
  parse_out
  if [ "$DECISION" != "deny" ]; then
    (cd "$NEUTRAL" && bash -c "$cmd" >/dev/null 2>&1) || true
  fi
  EXECUTED=0
  [ -f "$HEREDOC_OUT_FILE" ] && EXECUTED=1
  return 0
}

# run_write_case <GUARD_LEVEL|""> <GUARD_FORCE_DENY|"">
#   メインワークツリーのファイルへの Write を走らせ、deny 以外なら実際に書く。
run_write_case() {
  local level="$1" force="$2" target=""
  guard_env "$level" "$force"
  make_repo
  target="$REPO/src/new-file.txt"
  OUT=$(jq -n --arg f "$target" --arg cwd "$NEUTRAL" '{tool_input:{file_path:$f, content:"x"}, cwd:$cwd}' \
    | env -u CLAUDE_PROJECT_DIR -u GUARD_SKIP -u GUARD_LEVEL -u GUARD_FORCE_DENY -u GIT_WORKFLOW -u CLAUDE_CLOUD \
        ${GUARD_ENVS[@]+"${GUARD_ENVS[@]}"} bash "$WORKTREE_GUARD" 2>/dev/null)
  parse_out
  if [ "$DECISION" != "deny" ]; then
    mkdir -p "$(dirname "$target")" && printf 'x' > "$target"
  fi
  EXECUTED=0
  [ -f "$target" ] && EXECUTED=1
  return 0
}

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() {
  echo "  FAIL: $1"
  echo "    decision: ${DECISION:-（出力なし）}"
  echo "    text:     ${TEXT:-（無し）}"
  echo "    executed: $EXECUTED"
  FAIL=$((FAIL + 1))
}

# 既定（warn）: 判定は allow、操作は実行され、文言に「ブロック」を含まず、
# 実行を止めていないと明記する。
assert_warn_case() {
  local label="$1" claims_block=0
  printf '%s' "$TEXT" | grep -q 'ブロック' && claims_block=1
  if [ "$DECISION" = "allow" ] && [ "$EXECUTED" -eq 1 ]; then
    pass "${label}（warn）は allow で、操作は実行される"
  else
    fail "${label}（warn）は allow で、操作は実行される"
  fi
  if [ -n "$TEXT" ] && [ "$claims_block" -eq 0 ]; then
    pass "${label}（warn）の文言はブロックと書かない"
  else
    fail "${label}（warn）の文言はブロックと書かない"
  fi
  if printf '%s' "$TEXT" | grep -q '実行は止めていません'; then
    pass "${label}（warn）は実行を止めていないと明記する"
  else
    fail "${label}（warn）は実行を止めていないと明記する"
  fi
}

# deny 設定: 判定は deny、操作は実行されず、ブロックしたと書く。
assert_deny_case() {
  local label="$1" mode="$2"
  if [ "$DECISION" = "deny" ] && [ "$EXECUTED" -eq 0 ]; then
    pass "${label}（${mode}）は deny で、操作は実行されない"
  else
    fail "${label}（${mode}）は deny で、操作は実行されない"
  fi
  if printf '%s' "$TEXT" | grep -q 'ブロックしました' \
     && ! printf '%s' "$TEXT" | grep -q '実行は止めていません'; then
    pass "${label}（${mode}）はブロックしたと書く"
  else
    fail "${label}（${mode}）はブロックしたと書く"
  fi
}

# check_bash_op <label> <cmd> <検出文言の一部>
check_bash_op() {
  local label="$1" cmd="$2" subject="$3"
  run_bash_case "$COMMIT_GUARD" "" "" "$cmd"
  assert_warn_case "$label"
  if printf '%s' "$TEXT" | grep -q -- "$subject"; then
    pass "${label}（warn）は何を検出したかを書く"
  else
    fail "${label}（warn）は何を検出したかを書く（/$subject/）"
  fi
  run_bash_case "$COMMIT_GUARD" deny "" "$cmd"
  assert_deny_case "$label" "GUARD_LEVEL=deny"
  run_bash_case "$COMMIT_GUARD" "" commit-guard "$cmd"
  assert_deny_case "$label" "GUARD_FORCE_DENY=commit-guard"
}

echo "commit-guard: メインワークツリーの main での直接コミット"
check_bash_op "直接コミット" "git -C \"$REPO\" commit --allow-empty -m x" "メインワークツリーの main ブランチでの直接コミット"

echo "commit-guard: メインワークツリーでの checkout/switch"
check_bash_op "switch" "git -C \"$REPO\" switch -c topic" "メインワークツリーでの git checkout/switch"

echo "commit-guard: main への直接マージ"
check_bash_op "main への直接マージ" "git -C \"$REPO\" merge --no-edit feat" "main への直接マージ"

echo "commit-guard: メインワークツリーでの stash pop"
check_bash_op "stash pop" "git -C \"$REPO\" stash pop" "メインワークツリーでの git stash pop/apply"

echo "heredoc-guard: heredoc 構文"
run_heredoc_case "" ""
assert_warn_case "heredoc"
run_heredoc_case deny ""
assert_deny_case "heredoc" "GUARD_LEVEL=deny"
run_heredoc_case "" heredoc-guard
assert_deny_case "heredoc" "GUARD_FORCE_DENY=heredoc-guard"

echo "worktree-guard: メインワークツリーでのファイル編集"
run_write_case "" ""
assert_warn_case "メインワークツリーでの編集"
run_write_case deny ""
assert_deny_case "メインワークツリーでの編集" "GUARD_LEVEL=deny"
run_write_case "" worktree-guard
assert_deny_case "メインワークツリーでの編集" "GUARD_FORCE_DENY=worktree-guard"

echo
echo "PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
