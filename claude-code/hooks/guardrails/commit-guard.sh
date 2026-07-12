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
_COMMIT_GUARD_TILDE_LITERAL=()
_COMMIT_GUARD_ADVISORY_OPS=()
_COMMIT_GUARD_ADVISORY_DIRS=()
_COMMIT_GUARD_ADVISORY_UNKNOWN=()
_COMMIT_GUARD_ADVISORY_DETAILS=()

_commit_guard_record_advisory() {
  local op="$1" git_dir="$2" context_unknown="$3" detail="${4:-}"
  local index="${#_COMMIT_GUARD_ADVISORY_OPS[@]}"
  _COMMIT_GUARD_ADVISORY_OPS[$index]="$op"
  _COMMIT_GUARD_ADVISORY_DIRS[$index]="$git_dir"
  _COMMIT_GUARD_ADVISORY_UNKNOWN[$index]="$context_unknown"
  _COMMIT_GUARD_ADVISORY_DETAILS[$index]="$detail"
}

_commit_guard_is_protected_switch() {
  local operation="$1" i="$2" count="${#_COMMIT_GUARD_TOKENS[@]}"
  if [ "$i" -ge "$count" ]; then
    return 1
  fi
  case "${_COMMIT_GUARD_TOKENS[$i]}" in
    main|master|develop) ;;
    *) return 1 ;;
  esac
  if [ $((i + 1)) -eq "$count" ]; then
    return 0
  fi
  # `git checkout <revision> -- <pathspec>` はbranch switchではなく復元操作。
  [ "$operation" = "checkout" ] \
    && [ "${_COMMIT_GUARD_TOKENS[$((i + 1))]}" = "--" ] \
    && [ $((i + 2)) -lt "$count" ]
}

_commit_guard_merge_is_hotfix() {
  local i="$1" count="${#_COMMIT_GUARD_TOKENS[@]}" token="" option_mode=1 saw_revision=0
  while [ "$i" -lt "$count" ]; do
    token="${_COMMIT_GUARD_TOKENS[$i]}"
    if [ "$option_mode" -eq 1 ]; then
      case "$token" in
        --) option_mode=0; i=$((i + 1)); continue ;;
        -m|--message|-s|--strategy|-X|--strategy-option|-F|--file|--cleanup|--into-name)
          i=$((i + 2))
          continue
          ;;
        -m?*|-s?*|-X?*|-F?*|--message=*|--strategy=*|--strategy-option=*|--file=*|--cleanup=*|--into-name=*|-*)
          i=$((i + 1))
          continue
          ;;
      esac
    fi
    saw_revision=1
    case "$token" in
      hotfix/*|refs/heads/hotfix/*) ;;
      *) return 1 ;;
    esac
    i=$((i + 1))
  done
  [ "$saw_revision" -eq 1 ]
}

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
  local j=0 cluster_len=0 force=0 delete=0 mirror=0 all_branches=0 repo_via_option=0 option_mode=1
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
        --all|--branches)
          all_branches=1
          i=$((i + 1))
          continue
          ;;
        --mirror)
          mirror=1
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

  if [ "$mirror" -eq 1 ]; then
    guard_respond "critical" "コミット衛生ガード" "--mirror は protected refs の force 更新・削除を含むためブロックされています。"
  fi

  if [ "$force" -eq 1 ] && [ "$all_branches" -eq 1 ]; then
    if [ -z "$git_dir" ] \
       || git -C "$git_dir" show-ref --verify --quiet refs/heads/main \
       || git -C "$git_dir" show-ref --verify --quiet refs/heads/master; then
      guard_respond "critical" "コミット衛生ガード" "--all/--branches による main/master を含む force push はブロックされています。"
    fi
  fi

  if [ "$force" -eq 1 ] && [ "${#positional[@]}" -le "$ref_start" ]; then
    if [ -n "$git_dir" ]; then
      current_branch=$(git -C "$git_dir" branch --show-current 2>/dev/null || echo "")
    else
      current_branch=""
    fi
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
      if|then|elif|else|while|until|for|select|do|time|'!'|'{')
        # guard_split_segments 後に command position へ残る shell reserved word。
        # その直後の git は条件・body として実行され得るため検査を続ける。
        i=$((i + 1))
        ;;
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
  local stripped="" segments="" outer="" segment="" token="" tilde_literal=0 count=0 i=0 subcommand="" git_index=""
  local base_dir="" active_dir="" git_dir="" path=""
  local ambiguous_context=0 context_unknown=0 k=0 detail="" action="" cd_index=-1

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
  if guard_has_control_flow_cwd_change "$stripped"; then
    ambiguous_context=1
    active_dir=""
  fi
  segments=$(guard_split_segments "$stripped")
  case "$stripped" in
    *'$('*|*'`'*)
      # split 済みの置換本体に加え、置換を 1 引数へ畳んだ外側も検査する。
      # これにより置換後方の --no-verify / --force を同じ git command として扱える。
      outer=$(guard_mask_command_substitutions "$stripped")
      segments="${segments}"$'\n'"$(guard_split_segments "$outer")"
      ;;
  esac

  while IFS= read -r segment; do
    _COMMIT_GUARD_TOKENS=()
    _COMMIT_GUARD_TILDE_LITERAL=()
    while IFS=$'\034' read -r tilde_literal token; do
      _COMMIT_GUARD_TOKENS[${#_COMMIT_GUARD_TOKENS[@]}]="$token"
      _COMMIT_GUARD_TILDE_LITERAL[${#_COMMIT_GUARD_TILDE_LITERAL[@]}]="$tilde_literal"
    done < <(guard_shell_tokens_expanding_env_split "$segment" tilde-meta)

    count=${#_COMMIT_GUARD_TOKENS[@]}
    if [ "$count" -eq 0 ]; then
      continue
    fi

    cd_index=$(guard_cd_command_index "$segment" 2>/dev/null || echo -1)
    if [ "$cd_index" -ge 0 ]; then
      i=$((cd_index + 1))
      while [ "$i" -lt "$count" ]; do
        token="${_COMMIT_GUARD_TOKENS[$i]}"
        case "$token" in
          -L|-P|-e|-@) i=$((i + 1)) ;;
          *) break ;;
        esac
      done
      if [ "$i" -lt "$count" ] && [ "${_COMMIT_GUARD_TOKENS[$i]}" = "--" ]; then
        i=$((i + 1))
      fi
      if [ "$i" -lt "$count" ]; then
        path="${_COMMIT_GUARD_TOKENS[$i]}"
        active_dir=$(_guard_resolve_directory "$active_dir" "$path" "${_COMMIT_GUARD_TILDE_LITERAL[$i]:-0}" 2>/dev/null || echo "")
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
            git_dir=$(_guard_resolve_directory "$git_dir" "${_COMMIT_GUARD_TOKENS[$((k + 1))]}" "${_COMMIT_GUARD_TILDE_LITERAL[$((k + 1))]:-0}" 2>/dev/null || echo "")
          else
            context_unknown=1
          fi
          k=$((k + 2))
          continue
          ;;
        --chdir=*)
          git_dir=$(_guard_resolve_directory "$git_dir" "${token#*=}" "${_COMMIT_GUARD_TILDE_LITERAL[$k]:-0}" 2>/dev/null || echo "")
          ;;
      esac
      k=$((k + 1))
    done

    # common policy resolver と同じ global option 分類で target/subcommand を得る。
    subcommand=""
    while [ "$i" -lt "$count" ]; do
      token="${_COMMIT_GUARD_TOKENS[$i]}"
      guard_classify_git_global_token "$token"
      case "$GUARD_GIT_GLOBAL_KIND" in
        cwd-value)
          if [ $((i + 1)) -lt "$count" ]; then
            git_dir=$(_guard_resolve_directory "$git_dir" "${_COMMIT_GUARD_TOKENS[$((i + 1))]}" "${_COMMIT_GUARD_TILDE_LITERAL[$((i + 1))]:-0}" 2>/dev/null || echo "")
          else
            git_dir=""
          fi
          i=$((i + 2))
          ;;
        cwd-attached)
          git_dir=$(_guard_resolve_directory "$git_dir" "$GUARD_GIT_GLOBAL_VALUE" "${_COMMIT_GUARD_TILDE_LITERAL[$i]:-0}" 2>/dev/null || echo "")
          i=$((i + 1))
          ;;
        context-value)
          context_unknown=1
          i=$((i + 2))
          ;;
        context-attached)
          context_unknown=1
          i=$((i + 1))
          ;;
        value) i=$((i + 2)) ;;
        flag) i=$((i + 1)) ;;
        subcommand)
          subcommand="$GUARD_GIT_GLOBAL_VALUE"
          i=$((i + 1))
          break
          ;;
        unknown)
          # 将来の global option が危険 subcommand を隠しても fail-open しない。
          context_unknown=1
          i=$((i + 1))
          while [ "$i" -lt "$count" ]; do
            token="${_COMMIT_GUARD_TOKENS[$i]}"
            case "$token" in
              commit|push|branch|checkout|switch|merge|stash)
                subcommand="$token"
                i=$((i + 1))
                break
                ;;
            esac
            i=$((i + 1))
          done
          break
          ;;
      esac
    done
    if [ -z "$subcommand" ]; then
      continue
    fi

    if [ "$context_unknown" -eq 1 ]; then
      git_dir=""
    fi

    detail=""
    case "$subcommand" in
      commit)
        _commit_guard_record_advisory "commit" "$git_dir" "$context_unknown"
        ;;
      checkout|switch)
        detail=0
        if _commit_guard_is_protected_switch "$subcommand" "$i"; then
          detail=1
        fi
        _commit_guard_record_advisory "$subcommand" "$git_dir" "$context_unknown" "$detail"
        ;;
      merge)
        detail=0
        if _commit_guard_merge_is_hotfix "$i"; then
          detail=1
        fi
        _commit_guard_record_advisory "merge" "$git_dir" "$context_unknown" "$detail"
        ;;
      stash)
        action="${_COMMIT_GUARD_TOKENS[$i]:-}"
        case "$action" in
          pop|apply) _commit_guard_record_advisory "stash-$action" "$git_dir" "$context_unknown" ;;
        esac
        ;;
    esac

    case "$subcommand" in
      commit) _commit_guard_check_commit_args "$i" ;;
      push)   _commit_guard_check_push_args "$i" "$git_dir" ;;
      branch) _commit_guard_check_branch_args "$i" ;;
    esac
  done <<< "$segments"
}

_commit_guard_check_universal_critical

# --- workflow advisory: parser が記録した各 git invocation を target repo 単位で判定 ---
if ! guard_is_trunk_direct; then
  ADVISORY_INDEX=0
  while [ "$ADVISORY_INDEX" -lt "${#_COMMIT_GUARD_ADVISORY_OPS[@]}" ]; do
    ADVISORY_OP="${_COMMIT_GUARD_ADVISORY_OPS[$ADVISORY_INDEX]}"
    ADVISORY_DIR="${_COMMIT_GUARD_ADVISORY_DIRS[$ADVISORY_INDEX]}"
    ADVISORY_UNKNOWN="${_COMMIT_GUARD_ADVISORY_UNKNOWN[$ADVISORY_INDEX]}"
    ADVISORY_DETAIL="${_COMMIT_GUARD_ADVISORY_DETAILS[$ADVISORY_INDEX]}"

    if [ "$ADVISORY_UNKNOWN" -eq 1 ] || [ -z "$ADVISORY_DIR" ]; then
      guard_respond "advisory" "コミット衛生ガード" "${ADVISORY_OP} の対象リポジトリを一意に確認できなかったため、安全のためブロックしました。"
    fi

    GIT_COMMON_DIR=$(git -C "$ADVISORY_DIR" rev-parse --git-common-dir 2>/dev/null || echo "")
    GIT_DIR=$(git -C "$ADVISORY_DIR" rev-parse --git-dir 2>/dev/null || echo "")
    BRANCH=$(git -C "$ADVISORY_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    if [ -z "$GIT_DIR" ] || [ -z "$GIT_COMMON_DIR" ]; then
      guard_respond "advisory" "コミット衛生ガード" "${ADVISORY_OP} の対象リポジトリを確認できなかったため、安全のためブロックしました。"
    fi

    case "$ADVISORY_OP" in
      commit)
        if { [ "$GIT_DIR" = "$GIT_COMMON_DIR" ] || [ "$GIT_DIR" = ".git" ]; } \
           && { [ "$BRANCH" = "main" ] || [ "$BRANCH" = "master" ] || [ "$BRANCH" = "develop" ]; }; then
          guard_respond "advisory" "コミット衛生ガード" "メインワークツリーの ${BRANCH} ブランチでの直接コミットはブロックされています。ブランチを作成して PR 経由でマージしてください。.claude/ の変更も含め、ワークツリーまたは別ブランチで作業してください。"
        fi
        ;;
      checkout|switch)
        if { [ "$GIT_DIR" = "$GIT_COMMON_DIR" ] || [ "$GIT_DIR" = ".git" ]; } \
           && [ "$ADVISORY_DETAIL" -ne 1 ]; then
          guard_respond "advisory" "コミット衛生ガード" "メインワークツリーでの git checkout/switch はブロックされています。\`git worktree add\` でワークツリーを作成してください。未コミットの作業が消失するリスクがあります。（develop/main への切り替えは許可されています）"
        fi
        ;;
      merge)
        if [ "$ADVISORY_DETAIL" -ne 1 ] && { [ "$BRANCH" = "main" ] || [ "$BRANCH" = "master" ]; }; then
          guard_respond "advisory" "ブランチ戦略ガード" "main への直接マージはブロックされています。develop 経由でマージしてください。hotfix の場合は hotfix/* ブランチを使用してください。"
        fi
        ;;
      stash-pop|stash-apply)
        if [ "$GIT_DIR" = "$GIT_COMMON_DIR" ] || [ "$GIT_DIR" = ".git" ]; then
          guard_respond "advisory" "コミット衛生ガード" "メインワークツリーでの git stash pop/apply はブロックされています。ワークツリー内で作業してください。"
        fi
        ;;
    esac
    ADVISORY_INDEX=$((ADVISORY_INDEX + 1))
  done
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

exit 0
