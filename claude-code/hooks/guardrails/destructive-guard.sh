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
# （heredoc は複数行の本文ごと落とす。マーカー除去だけでは本文中の rm -rf 等に誤反応する）
STRIPPED_CMD=$(guard_strip_heredoc_bodies "$COMMAND")
SAFE_CMD=$(guard_sanitize_command "$STRIPPED_CMD")

# critical rm 判定では、quote 全体がシステム絶対パスの場合だけ marker で保護する。
# その後に残りの引用文字列を sanitize し、外側の quote に包まれた説明文では marker
# ごと除去する。これにより rm -rf "/etc" は検出しつつ、echo 'rm -rf "/etc"' や
# rm -rf '\"/etc\"' のように quote 自体がパス名の一部である場合は除外できる。
# "$HOME" は展開されるため保護するが、"~" と '$HOME' は展開されないため保護しない。
MARKER_NONCE="$$"
MARKER_NONCE="${MARKER_NONCE}_${RANDOM}_${#STRIPPED_CMD}"
CRITICAL_BEGIN_MARKER="__AH_GUARD_CRITICAL_BEGIN_${MARKER_NONCE}__"
CRITICAL_END_MARKER="__AH_GUARD_CRITICAL_END_${MARKER_NONCE}__"
while [[ "$STRIPPED_CMD" == *"$CRITICAL_BEGIN_MARKER"* || "$STRIPPED_CMD" == *"$CRITICAL_END_MARKER"* ]]; do
  MARKER_NONCE="${MARKER_NONCE}_X"
  CRITICAL_BEGIN_MARKER="__AH_GUARD_CRITICAL_BEGIN_${MARKER_NONCE}__"
  CRITICAL_END_MARKER="__AH_GUARD_CRITICAL_END_${MARKER_NONCE}__"
done

PROTECTED_CMD=$(printf '%s\n' "$STRIPPED_CMD" | sed -E \
  -e "s#\"(/(etc|var|usr)(/[^\"]*)?|/)\"#${CRITICAL_BEGIN_MARKER}\\1${CRITICAL_END_MARKER}#g" \
  -e "s#'(/(etc|var|usr)(/[^']*)?|/)'#${CRITICAL_BEGIN_MARKER}\\1${CRITICAL_END_MARKER}#g" \
  -e 's#"\$HOME/?"#'"${CRITICAL_BEGIN_MARKER}"'$HOME'"${CRITICAL_END_MARKER}"'#g' \
  -e "s#/\"(etc|var|usr)\"#/${CRITICAL_BEGIN_MARKER}\\1${CRITICAL_END_MARKER}#g" \
  -e "s#/'(etc|var|usr)'#/${CRITICAL_BEGIN_MARKER}\\1${CRITICAL_END_MARKER}#g")
CRITICAL_CMD=$(guard_sanitize_command "$PROTECTED_CMD")
CRITICAL_CMD="${CRITICAL_CMD//${CRITICAL_BEGIN_MARKER}/}"
CRITICAL_CMD="${CRITICAL_CMD//${CRITICAL_END_MARKER}/}"

# --- rm -rf /（ルート・ホーム・重要ディレクトリ）: ブロック ---
# 注: \b は / や ~ の直後では一致しない（非単語文字同士に語境界が立たない）ため、
# 「対象の直後が空白か行末」で判定する。/etc /var /usr は配下のパスも含める
CRITICAL_RM_RE='rm\s+(-[a-zA-Z]*r[a-zA-Z]*f|(-[a-zA-Z]*f[a-zA-Z]*r))\s+(/(etc|var|usr)(/[^[:space:]]*)?|/|~/?|\$HOME/?)(\s|$)'
CRITICAL_RM=0

# unquoted target は既存挙動を維持する。selective unquote した target は、echo 等の
# 引数中の rm を deny に昇格させないよう、実際のコマンド先頭にある rm だけを拾う。
if echo "$SAFE_CMD" | grep -qE "$CRITICAL_RM_RE"; then
  CRITICAL_RM=1
else
  RM_ASSIGNMENT='([A-Za-z_][A-Za-z_0-9]*=[^[:space:]]*[[:space:]]+)*'
  RM_CONTROL='((if|then|elif|else|while|until|do)[[:space:]]+)?'
  RM_ENV="env[[:space:]]+${RM_ASSIGNMENT}"
  RM_SUDO='sudo([[:space:]]+((-[ug]|--(user|group))[[:space:]]+[^[:space:]]+|--(user|group)=[^[:space:]]+|-[ug][^[:space:]]+|-[nEHSbPk]+|--(non-interactive|preserve-env|set-home|stdin|background|preserve-groups)|--))*[[:space:]]+'
  RM_COMMAND='command([[:space:]]+(-p|--))*[[:space:]]+'
  RM_WRAPPERS="(((${RM_ENV})|(${RM_SUDO})|(${RM_COMMAND}))${RM_ASSIGNMENT})*"
  RM_COMMAND_PREFIX="${RM_CONTROL}${RM_ASSIGNMENT}${RM_WRAPPERS}${RM_ASSIGNMENT}([^[:space:]]*/)?"
  while IFS= read -r segment; do
    if echo "$segment" | grep -qE "^[[:space:]]*${RM_COMMAND_PREFIX}${CRITICAL_RM_RE}"; then
      CRITICAL_RM=1
      break
    fi
  done <<< "$(guard_split_segments "$CRITICAL_CMD")"
fi

if [ "$CRITICAL_RM" -eq 1 ]; then
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
