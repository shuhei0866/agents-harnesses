#!/bin/bash
# guard_prime_command_cache の契約テスト。
#
# 固定する性質はひとつ: memo 化した 3 関数は、prime してもしなくても
# 同じ結果を返す。ここが崩れると、ガードは「速いが判定が違う」状態になり、
# しかも出力が変わらないので気づけない。
#
# あわせてキャッシュミスの経路も固定する。prime した命令と別の引数を渡したときは
# 従来の計算経路へ落ちて正しい結果を返す必要がある。ここが壊れると、直前の
# コマンドの解析結果を別のコマンドに適用してしまう。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON="$SCRIPT_DIR/../_guard-common.sh"

PASS=0
FAIL=0

fail() {
  FAIL=$((FAIL + 1))
  echo "FAIL: $1"
  echo "  期待: $(printf '%q' "$2")"
  echo "  実際: $(printf '%q' "$3")"
}

pass() { PASS=$((PASS + 1)); }

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

run_case() {
  local cmd="$1"

  # env をテスト側で固定し、guard 設定の読み込みが判定へ混ざらないようにする
  local out
  out=$(env -u CLAUDE_PROJECT_DIR -u GUARD_SKIP -u GUARD_LEVEL -u GUARD_FORCE_DENY \
        -u GIT_WORKFLOW bash -c '
    source "$1" 2>/dev/null
    cmd="$2"

    # prime しない状態（従来の計算経路）
    _GUARD_MEMO_PRIMED=""
    raw_stripped=$(guard_strip_heredoc_bodies "$cmd")
    raw_full=$(guard_split_segments "$raw_stripped" full)
    raw_pipeline=$(guard_split_segments "$raw_stripped" pipeline)
    raw_sanitized=$(guard_sanitize_command "$raw_stripped")

    # prime した状態（キャッシュ経路）
    guard_prime_command_cache "$cmd"
    memo_stripped=$(guard_strip_heredoc_bodies "$cmd")
    memo_full=$(guard_split_segments "$memo_stripped" full)
    memo_pipeline=$(guard_split_segments "$memo_stripped" pipeline)
    memo_sanitized=$(guard_sanitize_command "$memo_stripped")

    # キャッシュミス: prime した命令と別の引数
    other="git push --force origin other-branch"
    miss_actual=$(guard_split_segments "$other" full)
    _GUARD_MEMO_PRIMED=""
    miss_expected=$(guard_split_segments "$other" full)

    printf "%s\x1e%s\x1e%s\x1e%s\x1e" "$raw_stripped" "$raw_full" "$raw_pipeline" "$raw_sanitized"
    printf "%s\x1e%s\x1e%s\x1e%s\x1e" "$memo_stripped" "$memo_full" "$memo_pipeline" "$memo_sanitized"
    printf "%s\x1e%s" "$miss_actual" "$miss_expected"
  ' _ "$COMMON" "$cmd")

  local -a f
  IFS=$'\x1e' read -r -d '' -a f < <(printf '%s\x1e\x00' "$out")

  local labels=("strip_heredoc_bodies" "split_segments(full)" "split_segments(pipeline)" "sanitize_command")
  local i
  for i in 0 1 2 3; do
    if [ "${f[$i]:-}" = "${f[$((i + 4))]:-}" ]; then
      pass
    else
      fail "prime 有無で結果が違う [${labels[$i]}] cmd=$(printf '%q' "$cmd")" \
           "${f[$i]:-}" "${f[$((i + 4))]:-}"
    fi
  done

  if [ "${f[8]:-}" = "${f[9]:-}" ]; then
    pass
  else
    fail "キャッシュミス時に従来経路へ落ちていない cmd=$(printf '%q' "$cmd")" \
         "${f[9]:-}" "${f[8]:-}"
  fi
}

for c in "${CASES[@]}"; do
  run_case "$c"
done

echo "結果: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
