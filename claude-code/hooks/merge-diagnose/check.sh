#!/bin/bash
# merge-diagnose: PostToolUse (Bash) - gh pr merge 失敗時に原因を診断 [L3]
#
# `gh pr merge` が失敗した場合、未解決のレビュースレッドを自動検出し、
# その内容をコンテキストに注入する。
# これにより「マージできない → 原因不明 → 手動調査」のループを防ぐ。

set -uo pipefail

INPUT=$(cat)

if ! command -v jq &>/dev/null; then
  exit 0
fi

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')

if [ "$TOOL_NAME" != "Bash" ]; then
  exit 0
fi

COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# gh pr merge コマンドのみ対象
if ! echo "$COMMAND" | grep -qE 'gh\s+pr\s+merge'; then
  exit 0
fi

# コマンドが成功した場合はスキップ（失敗時のみ診断）
EXIT_CODE=$(echo "$INPUT" | jq -r '.tool_output.exit_code // "0"')
if [ "$EXIT_CODE" = "0" ]; then
  exit 0
fi

STDERR=$(echo "$INPUT" | jq -r '.tool_output.stderr // empty')

# "policy prohibits the merge" または "not mergeable" を含む場合のみ診断
if ! echo "$STDERR" | grep -qiE 'policy prohibits|not mergeable'; then
  exit 0
fi

# PR 番号を抽出（gh pr merge 以降の引数から数値を探す、なければ gh pr view で取得）
# "gh pr merge" 以降の部分を抽出してから数値を探す
MERGE_ARGS=$(echo "$COMMAND" | sed -n 's/.*gh[[:space:]]\+pr[[:space:]]\+merge[[:space:]]*//p')
PR_NUMBER=$(echo "$MERGE_ARGS" | grep -oE '\b[0-9]+\b' | head -1)
if [ -z "$PR_NUMBER" ]; then
  # 番号なしの場合（カレントブランチの PR を対象）
  PR_NUMBER=$(gh pr view --json number --jq '.number' 2>/dev/null)
fi
if [ -z "$PR_NUMBER" ]; then
  exit 0
fi

# gh CLI が利用可能か確認
if ! command -v gh &>/dev/null; then
  exit 0
fi

# 未解決のレビュースレッドを GraphQL で取得
REPO_OWNER=$(gh repo view --json owner -q .owner.login 2>/dev/null)
REPO_NAME=$(gh repo view --json name -q .name 2>/dev/null)

if [ -z "$REPO_OWNER" ] || [ -z "$REPO_NAME" ]; then
  exit 0
fi

THREADS=$(gh api graphql \
  -F owner="$REPO_OWNER" \
  -F name="$REPO_NAME" \
  -F prNum="$PR_NUMBER" \
  -f query='query {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $prNum) {
      reviewDecision
      mergeStateStatus
      reviewThreads(first: 20) {
        nodes {
          id
          isResolved
          comments(first: 2) {
            nodes {
              body
              author { login }
              path
            }
          }
        }
      }
    }
  }
}' 2>/dev/null)

if [ -z "$THREADS" ]; then
  exit 0
fi

REVIEW_DECISION=$(echo "$THREADS" | jq -r '.data.repository.pullRequest.reviewDecision // "unknown"')
MERGE_STATE=$(echo "$THREADS" | jq -r '.data.repository.pullRequest.mergeStateStatus // "unknown"')

# 未解決スレッドを抽出
UNRESOLVED=$(echo "$THREADS" | jq -r '
  [.data.repository.pullRequest.reviewThreads.nodes[]
   | select(.isResolved == false)
   | {
       id: .id,
       file: (.comments.nodes[0].path // "general"),
       author: (.comments.nodes[0].author.login // "unknown"),
       summary: (.comments.nodes[0].body | split("\n")[0] | .[0:120])
     }
  ]')

UNRESOLVED_COUNT=$(echo "$UNRESOLVED" | jq 'length')

# 診断メッセージを構築
DIAG="[マージ失敗診断] PR #${PR_NUMBER} のマージがブロックされています。\n\n"
DIAG="${DIAG}**状態**: reviewDecision=${REVIEW_DECISION}, mergeState=${MERGE_STATE}\n\n"

if [ "$UNRESOLVED_COUNT" -gt 0 ]; then
  DIAG="${DIAG}**未解決のレビュースレッド (${UNRESOLVED_COUNT}件)**:\n"
  # 各スレッドの要約を追加
  while IFS= read -r thread; do
    FILE=$(echo "$thread" | jq -r '.file')
    AUTHOR=$(echo "$thread" | jq -r '.author')
    SUMMARY=$(echo "$thread" | jq -r '.summary')
    THREAD_ID=$(echo "$thread" | jq -r '.id')
    DIAG="${DIAG}- \`${FILE}\` (${AUTHOR}): ${SUMMARY}\n  Thread ID: ${THREAD_ID}\n"
  done < <(echo "$UNRESOLVED" | jq -c '.[]')
  DIAG="${DIAG}\n**対応方法**: 指摘内容を確認し、修正が必要なら修正してコミット。対応不要なら GraphQL mutation \`resolveReviewThread\` でスレッドを resolve してください。"
else
  DIAG="${DIAG}未解決スレッドはありません。reviewDecision (${REVIEW_DECISION}) または CI ステータスが原因の可能性があります。\n"
  DIAG="${DIAG}\n**確認事項**:\n- \`gh pr checks ${PR_NUMBER}\` で CI ステータスを確認\n- 新しい push 後に re-approve が必要か確認"
fi

# JSON エスケープ
ESCAPED_DIAG=$(printf '%s' "$DIAG" | jq -Rs '.')

cat << EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PostToolUse",
    "additionalContext": $ESCAPED_DIAG
  }
}
EOF
