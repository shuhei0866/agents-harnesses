#!/bin/bash
# branch-divergence-guard: PreToolUse (Bash) - ブランチ分岐時の Temporal 操作警告 [advisory]
#
# feature ブランチ上で Temporal Workflow にタスクを投入しようとした場合に警告する。
# リモートデバイスの SSOT リポジトリは main を追従しているため、
# feature ブランチの未マージ変更は反映されない。
#
# 検出対象:
#   - temporal workflow signal
#   - temporal workflow start
#   - ssh でリモート経由の temporal コマンド
#
# これは best-effort の補助警告。本命のガードは Temporal Workflow 内の
# check_branch_divergence Activity で決定論的に実行される。

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

# Temporal 操作コマンドかチェック
SAFE_CMD=$(guard_sanitize_command "$COMMAND")
if ! echo "$SAFE_CMD" | grep -qE 'temporal\s+workflow\s+(signal|start)'; then
  exit 0
fi

# 現在のブランチを取得
BRANCH=$(git branch --show-current 2>/dev/null || echo "")
if [ -z "$BRANCH" ]; then
  exit 0
fi

# main/master なら OK
if [ "$BRANCH" = "main" ] || [ "$BRANCH" = "master" ]; then
  exit 0
fi

# feature ブランチ上で Temporal 操作 → 警告
guard_respond "advisory" "ブランチ分岐ガード" \
  "現在 '${BRANCH}' ブランチ上で Temporal タスクを投入しようとしています。リモートデバイスの skynet-hub は main を追従しているため、未マージの変更は反映されません。main にマージしてから実行するか、意図的であれば続行してください。"
