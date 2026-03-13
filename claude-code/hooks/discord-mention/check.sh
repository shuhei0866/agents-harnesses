#!/bin/bash
# discord-mention-check: PreToolUse (mcp__discord__*) - Discord メンションの形式を検証 [L5]
#
# Discord MCP ツールでメッセージを送信する際、プレーンテキストの @username が
# 含まれている場合にブロックする。Discord では <@USER_ID> 形式でないと
# メンションとして機能しないため。
#
# ユーザーマッピングは環境変数または設定ファイルから読み込む。
# 設定ファイル: ~/.claude/discord-mention-map.conf
# 形式（1行1エントリ）:
#   @display_name_pattern|<@DISCORD_USER_ID>
# 例:
#   @open.claw|<@111111111111111111>
#   @my.bot|<@222222222222222222>
#   @claude.code.vps|<@333333333333333333>

set -uo pipefail

INPUT=$(cat)

# tool_input から message/content フィールドを取得
if ! command -v jq &>/dev/null; then
  exit 0
fi

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')

# Discord の送信系ツールのみチェック
case "$TOOL_NAME" in
  mcp__discord__discord_send|\
  mcp__discord__discord_send_webhook_message|\
  mcp__discord__discord_reply_to_forum|\
  mcp__discord__discord_create_forum_post)
    ;;
  *)
    exit 0
    ;;
esac

# メッセージ本文を取得（message または content フィールド）
MESSAGE=$(echo "$INPUT" | jq -r '.tool_input.message // .tool_input.content // empty')

if [ -z "$MESSAGE" ]; then
  exit 0
fi

# 既に正しい <@ID> 形式のメンションを一時的に除去してからチェック
CLEANED=$(echo "$MESSAGE" | sed -E 's/<@[0-9]+>//g')

# メンションマッピング設定ファイルを読み込む
MENTION_MAP_FILE="${DISCORD_MENTION_MAP:-$HOME/.claude/discord-mention-map.conf}"

FOUND_MENTIONS=""

if [ -f "$MENTION_MAP_FILE" ]; then
  # 設定ファイルからマッピングを読み込んでチェック
  while IFS='|' read -r pattern replacement; do
    # コメント行・空行をスキップ
    [[ "$pattern" =~ ^#.*$ || -z "$pattern" ]] && continue
    # パターンの @ を除去して grep 用パターンを構築
    grep_pattern=$(echo "$pattern" | sed 's/@//')
    if echo "$CLEANED" | grep -qiF "$grep_pattern"; then
      FOUND_MENTIONS="${FOUND_MENTIONS}${pattern} → ${replacement}\n"
    fi
  done < "$MENTION_MAP_FILE"
else
  # 設定ファイルがない場合は汎用パターンのみチェック
  # プレーンテキストの @mention が含まれているか検出
  if echo "$CLEANED" | grep -qE '@[a-zA-Z][a-zA-Z0-9_. ]+'; then
    FOUND_MENTIONS="プレーンテキストの @mention が検出されました。<@USER_ID> 形式を使用してください。\n"
  fi
fi

if [ -n "$FOUND_MENTIONS" ]; then
  cat << DENY
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "[Discord メンションガード] プレーンテキストの @mention が検出されました。Discord ではメンションとして機能しません。\n\n以下の形式に修正してください:\n${FOUND_MENTIONS}\nメッセージを修正して再送信してください。"
  }
}
DENY
  exit 0
fi

# 問題なし
exit 0
