#!/bin/bash
# secret-guard: PreToolUse (Bash) - シークレット値の平文表示を防止
#
# Claude Code がシークレット値をターミナル出力に露出させるコマンドをブロックする。
# ブロック対象:
#   - secret-tool search (シークレット値を含む全属性をダンプ)
#   - secret-tool lookup (シークレット値のみ出力 — 検証はパイプで wc -c 等を使う)
#   - echo/printf/printenv で API キー系環境変数を展開して表示
#
# 安全な代替:
#   secret-tool lookup service koe key xxx | wc -c  → 長さ確認のみ
#   [ -n "$(secret-tool lookup ...)" ] && echo "set" → 存在確認

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

# --- secret-tool search: 常にブロック (シークレット値が出力に含まれる) ---
if echo "$SAFE_CMD" | grep -qE 'secret-tool\s+search'; then
  guard_respond "critical" "シークレット保護ガード" "secret-tool search はシークレット値を平文で表示するためブロックされています。属性の確認には secret-tool lookup ... | wc -c を使ってください。"
fi

# --- secret-tool lookup: 単体実行をブロック (パイプ/リダイレクト/変数代入なし) ---
if echo "$SAFE_CMD" | grep -qE 'secret-tool\s+lookup'; then
  # パイプ、リダイレクト、$() による代入がなければブロック
  if ! echo "$SAFE_CMD" | grep -qE 'secret-tool\s+lookup\s.*(\||>|2>|\$\()'; then
    # コマンド全体で見てもパイプ等がなければブロック
    if ! echo "$SAFE_CMD" | grep -qE '\|\s|>\s|2>\s'; then
      guard_respond "critical" "シークレット保護ガード" "secret-tool lookup の単体実行はシークレット値が平文表示されるためブロックされています。代わりに secret-tool lookup ... | wc -c （長さ確認）を使ってください。"
    fi
  fi
fi

# --- echo/printf で API キー系変数を展開表示 ---
if echo "$SAFE_CMD" | grep -qiE '(echo|printf)\s.*\$\{?(ANTHROPIC_API_KEY|OPENAI_API_KEY|API_KEY|SECRET|TOKEN|AWS_SECRET_ACCESS_KEY|GITHUB_TOKEN|DATABASE_URL|PRIVATE_KEY|PASSWORD)\}?'; then
  guard_respond "critical" "シークレット保護ガード" "API キー系環境変数の echo/printf 表示はブロックされています。設定確認には printenv VAR_NAME | wc -c を使ってください。"
fi

# --- printenv で直接キー表示 ---
if echo "$SAFE_CMD" | grep -qiE 'printenv\s+(ANTHROPIC_API_KEY|OPENAI_API_KEY|API_KEY)'; then
  # パイプがあれば OK (wc -c 等)
  if ! echo "$SAFE_CMD" | grep -qE '\|'; then
    guard_respond "critical" "シークレット保護ガード" "printenv でのキー直接表示はブロックされています。printenv VAR_NAME | wc -c を使ってください。"
  fi
fi

exit 0
