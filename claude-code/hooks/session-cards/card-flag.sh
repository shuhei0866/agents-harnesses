#!/usr/bin/env bash
# waiting_on_input フラグの反転（LLM なし・同期・数 ms）。
#
# 配線:
#   Notification (permission_prompt) → card-flag.sh waiting  … 入力待ちで停止した
#   UserPromptSubmit                 → card-flag.sh active   … ユーザーが応答した
#
# カードが無ければ何もしない（カード生成は card-stop-hook.sh 側の責務）。
set -u
trap 'exit 0' EXIT

if [ "${CLAUDE_SESSION_CARDS_DISABLE:-0}" = "1" ]; then
  exit 0
fi

MODE="${1:-}"
case "$MODE" in
  waiting) NEW=true;  OLD=false ;;
  active)  NEW=false; OLD=true ;;
  *) exit 0 ;;
esac

INPUT=$(cat)
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)
TRANSCRIPT=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null || true)
[ -n "$SESSION_ID" ] && [ -n "$TRANSCRIPT" ] || exit 0

CARDS_ROOT="${CLAUDE_SESSION_CARDS_ROOT:-$HOME/.claude/session-cards}"
CARD="$CARDS_ROOT/$(basename "$(dirname "$TRANSCRIPT")")/$SESSION_ID.md"
[ -f "$CARD" ] || exit 0

/usr/bin/sed -i '' "s/^waiting_on_input: $OLD\$/waiting_on_input: $NEW/" "$CARD" 2>/dev/null || true

exit 0
