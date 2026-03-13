#!/bin/bash
# migration-guard: PreToolUse (Write) - マイグレーション番号の重複を警告 [L4]
#
# supabase/migrations/ へのファイル作成時に既存番号と照合し、
# 重複があればユーザーに確認を求める。重複がなくても最新番号を通知する。

set -uo pipefail

INPUT=$(cat)

# file_path を取得
if command -v jq &>/dev/null; then
  FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
else
  exit 0
fi

if [ -z "${FILE_PATH:-}" ]; then
  exit 0
fi

# supabase/migrations/ 配下かチェック
case "$FILE_PATH" in
  */supabase/migrations/*)
    ;;
  *)
    exit 0
    ;;
esac

# プロジェクトルートを取得
PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
if [ -z "$PROJECT_ROOT" ]; then
  exit 0
fi

MIGRATIONS_DIR="$PROJECT_ROOT/supabase/migrations"
if [ ! -d "$MIGRATIONS_DIR" ]; then
  exit 0
fi

# 新規ファイルの番号を抽出（ファイル名の先頭数字部分）
NEW_FILENAME=$(basename "$FILE_PATH")
NEW_NUMBER=$(echo "$NEW_FILENAME" | grep -oE '^[0-9]+' || echo "")

if [ -z "$NEW_NUMBER" ]; then
  exit 0
fi

# 既存のマイグレーション番号一覧を取得
EXISTING_NUMBERS=$(find "$MIGRATIONS_DIR" -maxdepth 1 -name '*.sql' -exec basename {} \; 2>/dev/null | grep -oE '^[0-9]+' | sort -n)
LATEST_NUMBER=$(echo "$EXISTING_NUMBERS" | tail -1)

# 重複チェック
if echo "$EXISTING_NUMBERS" | grep -qx "$NEW_NUMBER"; then
  # 既存ファイルの上書き（同じファイル名）かチェック
  EXISTING_FILE=$(ls "$MIGRATIONS_DIR"/${NEW_NUMBER}*.sql 2>/dev/null | head -1)
  if [ "$(basename "$EXISTING_FILE" 2>/dev/null)" = "$NEW_FILENAME" ]; then
    # 同じファイルの更新は許可
    exit 0
  fi

  # 異なるファイル名で同じ番号 → 重複警告
  cat << EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "ask",
    "permissionDecisionReason": "[マイグレーションガード] 番号 ${NEW_NUMBER} は既に存在します: $(basename "$EXISTING_FILE" 2>/dev/null)。最新の番号は ${LATEST_NUMBER} です。次は $((10#$LATEST_NUMBER + 1)) を使用してください。"
  }
}
EOF
else
  # 重複なし - 最新番号をコンテキストとして注入
  cat << EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "additionalContext": "[マイグレーションガード] 番号チェック OK。現在の最新番号: ${LATEST_NUMBER}。新規番号: ${NEW_NUMBER}。"
  }
}
EOF
fi
