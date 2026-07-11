#!/bin/bash
# worktree-rm-guard: PreToolUse (Bash) - .worktrees/ 配下への再帰削除をブロック
#
# 並走セッションの worktree を rm -rf で消すと、未コミット変更ごと失われる。
# worktree の所有権・dirty 状態は別セッション側にあってコンテキストに入らないため、
# 削除手段そのものを git worktree remove に限定する。git worktree remove は dirty な
# worktree を git 自身が拒否するので、未コミット変更の保護がモデルの注意に依存しない。
#
# 挙動:
#   - コマンド先頭位置の再帰 rm（-r/-R/--recursive。環境変数代入・sudo・command 前置、
#     find -exec 経由を含む）で、対象に .worktrees を含む → deny（critical）
#   - cd で .worktrees 配下に入った後の再帰 rm も deny（相対パス削除の抜け道防止）
#   - 同一パイプライン内に .worktrees を含む xargs 経由の再帰 rm → deny
#   - find <path> -delete で .worktrees を含む → deny（critical）
#   - echo の引数・引用符内・データ用 heredoc 本文に書かれただけの rm -rf → 許可
#   - 正規の削除手段: git worktree remove <path>（--force はユーザー確認後のみ）
#   - opt-out: リポジトリの .claude/harness.config に GUARD_SKIP="worktree-rm-guard"
#     を追記する（コマンドに VAR=... を前置しても hook の環境には届かない）
#
# 制約: 判定は「.worktrees」というパス規約の文字列に依る。規約外の場所に作った
# worktree を絶対パスで消す操作までは検出しない。

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

# .worktrees を含まないコマンドは即許可（早期 return で通常コマンドを重くしない）
case "$COMMAND" in
  *.worktrees*) ;;
  *) exit 0 ;;
esac

# データ用 heredoc 本文（issue 本文等）を落とす。bash <<EOF など実行される本文は残る
STRIPPED=$(guard_strip_heredoc_bodies "$COMMAND")

# 環境変数代入・sudo・command の前置を許すコマンド先頭
PFX='([A-Za-z_][A-Za-z_0-9]*=[^[:space:]]*[[:space:]]+)*(sudo[[:space:]]+)?(command[[:space:]]+)?'

RECURSIVE_FLAG='(^|[[:space:]])-[A-Za-z]*[rR][A-Za-z]*([[:space:]]|$)|(^|[[:space:]])--recursive([[:space:]]|$)'

DENY_MSG=".worktrees/ 配下への再帰削除はブロックされています。並走セッションの worktree を消すと未コミット変更ごと失われます。\n\n対処法: git worktree remove <path> を使ってください（dirty な worktree は git 自身が拒否します。--force はユーザーに確認してから）。\n\nworktree 以外の生成物などでどうしても rm が必要な場合は、ユーザーに確認した上で .claude/harness.config の GUARD_SKIP に worktree-rm-guard を追加して再実行してください。"

# --- コマンド先頭位置の rm / find を検査（| でも分割した細かい単位）---
CDWT=0
while IFS= read -r seg; do
  # cd で .worktrees 配下へ入るセグメントを記録（以降の相対パス削除を捕まえる）
  if echo "$seg" | grep -qE "^[[:space:]]*${PFX}cd[[:space:]]" && echo "$seg" | grep -q '\.worktrees'; then
    CDWT=1
  fi

  seg_has_wt=0
  if echo "$seg" | grep -q '\.worktrees'; then
    seg_has_wt=1
  fi
  if [ "$seg_has_wt" = "0" ] && [ "$CDWT" = "0" ]; then
    continue
  fi

  is_rm=0
  if echo "$seg" | grep -qE "^[[:space:]]*${PFX}rm([[:space:]]|$)"; then
    is_rm=1
  elif echo "$seg" | grep -qE -- '-exec(dir)?[[:space:]]+rm([[:space:]]|$)'; then
    is_rm=1
  fi

  if [ "$is_rm" = "1" ] && echo "$seg" | grep -qE "$RECURSIVE_FLAG"; then
    guard_respond "critical" "worktree-rm ガード" "$DENY_MSG"
  fi

  # find ... -delete も再帰削除になる
  if echo "$seg" | grep -qE "^[[:space:]]*${PFX}find([[:space:]]|$)" \
     && echo "$seg" | grep -qE '(^|[[:space:]])-delete([[:space:]]|$)'; then
    guard_respond "critical" "worktree-rm ガード" "$DENY_MSG"
  fi
done <<< "$(guard_split_segments "$STRIPPED")"

# --- xargs 経由の再帰 rm を検査（パイプ隣接を保った単位で判定）---
# 削除対象は stdin 越しに渡るため、同一パイプライン内の .worktrees を根拠にする。
# 別セグメント（&& や ; の先）の .worktrees は根拠にしない（無関係な cleanup の誤 deny 防止）
while IFS= read -r pseg; do
  if echo "$pseg" | grep -qE "(^|[[:space:]])xargs([[:space:]]|$)" \
     && echo "$pseg" | grep -qE '[[:space:]]rm[[:space:]]+(-[A-Za-z]*[rR]|--recursive)' \
     && { echo "$pseg" | grep -q '\.worktrees' || [ "$CDWT" = "1" ]; }; then
    guard_respond "critical" "worktree-rm ガード" "$DENY_MSG"
  fi
done <<< "$(guard_split_segments "$STRIPPED" pipeline)"

exit 0
