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

# sed -i は GNU/BSD で非互換なので使わず、temp+mv で原子的に書く。
# 反転対象の行が無ければ何もしない (mtime を無駄に動かさない)。
if grep -q "^waiting_on_input: $OLD\$" "$CARD" 2>/dev/null; then
  CARD_DIR=$(dirname "$CARD")
  TMP_FLIP=$(mktemp "$CARD_DIR/.flag.XXXXXX" 2>/dev/null || true)
  if [ -n "$TMP_FLIP" ]; then
    if sed "s/^waiting_on_input: $OLD\$/waiting_on_input: $NEW/" "$CARD" > "$TMP_FLIP" 2>/dev/null; then
      mv -f "$TMP_FLIP" "$CARD"
    else
      rm -f "$TMP_FLIP"
    fi
  fi
fi

exit 0
