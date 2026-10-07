#!/bin/bash
# worktree-guard: PreToolUse (Write|Edit) - メインワークツリーでのファイル編集を警告（GUARD_LEVEL=deny 等でブロック） [L5]
#
# メインワークツリー（リポジトリルート）でのファイル編集を検出する。
# 判定は advisory であり、既定の GUARD_LEVEL=warn では警告のみで編集を止めない。
# GUARD_LEVEL=deny または GUARD_FORCE_DENY=worktree-guard のときだけブロックする。
# 文言はこの判定に合わせて「ブロックしました」/「警告のみで、実行は止めていません」を
# 書き分ける。
# ワークツリー内、または除外パス（.claude/, CLAUDE.md 等）への書き込みは対象外。
#
# project_root はファイルパス起点で特定する。Claude Code は cwd と異なるリポジトリの
# ファイルを操作することがあり (例: cwd=my-skynet-hub で projects/student-portal/ 配下
# を Edit する)、cwd 起点だと別リポジトリの harness.config が読まれて当該リポジトリの
# GUARD_FORCE_DENY 等が無視されてしまうため。

set -uo pipefail

# _normalize_path PATH
#   シンボリックリンクと . / .. を解決した絶対パスを出力する（存在しない要素があってもよい）。
#   GNU の `realpath -m` 相当だが、macOS の BSD コマンドと /bin/bash 3.2 でも同じ結果になるよう、
#   存在する最も近い祖先ディレクトリを `pwd -P` で解決し、残りの要素を 1 つずつつなぐ。
#   途中の要素がシンボリックリンクなら readlink（オプションなし）で辿り直す。
#   cd は -P で物理的に移動する（論理的な .. の処理だと、リンクの親に戻ってしまう）。
#   git rev-parse --show-toplevel はシンボリックリンクを解決したパスを返すので、比較する
#   パスはすべてこの関数で同じ表記にそろえる。解決できなければ 1 を返す。
_normalize_path() {
  local path="$1" base="" rest="" comp="" result="" target="" hops=0
  [ -n "$path" ] || return 1
  case "$path" in
    /*) ;;
    *) path="$PWD/$path" ;;
  esac
  while :; do
    # 存在する最も近い祖先ディレクトリと、その下の残りの要素に分ける
    base="$path"
    rest=""
    while [ ! -d "$base" ]; do
      rest="$(basename "$base")${rest:+/$rest}"
      base=$(dirname "$base")
    done
    result=$(CDPATH= cd -P -- "$base" 2>/dev/null && pwd -P) || return 1
    # 残りの要素を 1 つずつつなぐ
    while [ -n "$rest" ]; do
      case "$rest" in
        */*) comp="${rest%%/*}"; rest="${rest#*/}" ;;
        *)   comp="$rest"; rest="" ;;
      esac
      case "$comp" in
        ''|.) continue ;;
        ..) result=$(dirname "$result"); continue ;;
      esac
      if [ "$result" = "/" ]; then
        result="/$comp"
      else
        result="$result/$comp"
      fi
      # 循環したリンクは辿り続けず、40 回で打ち切ってそのままの表記を使う（realpath -m と同じ）
      if [ -L "$result" ] && [ "$hops" -lt 40 ]; then
        hops=$((hops + 1))
        target=$(readlink "$result") || return 1
        case "$target" in
          /*) ;;
          *) target="$(dirname "$result")/$target" ;;
        esac
        path="$target${rest:+/$rest}"
        continue 2
      fi
    done
    printf '%s\n' "$result"
    return 0
  done
}

INPUT=$(cat)

if ! command -v jq &>/dev/null; then
  # jq がない場合はスキップ（安全側に倒す）
  exit 0
fi

# file_path を取得
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

# パストラバーサル防止: .. を含むパスを正規化
FILE_PATH=$(_normalize_path "$FILE_PATH" || echo "$FILE_PATH")

if [ -z "${FILE_PATH:-}" ]; then
  exit 0
fi

# ファイルが属するリポジトリのルートをファイルパス起点で特定
# (Write でまだ存在しない新規ファイルでも、親ディレクトリを辿って解決する)
FILE_DIR=$(dirname "$FILE_PATH")
while [ -n "$FILE_DIR" ] && [ "$FILE_DIR" != "/" ] && [ ! -d "$FILE_DIR" ]; do
  FILE_DIR=$(dirname "$FILE_DIR")
done

if [ ! -d "$FILE_DIR" ]; then
  exit 0
fi

PROJECT_ROOT=$(cd "$FILE_DIR" && git rev-parse --show-toplevel 2>/dev/null || echo "")
if [ -z "$PROJECT_ROOT" ]; then
  exit 0
fi

# パスを正規化
PROJECT_ROOT=$(_normalize_path "$PROJECT_ROOT" || echo "$PROJECT_ROOT")

# CLAUDE_PROJECT_DIR をファイル所属リポジトリで上書き
# (_guard-common.sh が harness.config を探索する際にこの値を使う)
export CLAUDE_PROJECT_DIR="$PROJECT_ROOT"

# 共通ライブラリを source（このタイミングで GUARD_LEVEL / GUARD_SKIP / GUARD_FORCE_DENY がロードされる）
GUARD_COMMON="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_guard-common.sh"
source "$GUARD_COMMON"

# trunk-direct はメインワークツリーでの Edit/Write を明示的に許可する。
# ただし GUARD_FORCE_DENY=worktree-guard は policy より優先して通常の deny 判定へ進む。
if guard_is_trunk_direct && ! _is_force_deny; then
  exit 0
fi

# 現在のディレクトリがワークツリーかどうかを判定
# git worktree 内では git rev-parse --git-dir が .git/worktrees/<name> を返す
# メインワークツリーでは git の common dir と toplevel が一致する
GIT_COMMON_DIR=$(cd "$PROJECT_ROOT" && git rev-parse --git-common-dir 2>/dev/null || echo "")
GIT_DIR=$(cd "$PROJECT_ROOT" && git rev-parse --git-dir 2>/dev/null || echo "")

# ワークツリー内にいる場合（.git がファイルで common dir と異なる）は許可
if [ "$GIT_DIR" != "$GIT_COMMON_DIR" ] && [ "$GIT_DIR" != ".git" ]; then
  exit 0
fi

# ファイルパスがワークツリー内かチェック（メインWT 配下のファイルでも、worktree 内なら許可）
while IFS= read -r line; do
  case "$line" in
    worktree\ *)
      WT_PATH="${line#worktree }"
      # ワークツリーパスも正規化してから比較（パストラバーサル対策）
      WT_PATH_NORMALIZED=$(_normalize_path "$WT_PATH" || echo "$WT_PATH")
      # メインワークツリーはスキップ（正規化後に比べる。表記がずれたまま素通りすると、
      # 下の判定でメインワークツリー配下のファイルをすべて許可してしまう）
      if [ "$WT_PATH_NORMALIZED" = "$PROJECT_ROOT" ]; then
        continue
      fi
      # ファイルがこのワークツリー内にある場合は許可
      case "$FILE_PATH" in
        "$WT_PATH_NORMALIZED"/*)
          exit 0
          ;;
      esac
      ;;
  esac
done < <(cd "$PROJECT_ROOT" && git worktree list --porcelain 2>/dev/null)

# ファイルパスがプロジェクトルート配下かチェック
case "$FILE_PATH" in
  "$PROJECT_ROOT"/*)
    # プロジェクト内のファイル - 除外パスをチェック
    ;;
  *)
    # プロジェクト外のファイル - 許可
    exit 0
    ;;
esac

# 除外パス: これらはメインワークツリーでの編集を許可
RELATIVE_PATH="${FILE_PATH#$PROJECT_ROOT/}"
case "$RELATIVE_PATH" in
  .claude/*)         exit 0 ;;  # Claude Code 設定・メモリ
  CLAUDE.md)         exit 0 ;;  # 自己改善プロトコル
  .gitignore)        exit 0 ;;  # gitignore の更新
  .github/*)         exit 0 ;;  # CI/CD 設定
esac

# メインワークツリーでの編集を検出（既定では警告のみ、deny 設定ではブロック）
if guard_respond_denies "advisory"; then
  WORKTREE_MSG="メインワークツリーでのファイル編集をブロックしました。"
else
  WORKTREE_MSG="メインワークツリーでのファイル編集を検出しました。警告のみで、実行は止めていません。"
fi
guard_respond "advisory" "ワークツリーガード" "${WORKTREE_MSG}\n\n対処法: ユーザーに報告し、\`git worktree add .worktrees/<name> <branch>\` でワークツリーを作成してそこで作業してください。\n\n編集しようとしたファイル: ${RELATIVE_PATH}"
