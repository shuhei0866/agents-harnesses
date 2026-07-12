#!/bin/bash
# worktree-guard: PreToolUse (Write|Edit) - メインワークツリーでのファイル編集をブロック [L5]
#
# メインワークツリー（リポジトリルート）でのファイル編集を技術的にブロックする。
# ワークツリー内、または除外パス（.claude/, CLAUDE.md 等）への書き込みは許可。
#
# project_root はファイルパス起点で特定する。Claude Code は cwd と異なるリポジトリの
# ファイルを操作することがあり (例: cwd=my-skynet-hub で projects/student-portal/ 配下
# を Edit する)、cwd 起点だと別リポジトリの harness.config が読まれて当該リポジトリの
# GUARD_FORCE_DENY 等が無視されてしまうため。

set -uo pipefail

INPUT=$(cat)

if ! command -v jq &>/dev/null; then
  # jq がない場合はスキップ（安全側に倒す）
  exit 0
fi

# file_path を取得
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

# パストラバーサル防止: .. を含むパスを正規化
FILE_PATH=$(realpath -m "$FILE_PATH" 2>/dev/null || echo "$FILE_PATH")

if [ -z "${FILE_PATH:-}" ]; then
  exit 0
fi

# ファイルが属するリポジトリのルートをファイルパス起点で特定
# (Write でまだ存在しない新規ファイルでも、親ディレクトリを辿って解決する)
FILE_DIR=$(dirname "$FILE_PATH")
while [ -n "$FILE_DIR" ] && [ "$FILE_DIR" != "/" ] && [ ! -d "$FILE_DIR" ]; do
  FILE_DIR=$(dirname "$FILE_DIR")
done

if [ ! -d "$FILE_DIR" ]; then
  exit 0
fi

PROJECT_ROOT=$(cd "$FILE_DIR" && git rev-parse --show-toplevel 2>/dev/null || echo "")
if [ -z "$PROJECT_ROOT" ]; then
  exit 0
fi

# パスを正規化
PROJECT_ROOT=$(realpath -m "$PROJECT_ROOT" 2>/dev/null || echo "$PROJECT_ROOT")

# CLAUDE_PROJECT_DIR をファイル所属リポジトリで上書き
# (_guard-common.sh が harness.config を探索する際にこの値を使う)
export CLAUDE_PROJECT_DIR="$PROJECT_ROOT"

# 共通ライブラリを source（このタイミングで GUARD_LEVEL / GUARD_SKIP / GUARD_FORCE_DENY がロードされる）
GUARD_COMMON="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_guard-common.sh"
source "$GUARD_COMMON"

# trunk-direct はメインワークツリーでの Edit/Write を明示的に許可する。
# 未設定・worktree-pr・不正値は guard_is_trunk_direct が false となり従来どおり判定する。
if guard_is_trunk_direct; then
  exit 0
fi

# 現在のディレクトリがワークツリーかどうかを判定
# git worktree 内では git rev-parse --git-dir が .git/worktrees/<name> を返す
# メインワークツリーでは git の common dir と toplevel が一致する
GIT_COMMON_DIR=$(cd "$PROJECT_ROOT" && git rev-parse --git-common-dir 2>/dev/null || echo "")
GIT_DIR=$(cd "$PROJECT_ROOT" && git rev-parse --git-dir 2>/dev/null || echo "")

# ワークツリー内にいる場合（.git がファイルで common dir と異なる）は許可
if [ "$GIT_DIR" != "$GIT_COMMON_DIR" ] && [ "$GIT_DIR" != ".git" ]; then
  exit 0
fi

# ファイルパスがワークツリー内かチェック（メインWT 配下のファイルでも、worktree 内なら許可）
while IFS= read -r line; do
  case "$line" in
    worktree\ *)
      WT_PATH="${line#worktree }"
      # メインワークツリーはスキップ
      if [ "$WT_PATH" = "$PROJECT_ROOT" ]; then
        continue
      fi
      # ワークツリーパスも正規化してから比較（パストラバーサル対策）
      WT_PATH_NORMALIZED=$(realpath -m "$WT_PATH" 2>/dev/null || echo "$WT_PATH")
      # ファイルがこのワークツリー内にある場合は許可
      case "$FILE_PATH" in
        "$WT_PATH_NORMALIZED"/*)
          exit 0
          ;;
      esac
      ;;
  esac
done < <(cd "$PROJECT_ROOT" && git worktree list --porcelain 2>/dev/null)

# ファイルパスがプロジェクトルート配下かチェック
case "$FILE_PATH" in
  "$PROJECT_ROOT"/*)
    # プロジェクト内のファイル - 除外パスをチェック
    ;;
  *)
    # プロジェクト外のファイル - 許可
    exit 0
    ;;
esac

# 除外パス: これらはメインワークツリーでの編集を許可
RELATIVE_PATH="${FILE_PATH#$PROJECT_ROOT/}"
case "$RELATIVE_PATH" in
  .claude/*)         exit 0 ;;  # Claude Code 設定・メモリ
  CLAUDE.md)         exit 0 ;;  # 自己改善プロトコル
  .gitignore)        exit 0 ;;  # gitignore の更新
  .github/*)         exit 0 ;;  # CI/CD 設定
esac

# メインワークツリーでの編集をブロック
guard_respond "advisory" "ワークツリーガード" "メインワークツリーでのファイル編集はブロックされています。\n\n対処法: ユーザーに報告し、\`git worktree add .worktrees/<name> <branch>\` でワークツリーを作成してそこで作業してください。\n\n編集しようとしたファイル: ${RELATIVE_PATH}"
