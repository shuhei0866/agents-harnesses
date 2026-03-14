#!/bin/bash
# discord-response-poll: PostToolUse (mcp__discord__discord_send) - Discord 送信後に応答待ちをリマインド [L3]
#
# Discord チャンネルにレビュアー宛てのメッセージを送信した後、
# 応答を確認するようリマインダーを注入する。
# これにより「送りっぱなし」で実装に進むことを防ぐ。

set -uo pipefail

INPUT=$(cat)

if ! command -v jq &>/dev/null; then
  exit 0
fi

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')

# discord_send のみ対象
if [ "$TOOL_NAME" != "mcp__discord__discord_send" ]; then
  exit 0
fi

CHANNEL_ID=$(echo "$INPUT" | jq -r '.tool_input.channelId // empty')
MESSAGE=$(echo "$INPUT" | jq -r '.tool_input.message // empty')

# 対象チャンネルへの送信のみ対象
TARGET_CHANNEL="${DISCORD_CHANNEL_ID:-}"
if [ -z "$TARGET_CHANNEL" ] || [ "$CHANNEL_ID" != "$TARGET_CHANNEL" ]; then
  exit 0
fi

# レビュアーへのメンションを含むメッセージのみ対象
REVIEWER_MENTION="${DISCORD_REVIEWER_MENTION:-}"
if [ -z "$REVIEWER_MENTION" ] || ! echo "$MESSAGE" | grep -qF "$REVIEWER_MENTION"; then
  exit 0
fi

# 応答ポーリングのリマインダーを注入
REMIND_CHANNEL="${DISCORD_CHANNEL_ID:-}"
cat << CONTEXT
{
  "hookSpecificOutput": {
    "hookEventName": "PostToolUse",
    "additionalContext": "[応答待ち] レビュアーにメッセージを送信しました。\n\n**必須アクション**: 30秒待ってから discord_read_messages でチャンネル ${REMIND_CHANNEL} の最新メッセージを確認してください。レビュアーの返答が来るまで実装に進まないこと（議論→合意→実装）。\n\n返答が来ていない場合は、さらに30秒待って再確認してください（最大3回）。3回確認しても返答がない場合は、他の作業を進めつつ定期的に確認してください。"
  }
}
CONTEXT
