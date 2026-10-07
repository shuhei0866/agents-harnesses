#!/usr/bin/env bash
# Tests for worktree-guard のパス正規化 — シンボリックリンク経由のパスでも fail-open しない
#
# worktree-guard はファイルパスとプロジェクトルートを同じ表記にそろえてから
# 「メインワークツリー配下か」を比べる。git rev-parse --show-toplevel はシンボリックリンクを
# 解決したパスを返すので、ファイルパス側も解決しないと表記がずれ、メインワークツリーでの
# 編集を「プロジェクト外」とみなして何も返さずに通してしまう（GUARD_FORCE_DENY でも止まらない）。
# macOS では一時ディレクトリが /var → /private/var のようにシンボリックリンク配下にあり、
# かつ /bin/realpath（BSD）が GNU の -m を受け付けないため、まさにこの状態になっていた。
#
# Linux で BSD の挙動を模すため、PATH の先頭に「-m を受け付けない realpath」の代役を置いた
# 実行（bsd-realpath）と、そのままの実行（native）の両方で、同じ表明を確かめる。
set -uo pipefail

for required_cmd in bash dirname mktemp mkdir rm ln chmod git jq env grep cat; do
  command -v "$required_cmd" >/dev/null 2>&1 || {
    printf 'required command is unavailable: %s\n' "$required_cmd" >&2
    exit 1
  }
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKTREE_GUARD="$SCRIPT_DIR/../worktree-guard.sh"

PASS=0
FAIL=0
# fixture 自体は物理パスで作り、シンボリックリンク経由の表記はテスト内で明示的に作る。
TMPDIR_TEST="$(cd "$(mktemp -d)" && pwd -P)" || exit 1
FIXTURE_MARKER=".worktree-guard-path-fixture"
: > "$TMPDIR_TEST/$FIXTURE_MARKER"

cleanup() {
  [ -n "$TMPDIR_TEST" ] || return 0
  [ -f "$TMPDIR_TEST/$FIXTURE_MARKER" ] || return 0
  rm -rf "$TMPDIR_TEST"
}
trap cleanup EXIT

NEUTRAL="$TMPDIR_TEST/neutral"
mkdir -p "$NEUTRAL"

# --- BSD realpath の代役: -m（および GNU 専用の長いオプション）を受け付けない ---
SHIM_DIR="$TMPDIR_TEST/bsd-bin"
mkdir -p "$SHIM_DIR"
REAL_REALPATH="$(command -v realpath 2>/dev/null || printf '')"
cat > "$SHIM_DIR/realpath" <<EOF
#!/bin/sh
for arg in "\$@"; do
  case "\$arg" in
    -m|-e|--*) echo "realpath: illegal option -- \${arg#-}" >&2; echo "usage: realpath [-q] [path ...]" >&2; exit 1 ;;
  esac
done
if [ -n "$REAL_REALPATH" ]; then
  exec "$REAL_REALPATH" "\$@"
fi
exit 1
EOF
chmod +x "$SHIM_DIR/realpath"

# --- fixture: 物理ディレクトリ real/ と、それを指すシンボリックリンク link/ ---
# real/repo がメインワークツリー（main）、real/repo/.worktrees/wt が linked worktree。
PHYS="$TMPDIR_TEST/real"
LINK="$TMPDIR_TEST/link"
mkdir -p "$PHYS"
ln -s "$PHYS" "$LINK"
REPO="$PHYS/repo"
GIT_ID=(-c user.email=t@t -c user.name=t)
git init -q "$REPO"
git -C "$REPO" symbolic-ref HEAD refs/heads/main
mkdir -p "$REPO/src"
printf 'base\n' > "$REPO/src/tracked.txt"
git -C "$REPO" add src/tracked.txt
git -C "$REPO" "${GIT_ID[@]}" commit -q -m init
git -C "$REPO" worktree add -q "$REPO/.worktrees/wt" -b feat 2>/dev/null

OUT=""
DECISION=""
TEXT=""

# run_case <mode: native|bsd-realpath> <GUARD_FORCE_DENY|""> <file_path>
run_case() {
  local mode="$1" force="$2" target="$3" path_env="$PATH"
  local -a extra=()
  [ "${mode}" = "bsd-realpath" ] && path_env="$SHIM_DIR:$PATH"
  [ -n "$force" ] && extra+=(GUARD_FORCE_DENY="$force")
  OUT=$(cd "$NEUTRAL" && jq -n --arg f "$target" --arg cwd "$NEUTRAL" '{tool_input:{file_path:$f, content:"x"}, cwd:$cwd}' \
    | env -u CLAUDE_PROJECT_DIR -u GUARD_SKIP -u GUARD_LEVEL -u GUARD_FORCE_DENY -u GIT_WORKFLOW -u CLAUDE_CLOUD \
        PATH="$path_env" ${extra[@]+"${extra[@]}"} bash "$WORKTREE_GUARD" 2>/dev/null)
  DECISION=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // ""' 2>/dev/null || printf '')
  TEXT=$(printf '%s' "$OUT" | jq -r '(.hookSpecificOutput.permissionDecisionReason // "") + (.hookSpecificOutput.additionalContext // "")' 2>/dev/null || printf '')
  return 0
}

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() {
  echo "  FAIL: $1"
  echo "    decision: ${DECISION:-（出力なし）}"
  echo "    text:     ${TEXT:-（無し）}"
  FAIL=$((FAIL + 1))
}

# メインワークツリーでの編集: warn では advisory（allow + 警告）、FORCE_DENY では deny。
# 警告文には編集しようとしたファイルのリポジトリ相対パスが入る。
expect_main_worktree() {
  local mode="$1" label="$2" target="$3" rel="$4"
  run_case "${mode}" "" "$target"
  if [ "$DECISION" = "allow" ] && printf '%s' "$TEXT" | grep -q 'メインワークツリーでのファイル編集を検出しました'; then
    pass "[${mode}] ${label}（warn）は advisory を返す"
  else
    fail "[${mode}] ${label}（warn）は advisory を返す"
  fi
  if printf '%s' "$TEXT" | grep -qF "編集しようとしたファイル: ${rel}"; then
    pass "[${mode}] ${label}（warn）はリポジトリ相対パスを示す"
  else
    fail "[${mode}] ${label}（warn）はリポジトリ相対パスを示す（${rel}）"
  fi
  run_case "${mode}" worktree-guard "$target"
  if [ "$DECISION" = "deny" ] && printf '%s' "$TEXT" | grep -q 'ブロックしました'; then
    pass "[${mode}] ${label}（GUARD_FORCE_DENY=worktree-guard）は deny を返す"
  else
    fail "[${mode}] ${label}（GUARD_FORCE_DENY=worktree-guard）は deny を返す"
  fi
}

# 対象外（linked worktree 内・除外パス・リポジトリ外）: FORCE_DENY でも何も返さない。
expect_silent() {
  local mode="$1" label="$2" target="$3"
  run_case "${mode}" worktree-guard "$target"
  if [ -z "$OUT" ]; then
    pass "[${mode}] ${label} は対象外（出力なし）"
  else
    fail "[${mode}] ${label} は対象外（出力なし）"
  fi
}

for mode in native bsd-realpath; do
  echo "worktree-guard（${mode}）: 物理パス"
  expect_main_worktree "${mode}" "物理パスの新規ファイル" "$REPO/src/new-file.txt" "src/new-file.txt"
  expect_main_worktree "${mode}" "物理パスの既存ファイル" "$REPO/src/tracked.txt" "src/tracked.txt"
  expect_main_worktree "${mode}" "物理パスの新規ディレクトリ配下" "$REPO/new-dir/deep/file.txt" "new-dir/deep/file.txt"
  expect_silent "${mode}" "物理パスの linked worktree 内" "$REPO/.worktrees/wt/src/new-file.txt"
  expect_silent "${mode}" "物理パスの .claude/ 配下" "$REPO/.claude/settings.json"

  echo "worktree-guard（${mode}）: シンボリックリンク経由のパス"
  expect_main_worktree "${mode}" "リンク経由の新規ファイル" "$LINK/repo/src/new-file.txt" "src/new-file.txt"
  expect_main_worktree "${mode}" "リンク経由の既存ファイル" "$LINK/repo/src/tracked.txt" "src/tracked.txt"
  expect_main_worktree "${mode}" "リンク経由の新規ディレクトリ配下" "$LINK/repo/new-dir/deep/file.txt" "new-dir/deep/file.txt"
  expect_main_worktree "${mode}" "リンク経由で .. を含むパス" "$LINK/repo/.worktrees/wt/../../src/new-file.txt" "src/new-file.txt"
  expect_main_worktree "${mode}" "リンク経由で存在しない要素の .. を含むパス" "$LINK/repo/new-dir/../src/new-file.txt" "src/new-file.txt"
  expect_silent "${mode}" "リンク経由の linked worktree 内" "$LINK/repo/.worktrees/wt/src/new-file.txt"
  expect_silent "${mode}" "リンク経由の .claude/ 配下" "$LINK/repo/.claude/settings.json"
  expect_silent "${mode}" "リンク経由の CLAUDE.md" "$LINK/repo/CLAUDE.md"
  expect_silent "${mode}" "リポジトリ外" "$NEUTRAL/outside.txt"
done

echo
echo "PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
