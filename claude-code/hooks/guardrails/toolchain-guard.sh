#!/bin/bash
# toolchain-guard: PreToolUse (Bash) - ツールチェイン利用時のガード
#
# - node/npm/npx: fnm（ユーザースペース）を使い、sudo npm は禁止
# - gh: 未認証ならブロック（認証済みなら素通り）

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

# sudo npm / sudo node の検出 → ブロック
if echo "$COMMAND" | grep -qE '\bsudo\s+(npm|node|npx)\b'; then
  guard_respond "critical" "toolchain ガード" "sudo npm/node/npx は禁止です。fnm（ユーザースペース）を使ってください: eval \"\$(fnm env)\" && npm install ..."
fi

# npm/node/npx の使用 → fnm 環境の確認リマインド
if echo "$COMMAND" | grep -qE '\b(npm|node|npx)\b'; then
  guard_respond "advisory" "toolchain リマインド" "Node.js は fnm で管理しています。fnm 環境が有効か確認してください（eval \"\$(fnm env)\"）。sudo は不要です。"
fi

# gh コマンドの使用 → 実際に認証チェックし、未認証ならブロック（gh auth status 自体は除外）
if echo "$COMMAND" | grep -qE '\bgh\s' && ! echo "$COMMAND" | grep -qE '\bgh\s+auth\s+status\b'; then
  if ! gh auth status &>/dev/null; then
    guard_respond "critical" "gh ガード" "gh CLI が未認証です。先に gh auth login を実行してください。"
  fi
fi

exit 0
