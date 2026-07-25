#!/bin/bash
# guard_prime_command_cache の契約テスト。
#
# 固定する性質はひとつ: memo 化した 3 関数は、prime してもしなくても同じ結果を返す。
# ここが崩れると、ガードは「速いが判定が違う」状態になり、しかも出力が変わらないので
# 気づけない。
#
# あわせてキャッシュミスの経路も固定する。prime した命令と別の引数を渡したときは
# 従来の計算経路へ落ちて正しい結果を返す必要がある。ここが壊れると、直前のコマンドの
# 解析結果を別のコマンドに適用してしまう。
#
# テスト自体が空振りしないための設計:
#   - 比較は子シェルの中で行い、結果を 1 表明 1 行で出す。親が空文字同士を比べて
#     素通りする余地を作らない
#   - source の失敗と関数の未定義を明示的に検出して異常終了する
#   - 親は「表明が何行返るはずか」を知っていて、行数が合わなければ失敗させる。
#     子が途中で死んで 0 行になった場合も緑にならない

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON="$SCRIPT_DIR/../_guard-common.sh"

PASS=0
FAIL=0

# 1 ケースあたりの表明数。prime 一致 4 つ + キャッシュミス 4 つ。
ASSERTIONS_PER_CASE=8

# 代表入力。heredoc・引用符・コマンド置換・複数セグメント・パイプライン・
# 継続行・チルダ・空文字・非 ASCII を含める。
CASES=(
  "echo hi"
  ""
  "   "
  "git commit -m \"fix: something\""
  "git push --force origin main"
  "cd /tmp && git commit -m a || echo fail"
  "git log --oneline | head -5"
  "gh pr merge 12 --squash; gh pr review --approve 5"
  "echo 'git push --force origin main'"
  "FOO=bar git push origin main"
  "rm -rf ~/tmp/x"
  "git -C ~/repo push --force"
  "echo \$(git rev-parse HEAD)"
  "gh issue create --body \"\$(cat <<EOF
rm -rf /
git push --force
EOF
)\""
  "bash <<EOF
git push --force origin main
EOF"
  "cat <<-EOF
	indented body
	EOF"
  "echo a <<< 'here string'"
  "echo \$((1 << 3))"
  "git commit -m 'こんにちは' && echo 完了"
  "echo one \\
&& echo two"
  "printf '%s' \"nested \\\"quotes\\\" here\""
)

# 子シェル本体。全比較をここで行い、1 表明 1 行で出す。
CHILD='
set -uo pipefail

if ! source "$1" >/dev/null 2>&1; then
  echo "ABORT source-failed" >&2
  exit 90
fi

for fn in guard_strip_heredoc_bodies guard_split_segments guard_sanitize_command \
          guard_prime_command_cache; do
  if ! declare -f "$fn" >/dev/null 2>&1; then
    echo "ABORT missing-function:$fn" >&2
    exit 91
  fi
done

cmd="$2"

emit() {  # emit <label> <expected> <actual>
  if [ "$2" = "$3" ]; then
    printf "OK %s\n" "$1"
  else
    printf "NG %s\n  期待: %s\n  実際: %s\n" "$1" "$2" "$3"
  fi
}

# --- prime しない状態（従来の計算経路）を先に取る ---
_GUARD_MEMO_PRIMED=""
raw_stripped=$(guard_strip_heredoc_bodies "$cmd")
raw_full=$(guard_split_segments "$raw_stripped" full)
raw_pipeline=$(guard_split_segments "$raw_stripped" pipeline)
raw_sanitized=$(guard_sanitize_command "$raw_stripped")

# --- prime した状態（キャッシュ経路）と突き合わせる ---
guard_prime_command_cache "$cmd"
emit "strip_heredoc_bodies"      "$raw_stripped"  "$(guard_strip_heredoc_bodies "$cmd")"
emit "split_segments(full)"      "$raw_full"      "$(guard_split_segments "$raw_stripped" full)"
emit "split_segments(pipeline)"  "$raw_pipeline"  "$(guard_split_segments "$raw_stripped" pipeline)"
emit "sanitize_command"          "$raw_sanitized" "$(guard_sanitize_command "$raw_stripped")"

# --- キャッシュミス: prime した命令と別の引数を、memo 対象の全関数に対して確認する ---
other="git push --force origin other-branch && rm -rf ~/tmp"
miss_strip=$(guard_strip_heredoc_bodies "$other")
miss_full=$(guard_split_segments "$other" full)
miss_pipeline=$(guard_split_segments "$other" pipeline)
miss_sanitized=$(guard_sanitize_command "$other")

_GUARD_MEMO_PRIMED=""
emit "miss:strip_heredoc_bodies"     "$(guard_strip_heredoc_bodies "$other")"      "$miss_strip"
emit "miss:split_segments(full)"     "$(guard_split_segments "$other" full)"      "$miss_full"
emit "miss:split_segments(pipeline)" "$(guard_split_segments "$other" pipeline)"  "$miss_pipeline"
emit "miss:sanitize_command"         "$(guard_sanitize_command "$other")"         "$miss_sanitized"
'

run_case() {
  local cmd="$1" out rc emitted

  out=$(env -u CLAUDE_PROJECT_DIR -u GUARD_SKIP -u GUARD_LEVEL -u GUARD_FORCE_DENY \
        -u GIT_WORKFLOW bash -c "$CHILD" _ "$COMMON" "$cmd" 2>&1)
  rc=$?

  if [ "$rc" -ne 0 ]; then
    FAIL=$((FAIL + 1))
    echo "FAIL: テスト用シェルが異常終了した (rc=$rc) cmd=$(printf '%q' "$cmd")"
    echo "  $out"
    return
  fi

  # 表明が想定数だけ返っていることを確かめる。子が途中で死んで 0 行になった場合に
  # 緑へ落ちないようにする（空文字同士の比較で素通りするのを構造的に塞ぐ）
  emitted=$(printf '%s\n' "$out" | grep -cE '^(OK|NG) ')
  if [ "$emitted" -ne "$ASSERTIONS_PER_CASE" ]; then
    FAIL=$((FAIL + 1))
    echo "FAIL: 表明数が合わない (期待 $ASSERTIONS_PER_CASE / 実際 $emitted) cmd=$(printf '%q' "$cmd")"
    echo "$out" | sed 's/^/  /'
    return
  fi

  while IFS= read -r line; do
    case "$line" in
      "OK "*) PASS=$((PASS + 1)) ;;
      "NG "*)
        FAIL=$((FAIL + 1))
        echo "FAIL: ${line#NG } cmd=$(printf '%q' "$cmd")"
        ;;
    esac
  done < <(printf '%s\n' "$out")
}

for c in "${CASES[@]}"; do
  run_case "$c"
done

# 全ケースが空振りしていないことの最終確認
EXPECTED=$((${#CASES[@]} * ASSERTIONS_PER_CASE))
if [ "$((PASS + FAIL))" -ne "$EXPECTED" ]; then
  echo "FAIL: 総表明数が合わない (期待 $EXPECTED / 実際 $((PASS + FAIL)))"
  FAIL=$((FAIL + 1))
fi

echo "結果: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
