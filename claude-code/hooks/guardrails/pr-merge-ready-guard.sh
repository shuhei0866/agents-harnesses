#!/bin/bash
# pr-merge-ready-guard: PreToolUse (Bash) - PR マージ前に準備状態をチェック
#
# gh pr merge コマンド実行前に以下を検証:
#   1. 未解決のレビューコメントが無いこと（resolved or outdated）
#   2. マージコンフリクトが無いこと（mergeable != CONFLICTING）
#
# 問題があれば deny してマージをブロックする。

set -uo pipefail

GUARD_COMMON="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_guard-common.sh"
source "$GUARD_COMMON"

INPUT=$(cat)

if command -v jq &>/dev/null; then
  COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
else
  exit 0
fi

if [ -z "${COMMAND:-}" ]; then
  exit 0
fi

# gh pr merge 以外はスキップ
COMMAND_FOR_MATCH=$(echo "$COMMAND" | sed -E "s/\"[^\"]*\"/_Q_/g; s/'[^']*'/_Q_/g")
if ! echo "$COMMAND_FOR_MATCH" | grep -qE 'gh\s+pr\s+merge'; then
  exit 0
fi

# PR 番号を抽出
PR_NUM=$(echo "$COMMAND" | grep -oE 'gh\s+pr\s+merge\s+[0-9]+' | grep -oE '[0-9]+$')

# PR 番号がない場合（カレントブランチの PR）
if [ -z "$PR_NUM" ]; then
  PR_NUM=$(gh pr view --json number -q .number 2>/dev/null) || true
fi

if [ -z "$PR_NUM" ]; then
  exit 0
fi

# --- リポジトリ owner/name を取得 ---
REPO_NWO=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null) || true
if [ -z "$REPO_NWO" ]; then
  exit 0
fi
OWNER=$(echo "$REPO_NWO" | cut -d/ -f1)
NAME=$(echo "$REPO_NWO" | cut -d/ -f2)

ISSUES=""

# --- チェック 1: 未解決レビューコメント ---
UNRESOLVED=$(gh api graphql \
  -F owner="$OWNER" \
  -F name="$NAME" \
  -F prNum="$PR_NUM" \
  -f query='
{
  repository(owner: $owner, name: $name) {
    pullRequest(number: $prNum) {
      reviewThreads(first: 50) {
        nodes {
          isResolved
          isOutdated
        }
      }
    }
  }
}' --jq '[.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved == false and .isOutdated == false)] | length' 2>/dev/null) || true

if [ -n "$UNRESOLVED" ] && [ "$UNRESOLVED" -gt 0 ]; then
  ISSUES="${ISSUES}未解決のレビューコメントが ${UNRESOLVED} 件あります。resolve してからマージしてください。"
fi

# --- チェック 2: マージコンフリクト ---
MERGEABLE=$(gh pr view "$PR_NUM" --json mergeable -q .mergeable 2>/dev/null) || true

if [ "$MERGEABLE" = "CONFLICTING" ]; then
  if [ -n "$ISSUES" ]; then
    ISSUES="${ISSUES} / "
  fi
  ISSUES="${ISSUES}マージコンフリクトがあります。コンフリクトを解消してからマージしてください。"
fi

# --- 結果 ---
if [ -n "$ISSUES" ]; then
  guard_respond "critical" "PR マージ準備ガード" "PR #${PR_NUM} はマージできる状態ではありません: ${ISSUES}"
fi

exit 0
