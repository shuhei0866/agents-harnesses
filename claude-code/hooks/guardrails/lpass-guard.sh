#!/bin/bash
# lpass-guard: PreToolUse (Bash) - エージェントによる LastPass CLI の直接実行をブロック
#
# lpass のエージェントがロック解除されているあいだは、同じユーザーで動くプロセスなら
# 保管庫のどの項目でも読める。エージェントがパスワードの項目を表示すると、値が会話ログに
# 平文で残る。読める範囲を専用の窓口 claude-code/scripts/claude-profile（保管庫の Claude/
# フォルダだけを読み書きする）に絞るため、lpass の直接実行を止める。
#
# ブロック対象:
#   - lpass を実行するコマンド行（lpass status / lpass --version だけは許す）
#   - $( ) やバッククォート、bash -c / sh -c / zsh -c / eval の中の lpass
#   - lpass を含む python / node / ruby / perl / osascript の実行（heredoc で渡すコードを含む）
#
# 許可:
#   - claude-profile 経由の読み書き（このフックからは内部の lpass 呼び出しが見えない）
#   - 引用符の中や、cat 等に流す heredoc 本文に lpass という語が出てくるだけのもの
#   - ~/.lpass のようにパスの一部として出てくるもの

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

# 速い経路: lpass という文字列を含まないコマンドは素通しする
case "$COMMAND" in
  *lpass*) ;;
  *) exit 0 ;;
esac

MSG="lpass の直接実行はブロックされています。保管庫の Claude/ フォルダの読み書きは ~/agents-harnesses/claude-code/scripts/claude-profile を使ってください（例: claude-profile get 電話番号）。パスワードやカード番号の項目は、ユーザーがブラウザの自動入力やログイン操作で扱います。"

# lpass を 1 語として含むか（claude-profile や ~/.lpass、lastpass-cli の一部としては数えない）
WORD='(^|[^[:alnum:]_.-])lpass([^[:alnum:]_-]|$)'

# 1) 引用符の中でも実行される経路: 置換・別シェル・eval・インタプリタ
SUBST_RE='\$\(([^)]*[^[:alnum:]_.-])?lpass([^[:alnum:]_-]|$)'
BACKTICK_RE='`([^`]*[^[:alnum:]_.-])?lpass([^[:alnum:]_-]|$)'
SUBSHELL_RE='(^|[;&|[:space:](])((ba|z)?sh[[:space:]]+-[[:alnum:]]*c|eval)[[:space:]]'
if printf '%s' "$COMMAND" | grep -qE "$SUBST_RE" \
   || printf '%s' "$COMMAND" | grep -qE "$BACKTICK_RE"; then
  guard_respond "critical" "LastPass ガード" "$MSG"
fi
if printf '%s' "$COMMAND" | grep -qE "$SUBSHELL_RE" \
   && printf '%s' "$COMMAND" | grep -qE "$WORD"; then
  guard_respond "critical" "LastPass ガード" "$MSG"
fi
if printf '%s' "$COMMAND" | grep -qE '(^|[;&|[:space:](])(python3?|node|ruby|perl|osascript)([[:space:]]|$)' \
   && printf '%s' "$COMMAND" | grep -qE "$WORD"; then
  guard_respond "critical" "LastPass ガード" "$MSG"
fi

# 2) 実行されるコマンド行: heredoc 本文と引用符の中身を除いてから判定する
EXEC_LINES=$(guard_strip_heredoc_bodies "$COMMAND")
SAFE_CMD=$(guard_sanitize_command "$EXEC_LINES")

if printf '%s' "$SAFE_CMD" | grep -qE '(^|[^[:alnum:]_.-])(/[^[:space:]]*/)?lpass([^[:alnum:]_-]|$)'; then
  # 状態確認とバージョン表示だけは許す（保管庫の中身に触れない）
  while IFS= read -r seg; do
    [ -z "$seg" ] && continue
    sub=$(printf '%s' "$seg" | sed -E 's#^[^[:alnum:]/]*(/[^[:space:]]*/)?lpass[[:space:]]*##' | awk '{print $1}')
    case "$sub" in
      status|--version|-v) ;;
      *) guard_respond "critical" "LastPass ガード" "$MSG" ;;
    esac
  done < <(printf '%s' "$SAFE_CMD" | grep -oE '(^|[^[:alnum:]_.-])(/[^[:space:]]*/)?lpass([[:space:]]+[^;&|]*)?')
fi

exit 0
