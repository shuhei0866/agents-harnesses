#!/usr/bin/env bash
# Stop hook: セッションカード（常時蒸留）の入口 wrapper。
#
# 毎ターン終了時に呼ばれる。大半のターンはデバウンスで即復帰し
# （hot path は jq 1 回 + sed + stat のみ）、5 分に 1 回だけ
# 蒸留本体 distill.sh を detach して起動する。ユーザーの次ターンは遅らせない。
#
# 設計の根拠 (my-skynet-hub docs/workspace/decisions.md D-001):
# - セッションには「終わりの瞬間」が無い（放置で終わる）ため、
#   SessionEnd ではなく毎ターンの Stop で常時カードを最新化する。
# - 人間の儀式に依存しない。
set -u
trap 'exit 0' EXIT

# 再帰ガード第 1 層: distill.sh の子 claude -p から発火した場合は即終了
if [ "${CLAUDE_SESSION_CARDS_DISABLE:-0}" = "1" ]; then
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CARDS_ROOT="${CLAUDE_SESSION_CARDS_ROOT:-$HOME/.claude/session-cards}"
DEBOUNCE_SECS="${CLAUDE_SESSION_CARDS_DEBOUNCE:-300}"

# mtime 取得は GNU (stat -c %Y) と BSD/macOS (stat -f %m) で分岐する
if stat -c %Y . >/dev/null 2>&1; then
  mtime() { stat -c %Y "$1" 2>/dev/null || echo 0; }
else
  mtime() { stat -f %m "$1" 2>/dev/null || echo 0; }
fi

INPUT=$(cat)
# jq の spawn は 1 回に抑える（wrapper の復帰時間を削るため）
SESSION_ID=""; TRANSCRIPT=""; CWD=""
{ IFS= read -r SESSION_ID; IFS= read -r TRANSCRIPT; IFS= read -r CWD; } <<PARSED_EOF || true
$(printf '%s' "$INPUT" | jq -r '(.session_id // ""), (.transcript_path // ""), (.cwd // "")' 2>/dev/null || true)
PARSED_EOF

[ -n "$SESSION_ID" ] || exit 0
[ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ] || exit 0

# カードパスは Claude 自身の cwd エンコード（transcript の親ディレクトリ名）を流用
PROJECT_SLUG=$(basename "$(dirname "$TRANSCRIPT")")
CARD_DIR="$CARDS_ROOT/$PROJECT_SLUG"
CARD="$CARD_DIR/$SESSION_ID.md"

# ターンが完了した = permission prompt では止まっていない。同期で解除（LLM なし）。
# sed -i は GNU/BSD で非互換なので使わず、distill.sh と同じ temp+mv で原子的に書く。
if [ -f "$CARD" ] && grep -q '^waiting_on_input: true$' "$CARD" 2>/dev/null; then
  TMP_FLIP=$(mktemp "$CARD_DIR/.flag.XXXXXX" 2>/dev/null || true)
  if [ -n "$TMP_FLIP" ]; then
    if sed 's/^waiting_on_input: true$/waiting_on_input: false/' "$CARD" > "$TMP_FLIP" 2>/dev/null; then
      mv -f "$TMP_FLIP" "$CARD"
    else
      rm -f "$TMP_FLIP"
    fi
  fi
fi

# デバウンス。カード本体の mtime は flag 反転でも動くため、
# 蒸留時刻は sidecar stamp で管理する。大半の Stop はここで終わる。
STAMP="$CARD_DIR/.$SESSION_ID.stamp"
if [ -f "$STAMP" ]; then
  NOW=$(date +%s)
  LAST=$(mtime "$STAMP")
  if [ $((NOW - LAST)) -lt "$DEBOUNCE_SECS" ]; then
    exit 0
  fi
fi

# 対話セッションのみカード化する（claude -p の一発物を除外）。
# 注意: -p 一発物も kind=interactive で登録される（2.1.207 実測）。
# 判別子は entrypoint で、対話セッション=cli / -p 一発物=sdk-cli。
# ~/.claude/sessions/<pid>.json のライブレジストリに
# sessionId 一致 + kind=interactive + entrypoint=cli のエントリを要求する。
REGISTRY_DIR="$HOME/.claude/sessions"
IS_INTERACTIVE=0
if [ -d "$REGISTRY_DIR" ]; then
  for f in "$REGISTRY_DIR"/*.json; do
    [ -f "$f" ] || continue
    grep -q "$SESSION_ID" "$f" 2>/dev/null || continue
    # 同一 sessionId のエントリが複数あるケース (stale ファイル残存 +
    # claude -p --resume 併用など) に備え、interactive cli が見つかるまで走査する
    if jq -e '.kind == "interactive" and .entrypoint == "cli"' "$f" >/dev/null 2>&1; then
      IS_INTERACTIVE=1
      break
    fi
  done
fi
[ "$IS_INTERACTIVE" = "1" ] || exit 0

mkdir -p "$CARD_DIR"

# 多重蒸留ロック（10 分 stale なら奪う）
LOCK="$CARD_DIR/.$SESSION_ID.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  NOW=$(date +%s)
  LOCK_MTIME=$(mtime "$LOCK")
  if [ $((NOW - LOCK_MTIME)) -lt 600 ]; then
    exit 0
  fi
  rmdir "$LOCK" 2>/dev/null || true
  mkdir "$LOCK" 2>/dev/null || exit 0
fi

# 蒸留本体を完全に切り離して起動（stdio を全て閉じ、hook の 60s timeout に掛けない）
nohup "$SCRIPT_DIR/distill.sh" "$SESSION_ID" "$TRANSCRIPT" "$CWD" "$CARD" "$LOCK" "$STAMP" </dev/null >/dev/null 2>&1 &

exit 0
