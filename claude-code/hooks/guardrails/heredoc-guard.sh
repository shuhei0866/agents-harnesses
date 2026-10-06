#!/bin/bash
# heredoc-guard: PreToolUse (Bash) - heredoc 構文を警告（GUARD_LEVEL=deny 等でブロック）
#
# ユーザーがコピペする際に heredoc が正しく動作しないケースがあるため、
# echo '...' | sudo tee や printf を使うよう促す。
# 判定は advisory であり、既定の GUARD_LEVEL=warn では警告のみで実行を止めない。
# GUARD_LEVEL=deny または GUARD_FORCE_DENY=heredoc-guard のときだけブロックする。
# 文言はこの判定に合わせて「ブロックしました」/「警告のみで、実行は止めていません」を
# 書き分ける。

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

# heredoc パターン検出: <<EOF, <<'EOF', <<"EOF", << 'CONF', <<-EOF など
if echo "$COMMAND" | grep -qE '<<-?\s*'\''?\"?[A-Za-z_]+'\''?\"?\s*$'; then
  if guard_respond_denies "advisory"; then
    HEREDOC_MSG="heredoc (<<EOF) 構文はコピペ時に問題が発生するためブロックしました。"
  else
    HEREDOC_MSG="heredoc (<<EOF) 構文を検出しました（コピペ時に問題が発生します）。警告のみで、実行は止めていません。"
  fi
  guard_respond "advisory" "heredoc ガード" "${HEREDOC_MSG}代わりに echo '...' | sudo tee /path/to/file または printf を使用してください。"
fi

exit 0
