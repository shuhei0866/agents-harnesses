#!/bin/bash
# pr-review/resolve-reminder.sh: PostToolUse (Bash) - push 後に未 resolve スレッドをリマインド
#
# git push 完了後に、push 先ブランチに紐づく PR の未 resolve レビュースレッドを検出し、
# あれば resolve を促すリマインドを出力する。

set -uo pipefail

INPUT=$(cat)

# command を取得
if ! command -v jq &>/dev/null; then
  exit 0
fi

COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
TOOL_RESULT=$(echo "$INPUT" | jq -r '.tool_result.stdout // empty')

if [ -z "${COMMAND:-}" ]; then
  exit 0
fi

# git push コマンドかチェック（失敗した push はスキップ）
if ! echo "$COMMAND" | grep -qE 'git\s+push\b'; then
  exit 0
fi

# push が成功したかチェック（reject や error を含む場合はスキップ）
if echo "$TOOL_RESULT" | grep -qiE 'rejected|error|fatal'; then
  exit 0
fi

# gh コマンドが利用可能かチェック
if ! command -v gh &>/dev/null; then
  exit 0
fi

# 現在のブランチに紐づく open な PR を探す
BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
if [ -z "$BRANCH" ]; then
  exit 0
fi

PR_NUMBER=$(gh pr list --head "$BRANCH" --state open --json number --jq '.[0].number' 2>/dev/null || echo "")
if [ -z "$PR_NUMBER" ]; then
  exit 0
fi

# リポジトリ情報取得
REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || echo "")
if [ -z "$REPO" ]; then
  exit 0
fi

OWNER=$(echo "$REPO" | cut -d/ -f1)
NAME=$(echo "$REPO" | cut -d/ -f2)

# 未 resolve のレビュースレッドを取得
UNRESOLVED=$(gh api graphql \
  -F owner="$OWNER" \
  -F name="$NAME" \
  -F prNum="$PR_NUMBER" \
  -f query='
  { repository(owner: $owner, name: $name) {
    pullRequest(number: $prNum) {
      reviewThreads(first:50) {
        nodes {
          id
          isResolved
          comments(first:1) {
            nodes { path }
          }
        }
      }
    }
  }
' --jq '[.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved == false)] | length' 2>/dev/null || echo "0")

if [ "$UNRESOLVED" -gt 0 ] 2>/dev/null; then
  THREAD_IDS=$(gh api graphql \
    -F owner="$OWNER" \
    -F name="$NAME" \
    -F prNum="$PR_NUMBER" \
    -f query='
    { repository(owner: $owner, name: $name) {
      pullRequest(number: $prNum) {
        reviewThreads(first:50) {
          nodes {
            id
            isResolved
            comments(first:1) {
              nodes { path body }
            }
          }
        }
      }
    }
  ' --jq '[.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved == false) | {id: .id, path: .comments.nodes[0].path, body: (.comments.nodes[0].body[:80])}]' 2>/dev/null || echo "[]")

  echo "[PR レビュースレッド] PR #${PR_NUMBER} に未 resolve のレビュースレッドが ${UNRESOLVED} 件あります。対応済みのスレッドは gh api graphql の resolveReviewThread mutation で resolve してください。" >&2
  echo "未 resolve スレッド: ${THREAD_IDS}" >&2
fi

exit 0
