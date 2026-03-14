#!/bin/bash
# destructive-guard: PreToolUse (Bash) - 破壊的操作の二重確認
#
# 復元困難な破壊的コマンドを検出して警告またはブロックする。
# ブロック対象:
#   - rm -rf（ルートや重要ディレクトリ）
#   - git reset --hard, git clean -f
#   - docker system prune, docker volume rm
#   - DROP TABLE / DROP DATABASE
#
# 警告のみ（advisory）:
#   - rm -rf（一般的なディレクトリ）
#   - kubectl delete

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

# 引用符・heredoc 内のテキストを除外してからマッチ
SAFE_CMD=$(guard_sanitize_command "$COMMAND")

# --- rm -rf /（ルート・ホーム・重要ディレクトリ）: ブロック ---
if echo "$SAFE_CMD" | grep -qE 'rm\s+(-[a-zA-Z]*r[a-zA-Z]*f|(-[a-zA-Z]*f[a-zA-Z]*r))\s+(/|~|\$HOME|/etc|/var|/usr)\b'; then
  guard_respond "critical" "破壊的操作ガード" "ルートやシステムディレクトリに対する rm -rf はブロックされています。"
fi

# --- rm -rf（一般）: 警告 ---
if echo "$SAFE_CMD" | grep -qE 'rm\s+(-[a-zA-Z]*r[a-zA-Z]*f|(-[a-zA-Z]*f[a-zA-Z]*r))'; then
  guard_respond "advisory" "破壊的操作ガード" "rm -rf を実行しようとしています。対象ディレクトリが正しいか確認してください。"
fi

# --- git reset --hard: 警告 ---
if echo "$SAFE_CMD" | grep -qE 'git\s+reset\s+--hard'; then
  guard_respond "advisory" "破壊的操作ガード" "git reset --hard はコミットされていない変更を全て失います。git stash を検討してください。"
fi

# --- git clean -f: 警告 ---
if echo "$SAFE_CMD" | grep -qE 'git\s+clean\s+-[a-zA-Z]*f'; then
  guard_respond "advisory" "破壊的操作ガード" "git clean -f は未追跡ファイルを削除します。git clean -n で対象を確認してください。"
fi

# --- DROP TABLE / DROP DATABASE: ブロック ---
if echo "$COMMAND" | grep -qiE 'DROP\s+(TABLE|DATABASE|SCHEMA)'; then
  guard_respond "critical" "破壊的操作ガード" "DROP TABLE/DATABASE はブロックされています。本当に必要な場合はユーザーに確認してください。"
fi

# --- docker system prune / docker volume rm: 警告 ---
if echo "$SAFE_CMD" | grep -qE 'docker\s+(system\s+prune|volume\s+rm)'; then
  guard_respond "advisory" "破壊的操作ガード" "Docker の破壊的操作を検出しました。対象が正しいか確認してください。"
fi

# --- kubectl delete: 警告 ---
if echo "$SAFE_CMD" | grep -qE 'kubectl\s+delete'; then
  guard_respond "advisory" "破壊的操作ガード" "kubectl delete を実行しようとしています。対象リソースが正しいか確認してください。"
fi

exit 0
