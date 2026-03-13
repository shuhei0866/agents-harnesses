#!/bin/bash
# Discord 通知スクリプト（OpenClaw メンション付き）
# Usage: notify-discord.sh <status> <title> <message> [pr_url]
#
# status: success | error | info | review
# title: 通知タイトル
# message: 本文
# pr_url: (任意) PR の URL
#
# 環境変数（~/.claude/.env から読み込み）:
#   DISCORD_WEBHOOK_URL: Discord webhook URL（あれば優先）
#   DISCORD_CHANNEL_ID: Bot token fallback の送信先チャンネル ID
#   OPENCLAW_MENTION: OpenClaw のメンション文字列 (例: <@123456789>)
#   DISCORD_TOKEN: Discord Bot token（未設定なら GNOME Keyring から取得を試行）

set -euo pipefail

# このプロジェクト専用のデフォルト値。必要に応じて ~/.claude/.env で上書きする。
DEFAULT_CHANNEL_ID="${DISCORD_CHANNEL_ID:-}"
DEFAULT_OPENCLAW_MENTION="${DISCORD_REVIEWER_MENTION:-}"

# 環境変数の読み込み
if [ -f ~/.claude/.env ]; then
  source ~/.claude/.env
fi

STATUS=${1:-info}
TITLE=${2:-通知}
MESSAGE=${3:-}
PR_URL=${4:-}

# ステータスごとの色（Discord embed color）
case $STATUS in
  success) COLOR=5763719 ;;   # Green
  error)   COLOR=15548997 ;;  # Red
  review)  COLOR=16776960 ;;  # Yellow
  info)    COLOR=5793266 ;;   # Blue
  *)       COLOR=9807270 ;;   # Gray
esac

# ステータスラベル
case $STATUS in
  success) LABEL="完了" ;;
  error)   LABEL="エラー" ;;
  review)  LABEL="レビュー待ち" ;;
  info)    LABEL="情報" ;;
  *)       LABEL=$STATUS ;;
esac

MENTION="${OPENCLAW_MENTION:-$DEFAULT_OPENCLAW_MENTION}"
CHANNEL_ID="${DISCORD_CHANNEL_ID:-$DEFAULT_CHANNEL_ID}"
TIMESTAMP="$(TZ=Asia/Tokyo date +'%Y-%m-%d %H:%M:%S JST')"

get_discord_token() {
  if [ -n "${DISCORD_TOKEN:-}" ]; then
    printf '%s' "$DISCORD_TOKEN"
    return 0
  fi

  if command -v secret-tool >/dev/null 2>&1; then
    secret-tool lookup service claude-agent attribute DISCORD_TOKEN 2>/dev/null | tr -d '\n' || true
  fi
}

build_embed_payload() {
  jq -cn \
    --arg content "$MENTION" \
    --arg title "[$LABEL] $TITLE" \
    --arg description "$MESSAGE" \
    --arg timestamp "$TIMESTAMP" \
    --arg pr "$PR_URL" \
    --arg hostname "${HOSTNAME:-unknown}" \
    --argjson color "$COLOR" '
    {
      content: $content,
      embeds: [
        {
          title: $title,
          description: $description,
          color: $color,
          fields: (
            [
              { name: "環境", value: $hostname, inline: true },
              { name: "時刻", value: $timestamp, inline: true }
            ] +
            (if $pr == "" then [] else [{ name: "PR", value: $pr, inline: false }] end)
          ),
          footer: { text: "Claude Code VPS" }
        }
      ]
    }'
}

send_via_webhook() {
  local payload
  payload="$(build_embed_payload)"

  curl -fsS \
    -H "Content-Type: application/json" \
    -d "$payload" \
    "$DISCORD_WEBHOOK_URL" >/dev/null
}

send_via_bot_token() {
  local token payload

  token="$(get_discord_token)"
  if [ -z "$token" ]; then
    echo "Discord credentials are not set. Skipping notification."
    exit 0
  fi

  if [ -z "$CHANNEL_ID" ]; then
    echo "DISCORD_CHANNEL_ID is not set. Skipping notification."
    exit 0
  fi

  payload="$(build_embed_payload)"

  curl -fsS \
    -H "Authorization: Bot $token" \
    -H "Content-Type: application/json" \
    -d "$payload" \
    "https://discord.com/api/v10/channels/$CHANNEL_ID/messages" >/dev/null
}

if [ -n "${DISCORD_WEBHOOK_URL:-}" ]; then
  send_via_webhook
else
  send_via_bot_token
fi

echo "Discord notification sent: [$LABEL] $TITLE"
