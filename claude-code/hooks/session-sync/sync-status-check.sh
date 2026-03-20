#!/bin/bash
# sync-status-check.sh: SessionStart - 全主要リポジトリの同期状態をチェック
#
# セッション開始時に以下を検出して警告:
# - リモートより遅れている (behind)
# - push していないコミットがある (ahead)
# - 未コミットの変更がある (dirty)
#
# カレントリポジトリだけでなく、主要リポジトリ全てをチェックする。

set -uo pipefail

# チェック対象リポジトリ（追加する場合はここに追記）
REPOS=(
  "$HOME/Documents/my-skynet-hub"
  "$HOME/agents-harnesses"
)

# カレントディレクトリも追加（重複は後で除外）
CWD_REPO=$(git -C "$(pwd)" rev-parse --show-toplevel 2>/dev/null || echo "")
if [ -n "$CWD_REPO" ]; then
  REPOS+=("$CWD_REPO")
fi

# 重複除外
REPOS=($(printf '%s\n' "${REPOS[@]}" | sort -u))

WARNINGS=""

for repo in "${REPOS[@]}"; do
  [ -d "$repo/.git" ] || continue
  name=$(basename "$repo")

  # fetch（タイムアウト 5 秒、失敗しても続行）
  timeout 5 git -C "$repo" fetch --quiet 2>/dev/null || true

  BRANCH=$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  [ -z "$BRANCH" ] || [ "$BRANCH" = "HEAD" ] && continue

  UPSTREAM=$(git -C "$repo" rev-parse --abbrev-ref "@{upstream}" 2>/dev/null || echo "")

  BEHIND=0
  AHEAD=0
  if [ -n "$UPSTREAM" ]; then
    BEHIND=$(git -C "$repo" rev-list --count HEAD.."$UPSTREAM" 2>/dev/null || echo "0")
    AHEAD=$(git -C "$repo" rev-list --count "$UPSTREAM"..HEAD 2>/dev/null || echo "0")
  fi

  DIRTY=$(git -C "$repo" diff --name-only 2>/dev/null | wc -l | tr -d ' ')
  STAGED=$(git -C "$repo" diff --cached --name-only 2>/dev/null | wc -l | tr -d ' ')
  DIRTY=$((DIRTY + STAGED))

  ISSUES=""
  [ "$BEHIND" -gt 0 ] && ISSUES="${ISSUES} behind=${BEHIND}"
  [ "$AHEAD" -gt 0 ] && ISSUES="${ISSUES} ahead=${AHEAD}(未push)"
  [ "$DIRTY" -gt 0 ] && ISSUES="${ISSUES} dirty=${DIRTY}(未commit)"

  if [ -n "$ISSUES" ]; then
    WARNINGS="${WARNINGS}\n  - ${name} (${BRANCH}):${ISSUES}"
  fi
done

if [ -n "$WARNINGS" ]; then
  # JSON エスケープ
  MSG=$(printf "[同期チェック] 以下のリポジトリに同期が必要です:%b" "$WARNINGS")
  ESCAPED=$(python3 -c "import json,sys; print(json.dumps(sys.stdin.read().strip()))" <<< "$MSG" 2>/dev/null || echo "\"$MSG\"")
  cat << EOF
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": ${ESCAPED}
  }
}
EOF
fi

exit 0
