#!/bin/bash
# gh-guard: PreToolUse (Bash) - PR 操作をブロック [L5]
#
# ローカル環境: main 向け PR の approve/merge のみブロック。
#               release/* → develop のマージは許可。
#
# クラウド環境 (CLAUDE_CLOUD=1):
#   - 自己 approve（PR 作成者 = 現在のユーザー）: 全 PR をブロック
#   - 代理 approve（PR 作成者 ≠ 現在のユーザー）: develop 向けのみ許可、main 向けはブロック
#   - merge は develop 向けのみ許可（独立レビュアー approve 確認後）。
#   - main 向け merge は両環境でブロック。
#
# 両環境共通: curl / gh api による GitHub approve API 直接呼び出しもブロック。

set -uo pipefail

GUARD_COMMON="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_guard-common.sh"
source "$GUARD_COMMON"

INPUT=$(cat)

# command を取得
if command -v jq &>/dev/null; then
  COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
else
  exit 0
fi

if [ -z "${COMMAND:-}" ]; then
  exit 0
fi

# パターンマッチ用: 引用符 / HEREDOC 内のテキストをプレースホルダーに置換（body テキスト誤検出防止）
# perl で全文一括処理することで、改行を跨ぐ引用符や HEREDOC body 内の "gh pr ..." が
# 誤検出されないようにする（例: git commit -m "...gh pr merge..." の本文は無視）。
if command -v perl &>/dev/null; then
  COMMAND_FOR_MATCH=$(printf '%s' "$COMMAND" | perl -0777 -pe '
    s/<<-?\s*'\''?(\w+)'\''?[\s\S]*?\n\1\b/_HEREDOC_/g;
    s/"[^"]*"/_Q_/g;
    s/'\''[^'\'']*'\''/_Q_/g;
  ')
else
  COMMAND_FOR_MATCH=$(echo "$COMMAND" | sed -E "s/\"[^\"]*\"/_Q_/g; s/'[^']*'/_Q_/g")
fi

# --- クラウド環境判定 ---
IS_CLOUD="${CLAUDE_CLOUD:-0}"

# --- チェック 0: curl / gh api による GitHub merge/approve API 直接呼び出し ---
if echo "$COMMAND_FOR_MATCH" | grep -qiE '(curl|gh\s+api)\s'; then
  if echo "$COMMAND" | grep -qiE '/pulls/[0-9]+/merge'; then
    guard_respond "critical" "GH ガード" "GitHub API 経由の PR マージはブロックされています。gh pr merge コマンドを使用してください。"
  fi
  if echo "$COMMAND" | grep -qiE '/pulls/[0-9]+/reviews'; then
    if echo "$COMMAND" | grep -qiE 'approve'; then
      guard_respond "critical" "GH ガード" "GitHub API 経由の PR approve はブロックされています。gh pr review --approve も curl/gh api による直接呼び出しも禁止です。"
    fi
  fi
fi

# gh pr コマンド以外はスキップ
case "$COMMAND_FOR_MATCH" in
  *gh\ pr\ *)
    ;;
  *)
    exit 0
    ;;
esac

# --- ヘルパー: PR のターゲットブランチを取得 ---
# COMMAND 内の `cd <path>` や `--repo <owner/repo>` を尊重して PR view を実行する。
# hook の cwd は Claude Code の起動 dir なので、コマンド側の context を読まないと
# 別リポの PR 番号を hook の cwd リポで探してしまい __UNKNOWN__ になる（false positive）。
get_pr_base() {
  local pr_num="$1"
  local cmd="${2:-}"
  local result repo_arg="" working_dir=""

  if [ -n "$cmd" ]; then
    repo_arg=$(echo "$cmd" | grep -oE -- '(--repo|-R)[[:space:]]+[^[:space:]]+' | head -1 | sed -E 's/^(--repo|-R)[[:space:]]+//' | tr -d "\"'")
    working_dir=$(echo "$cmd" | grep -oE 'cd[[:space:]]+[^[:space:]&|;]+' | head -1 | sed -E 's/^cd[[:space:]]+//')
    working_dir="${working_dir/#~/$HOME}"
  fi

  if [ -n "$pr_num" ]; then
    if [ -n "$repo_arg" ]; then
      result=$(gh pr view "$pr_num" --repo "$repo_arg" --json baseRefName -q .baseRefName 2>/dev/null) || true
    elif [ -n "$working_dir" ] && [ -d "$working_dir" ]; then
      result=$(cd "$working_dir" 2>/dev/null && gh pr view "$pr_num" --json baseRefName -q .baseRefName 2>/dev/null) || true
    else
      result=$(gh pr view "$pr_num" --json baseRefName -q .baseRefName 2>/dev/null) || true
    fi
  else
    if [ -n "$working_dir" ] && [ -d "$working_dir" ]; then
      result=$(cd "$working_dir" 2>/dev/null && gh pr view --json baseRefName -q .baseRefName 2>/dev/null) || true
    else
      result=$(gh pr view --json baseRefName -q .baseRefName 2>/dev/null) || true
    fi
  fi

  if [ -z "$result" ]; then
    echo "__UNKNOWN__"
  else
    echo "$result"
  fi
}

# --- ヘルパー: コマンドから PR 番号を抽出 ---
extract_pr_number() {
  local cmd="$1"
  local subcmd="$2"
  local args
  args=$(echo "$cmd" | sed -E "s/.*gh[[:space:]]+pr[[:space:]]+${subcmd}[[:space:]]+//")

  args=$(echo "$args" | sed -E 's/(--body-file|--body|-b|--subject|-t|--match-head-commit|--author|-R|--repo)[[:space:]]+"[^"]*"//g')
  args=$(echo "$args" | sed -E "s/(--body-file|--body|-b|--subject|-t|--match-head-commit|--author|-R|--repo)[[:space:]]+'[^']*'//g")
  args=$(echo "$args" | sed -E 's/(--body-file|--body|-b|--subject|-t|--match-head-commit|--author|-R|--repo)[[:space:]]+[^[:space:]]+//g')

  args=$(echo "$args" | sed -E 's/--[a-zA-Z-]+="[^"]*"//g')
  args=$(echo "$args" | sed -E "s/--[a-zA-Z-]+='[^']*'//g")
  args=$(echo "$args" | sed -E 's/--[a-zA-Z-]+=[^[:space:]]+//g')

  args=$(echo "$args" | sed -E 's/--?[a-zA-Z-]+//g')
  args=$(echo "$args" | sed -E "s/[\"']//g")

  echo "$args" | grep -oE '\b[0-9]+\b' | head -1
}

# --- ヘルパー: 代理 approve 判定（クラウド環境用）---
is_proxy_approve() {
  local pr_num="$1"
  local cmd="${2:-}"
  local pr_author current_user
  local repo_arg="" working_dir=""

  if [ -n "$cmd" ]; then
    repo_arg=$(echo "$cmd" | grep -oE -- '(--repo|-R)[[:space:]]+[^[:space:]]+' | head -1 | sed -E 's/^(--repo|-R)[[:space:]]+//' | tr -d "\"'")
    working_dir=$(echo "$cmd" | grep -oE 'cd[[:space:]]+[^[:space:]&|;]+' | head -1 | sed -E 's/^cd[[:space:]]+//')
    working_dir="${working_dir/#~/$HOME}"
  fi

  if [ -n "$pr_num" ]; then
    if [ -n "$repo_arg" ]; then
      pr_author=$(gh pr view "$pr_num" --repo "$repo_arg" --json author -q .author.login 2>/dev/null) || true
    elif [ -n "$working_dir" ] && [ -d "$working_dir" ]; then
      pr_author=$(cd "$working_dir" 2>/dev/null && gh pr view "$pr_num" --json author -q .author.login 2>/dev/null) || true
    else
      pr_author=$(gh pr view "$pr_num" --json author -q .author.login 2>/dev/null) || true
    fi
  else
    if [ -n "$working_dir" ] && [ -d "$working_dir" ]; then
      pr_author=$(cd "$working_dir" 2>/dev/null && gh pr view --json author -q .author.login 2>/dev/null) || true
    else
      pr_author=$(gh pr view --json author -q .author.login 2>/dev/null) || true
    fi
  fi

  current_user=$(gh api user -q .login 2>/dev/null) || true

  if [ -z "$pr_author" ] || [ -z "$current_user" ]; then
    return 1
  fi

  [ "$pr_author" != "$current_user" ]
}

# --- ヘルパー: approve の deny 判定 ---
should_deny_approve() {
  local base="$1"
  [ "$base" = "main" ] || [ "$base" = "master" ] || [ "$base" = "__UNKNOWN__" ]
}

# --- ヘルパー: merge の deny 判定 ---
should_deny_merge() {
  local base="$1"
  [ "$base" = "main" ] || [ "$base" = "master" ] || [ "$base" = "__UNKNOWN__" ]
}

# --- チェック 1: gh pr review --approve ---
if echo "$COMMAND_FOR_MATCH" | grep -qE 'gh\s+pr\s+review\s.*(-a\b|--approve)'; then
  PR_NUM=$(extract_pr_number "$COMMAND" "review")
  BASE=$(get_pr_base "$PR_NUM" "$COMMAND")

  if [ "$IS_CLOUD" = "1" ]; then
    if is_proxy_approve "$PR_NUM" "$COMMAND"; then
      if should_deny_approve "$BASE"; then
        REASON="main 向け PR は代理 approve でもブロックされています。"
        [ "$BASE" = "__UNKNOWN__" ] && REASON="PR のターゲットブランチを確認できなかったため、安全のためブロックしました。"
        guard_respond "advisory" "GH ガード" "${REASON} develop → main の昇格は人間が承認・実行してください。"
      fi
    else
      guard_respond "advisory" "GH ガード" "VPS 環境での自己 approve はブロックされています。代理 approve（PR 作成者と異なるアカウント）は develop 向け PR で許可されます。"
    fi
  elif should_deny_approve "$BASE"; then
    REASON="main 向け PR の approve はブロックされています。"
    [ "$BASE" = "__UNKNOWN__" ] && REASON="PR のターゲットブランチを確認できなかったため、安全のためブロックしました。"
    guard_respond "advisory" "GH ガード" "${REASON} develop → main の昇格は人間が承認・実行してください。"
  fi
fi

# --- チェック 2: gh pr merge ---
if echo "$COMMAND_FOR_MATCH" | grep -qE 'gh\s+pr\s+merge'; then
  PR_NUM=$(extract_pr_number "$COMMAND" "merge")
  BASE=$(get_pr_base "$PR_NUM" "$COMMAND")

  if should_deny_merge "$BASE"; then
    REASON="main 向け PR のマージはブロックされています。"
    [ "$BASE" = "__UNKNOWN__" ] && REASON="PR のターゲットブランチを確認できなかったため、安全のためブロックしました。"
    guard_respond "advisory" "GH ガード" "${REASON} develop → main の昇格は人間が実行してください。"
  fi
fi

exit 0
