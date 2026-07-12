#!/bin/bash
# _guard-common.sh: 全ガードスクリプト共通ライブラリ
#
# GUARD_LEVEL に基づいて deny / warn を制御する。
# - critical: GUARD_LEVEL に関係なく常に deny
# - advisory: GUARD_LEVEL=deny → deny, GUARD_LEVEL=warn → allow + additionalContext
#
# GUARD_SKIP でガード単位のスキップが可能。
# - harness.config に GUARD_SKIP="commit-guard,heredoc-guard" と書けば該当ガードを完全スキップ
# - guard_respond の tag（第2引数）ではなくスクリプトファイル名で判定
#
# 使い方:
#   source "$GUARD_COMMON"
#   guard_respond "advisory" "heredoc" "heredoc は使わないでください"

# source 後に config 値を GIT_WORKFLOW へ格納しても、明示的な環境変数と
# 取り違えないよう、初回ロード前の有無と値を保持する。
if [ "${_GUARD_GIT_WORKFLOW_ENV_CAPTURED:-0}" != "1" ]; then
  _GUARD_GIT_WORKFLOW_ENV_CAPTURED=1
  if [ "${GIT_WORKFLOW+x}" = "x" ]; then
    _GUARD_GIT_WORKFLOW_ENV_IS_SET=1
    _GUARD_GIT_WORKFLOW_ENV_VALUE="$GIT_WORKFLOW"
  else
    _GUARD_GIT_WORKFLOW_ENV_IS_SET=0
    _GUARD_GIT_WORKFLOW_ENV_VALUE=""
  fi
fi

# --- 設定ファイルの探索 ---
# 優先順位: harness.config > vdd.config（後方互換）
_find_config_file() {
  local config_file=""

  # harness.config を優先探索
  if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -f "$CLAUDE_PROJECT_DIR/.claude/harness.config" ]; then
    config_file="$CLAUDE_PROJECT_DIR/.claude/harness.config"
  else
    local project_root
    project_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
    if [ -n "$project_root" ] && [ -f "$project_root/.claude/harness.config" ]; then
      config_file="$project_root/.claude/harness.config"
    fi
  fi

  # harness.config が見つからなければ vdd.config にフォールバック（後方互換）
  if [ -z "$config_file" ]; then
    if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -f "$CLAUDE_PROJECT_DIR/.claude/vdd.config" ]; then
      config_file="$CLAUDE_PROJECT_DIR/.claude/vdd.config"
    else
      local project_root
      project_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
      if [ -n "$project_root" ] && [ -f "$project_root/.claude/vdd.config" ]; then
        config_file="$project_root/.claude/vdd.config"
      fi
    fi
  fi

  echo "$config_file"
}

# --- GUARD_LEVEL のロード ---
# 優先順位: 環境変数 GUARD_LEVEL > harness.config > デフォルト (warn)
_load_guard_level() {
  # 既に環境変数で設定済みならそれを使う
  if [ -n "${GUARD_LEVEL:-}" ]; then
    return
  fi

  local config_file
  config_file=$(_find_config_file)

  if [ -n "$config_file" ]; then
    local level
    level=$(grep -E '^GUARD_LEVEL=' "$config_file" 2>/dev/null | tail -1 | cut -d= -f2 | tr -d '"'"'" | tr -d '[:space:]')
    if [ -n "$level" ]; then
      GUARD_LEVEL="$level"
      return
    fi
  fi

  # デフォルト
  GUARD_LEVEL="warn"
}

# --- GUARD_SKIP のロード ---
# harness.config の GUARD_SKIP にカンマ区切りでスクリプト名を指定するとスキップ
# 例: GUARD_SKIP="commit-guard,heredoc-guard"
_load_guard_skip() {
  GUARD_SKIP_LIST=""

  # 環境変数で設定済みならそれを使う
  if [ -n "${GUARD_SKIP:-}" ]; then
    GUARD_SKIP_LIST="$GUARD_SKIP"
    return
  fi

  local config_file
  config_file=$(_find_config_file)

  if [ -n "$config_file" ]; then
    GUARD_SKIP_LIST=$(grep -E '^GUARD_SKIP=' "$config_file" 2>/dev/null | tail -1 | cut -d= -f2 | tr -d '"'"'" | tr -d '[:space:]')
  fi
}

# --- スキップ判定 ---
# 呼び出し元スクリプトのファイル名が GUARD_SKIP_LIST に含まれていれば exit 0
# ただし GUARD_FORCE_DENY_LIST に含まれる guard は skip 不可（force_deny が skip より優先）
_check_skip() {
  if [ -z "${GUARD_SKIP_LIST:-}" ]; then
    return
  fi

  # source 元スクリプトのファイル名（拡張子なし）を取得
  # BASH_SOURCE スタック: [0]=_guard-common.sh, [1]=_guard-common.sh(トップレベル呼び出し), [N]=呼び出し元
  # 最後の要素が source を実行したスクリプト
  local caller_script
  caller_script=$(basename "${BASH_SOURCE[${#BASH_SOURCE[@]}-1]}" .sh)

  # GUARD_FORCE_DENY に含まれる guard は skip 不可
  # 環境変数 GUARD_SKIP=worktree-guard 等で force_deny を回避できないようにする
  if [ -n "${GUARD_FORCE_DENY_LIST:-}" ]; then
    IFS=',' read -ra DENY_ARRAY <<< "$GUARD_FORCE_DENY_LIST"
    for deny_name in "${DENY_ARRAY[@]}"; do
      if [ "$deny_name" = "$caller_script" ]; then
        return
      fi
    done
  fi

  # カンマ区切りリストをチェック
  IFS=',' read -ra SKIP_ARRAY <<< "$GUARD_SKIP_LIST"
  for skip_name in "${SKIP_ARRAY[@]}"; do
    if [ "$skip_name" = "$caller_script" ]; then
      exit 0
    fi
  done
}

# --- GUARD_FORCE_DENY のロード ---
# harness.config の GUARD_FORCE_DENY にカンマ区切りでスクリプト名を指定すると、
# そのガードは advisory severity でも deny として扱う（GUARD_LEVEL=warn を上書き）
# 例: GUARD_FORCE_DENY="worktree-guard"
_load_guard_force_deny() {
  GUARD_FORCE_DENY_LIST=""

  # 環境変数で設定済みならそれを使う
  if [ -n "${GUARD_FORCE_DENY:-}" ]; then
    GUARD_FORCE_DENY_LIST="$GUARD_FORCE_DENY"
    return
  fi

  local config_file
  config_file=$(_find_config_file)

  if [ -n "$config_file" ]; then
    GUARD_FORCE_DENY_LIST=$(grep -E '^GUARD_FORCE_DENY=' "$config_file" 2>/dev/null | tail -1 | cut -d= -f2 | tr -d '"'"'" | tr -d '[:space:]')
  fi
}

# --- GIT_WORKFLOW のロード ---
# 優先順位: 環境変数 GIT_WORKFLOW > harness.config > 未設定
#
# 許可される値は呼び出し側で明示的に判定する。未設定・空文字・不正値は
# trunk-direct とみなさず、従来の安全側の挙動を維持する。
_load_git_workflow() {
  # 空文字や不正値を含め、環境変数が明示されていれば config へ fallback しない。
  if [ "${_GUARD_GIT_WORKFLOW_ENV_IS_SET:-0}" = "1" ]; then
    GIT_WORKFLOW="$_GUARD_GIT_WORKFLOW_ENV_VALUE"
    return
  fi

  GIT_WORKFLOW=""

  local config_file
  config_file=$(_find_config_file)

  if [ -n "$config_file" ]; then
    GIT_WORKFLOW=$(grep -E '^GIT_WORKFLOW=' "$config_file" 2>/dev/null | tail -1 | cut -d= -f2 | tr -d "\"'" | tr -d '[:space:]')
  fi
}

# trunk-direct だけが workflow 固有の制限を緩和する。
# worktree-pr・未設定・不正値はすべて false を返す。
guard_is_trunk_direct() {
  [ "${GIT_WORKFLOW:-}" = "trunk-direct" ]
}

# 指定ディレクトリが属する repo の GIT_WORKFLOW を出力する。
# config がない・repo でない場合は空文字を返す。
_guard_git_workflow_from_dir() {
  local dir="$1" repo_root="" config_file="" workflow=""

  if [ -z "$dir" ] || [ ! -d "$dir" ]; then
    return
  fi

  repo_root=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null || echo "")
  if [ -z "$repo_root" ]; then
    return
  fi

  if [ -f "$repo_root/.claude/harness.config" ]; then
    config_file="$repo_root/.claude/harness.config"
  elif [ -f "$repo_root/.claude/vdd.config" ]; then
    config_file="$repo_root/.claude/vdd.config"
  fi

  if [ -n "$config_file" ]; then
    workflow=$(grep -E '^GIT_WORKFLOW=' "$config_file" 2>/dev/null | tail -1 | cut -d= -f2 | tr -d "\"'" | tr -d '[:space:]')
  fi

  printf '%s\n' "$workflow"
}

# base を基準に path を実在ディレクトリへ解決する。
_guard_resolve_directory() {
  local base="$1" path="$2" candidate=""

  if [ -z "$path" ]; then
    return 1
  fi

  path="${path/#~/$HOME}"
  case "$path" in
    /*) candidate="$path" ;;
    *)  candidate="$base/$path" ;;
  esac

  if [ ! -d "$candidate" ]; then
    return 1
  fi

  (cd "$candidate" 2>/dev/null && pwd -P)
}

# shell の先頭引数を、single/double quote を外して取り出す。
# command context の path / repo selector 専用であり eval は行わない。
_guard_first_shell_arg() {
  local text="$1" value=""
  text=$(printf '%s\n' "$text" | sed -E 's/^[[:space:]]+//')

  case "$text" in
    \"*)
      value="${text#\"}"
      case "$value" in
        *\"*) value="${value%%\"*}" ;;
        *) return 1 ;;
      esac
      ;;
    \'*)
      value="${text#\'}"
      case "$value" in
        *\'*) value="${value%%\'*}" ;;
        *) return 1 ;;
      esac
      ;;
    *)
      value="${text%%[[:space:]]*}"
      ;;
  esac

  if [ -z "$value" ]; then
    return 1
  fi
  printf '%s\n' "$value"
}

# shell segment を quote-aware に引数へ分割し、1 token/line で出力する。
# 危険 option の判定で quoted option と message/value を区別するために使う。
guard_shell_tokens() {
  local segment="$1"
  printf '%s\n' "$segment" | awk '
    BEGIN { SQ = sprintf("%c", 39); q = ""; tok = ""; esc = 0; have = 0 }
    function emit() {
      if (have) print tok
      tok = ""; have = 0
    }
    {
      if (NR > 1) {
        if (q == "") emit()
        else { tok = tok "\n"; have = 1 }
      }
      for (i = 1; i <= length($0); i++) {
        c = substr($0, i, 1)
        if (q == SQ) {
          if (c == SQ) q = ""
          else { tok = tok c; have = 1 }
        } else if (q == "\"") {
          if (esc) { tok = tok c; have = 1; esc = 0 }
          else if (c == "\\") esc = 1
          else if (c == "\"") q = ""
          else { tok = tok c; have = 1 }
        } else if (esc) {
          tok = tok c; have = 1; esc = 0
        } else if (c == "\\") {
          esc = 1; have = 1
        } else if (c == SQ || c == "\"") {
          q = c; have = 1
        } else if (c ~ /[[:space:]]/) {
          emit()
        } else {
          tok = tok c; have = 1
        }
      }
    }
    END {
      if (esc) tok = tok "\\"
      emit()
    }
  '
}

# env -S/--split-string の static payload を argv と同様に展開して token 化する。
# command/sudo wrapper と nested env を扱い、動的 payload の policy 判定自体は
# guard_command_context_is_ambiguous が fail closed にする。
guard_shell_tokens_expanding_env_split() {
  local segment="$1" token="" base="" payload=""
  local i=0 count=0 option_index=-1 suffix_index=-1 k=0
  local -a tokens=() expanded=()

  while IFS= read -r token; do
    tokens[${#tokens[@]}]="$token"
  done < <(guard_shell_tokens "$segment")

  while :; do
    count=${#tokens[@]}
    option_index=-1
    suffix_index=-1
    payload=""
    i=0

    while [ "$i" -lt "$count" ]; do
      token="${tokens[$i]}"
      if [[ "$token" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
        i=$((i + 1))
        continue
      fi
      base="${token##*/}"
      case "$base" in
        command)
          i=$((i + 1))
          while [ "$i" -lt "$count" ]; do
            token="${tokens[$i]}"
            case "$token" in
              --) i=$((i + 1)); break ;;
              -p) i=$((i + 1)) ;;
              -*) i="$count"; break ;;
              *) break ;;
            esac
          done
          ;;
        sudo)
          i=$((i + 1))
          while [ "$i" -lt "$count" ]; do
            token="${tokens[$i]}"
            case "$token" in
              --) i=$((i + 1)); break ;;
              -u|-g|-h|-p|-C|-D|-T|-r|-t|-U|--user|--group|--host|--prompt|--chdir|--command-timeout|--role|--type|--other-user) i=$((i + 2)) ;;
              --*=*|-*) i=$((i + 1)) ;;
              *=*) i=$((i + 1)) ;;
              *) break ;;
            esac
          done
          ;;
        env)
          i=$((i + 1))
          while [ "$i" -lt "$count" ]; do
            token="${tokens[$i]}"
            case "$token" in
              -S|--split-string)
                if [ $((i + 1)) -lt "$count" ]; then
                  option_index="$i"
                  payload="${tokens[$((i + 1))]}"
                  suffix_index=$((i + 2))
                fi
                break
                ;;
              --split-string=*)
                option_index="$i"
                payload="${token#*=}"
                suffix_index=$((i + 1))
                break
                ;;
              -u|--unset|-C|--chdir) i=$((i + 2)) ;;
              --) i=$((i + 1)); break ;;
              --unset=*|--chdir=*|*=*|-*) i=$((i + 1)) ;;
              *) break ;;
            esac
          done
          break
          ;;
        *) break ;;
      esac
    done

    [ "$option_index" -ge 0 ] || break
    expanded=()
    k=0
    while [ "$k" -lt "$option_index" ]; do
      expanded[${#expanded[@]}]="${tokens[$k]}"
      k=$((k + 1))
    done
    while IFS= read -r token; do
      expanded[${#expanded[@]}]="$token"
    done < <(guard_shell_tokens "$payload")
    k="$suffix_index"
    while [ "$k" -lt "$count" ]; do
      expanded[${#expanded[@]}]="${tokens[$k]}"
      k=$((k + 1))
    done
    tokens=("${expanded[@]}")
  done

  if [ "${#tokens[@]}" -gt 0 ]; then
    for token in "${tokens[@]}"; do
      printf '%s\n' "$token"
    done
  fi
}

# shell segment が cwd を変更する cd invocation なら cd token の index を返す。
# quoted/concatenated builtin 名と `builtin -- cd` / `command -p -- cd` を扱い、
# `command -v/-V cd` の query mode は実行扱いにしない。
guard_cd_command_index() {
  local segment="$1" token="" base="" i=0 count=0
  local -a tokens=()
  while IFS= read -r token; do
    tokens[${#tokens[@]}]="$token"
  done < <(guard_shell_tokens "$segment")
  count=${#tokens[@]}
  [ "$count" -gt 0 ] || return 1

  base="${tokens[0]##*/}"
  if [ "$base" = "cd" ]; then
    printf '0\n'
    return 0
  fi

  if [ "$base" = "builtin" ]; then
    i=1
    if [ "$i" -lt "$count" ] && [ "${tokens[$i]}" = "--" ]; then
      i=$((i + 1))
    fi
    if [ "$i" -lt "$count" ] && [ "${tokens[$i]##*/}" = "cd" ]; then
      printf '%s\n' "$i"
      return 0
    fi
    return 1
  fi

  if [ "$base" = "command" ]; then
    i=1
    while [ "$i" -lt "$count" ]; do
      token="${tokens[$i]}"
      case "$token" in
        --) i=$((i + 1)); break ;;
        -p) i=$((i + 1)) ;;
        -*v*|-*V*) return 1 ;;
        -*) return 1 ;;
        *) break ;;
      esac
    done
    if [ "$i" -lt "$count" ] && [ "${tokens[$i]##*/}" = "cd" ]; then
      printf '%s\n' "$i"
      return 0
    fi
  fi
  return 1
}

# git global option の解釈を policy resolver と各 guard で共有する。
# 呼び出し後に GUARD_GIT_GLOBAL_KIND / VALUE を参照する。
guard_classify_git_global_token() {
  local token="$1"
  GUARD_GIT_GLOBAL_KIND=""
  GUARD_GIT_GLOBAL_VALUE=""

  case "$token" in
    -C)
      GUARD_GIT_GLOBAL_KIND="cwd-value"
      ;;
    -C?*)
      # Git の実装差を安全側に扱い、attached form も target として解釈する。
      GUARD_GIT_GLOBAL_KIND="cwd-attached"
      GUARD_GIT_GLOBAL_VALUE="${token#-C}"
      ;;
    -c|--namespace|--config-env)
      GUARD_GIT_GLOBAL_KIND="value"
      ;;
    -c?*|--namespace=*|--config-env=*)
      GUARD_GIT_GLOBAL_KIND="flag"
      ;;
    --git-dir|--work-tree)
      GUARD_GIT_GLOBAL_KIND="context-value"
      ;;
    --git-dir=*|--work-tree=*)
      GUARD_GIT_GLOBAL_KIND="context-attached"
      ;;
    --bare|-p|-P|--paginate|--no-pager|--no-replace-objects|--literal-pathspecs|--glob-pathspecs|--noglob-pathspecs|--icase-pathspecs|--no-optional-locks|--no-lazy-fetch|--no-advice|--exec-path=*|--super-prefix=*|--attr-source=*|--list-cmds=*)
      GUARD_GIT_GLOBAL_KIND="flag"
      ;;
    -*)
      GUARD_GIT_GLOBAL_KIND="unknown"
      ;;
    *)
      GUARD_GIT_GLOBAL_KIND="subcommand"
      GUARD_GIT_GLOBAL_VALUE="$token"
      ;;
  esac
}

# 指定した gh pr subcommand を実行する shell segment を1つ返す。
# gh root flag は gh の直後・pr の後・subcommand の後のどこでも許容されるため、
# regex ではなく token 列の最初の非 option command/group を追う。
guard_extract_gh_pr_segment() {
  local command="$1" expected_subcommand="$2" stripped="" segments="" segment=""
  local token="" base="" i=0 count=0 gh_index=-1 state=0 found=0
  local -a tokens=()

  stripped=$(guard_strip_heredoc_bodies "$command")
  segments=$(guard_split_segments "$stripped")
  while IFS= read -r segment; do
    tokens=()
    while IFS= read -r token; do
      tokens[${#tokens[@]}]="$token"
    done < <(guard_shell_tokens "$segment")
    count=${#tokens[@]}
    gh_index=-1
    i=0
    while [ "$i" -lt "$count" ]; do
      base="${tokens[$i]##*/}"
      if [ "$base" = "gh" ]; then
        gh_index="$i"
        break
      fi
      i=$((i + 1))
    done
    if [ "$gh_index" -lt 0 ]; then
      continue
    fi

    state=0
    i=$((gh_index + 1))
    while [ "$i" -lt "$count" ]; do
      token="${tokens[$i]}"
      case "$token" in
        --repo|-R|--hostname)
          i=$((i + 2))
          continue
          ;;
        --repo=*|-R=*|-R?*|--hostname=*|--help|-h|--version)
          i=$((i + 1))
          continue
          ;;
        -*)
          i=$((i + 1))
          continue
          ;;
      esac

      if [ "$state" -eq 0 ]; then
        if [ "$token" != "pr" ]; then
          break
        fi
        state=1
      else
        if [ "$token" = "$expected_subcommand" ]; then
          printf '%s\n' "$segment"
          found=1
          break
        fi
        break
      fi
      i=$((i + 1))
    done
  done <<< "$segments"
  [ "$found" -eq 1 ]
}

# gh command の explicit repository selector を quote-aware に抽出する。
# 対応形: --repo value / --repo=value / -R value / -R=value / -Rvalue
guard_extract_gh_repo_selector() {
  local command="$1" expected_subcommand="${2:-}" stripped="" segments="" segment="" token="" base=""
  local i=0 count=0 gh_index=-1 found=0 repo_selector="" matched_segment=""
  local env_options=0 expect_env_unset=0
  local -a tokens=()

  if [ -n "${GH_REPO:-}" ]; then
    found=1
    repo_selector="$GH_REPO"
  fi

  stripped=$(guard_strip_heredoc_bodies "$command")
  if [ -n "$expected_subcommand" ]; then
    matched_segment=$(guard_extract_gh_pr_segment "$stripped" "$expected_subcommand" 2>/dev/null || echo "")
    if [ -z "$matched_segment" ]; then
      return 1
    fi
    segments="$matched_segment"
  else
    segments=$(guard_split_segments "$stripped")
  fi
  while IFS= read -r segment; do
    tokens=()
    while IFS= read -r token; do
      tokens[${#tokens[@]}]="$token"
    done < <(guard_shell_tokens "$segment")
    count=${#tokens[@]}
    gh_index=-1
    i=0
    while [ "$i" -lt "$count" ]; do
      base="${tokens[$i]##*/}"
      if [ "$base" = "gh" ]; then
        gh_index="$i"
        break
      fi
      i=$((i + 1))
    done
    if [ "$gh_index" -lt 0 ]; then
      continue
    fi

    # command-local GH_REPO assignment は explicit selector と同じく扱う。
    # ただし env -u GH_REPO / env -i は実行時の ambient selector を消すため、
    # prefix を左から順に解釈して状態を反映する。
    i=0
    while [ "$i" -lt "$gh_index" ]; do
      token="${tokens[$i]}"
      if [ "$expect_env_unset" -eq 1 ]; then
        if [ "$token" = "GH_REPO" ]; then
          found=0
          repo_selector=""
        fi
        expect_env_unset=0
        i=$((i + 1))
        continue
      fi

      base="${token##*/}"
      if [ "$base" = "env" ]; then
        env_options=1
        i=$((i + 1))
        continue
      fi

      if [ "$env_options" -eq 1 ]; then
        case "$token" in
          -i|--ignore-environment|-)
            found=0
            repo_selector=""
            ;;
          -u|--unset)
            expect_env_unset=1
            ;;
          --unset=GH_REPO|-uGH_REPO)
            found=0
            repo_selector=""
            ;;
          --unset=*|-u?*)
            ;;
          GH_REPO=*)
            found=1
            repo_selector="${token#GH_REPO=}"
            ;;
          --)
            env_options=0
            ;;
          *=*|-*)
            ;;
          *)
            env_options=0
            ;;
        esac
      else
        case "$token" in
          GH_REPO=*)
            found=1
            repo_selector="${token#GH_REPO=}"
            ;;
        esac
      fi
      i=$((i + 1))
    done

    i=$((gh_index + 1))
    while [ "$i" -lt "$count" ]; do
      token="${tokens[$i]}"
      case "$token" in
        --)
          break
          ;;
        --body|--body-file|-b|-F|--subject|-t|--match-head-commit|--author|-A|--author-email)
          i=$((i + 2))
          continue
          ;;
        --body=*|--body-file=*|-b=*|-F=*|-F?*|--subject=*|-t=*|--match-head-commit=*|--author=*|-A=*|-A?*|--author-email=*)
          i=$((i + 1))
          continue
          ;;
        --repo|-R)
          found=1
          if [ $((i + 1)) -lt "$count" ]; then
            repo_selector="${tokens[$((i + 1))]}"
          fi
          i=$((i + 2))
          continue
          ;;
        --repo=*)
          found=1
          repo_selector="${token#--repo=}"
          i=$((i + 1))
          continue
          ;;
        -R=*)
          found=1
          repo_selector="${token#-R=}"
          i=$((i + 1))
          continue
          ;;
        -R?*)
          found=1
          repo_selector="${token#-R}"
          i=$((i + 1))
          continue
          ;;
      esac
      i=$((i + 1))
    done
    if [ "$found" -eq 1 ]; then
      printf '%s\n' "$repo_selector"
      return 0
    fi
  done <<< "$segments"
  return 1
}

# single quote 内の literal を除き、実行可能な `$()` / backtick があれば 0。
guard_has_executable_command_substitution() {
  local text="$1"
  text="${text//\\$'\n'/ }"
  printf '%s\n' "$text" | awk '
    BEGIN { SQ = sprintf("%c", 39); q = ""; found = 0 }
    function escaped(s, pos,    j, count) {
      count = 0
      for (j = pos - 1; j >= 1 && substr(s, j, 1) == "\\"; j--) count++
      return (count % 2) == 1
    }
    {
      line = $0
      for (i = 1; i <= length(line); i++) {
        c = substr(line, i, 1)
        nextc = (i < length(line)) ? substr(line, i + 1, 1) : ""
        if (q == SQ) {
          if (c == SQ) q = ""
          continue
        }
        if (c == SQ && q == "") {
          q = SQ
        } else if (c == "\"" && !escaped(line, i)) {
          if (q == "\"") q = ""
          else if (q == "") q = "\""
        } else if (c == "$" && nextc == "(" && !escaped(line, i)) {
          found = 1
          exit
        } else if (c == "`" && !escaped(line, i)) {
          found = 1
          exit
        }
      }
    }
    END { exit found ? 0 : 1 }
  '
}

# cd の効果範囲を逐次 segment として安全に追えない shell 構造なら 0 を返す。
guard_command_context_is_ambiguous() {
  local command="$1" stripped="" structure="" segments="" segment="" token="" base=""
  local i=0 count=0
  local -a tokens=()
  stripped=$(guard_strip_heredoc_bodies "$command")

  if guard_has_executable_command_substitution "$stripped"; then
    return 0
  fi

  structure=$(guard_sanitize_command "$stripped")
  case "$structure" in
    *"|"*|*"("*|*")"*) return 0 ;;
  esac
  structure=$(printf '%s\n' "$structure" | sed 's/&&//g')
  case "$structure" in
    *"&"*) return 0 ;;
  esac

  # directory stack と cwd-changing wrapper は全 guard で同じ target を安全に
  # 再現しにくいため、workflow を緩和せず fail closed にする。
  segments=$(guard_split_segments "$stripped")
  while IFS= read -r segment; do
    tokens=()
    while IFS= read -r token; do
      tokens[${#tokens[@]}]="$token"
    done < <(guard_shell_tokens "$segment")
    count=${#tokens[@]}
    i=0
    # 引数や message 内の単語ではなく、実際に実行される command position だけを
    # 追う。leading assignment と静的 wrapper は順に読み飛ばす。
    while [ "$i" -lt "$count" ]; do
      token="${tokens[$i]}"
      if [[ "$token" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
        case "$token" in
          GIT_DIR=*|GIT_WORK_TREE=*) return 0 ;;
        esac
        i=$((i + 1))
        continue
      fi

      base="${tokens[$i]##*/}"
      case "$base" in
        pushd|popd) return 0 ;;
        command)
          i=$((i + 1))
          while [ "$i" -lt "$count" ]; do
            token="${tokens[$i]}"
            case "$token" in
              --) i=$((i + 1)); break ;;
              -p) i=$((i + 1)) ;;
              -v|-V) i="$count"; break ;;
              -*) return 0 ;;
              *) break ;;
            esac
          done
          ;;
        builtin)
          i=$((i + 1))
          if [ "$i" -lt "$count" ] && [ "${tokens[$i]}" = "--" ]; then
            i=$((i + 1))
          fi
          ;;
        env)
          i=$((i + 1))
          while [ "$i" -lt "$count" ]; do
            token="${tokens[$i]}"
            case "$token" in
              -C|--chdir|-C?*|--chdir=*) return 0 ;;
              -S|--split-string|--split-string=*) return 0 ;;
              -u|--unset) i=$((i + 2)); continue ;;
              --unset=*) i=$((i + 1)); continue ;;
              --help|--version) i="$count"; break ;;
              --) i=$((i + 1)); break ;;
              GIT_DIR=*|GIT_WORK_TREE=*) return 0 ;;
              *=*) i=$((i + 1)); continue ;;
              -*) return 0 ;;
              *) break ;;
            esac
          done
          ;;
        sudo)
          i=$((i + 1))
          while [ "$i" -lt "$count" ]; do
            token="${tokens[$i]}"
            case "$token" in
              -D|--chdir|-D?*|--chdir=*) return 0 ;;
              -u|-g|-h|-p|-C|-T|-r|-t|-U|--user|--group|--host|--prompt|--command-timeout|--role|--type|--other-user)
                i=$((i + 2))
                continue
                ;;
              --*=*) i=$((i + 1)); continue ;;
              -A|-b|-E|-e|-H|-K|-k|-n|-P|-S|-V|-v) i=$((i + 1)); continue ;;
              --) i=$((i + 1)); break ;;
              *=*) i=$((i + 1)); continue ;;
              -*) return 0 ;;
              *) break ;;
            esac
          done
          ;;
        eval|source|.) return 0 ;;
        *) break ;;
      esac
    done
  done <<< "$segments"
  return 1
}

# command が実際に操作する repo を基準に GIT_WORKFLOW を再ロードする。
# - 明示的な環境変数（空・不正値を含む）は常に最優先
# - git -C / cd / hook input cwd を解決
# - 複数 repo が混在する場合は、全 target が trunk-direct の時だけ緩和
# - --repo / -R は local config に確実に対応付けられないため fail closed
guard_reload_git_workflow_for_command() {
  local command="$1" hook_cwd="${2:-}" base_dir="" active_dir=""
  local stripped="" segments="" segment="" path="" target_dir="" workflow="" token=""
  local seen_target=0 all_trunk_direct=1 i=0 token_count=0 command_index=0 command_base="" cd_index=-1
  local -a command_tokens=()

  if [ "${_GUARD_GIT_WORKFLOW_ENV_IS_SET:-0}" = "1" ]; then
    GIT_WORKFLOW="$_GUARD_GIT_WORKFLOW_ENV_VALUE"
    return
  fi

  if [ -n "$hook_cwd" ]; then
    base_dir=$(_guard_resolve_directory "$(pwd -P)" "$hook_cwd" 2>/dev/null || echo "")
  elif [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
    base_dir=$(_guard_resolve_directory "$(pwd -P)" "$CLAUDE_PROJECT_DIR" 2>/dev/null || echo "")
  else
    base_dir=$(pwd -P)
  fi

  if [ -z "$base_dir" ]; then
    GIT_WORKFLOW=""
    return
  fi
  active_dir="$base_dir"

  stripped=$(guard_strip_heredoc_bodies "$command")
  if guard_command_context_is_ambiguous "$stripped"; then
    GIT_WORKFLOW=""
    return
  fi

  segments=$(guard_split_segments "$stripped")

  while IFS= read -r segment; do
    segment=$(printf '%s\n' "$segment" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
    if [ -z "$segment" ]; then
      continue
    fi

    command_tokens=()
    while IFS= read -r token; do
      command_tokens[${#command_tokens[@]}]="$token"
    done < <(guard_shell_tokens "$segment")
    token_count=${#command_tokens[@]}
    if [ "$token_count" -eq 0 ]; then
      continue
    fi

    command_index=0
    command_base="${command_tokens[0]##*/}"
    cd_index=$(guard_cd_command_index "$segment" 2>/dev/null || echo -1)
    if [ "$cd_index" -ge 0 ]; then
      command_index="$cd_index"
      command_base="cd"
    else
      # cwd を変えない静的 wrapper と leading assignment を読み飛ばし、
      # config-based workflow でも実際の git/gh command を解決する。
      while [ "$command_index" -lt "$token_count" ]; do
        token="${command_tokens[$command_index]}"
        if [[ "$token" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
          case "$token" in
            GIT_DIR=*|GIT_WORK_TREE=*)
              seen_target=1
              all_trunk_direct=0
              command_index="$token_count"
              break
              ;;
          esac
          command_index=$((command_index + 1))
          continue
        fi
        command_base="${token##*/}"
        case "$command_base" in
          command)
            command_index=$((command_index + 1))
            while [ "$command_index" -lt "$token_count" ]; do
              token="${command_tokens[$command_index]}"
              case "$token" in
                --) command_index=$((command_index + 1)); break ;;
                -p) command_index=$((command_index + 1)) ;;
                -v|-V|-*) command_index="$token_count"; break ;;
                *) break ;;
              esac
            done
            ;;
          env)
            command_index=$((command_index + 1))
            while [ "$command_index" -lt "$token_count" ]; do
              token="${command_tokens[$command_index]}"
              case "$token" in
                --) command_index=$((command_index + 1)); break ;;
                -u|--unset|-S|--split-string) command_index=$((command_index + 2)) ;;
                --unset=*|--split-string=*) command_index=$((command_index + 1)) ;;
                --help|--version|-*) command_index="$token_count"; break ;;
                GIT_DIR=*|GIT_WORK_TREE=*)
                  seen_target=1
                  all_trunk_direct=0
                  command_index="$token_count"
                  break
                  ;;
                *=*) command_index=$((command_index + 1)) ;;
                *) break ;;
              esac
            done
            ;;
          *) break ;;
        esac
      done
      if [ "$command_index" -lt "$token_count" ]; then
        command_base="${command_tokens[$command_index]##*/}"
      else
        command_base=""
      fi
    fi

    case "$command_base" in
      cd)
        i=$((command_index + 1))
        while [ "$i" -lt "$token_count" ]; do
          token="${command_tokens[$i]}"
          case "$token" in
            --) i=$((i + 1)); break ;;
            -L|-P|-e|-@) i=$((i + 1)) ;;
            *) break ;;
          esac
        done
        path="${command_tokens[$i]:-}"
        active_dir=$(_guard_resolve_directory "$active_dir" "$path" 2>/dev/null || echo "")
        if [ -z "$active_dir" ]; then
          all_trunk_direct=0
        fi
        ;;
      git)
        seen_target=1
        target_dir="$active_dir"
        i=$((command_index + 1))
        while [ "$i" -lt "$token_count" ]; do
          token="${command_tokens[$i]}"
          guard_classify_git_global_token "$token"
          case "$GUARD_GIT_GLOBAL_KIND" in
            cwd-value)
              if [ $((i + 1)) -lt "$token_count" ]; then
                target_dir=$(_guard_resolve_directory "$target_dir" "${command_tokens[$((i + 1))]}" 2>/dev/null || echo "")
              else
                target_dir=""
              fi
              i=$((i + 2))
              ;;
            cwd-attached)
              target_dir=$(_guard_resolve_directory "$target_dir" "$GUARD_GIT_GLOBAL_VALUE" 2>/dev/null || echo "")
              i=$((i + 1))
              ;;
            value)
              i=$((i + 2))
              ;;
            flag)
              i=$((i + 1))
              ;;
            context-value|context-attached|unknown)
              target_dir=""
              all_trunk_direct=0
              break
              ;;
            subcommand)
              break
              ;;
          esac
        done
        workflow=$(_guard_git_workflow_from_dir "$target_dir")
        if [ "$workflow" != "trunk-direct" ]; then
          all_trunk_direct=0
        fi
        ;;
      gh)
        seen_target=1
        if guard_extract_gh_repo_selector "$segment" >/dev/null; then
          all_trunk_direct=0
        else
          workflow=$(_guard_git_workflow_from_dir "$active_dir")
          if [ "$workflow" != "trunk-direct" ]; then
            all_trunk_direct=0
          fi
        fi
        ;;
      *)
        # 未対応 prefix に git/gh が含まれる場合は target 不明として fail closed。
        i=0
        while [ "$i" -lt "$token_count" ]; do
          command_base="${command_tokens[$i]##*/}"
          if [ "$command_base" = "git" ] || [ "$command_base" = "gh" ]; then
            seen_target=1
            all_trunk_direct=0
            break
          fi
          i=$((i + 1))
        done
        ;;
    esac
  done <<< "$segments"

  if [ "$seen_target" -eq 1 ] && [ "$all_trunk_direct" -eq 1 ]; then
    GIT_WORKFLOW="trunk-direct"
  else
    GIT_WORKFLOW=""
  fi
}

# --- 呼び出し元 guard が GUARD_FORCE_DENY に含まれているか判定 ---
# 含まれていれば 0、それ以外は 1 を返す
_is_force_deny() {
  if [ -z "${GUARD_FORCE_DENY_LIST:-}" ]; then
    return 1
  fi

  local caller_script
  caller_script=$(basename "${BASH_SOURCE[${#BASH_SOURCE[@]}-1]}" .sh)

  IFS=',' read -ra DENY_ARRAY <<< "$GUARD_FORCE_DENY_LIST"
  for deny_name in "${DENY_ARRAY[@]}"; do
    if [ "$deny_name" = "$caller_script" ]; then
      return 0
    fi
  done
  return 1
}

# --- コマンドサニタイズ ---
# 引用符内・heredoc 内・コマンド置換内のテキストをプレースホルダーに置換し、
# 実際のコマンド部分のみを残す。誤検出防止用。
#
# 使い方:
#   SANITIZED=$(guard_sanitize_command "$COMMAND")
#   echo "$SANITIZED" | grep -qE 'terraform\s+apply' && ...
guard_sanitize_command() {
  local cmd="$1"
  echo "$cmd" \
    | sed -E "s/\"[^\"]*\"/_Q_/g; s/'[^']*'/_Q_/g" \
    | sed -E 's/\$\([^)]*\)/_SUBST_/g' \
    | sed 's/<<[[:space:]]*'\''*[A-Za-z_]*'\''*//g'
}

# --- heredoc 本文の除去 ---
# guard_sanitize_command は heredoc のマーカー（<<EOF）しか剥がせず、複数行コマンド
# では本文行がそのまま残って誤検出の原因になる（例: gh issue create --body の説明文に
# 書かれた rm -rf に destructive-guard が反応する）。データとして流し込まれる本文行を
# 落とし、実際に実行されるコマンド行だけを返す。
#
# 誤判定を避けるための規則:
#   - 引用符の内側にある << は opener と見なさない（'see <<EOF usage' 等の言及）
#   - here-string（<<<）と、直前が英数字の << （$((a<<b)) 等のシフト演算）は除外する
#   - 本文をシェルとして実行する heredoc（bash <<EOF、ssh host <<EOF 等）は
#     本文がコードなので落とさず、後続ガードの検査対象に残す
#   - タブ字下げされた終端行を認めるのは <<- の場合のみ（素の << では本文扱い）
#
# 制約: cat<<EOF のような空白なし連結は opener と認識しない。その場合は本文が
# 残る側（検出漏れではなく誤警告側）に倒れる。
#
# 使い方:
#   STRIPPED=$(guard_strip_heredoc_bodies "$COMMAND")
guard_strip_heredoc_bodies() {
  local cmd="$1"
  printf '%s\n' "$cmd" | awk '
    # pos の位置が引用符の内側かを判定する。$( ) の内側では引用符文脈が
    # リセットされる（"--body \"$(cat <<EOF ...)\"" の heredoc は引用外）ため、
    # コマンド置換をスタックで追跡する
    function in_quotes(s, pos,   i, c, nc, q, prev, depth, qs) {
      q = ""; prev = ""; depth = 0
      for (i = 1; i < pos; i++) {
        c = substr(s, i, 1)
        nc = (i < pos - 1) ? substr(s, i + 1, 1) : ""
        if (q == SQ) {
          if (c == SQ) q = ""
        } else if (q == "\"") {
          if (c == "\"" && prev != "\\") q = ""
          else if (c == "$" && nc == "(") { qs[depth] = q; depth++; q = ""; i++ }
        } else {
          if (c == SQ) q = SQ
          else if (c == "\"") q = "\""
          else if (c == "$" && nc == "(") { qs[depth] = q; depth++; q = ""; i++ }
          else if (c == ")" && depth > 0) { depth--; q = qs[depth] }
        }
        prev = c
      }
      return (q != "")
    }
    BEGIN {
      SQ = sprintf("%c", 39)
      opener  = "<<-?[ \t]*[\"" SQ "]?\\\\?[A-Za-z_][A-Za-z_0-9]*[\"" SQ "]?"
      quotes  = "[\"" SQ "\\\\]"
      execcmd = "(^|[|;&[:space:]])(bash|sh|zsh|ksh|dash|eval|ssh|sudo)([[:space:]]|$)"
    }
    skip == 1 {
      line = $0
      if (dash) sub(/^\t+/, "", line)
      if (line == term) { skip = 0 }
      next
    }
    {
      det = $0
      gsub(/<<</, "_HS_", det)
      if (match(det, opener)) {
        ok = 1
        # 引用符の内側は opener ではない
        if (in_quotes(det, RSTART)) ok = 0
        # 直前が英数字等ならシフト演算・連結（cat<<EOF）であり opener 扱いしない
        if (ok && RSTART > 1) {
          pc = substr(det, RSTART - 1, 1)
          if (pc ~ /[A-Za-z0-9_$)]/) ok = 0
        }
        if (ok) {
          m = substr(det, RSTART, RLENGTH)
          dash = (m ~ /^<<-/) ? 1 : 0
          sub(/<<-?[ \t]*/, "", m)
          gsub(quotes, "", m)
          term = m
          if (det !~ execcmd) skip = 1
        }
      }
      print
    }
  '
}

# --- 引用符を意識したセグメント分割 ---
# コマンドを「コマンド先頭位置の判定ができる単位」に分割する。引用符の外にある
# ; & | ( ) ` を改行に置き換え、引用符の中では実行され得ない区切り（; & |）を
# 空白に潰す。二重引用符内は `$(` と対応する `)`、backtick だけを
# コマンド置換として分割し、literal な括弧は引数データとして保持する。
# backslash + 改行の行継続は先に結合する。
#
# mode:
#   full     — | でも分割する（コマンド先頭位置の判定用。デフォルト）
#   pipeline — | では分割しない（パイプ隣接の判定用。xargs 等 stdin 越しの検査に使う）
#
# 使い方:
#   SEGS=$(guard_split_segments "$STRIPPED")
#   PIPE_SEGS=$(guard_split_segments "$STRIPPED" pipeline)
guard_split_segments() {
  local text="$1" mode="${2:-full}"
  text="${text//\\$'\n'/ }"
  printf '%s\n' "$text" | awk -v mode="$mode" '
    BEGIN { SQ = sprintf("%c", 39); q = ""; out = ""; prev = ""; cmdsub = 0 }
    function flush() {
      print out
      out = ""
      prev = ""
    }
    {
      if (NR > 1) {
        if (q != "") out = out " "
        else flush()
        prev = ""
      }
      line = $0
      n = length(line)
      for (i = 1; i <= n; i++) {
        c = substr(line, i, 1)
        if (q != "") {
          if (c == q && !(q == "\"" && prev == "\\")) {
            q = ""
            out = out c
          } else if (q == "\"" && c == "(" && prev == "$") {
            flush()
            cmdsub++          # `$(` の開始だけを実行境界として扱う
          } else if (q == "\"" && c == ")" && cmdsub > 0) {
            flush()
            cmdsub--
          } else if (q == "\"" && c == "`" && prev != "\\") {
            flush()           # backtick command substitution
          } else if (c == ";" || c == "&" || c == "|") {
            out = out " "    # 引用符内の区切り文字は実行されない
          } else {
            out = out c
          }
        } else {
          if (c == "\"" || c == SQ) {
            q = c
            out = out c
          } else if (c == ";" || c == "(" || c == ")" || c == "`" || c == "&") {
            flush()
          } else if (c == "|") {
            if (mode == "pipeline") out = out c
            else flush()
          } else {
            out = out c
          }
        }
        prev = c
      }
    }
    END { flush() }
  '
}

# コマンド置換の本体だけを placeholder に置き換え、置換の外側にある引数列を
# 保持する。guard_split_segments は置換本体の検査に使い、この出力は
# `git ... "$(...)" --no-verify` のような外側の critical option 検査に使う。
guard_mask_command_substitutions() {
  local text="$1"
  text="${text//\\$'\n'/ }"
  printf '%s\n' "$text" | awk '
    BEGIN { SQ = sprintf("%c", 39); out = ""; outer_q = ""; mode = ""; depth = 0; sub_q = ""; sub_bt = 0 }
    function escaped(s, pos,    j, count) {
      count = 0
      for (j = pos - 1; j >= 1 && substr(s, j, 1) == "\\"; j--) count++
      return (count % 2) == 1
    }
    {
      if (NR > 1 && mode == "") out = out " "
      line = $0
      n = length(line)
      for (i = 1; i <= n; i++) {
        c = substr(line, i, 1)
        nextc = (i < n) ? substr(line, i + 1, 1) : ""

        if (mode == "bt") {
          if (c == "`" && !escaped(line, i)) mode = ""
          continue
        }

        if (mode == "dollar") {
          if (sub_bt) {
            if (c == "`" && !escaped(line, i)) sub_bt = 0
            continue
          }
          if (sub_q != "") {
            if (c == sub_q && !(sub_q == "\"" && escaped(line, i))) sub_q = ""
            continue
          }
          if (c == SQ) {
            sub_q = SQ
          } else if (c == "\"") {
            sub_q = "\""
          } else if (c == "`" && !escaped(line, i)) {
            sub_bt = 1
          } else if (c == "(" && !escaped(line, i)) {
            depth++
          } else if (c == ")" && !escaped(line, i)) {
            depth--
            if (depth == 0) mode = ""
          }
          continue
        }

        if (outer_q == SQ) {
          out = out c
          if (c == SQ) outer_q = ""
          continue
        }

        if (c == "$" && nextc == "(" && !escaped(line, i)) {
          out = out "_SUBST_"
          mode = "dollar"
          depth = 1
          sub_q = ""
          sub_bt = 0
          i++
        } else if (c == "`" && !escaped(line, i)) {
          out = out "_SUBST_"
          mode = "bt"
        } else {
          out = out c
          if (c == SQ && outer_q == "") outer_q = SQ
          else if (c == "\"" && !escaped(line, i)) {
            if (outer_q == "\"") outer_q = ""
            else if (outer_q == "") outer_q = "\""
          }
        }
      }
    }
    END { print out }
  '
}

# --- レスポンス出力 ---
# guard_respond severity tag message
#   severity: "critical" | "advisory"
#   tag: ガード名（ログ用）
#   message: deny 理由メッセージ
guard_respond() {
  local severity="$1"
  local tag="$2"
  local message="$3"

  # メッセージ中の literal な \n（2 文字）は改行の慣行として使われてきたため、
  # 実際の改行に変換してから JSON エンコードに渡す
  message="${message//'\n'/$'\n'}"

  local decision
  if [ "$severity" = "critical" ] || [ "${GUARD_LEVEL:-warn}" = "deny" ] || _is_force_deny; then
    decision="deny"
  else
    decision="allow"
    message="WARNING: ${message}"
  fi

  # JSON 破壊防止: 補間値（branch 名等）に二重引用符やバックスラッシュが含まれると
  # 手書き JSON では応答自体が parse 不能になり、deny が hook エラーに化けて実行が
  # 通ってしまう。jq に組ませて常に valid JSON を返す
  if command -v jq &>/dev/null; then
    if [ "$decision" = "deny" ]; then
      jq -n --arg reason "[${tag}] ${message}" \
        '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}'
    else
      jq -n --arg ctx "[${tag}] ${message}" \
        '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "allow", additionalContext: $ctx}}'
    fi
    exit 0
  fi

  # jq が無い環境向けフォールバック（補間値が単純な場合のみ正しい）
  if [ "$decision" = "deny" ]; then
    cat << DENY
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "[${tag}] ${message}"
  }
}
DENY
  else
    cat << WARN
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "allow",
    "additionalContext": "[${tag}] ${message}"
  }
}
WARN
  fi
  exit 0
}

# --- ブランチベースの動的スキップ ---
# release/* ブランチ以外では release 系ガードをスキップ
# main/develop 以外のブランチでは一部ガードを緩和
_check_branch_context() {
  local caller_script
  caller_script=$(basename "${BASH_SOURCE[${#BASH_SOURCE[@]}-1]}" .sh)

  local current_branch
  current_branch=$(git branch --show-current 2>/dev/null || echo "")

  # pr-merge-ready-guard は release/* ブランチでのみ意味がある
  if [ "$caller_script" = "pr-merge-ready-guard" ]; then
    if [[ ! "$current_branch" =~ ^release/ ]]; then
      exit 0
    fi
  fi
}

# 初期化: source された時点で設定をロード
_load_guard_level
_load_guard_skip
_load_guard_force_deny
_load_git_workflow
_check_skip
_check_branch_context
