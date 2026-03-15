#!/bin/bash
# session-sync/fetch-on-start.sh: SessionStart - セッション開始時にリモートをフェッチし遅延を警告
#
# git fetch を実行し、現在のブランチがリモートより遅れている場合に
# additionalContext で警告する。pull は行わない（安全側）。

set -uo pipefail

# git リポジトリでなければスキップ
if ! git rev-parse --is-inside-work-tree &>/dev/null; then
  exit 0
fi

# fetch（タイムアウト 10 秒）
timeout 10 git fetch --quiet 2>/dev/null || exit 0

BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
if [ -z "$BRANCH" ] || [ "$BRANCH" = "HEAD" ]; then
  exit 0
fi

# リモート追跡ブランチがあるか確認
UPSTREAM=$(git rev-parse --abbrev-ref "@{upstream}" 2>/dev/null || echo "")
if [ -z "$UPSTREAM" ]; then
  exit 0
fi

# ローカルとリモートの差分
BEHIND=$(git rev-list --count HEAD.."$UPSTREAM" 2>/dev/null || echo "0")
AHEAD=$(git rev-list --count "$UPSTREAM"..HEAD 2>/dev/null || echo "0")

if [ "$BEHIND" -gt 0 ]; then
  cat << EOF
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "[同期警告] ブランチ ${BRANCH} はリモート (${UPSTREAM}) より ${BEHIND} コミット遅れています。作業前に git pull を検討してください。(ahead: ${AHEAD})"
  }
}
EOF
  exit 0
fi

exit 0
