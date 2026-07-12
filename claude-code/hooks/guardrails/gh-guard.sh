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

# hook 起動元ではなく、command が実際に操作する repo の workflow policy を使う。
HOOK_CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
guard_reload_git_workflow_for_command "$COMMAND" "$HOOK_CWD"

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

_gh_guard_api_client() {
  local stripped="" segments="" segment="" token="" base="" i=0 count=0 gh_index=-1
  local -a tokens=()
  stripped=$(guard_strip_heredoc_bodies "$COMMAND")
  segments=$(guard_split_segments "$stripped")
  while IFS= read -r segment; do
    tokens=()
    while IFS= read -r token; do
      tokens[${#tokens[@]}]="$token"
    done < <(guard_shell_tokens_expanding_env_split "$segment")
    count=${#tokens[@]}
    i=0
    while [ "$i" -lt "$count" ]; do
      base="${tokens[$i]##*/}"
      if [ "$base" = "curl" ]; then
        printf 'curl\n'
        return 0
      fi
      if [ "$base" = "gh" ]; then
        gh_index="$i"
        i=$((gh_index + 1))
        while [ "$i" -lt "$count" ]; do
          token="${tokens[$i]}"
          case "$token" in
            --repo|-R|--hostname) i=$((i + 2)); continue ;;
            --repo=*|-R=*|-R?*|--hostname=*|--help|-h|--version) i=$((i + 1)); continue ;;
            -*) i=$((i + 1)); continue ;;
          esac
          if [ "$token" = "api" ]; then
            printf 'gh\n'
            return 0
          fi
          break
        done
        break
      fi
      i=$((i + 1))
    done
  done <<< "$segments"
  return 1
}

# --- チェック 0: curl / gh api による GitHub merge/approve API 直接呼び出し ---
if _gh_guard_api_client >/dev/null; then
  if echo "$COMMAND" | grep -qiE '/pulls/[0-9]+/merge'; then
    guard_respond "critical" "GH ガード" "GitHub API 経由の PR マージはブロックされています。gh pr merge コマンドを使用してください。"
  fi
  if echo "$COMMAND" | grep -qiE '/pulls/[0-9]+/reviews'; then
    if echo "$COMMAND" | grep -qiE 'approve'; then
      guard_respond "critical" "GH ガード" "GitHub API 経由の PR approve はブロックされています。gh pr review --approve も curl/gh api による直接呼び出しも禁止です。"
    fi
  fi
fi

_GH_GUARD_OPS=()
_GH_GUARD_SEGMENTS=()
_GH_GUARD_DIRS=()
_GH_GUARD_CONTEXT_UNKNOWN=()

_gh_guard_record_pr_invocation() {
  local op="$1" segment="$2" active_dir="$3" context_unknown="$4"
  local index="${#_GH_GUARD_OPS[@]}"
  _GH_GUARD_OPS[$index]="$op"
  _GH_GUARD_SEGMENTS[$index]="$segment"
  _GH_GUARD_DIRS[$index]="$active_dir"
  _GH_GUARD_CONTEXT_UNKNOWN[$index]="$context_unknown"
}

_gh_guard_collect_pr_invocations() {
  local base_dir="" active_dir="" stripped="" segments="" segment="" token="" path=""
  local context_unknown=0 i=0 count=0 cd_index=-1 tilde_literal=0
  local -a tokens=() tilde_literals=()

  if [ -n "$HOOK_CWD" ]; then
    base_dir=$(_guard_resolve_directory "$(pwd -P)" "$HOOK_CWD" 2>/dev/null || echo "")
  elif [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
    base_dir=$(_guard_resolve_directory "$(pwd -P)" "$CLAUDE_PROJECT_DIR" 2>/dev/null || echo "")
  else
    base_dir=$(pwd -P)
  fi
  active_dir="$base_dir"
  if [ -z "$active_dir" ] || guard_command_context_is_ambiguous "$COMMAND"; then
    context_unknown=1
  fi

  stripped=$(guard_strip_heredoc_bodies "$COMMAND")
  if guard_has_control_flow_cwd_change "$stripped"; then
    context_unknown=1
    active_dir=""
  fi
  segments=$(guard_split_segments "$stripped")
  while IFS= read -r segment; do
    segment=$(printf '%s\n' "$segment" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
    [ -n "$segment" ] || continue
    tokens=()
    tilde_literals=()
    while IFS=$'\034' read -r tilde_literal token; do
      tokens[${#tokens[@]}]="$token"
      tilde_literals[${#tilde_literals[@]}]="$tilde_literal"
    done < <(guard_shell_tokens_expanding_env_split "$segment" tilde-meta)
    count=${#tokens[@]}
    [ "$count" -gt 0 ] || continue

    cd_index=$(guard_cd_command_index "$segment" 2>/dev/null || echo -1)
    if [ "$cd_index" -ge 0 ]; then
      i=$((cd_index + 1))
      while [ "$i" -lt "$count" ]; do
        token="${tokens[$i]}"
        case "$token" in
          -L|-P|-e|-@) i=$((i + 1)) ;;
          *) break ;;
        esac
      done
      if [ "$i" -lt "$count" ] && [ "${tokens[$i]}" = "--" ]; then
        i=$((i + 1))
      fi
      if [ "$i" -lt "$count" ]; then
        path="${tokens[$i]}"
        active_dir=$(_guard_resolve_directory "$active_dir" "$path" "${tilde_literals[$i]:-0}" 2>/dev/null || echo "")
      else
        active_dir=""
      fi
      if [ -z "$active_dir" ]; then
        context_unknown=1
      fi
      continue
    fi

    if guard_extract_gh_pr_segment "$segment" "review" >/dev/null 2>&1; then
      _gh_guard_record_pr_invocation "review" "$segment" "$active_dir" "$context_unknown"
    fi
    if guard_extract_gh_pr_segment "$segment" "merge" >/dev/null 2>&1; then
      _gh_guard_record_pr_invocation "merge" "$segment" "$active_dir" "$context_unknown"
    fi
  done <<< "$segments"
}

_gh_guard_collect_pr_invocations

# --- ヘルパー: PR のターゲットブランチを取得 ---
# COMMAND 内の `cd <path>` や `--repo <owner/repo>` を尊重して PR view を実行する。
# hook の cwd は Claude Code の起動 dir なので、コマンド側の context を読まないと
# 別リポの PR 番号を hook の cwd リポで探してしまい __UNKNOWN__ になる（false positive）。
get_pr_base() {
  local pr_target="$1"
  local cmd="${2:-}"
  local working_dir="${3:-}"
  local context_unknown="${4:-0}"
  local result repo_arg=""

  if [ -n "$cmd" ]; then
    repo_arg=$(guard_extract_gh_repo_selector "$cmd" 2>/dev/null || echo "")
  fi
  if [ -z "$repo_arg" ] && [ "$context_unknown" -eq 1 ]; then
    echo "__UNKNOWN__"
    return
  fi

  if [ -n "$pr_target" ]; then
    if [ -n "$repo_arg" ]; then
      result=$(gh pr view "$pr_target" --repo "$repo_arg" --json baseRefName -q .baseRefName 2>/dev/null) || true
    elif [ -n "$working_dir" ] && [ -d "$working_dir" ]; then
      result=$(cd "$working_dir" 2>/dev/null && gh pr view "$pr_target" --json baseRefName -q .baseRefName 2>/dev/null) || true
    else
      result=$(gh pr view "$pr_target" --json baseRefName -q .baseRefName 2>/dev/null) || true
    fi
  else
    if [ -n "$repo_arg" ]; then
      result=$(gh pr view --repo "$repo_arg" --json baseRefName -q .baseRefName 2>/dev/null) || true
    elif [ -n "$working_dir" ] && [ -d "$working_dir" ]; then
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

# --- ヘルパー: 対象 segment から PR selector（番号・URL・branch）を抽出 ---
extract_pr_target() {
  local cmd="$1"
  local subcmd="$2"
  local token="" base="" i=0 count=0 gh_index=-1 state=0 subcmd_index=-1 option_mode=1
  local -a tokens=()

  while IFS= read -r token; do
    tokens[${#tokens[@]}]="$token"
  done < <(guard_shell_tokens_expanding_env_split "$cmd")
  count=${#tokens[@]}

  while [ "$i" -lt "$count" ]; do
    base="${tokens[$i]##*/}"
    if [ "$base" = "gh" ]; then
      gh_index="$i"
      break
    fi
    i=$((i + 1))
  done
  if [ "$gh_index" -lt 0 ]; then
    return
  fi

  i=$((gh_index + 1))
  while [ "$i" -lt "$count" ]; do
    token="${tokens[$i]}"
    case "$token" in
      --repo|-R|--hostname) i=$((i + 2)); continue ;;
      --repo=*|-R=*|-R?*|--hostname=*|--help|-h|--version) i=$((i + 1)); continue ;;
      -*) i=$((i + 1)); continue ;;
    esac
    if [ "$state" -eq 0 ] && [ "$token" = "pr" ]; then
      state=1
    elif [ "$state" -eq 1 ] && [ "$token" = "$subcmd" ]; then
      subcmd_index="$i"
      break
    else
      return
    fi
    i=$((i + 1))
  done
  if [ "$subcmd_index" -lt 0 ]; then
    return
  fi

  i=$((subcmd_index + 1))
  while [ "$i" -lt "$count" ]; do
    token="${tokens[$i]}"
    if [ "$option_mode" -eq 1 ]; then
      case "$token" in
        --)
          option_mode=0
          i=$((i + 1))
          continue
          ;;
        --repo|-R|--hostname|--body|--body-file|-b|-F|--subject|-t|--match-head-commit|--author|-A|--author-email)
          i=$((i + 2))
          continue
          ;;
        --repo=*|-R=*|-R?*|--hostname=*|--body=*|--body-file=*|-b=*|-b?*|-F=*|-F?*|--subject=*|-t=*|-t?*|--match-head-commit=*|--author=*|-A=*|-A?*|--author-email=*|-*)
          i=$((i + 1))
          continue
          ;;
      esac
    fi
    printf '%s\n' "$token"
    return
  done
}

# --- ヘルパー: 代理 approve 判定（クラウド環境用）---
is_proxy_approve() {
  local pr_target="$1"
  local cmd="${2:-}"
  local working_dir="${3:-}"
  local context_unknown="${4:-0}"
  local pr_author current_user
  local repo_arg=""

  if [ -n "$cmd" ]; then
    repo_arg=$(guard_extract_gh_repo_selector "$cmd" 2>/dev/null || echo "")
  fi
  if [ -z "$repo_arg" ] && [ "$context_unknown" -eq 1 ]; then
    return 1
  fi

  if [ -n "$pr_target" ]; then
    if [ -n "$repo_arg" ]; then
      pr_author=$(gh pr view "$pr_target" --repo "$repo_arg" --json author -q .author.login 2>/dev/null) || true
    elif [ -n "$working_dir" ] && [ -d "$working_dir" ]; then
      pr_author=$(cd "$working_dir" 2>/dev/null && gh pr view "$pr_target" --json author -q .author.login 2>/dev/null) || true
    else
      pr_author=$(gh pr view "$pr_target" --json author -q .author.login 2>/dev/null) || true
    fi
  else
    if [ -n "$repo_arg" ]; then
      pr_author=$(gh pr view --repo "$repo_arg" --json author -q .author.login 2>/dev/null) || true
    elif [ -n "$working_dir" ] && [ -d "$working_dir" ]; then
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

_gh_guard_review_is_approve() {
  local segment="$1" token="" i=0 count=0
  local -a tokens=()
  while IFS= read -r token; do
    tokens[${#tokens[@]}]="$token"
  done < <(guard_shell_tokens_expanding_env_split "$segment")
  count=${#tokens[@]}
  while [ "$i" -lt "$count" ]; do
    token="${tokens[$i]}"
    case "$token" in
      --body|--body-file|-b|-F|--subject|-t|--match-head-commit|--author|--repo|-R|--hostname)
        i=$((i + 2))
        continue
        ;;
      --approve|-a)
        return 0
        ;;
    esac
    i=$((i + 1))
  done
  return 1
}

if ! guard_is_trunk_direct; then
  GH_INDEX=0
  while [ "$GH_INDEX" -lt "${#_GH_GUARD_OPS[@]}" ]; do
    GH_OP="${_GH_GUARD_OPS[$GH_INDEX]}"
    GH_SEGMENT="${_GH_GUARD_SEGMENTS[$GH_INDEX]}"
    GH_DIR="${_GH_GUARD_DIRS[$GH_INDEX]}"
    GH_CONTEXT_UNKNOWN="${_GH_GUARD_CONTEXT_UNKNOWN[$GH_INDEX]}"

    if [ "$GH_OP" = "review" ]; then
      if ! _gh_guard_review_is_approve "$GH_SEGMENT"; then
        GH_INDEX=$((GH_INDEX + 1))
        continue
      fi
      PR_TARGET=$(extract_pr_target "$GH_SEGMENT" "review")
      BASE=$(get_pr_base "$PR_TARGET" "$GH_SEGMENT" "$GH_DIR" "$GH_CONTEXT_UNKNOWN")

      if [ "$IS_CLOUD" = "1" ]; then
        if is_proxy_approve "$PR_TARGET" "$GH_SEGMENT" "$GH_DIR" "$GH_CONTEXT_UNKNOWN"; then
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
    elif [ "$GH_OP" = "merge" ]; then
      PR_TARGET=$(extract_pr_target "$GH_SEGMENT" "merge")
      BASE=$(get_pr_base "$PR_TARGET" "$GH_SEGMENT" "$GH_DIR" "$GH_CONTEXT_UNKNOWN")
      if should_deny_merge "$BASE"; then
        REASON="main 向け PR のマージはブロックされています。"
        [ "$BASE" = "__UNKNOWN__" ] && REASON="PR のターゲットブランチを確認できなかったため、安全のためブロックしました。"
        guard_respond "advisory" "GH ガード" "${REASON} develop → main の昇格は人間が実行してください。"
      fi
    fi
    GH_INDEX=$((GH_INDEX + 1))
  done
fi

exit 0
