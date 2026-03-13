#!/bin/bash
# Stop hook: セッション完了時に Discord へ通知
# PROJECT_DIR が設定されていればそのディレクトリ内でのみ発火する
set -uo pipefail

CWD=$(pwd)
PROJECT_DIR="${PROJECT_DIR:-$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null || echo "")}"
if [ -z "$PROJECT_DIR" ]; then
  exit 0
fi

source ~/.claude/.env 2>/dev/null || true

# スクリプトのパス（リポジトリ内のシンボリックリンク先）
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NOTIFY="$SCRIPT_DIR/notify-discord.sh"

if [ ! -x "$NOTIFY" ]; then
  # フォールバック: ~/.claude/scripts/ から探す
  NOTIFY=~/.claude/scripts/notify-discord.sh
fi

# 直近のコミットから文脈を取得
REPO_DIR=$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null || echo "$PROJECT_DIR")
BRANCH=$(git -C "$REPO_DIR" branch --show-current 2>/dev/null || echo 'unknown')
LAST_COMMIT=$(git -C "$REPO_DIR" log --oneline -1 2>/dev/null || echo 'no commits')

# 未プッシュのコミット数
UNPUSHED=$(git -C "$REPO_DIR" log --oneline @{upstream}..HEAD 2>/dev/null | wc -l | tr -d ' ')

MSG="ブランチ: $BRANCH\nディレクトリ: $CWD\n最新コミット: $LAST_COMMIT"
if [ "$UNPUSHED" -gt 0 ]; then
  MSG="$MSG\n未プッシュ: ${UNPUSHED}件"
fi

"$NOTIFY" success "セッション完了" "$MSG"
