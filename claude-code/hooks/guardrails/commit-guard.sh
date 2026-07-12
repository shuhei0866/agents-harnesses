#!/bin/bash
# commit-guard: PreToolUse (Bash) - 危険な git 操作をブロック [L5]
#
# メインワークツリーでの保護ブランチ (main/develop) への直接コミット、
# --no-verify によるフックスキップ、force push、ブランチ切り替え、
# main への直接マージ（hotfix 除く）、develop ブランチ削除などを検出してブロックする。
# gh pr merge による main 向け PR マージもブロック（hotfix/*, chore/promote-main-*, develop は除く）。

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

# パターンマッチ用: 引用符内のテキストをプレースホルダーに置換（コマンド引数の誤検出防止）
COMMAND_FOR_MATCH=$(echo "$COMMAND" | sed -E "s/\"[^\"]*\"/_Q_/g; s/'[^']*'/_Q_/g")

# --- 普遍 critical チェック ---
# workflow 固有の advisory は guard_respond で終了するため、critical 操作を先に判定する。
# quote-aware token 列を使い、quoted option を検出しつつ message/option value は誤検出しない。

_COMMIT_GUARD_TOKENS=()

_commit_guard_check_commit_args() {
  local i="$1" count="${#_COMMIT_GUARD_TOKENS[@]}" token="" cluster="" ch=""
  local j=0 cluster_len=0

  while [ "$i" -lt "$count" ]; do
    token="${_COMMIT_GUARD_TOKENS[$i]}"
    case "$token" in
      --) break ;;
      --no-verify)
        guard_respond "critical" "コミット衛生ガード" "--no-verify の使用はブロックされています。pre-commit フックのエラーを修正してからコミットしてください。lint エラーの場合は \`pnpm lint --fix\` を試してください。"
        ;;
      --message|--file|--reuse-message|--reedit-message|--template|--cleanup|--author|--date|--fixup|--squash|--pathspec-from-file|--trailer)
        i=$((i + 1))
        ;;
      --*)
        ;;
      -?*)
        cluster="${token#-}"
        cluster_len=${#cluster}
        j=1
        while [ "$j" -le "$cluster_len" ]; do
          ch="${cluster:$((j - 1)):1}"
          if [ "$ch" = "n" ]; then
            guard_respond "critical" "コミット衛生ガード" "--no-verify の使用はブロックされています。pre-commit フックのエラーを修正してからコミットしてください。lint エラーの場合は \`pnpm lint --fix\` を試してください。"
          fi
          case "$ch" in
            m|F|C|c|t)
              # 値を取る option 以降の文字は attached value。値が別 token ならそれも飛ばす。
              if [ "$j" -eq "$cluster_len" ]; then
                i=$((i + 1))
              fi
              break
              ;;
            S|u)
              # optional value は attached form のみ。次 token は別 option として判定する。
              break
              ;;
          esac
          j=$((j + 1))
        done
        ;;
    esac
    i=$((i + 1))
  done
}

_commit_guard_ref_name() {
  local ref="$1"
  ref="${ref#refs/heads/}"
  printf '%s\n' "$ref"
}

_commit_guard_check_push_args() {
  local i="$1" git_dir="$2" count="${#_COMMIT_GUARD_TOKENS[@]}" token="" cluster="" ch=""
  local j=0 cluster_len=0 force=0 delete=0 repo_via_option=0 option_mode=1
  local -a positional=()
  local ref_start=1 ref="" ref_without_plus="" destination="" normalized="" plus=0 current_branch=""

  while [ "$i" -lt "$count" ]; do
    token="${_COMMIT_GUARD_TOKENS[$i]}"
    if [ "$option_mode" -eq 1 ]; then
      case "$token" in
        --)
          option_mode=0
          i=$((i + 1))
          continue
          ;;
        --no-verify)
          guard_respond "critical" "コミット衛生ガード" "--no-verify の使用はブロックされています。Git hook のエラーを修正してから再実行してください。"
          ;;
        --force|--force=*|--force-with-lease|--force-with-lease=*|--force-if-includes)
          force=1
          i=$((i + 1))
          continue
          ;;
        --delete)
          delete=1
          i=$((i + 1))
          continue
          ;;
        --repo)
          repo_via_option=1
          i=$((i + 2))
          continue
          ;;
        --repo=*)
          repo_via_option=1
          i=$((i + 1))
          continue
          ;;
        --push-option|--receive-pack|--exec)
          i=$((i + 2))
          continue
          ;;
        --*)
          i=$((i + 1))
          continue
          ;;
        -?*)
          cluster="${token#-}"
          cluster_len=${#cluster}
          j=1
          while [ "$j" -le "$cluster_len" ]; do
            ch="${cluster:$((j - 1)):1}"
            case "$ch" in
              f) force=1 ;;
              d) delete=1 ;;
              o|r)
                # -o/-r は値を取るため、attached value 内の f/d は flag ではない。
                if [ "$j" -eq "$cluster_len" ]; then
                  i=$((i + 1))
                fi
                break
                ;;
            esac
            j=$((j + 1))
          done
          i=$((i + 1))
          continue
          ;;
      esac
    fi
    positional[${#positional[@]}]="$token"
    i=$((i + 1))
  done

  if [ "$repo_via_option" -eq 1 ]; then
    ref_start=0
  fi

  if [ "$force" -eq 1 ] && [ "${#positional[@]}" -le "$ref_start" ]; then
    current_branch=$(git -C "$git_dir" branch --show-current 2>/dev/null || echo "")
    if [ -z "$current_branch" ] || [ "$current_branch" = "main" ] || [ "$current_branch" = "master" ]; then
      guard_respond "critical" "コミット衛生ガード" "main/master への force push はブロックされています。"
    fi
  fi

  i="$ref_start"
  while [ "$i" -lt "${#positional[@]}" ]; do
    ref="${positional[$i]}"
    plus=0
    ref_without_plus="$ref"
    case "$ref_without_plus" in
      +*) plus=1; ref_without_plus="${ref_without_plus#+}" ;;
    esac

    if [ "${ref_without_plus#*:}" != "$ref_without_plus" ]; then
      destination="${ref_without_plus##*:}"
    else
      destination="$ref_without_plus"
    fi
    normalized=$(_commit_guard_ref_name "$destination")

    if { [ "$force" -eq 1 ] || [ "$plus" -eq 1 ]; } \
       && { [ "$normalized" = "main" ] || [ "$normalized" = "master" ]; }; then
      guard_respond "critical" "コミット衛生ガード" "main/master への force push はブロックされています。"
    fi

    if { [ "$delete" -eq 1 ] || [ "${ref_without_plus#:}" != "$ref_without_plus" ]; } \
       && [ "$normalized" = "develop" ]; then
      guard_respond "critical" "ブランチ戦略ガード" "develop ブランチの削除はブロックされています。develop は永続ブランチです。"
    fi
    i=$((i + 1))
  done
}

_commit_guard_check_branch_args() {
  local i="$1" count="${#_COMMIT_GUARD_TOKENS[@]}" token="" cluster="" ch=""
  local j=0 cluster_len=0 delete=0 option_mode=1
  local -a positional=()
  local normalized=""

  while [ "$i" -lt "$count" ]; do
    token="${_COMMIT_GUARD_TOKENS[$i]}"
    if [ "$option_mode" -eq 1 ]; then
      case "$token" in
        --)
          option_mode=0
          i=$((i + 1))
          continue
          ;;
        --delete)
          delete=1
          i=$((i + 1))
          continue
          ;;
        --move|--copy|--set-upstream-to|--track|--format|--sort|--points-at|--contains|--no-contains|--merged|--no-merged)
          i=$((i + 2))
          continue
          ;;
        --*)
          i=$((i + 1))
          continue
          ;;
        -?*)
          cluster="${token#-}"
          cluster_len=${#cluster}
          j=1
          while [ "$j" -le "$cluster_len" ]; do
            ch="${cluster:$((j - 1)):1}"
            case "$ch" in
              d|D) delete=1 ;;
              m|M|c|C|u|t)
                if [ "$j" -eq "$cluster_len" ]; then
                  i=$((i + 1))
                fi
                break
                ;;
            esac
            j=$((j + 1))
          done
          i=$((i + 1))
          continue
          ;;
      esac
    fi
    positional[${#positional[@]}]="$token"
    i=$((i + 1))
  done

  if [ "$delete" -eq 1 ]; then
    i=0
    while [ "$i" -lt "${#positional[@]}" ]; do
      normalized=$(_commit_guard_ref_name "${positional[$i]}")
      if [ "$normalized" = "develop" ]; then
        guard_respond "critical" "ブランチ戦略ガード" "develop ブランチの削除はブロックされています。develop は永続ブランチです。"
      fi
      i=$((i + 1))
    done
  fi
}

# standard command prefix を読み飛ばし、実行される git token の index を返す。
_commit_guard_find_git_index() {
  local i=0 count="${#_COMMIT_GUARD_TOKENS[@]}" token="" base=""

  while [ "$i" -lt "$count" ]; do
    token="${_COMMIT_GUARD_TOKENS[$i]}"
    if [[ "$token" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
      i=$((i + 1))
      continue
    fi

    base="${token##*/}"
    case "$base" in
      git)
        printf '%s\n' "$i"
        return 0
        ;;
      env)
        i=$((i + 1))
        while [ "$i" -lt "$count" ]; do
          token="${_COMMIT_GUARD_TOKENS[$i]}"
          if [[ "$token" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
            i=$((i + 1))
            continue
          fi
          case "$token" in
            --) i=$((i + 1)); break ;;
            -u|--unset|-C|--chdir|-S|--split-string) i=$((i + 2)) ;;
            --unset=*|--chdir=*|--split-string=*|-*) i=$((i + 1)) ;;
            *) break ;;
          esac
        done
        ;;
      command)
        i=$((i + 1))
        while [ "$i" -lt "$count" ]; do
          token="${_COMMIT_GUARD_TOKENS[$i]}"
          case "$token" in
            --) i=$((i + 1)); break ;;
            -*) i=$((i + 1)) ;;
            *) break ;;
          esac
        done
        ;;
      sudo)
        i=$((i + 1))
        while [ "$i" -lt "$count" ]; do
          token="${_COMMIT_GUARD_TOKENS[$i]}"
          case "$token" in
            --) i=$((i + 1)); break ;;
            -u|-g|-h|-p|-C|-D|-T|-r|-t|-U|--user|--group|--host|--prompt|--chdir|--command-timeout|--role|--type|--other-user) i=$((i + 2)) ;;
            --*=*|-*) i=$((i + 1)) ;;
            *) break ;;
          esac
        done
        ;;
      *)
        return 1
        ;;
    esac
  done
  return 1
}

_commit_guard_check_universal_critical() {
  local stripped="" segments="" segment="" token="" count=0 i=0 subcommand="" git_index=""
  local base_dir="" active_dir="" git_dir="" path=""
  local ambiguous_context=0 context_unknown=0 k=0

  if [ -n "$HOOK_CWD" ]; then
    base_dir=$(_guard_resolve_directory "$(pwd -P)" "$HOOK_CWD" 2>/dev/null || echo "")
  elif [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
    base_dir=$(_guard_resolve_directory "$(pwd -P)" "$CLAUDE_PROJECT_DIR" 2>/dev/null || echo "")
  else
    base_dir=$(pwd -P)
  fi
  active_dir="$base_dir"

  if guard_command_context_is_ambiguous "$COMMAND"; then
    ambiguous_context=1
  fi

  stripped=$(guard_strip_heredoc_bodies "$COMMAND")
  segments=$(guard_split_segments "$stripped")

  while IFS= read -r segment; do
    _COMMIT_GUARD_TOKENS=()
    while IFS= read -r token; do
      _COMMIT_GUARD_TOKENS[${#_COMMIT_GUARD_TOKENS[@]}]="$token"
    done < <(guard_shell_tokens "$segment")

    count=${#_COMMIT_GUARD_TOKENS[@]}
    if [ "$count" -eq 0 ]; then
      continue
    fi

    if [ "${_COMMIT_GUARD_TOKENS[0]}" = "cd" ]; then
      i=1
      if [ "$i" -lt "$count" ] && [ "${_COMMIT_GUARD_TOKENS[$i]}" = "--" ]; then
        i=$((i + 1))
      fi
      if [ "$i" -lt "$count" ]; then
        path="${_COMMIT_GUARD_TOKENS[$i]}"
        active_dir=$(_guard_resolve_directory "$active_dir" "$path" 2>/dev/null || echo "")
      else
        active_dir=""
      fi
      continue
    fi

    git_index=$(_commit_guard_find_git_index 2>/dev/null || echo "")
    if [ -z "$git_index" ]; then
      continue
    fi

    i=$((git_index + 1))
    git_dir="$active_dir"
    context_unknown="$ambiguous_context"

    # env/sudo 等の prefix が cwd を変える場合は同じ基準で target を解決する。
    k=0
    while [ "$k" -lt "$git_index" ]; do
      token="${_COMMIT_GUARD_TOKENS[$k]}"
      case "$token" in
        GIT_DIR=*|GIT_WORK_TREE=*)
          context_unknown=1
          ;;
        -C|-D|--chdir)
          if [ $((k + 1)) -lt "$git_index" ]; then
            git_dir=$(_guard_resolve_directory "$git_dir" "${_COMMIT_GUARD_TOKENS[$((k + 1))]}" 2>/dev/null || echo "")
          else
            context_unknown=1
          fi
          k=$((k + 2))
          continue
          ;;
        --chdir=*)
          git_dir=$(_guard_resolve_directory "$git_dir" "${token#*=}" 2>/dev/null || echo "")
          ;;
      esac
      k=$((k + 1))
    done

    # git global options（-C/-c は値を1つ消費）を読み飛ばして subcommand を得る。
    while [ "$i" -lt "$count" ]; do
      token="${_COMMIT_GUARD_TOKENS[$i]}"
      case "$token" in
        -C)
          if [ $((i + 1)) -lt "$count" ]; then
            git_dir=$(_guard_resolve_directory "$git_dir" "${_COMMIT_GUARD_TOKENS[$((i + 1))]}" 2>/dev/null || echo "")
          else
            git_dir=""
          fi
          i=$((i + 2))
          ;;
        --git-dir|--work-tree)
          context_unknown=1
          i=$((i + 2))
          ;;
        -c|--namespace|--config-env) i=$((i + 2)) ;;
        --git-dir=*|--work-tree=*)
          context_unknown=1
          i=$((i + 1))
          ;;
        --namespace=*|--config-env=*|--bare|--no-pager|--paginate|--literal-pathspecs|--glob-pathspecs|--noglob-pathspecs|--icase-pathspecs) i=$((i + 1)) ;;
        *) break ;;
      esac
    done
    if [ "$i" -ge "$count" ]; then
      continue
    fi

    subcommand="${_COMMIT_GUARD_TOKENS[$i]}"
    i=$((i + 1))
    if [ "$context_unknown" -eq 1 ]; then
      git_dir=""
    fi
    case "$subcommand" in
      commit) _commit_guard_check_commit_args "$i" ;;
      push)   _commit_guard_check_push_args "$i" "$git_dir" ;;
      branch) _commit_guard_check_branch_args "$i" ;;
    esac
  done <<< "$segments"
}

_commit_guard_check_universal_critical

# --- チェック 0: メインワークツリーでの git commit (保護ブランチ直接コミット防止) ---
if echo "$COMMAND_FOR_MATCH" | grep -qE 'git\s+(-C\s+\S+\s+)?commit\b' && ! guard_is_trunk_direct; then
  GIT_C_PATH=$(echo "$COMMAND" | sed -nE 's/.*git[[:space:]]+-C[[:space:]]+"([^"]+)".*/\1/p')
  if [ -z "$GIT_C_PATH" ]; then
    GIT_C_PATH=$(echo "$COMMAND" | sed -nE "s/.*git[[:space:]]+-C[[:space:]]+'([^']+)'.*/\1/p")
  fi
  if [ -z "$GIT_C_PATH" ]; then
    GIT_C_PATH=$(echo "$COMMAND" | sed -nE 's/.*git[[:space:]]+-C[[:space:]]+([^ "'"'"']+).*/\1/p')
  fi

  BEFORE_GIT=$(echo "$COMMAND" | sed -nE 's/(.*)(git[[:space:]]+(-C[[:space:]]+[^ ]+[[:space:]]+)?commit\b.*)/\1/p')
  CD_PATH=$(echo "$BEFORE_GIT" | sed -nE 's/.*cd[[:space:]]+"([^"]+)".*/\1/p')
  if [ -z "$CD_PATH" ]; then
    CD_PATH=$(echo "$BEFORE_GIT" | sed -nE "s/.*cd[[:space:]]+'([^']+)'.*/\1/p")
  fi
  if [ -z "$CD_PATH" ]; then
    CD_PATH=$(echo "$BEFORE_GIT" | sed -nE 's/.*cd[[:space:]]+([^ "&;|'"'"']+).*/\1/p')
  fi

  if [ -n "$GIT_C_PATH" ]; then
    GIT_COMMON_DIR=$(git -C "$GIT_C_PATH" rev-parse --git-common-dir 2>/dev/null || echo "")
    GIT_DIR=$(git -C "$GIT_C_PATH" rev-parse --git-dir 2>/dev/null || echo "")
    BRANCH=$(git -C "$GIT_C_PATH" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  elif [ -n "$CD_PATH" ] && [ -d "$CD_PATH" ]; then
    GIT_COMMON_DIR=$(git -C "$CD_PATH" rev-parse --git-common-dir 2>/dev/null || echo "")
    GIT_DIR=$(git -C "$CD_PATH" rev-parse --git-dir 2>/dev/null || echo "")
    BRANCH=$(git -C "$CD_PATH" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  else
    GIT_COMMON_DIR=$(git rev-parse --git-common-dir 2>/dev/null || echo "")
    GIT_DIR=$(git rev-parse --git-dir 2>/dev/null || echo "")
    BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  fi

  if [ "$GIT_DIR" = "$GIT_COMMON_DIR" ] || [ "$GIT_DIR" = ".git" ]; then
    if [ "$BRANCH" = "main" ] || [ "$BRANCH" = "master" ] || [ "$BRANCH" = "develop" ]; then
      guard_respond "advisory" "コミット衛生ガード" "メインワークツリーの ${BRANCH} ブランチでの直接コミットはブロックされています。ブランチを作成して PR 経由でマージしてください。.claude/ の変更も含め、ワークツリーまたは別ブランチで作業してください。"
    fi
  fi
fi

# --- チェック 3: メインワークツリーでの git checkout (ブランチ切り替え) ---
if echo "$COMMAND_FOR_MATCH" | grep -qE 'git\s+checkout\s|git\s+switch\s'; then
  GIT_COMMON_DIR=$(git rev-parse --git-common-dir 2>/dev/null || echo "")
  GIT_DIR=$(git rev-parse --git-dir 2>/dev/null || echo "")

  if { [ "$GIT_DIR" = "$GIT_COMMON_DIR" ] || [ "$GIT_DIR" = ".git" ]; } && ! guard_is_trunk_direct; then
    ALLOW_PROTECTED_SWITCH=0
    if echo "$COMMAND_FOR_MATCH" | grep -qE 'git\s+(checkout|switch)\s+(develop|main|master)(\s|$|&|;)'; then
      if ! echo "$COMMAND_FOR_MATCH" | grep -qE 'git\s+(checkout|switch)\s+(develop|main|master)\s+--'; then
        ALLOW_PROTECTED_SWITCH=1
      fi
    fi
    if [ "$ALLOW_PROTECTED_SWITCH" -ne 1 ]; then
      guard_respond "advisory" "コミット衛生ガード" "メインワークツリーでの git checkout/switch はブロックされています。\`git worktree add\` でワークツリーを作成してください。未コミットの作業が消失するリスクがあります。（develop/main への切り替えは許可されています）"
    fi
  fi
fi

# --- チェック 4: main ブランチへの直接マージ防止（hotfix/* 除く） ---
if echo "$COMMAND_FOR_MATCH" | grep -qE 'git\s+(-C\s+\S+\s+)?merge\s' && ! guard_is_trunk_direct; then
  if ! echo "$COMMAND_FOR_MATCH" | grep -qE 'git\s+(-C\s+\S+\s+)?merge\s.*hotfix/'; then
    GIT_C_PATH=$(echo "$COMMAND" | sed -nE 's/.*git[[:space:]]+-C[[:space:]]+"([^"]+)".*/\1/p')
    if [ -z "$GIT_C_PATH" ]; then
      GIT_C_PATH=$(echo "$COMMAND" | sed -nE "s/.*git[[:space:]]+-C[[:space:]]+'([^']+)'.*/\1/p")
    fi
    if [ -z "$GIT_C_PATH" ]; then
      GIT_C_PATH=$(echo "$COMMAND" | sed -nE 's/.*git[[:space:]]+-C[[:space:]]+([^ "'"'"']+).*/\1/p')
    fi

    if [ -n "$GIT_C_PATH" ]; then
      CURRENT_BRANCH=$(git -C "$GIT_C_PATH" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    else
      CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    fi

    if [ "$CURRENT_BRANCH" = "main" ] || [ "$CURRENT_BRANCH" = "master" ]; then
      guard_respond "advisory" "ブランチ戦略ガード" "main への直接マージはブロックされています。develop 経由でマージしてください。hotfix の場合は hotfix/* ブランチを使用してください。"
    fi
  fi
fi

# --- チェック 4b: gh pr merge で main 向け PR のマージ防止（hotfix/* 除く） ---
if echo "$COMMAND_FOR_MATCH" | grep -qE '(^|&&|\|\||[;|])\s*gh\s+pr\s+merge' && ! guard_is_trunk_direct; then
  PR_NUM=$(echo "$COMMAND" | grep -oE '(^|&&|\|\||[;|])\s*gh[[:space:]]+pr[[:space:]]+merge[[:space:]]+([0-9]+)' | grep -oE '[0-9]+' | head -1)

  if [ -n "$PR_NUM" ]; then
    PR_VIEW_ARGS="$PR_NUM"
  else
    PR_VIEW_ARGS=""
  fi

  PR_INFO=$(gh pr view $PR_VIEW_ARGS --json baseRefName,headRefName 2>/dev/null || echo "")
  if [ -n "$PR_INFO" ]; then
    BASE_BRANCH=$(echo "$PR_INFO" | jq -r '.baseRefName // empty')
    HEAD_BRANCH=$(echo "$PR_INFO" | jq -r '.headRefName // empty')

    if [ "$BASE_BRANCH" = "main" ] || [ "$BASE_BRANCH" = "master" ]; then
      if ! echo "$HEAD_BRANCH" | grep -qE '^hotfix/|^chore/promote-main-|^develop$'; then
        guard_respond "advisory" "ブランチ戦略ガード" "${HEAD_BRANCH} → ${BASE_BRANCH} への PR マージはブロックされています。develop を経由してマージしてください。hotfix の場合は hotfix/* ブランチを使用してください。"
      fi
    fi
  fi
fi

# --- チェック 6: メインワークツリーでの git stash pop/apply ---
if echo "$COMMAND_FOR_MATCH" | grep -qE 'git\s+stash\s+(pop|apply)'; then
  GIT_COMMON_DIR=$(git rev-parse --git-common-dir 2>/dev/null || echo "")
  GIT_DIR=$(git rev-parse --git-dir 2>/dev/null || echo "")

  if { [ "$GIT_DIR" = "$GIT_COMMON_DIR" ] || [ "$GIT_DIR" = ".git" ]; } && ! guard_is_trunk_direct; then
    guard_respond "advisory" "コミット衛生ガード" "メインワークツリーでの git stash pop/apply はブロックされています。ワークツリー内で作業してください。"
  fi
fi

exit 0
