#!/bin/bash
# terraform-guard: PreToolUse (Bash) - terraform apply/destroy 前に plan 確認を強制
#
# ブロック対象:
#   - terraform apply（-auto-approve 付き、または plan 出力ファイル未指定）
#   - terraform destroy（常にブロック、ユーザー確認を促す）
#
# 安全な代替:
#   terraform plan -out=tfplan && terraform apply tfplan

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

# terraform コマンド以外はスキップ
case "$SAFE_CMD" in
  *terraform\ *)
    ;;
  *)
    exit 0
    ;;
esac

# --- terraform destroy: 常にブロック ---
if echo "$SAFE_CMD" | grep -qE 'terraform\s+destroy'; then
  guard_respond "critical" "Terraform ガード" "terraform destroy はブロックされています。本当に必要な場合はユーザーに確認してから手動で実行してください。"
fi

# --- terraform apply -auto-approve: ブロック ---
if echo "$SAFE_CMD" | grep -qE 'terraform\s+apply\s.*-auto-approve'; then
  guard_respond "critical" "Terraform ガード" "terraform apply -auto-approve はブロックされています。terraform plan -out=tfplan で確認してから terraform apply tfplan を実行してください。"
fi

# --- terraform apply（plan ファイル未指定）: 警告 ---
if echo "$SAFE_CMD" | grep -qE 'terraform\s+apply'; then
  # plan ファイルが指定されているかチェック（.tfplan や tfplan 等のファイル引数）
  # terraform apply tfplan / terraform apply plan.out のパターン
  if ! echo "$SAFE_CMD" | grep -qE 'terraform\s+apply\s+\S+\.(tfplan|out)\b|terraform\s+apply\s+tfplan\b'; then
    guard_respond "advisory" "Terraform ガード" "terraform apply を plan ファイルなしで実行しようとしています。terraform plan -out=tfplan で変更内容を確認してから terraform apply tfplan を実行することを推奨します。"
  fi
fi

exit 0
