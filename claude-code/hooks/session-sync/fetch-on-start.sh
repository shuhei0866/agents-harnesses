#!/bin/bash
# session-sync/fetch-on-start.sh: SessionStart - セッション開始時にリモートをフェッチし遅延を警告
#
# git fetch を実行し、現在のブランチがリモートより遅れている場合に
# additionalContext で警告する。pull は行わない（安全側）。

set -uo pipefail

# git リポジトリでなければスキップ
if ! git rev-parse --is-inside-work-tree &>/dev/null; then
  exit 0
fi

# 指定秒数でコマンドを打ち切る。GNU timeout は macOS 標準に無いため
# Bash 3.2 の組み込み機能と sleep だけで実装する。
#   run_with_timeout <秒> <コマンド...>
# 時間切れなら TERM、1 秒後に KILL を送り、非 0 を返す。
#
# シグナルはコマンド単体ではなくプロセスグループ全体に送る。git fetch は
# ssh / git-remote-https などの子プロセスを起動するため、親だけを止めると
# 子が生き残ってしまう。setsid や perl に頼らず、ジョブ制御 (set -m) を
# 一時的に有効にしてコマンドを専用のプロセスグループで起動する。
# set -m はサブシェル内ではなくフック本体のシェルで切り替える
# (Bash 3.2 ではサブシェル内の set -m で新しいグループが作られないことがある)。
# シェルが出すジョブ終了通知 ("Terminated: 15" など) がフックの stderr に
# 漏れないよう、関数本体の stderr は /dev/null に向ける。
#
# コマンドと監視プロセスの標準入出力は /dev/null に向ける
# (残った子プロセスがフックの stdout パイプを掴んで呼び出し側を待たせないため)。
run_with_timeout() {
  local secs=$1
  shift
  local cmd_pid="" watchdog_pid="" target="" rc=0 watchdog_rc=0

  {
    set -m
    "$@" </dev/null >/dev/null 2>&1 &
    cmd_pid=$!
    set +m

    # 専用グループができていればグループ宛て (-PGID)、できていなければ
    # コマンド単体宛てにフォールバックする。
    target="-$cmd_pid"
    kill -0 -- "$target" 2>/dev/null || target="$cmd_pid"

    (
      nap_pid=""
      trap '[ -n "$nap_pid" ] && kill "$nap_pid" 2>/dev/null; exit 0' TERM
      sleep "$secs" &
      nap_pid=$!
      wait "$nap_pid"
      # ここからは時間切れ処理。途中で打ち切られないよう TERM を無視し、
      # TERM を無視する (または親の死後も残る) 子孫まで必ず KILL する。
      trap '' TERM
      kill -TERM -- "$target" 2>/dev/null || exit 0
      sleep 1 &
      nap_pid=$!
      wait "$nap_pid"
      kill -KILL -- "$target" 2>/dev/null
      exit 124
    ) </dev/null >/dev/null 2>&1 &
    watchdog_pid=$!

    wait "$cmd_pid" || rc=$?

    # 時間内に終わった場合は監視を止める。時間切れ処理中なら監視は TERM を
    # 無視するので、KILL まで終わるのを待ってから戻る。
    kill -TERM "$watchdog_pid" 2>/dev/null
    wait "$watchdog_pid" || watchdog_rc=$?

    # 未通知のジョブ終了通知を stderr を捨てているうちに消化しておく。
    jobs >/dev/null 2>&1
  } 2>/dev/null

  # 親が TERM の処理で 0 を返しても、時間切れの fetch は失敗として扱う。
  if [ "$watchdog_rc" -eq 124 ]; then
    return 124
  fi
  return "$rc"
}

# fetch（タイムアウト 10 秒）。失敗・時間切れ時は何も出さずに終了
run_with_timeout 10 git fetch --quiet || exit 0

BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
if [ -z "$BRANCH" ] || [ "$BRANCH" = "HEAD" ]; then
  exit 0
fi

# リモート追跡ブランチがあるか確認
UPSTREAM=$(git rev-parse --abbrev-ref "@{upstream}" 2>/dev/null || echo "")
if [ -z "$UPSTREAM" ]; then
  exit 0
fi

# ローカルとリモートの差分
BEHIND=$(git rev-list --count HEAD.."$UPSTREAM" 2>/dev/null || echo "0")
AHEAD=$(git rev-list --count "$UPSTREAM"..HEAD 2>/dev/null || echo "0")

if [ "$BEHIND" -gt 0 ]; then
  cat << EOF
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "[同期警告] ブランチ ${BRANCH} はリモート (${UPSTREAM}) より ${BEHIND} コミット遅れています。作業前に git pull を検討してください。(ahead: ${AHEAD})"
  }
}
EOF
  exit 0
fi

exit 0
