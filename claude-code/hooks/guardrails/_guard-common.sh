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

# cd の効果範囲を逐次 segment として安全に追えない shell 構造なら 0 を返す。
guard_command_context_is_ambiguous() {
  local command="$1" stripped="" structure=""
  stripped=$(guard_strip_heredoc_bodies "$command")

  case "$stripped" in
    *'$('*|*'`'*) return 0 ;;
  esac

  structure=$(guard_sanitize_command "$stripped")
  case "$structure" in
    *"|"*|*"("*|*")"*) return 0 ;;
  esac
  structure=$(printf '%s\n' "$structure" | sed 's/&&//g')
  case "$structure" in
    *"&"*) return 0 ;;
  esac
  return 1
}

# command が実際に操作する repo を基準に GIT_WORKFLOW を再ロードする。
# - 明示的な環境変数（空・不正値を含む）は常に最優先
# - git -C / cd / hook input cwd を解決
# - 複数 repo が混在する場合は、全 target が trunk-direct の時だけ緩和
# - --repo / -R は local config に確実に対応付けられないため fail closed
guard_reload_git_workflow_for_command() {
  local command="$1" hook_cwd="${2:-}" base_dir="" active_dir=""
  local stripped="" segments="" segment="" rest="" path="" target_dir="" workflow=""
  local seen_target=0 all_trunk_direct=1 command_for_match=""

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

    case "$segment" in
      cd[[:space:]]*)
        rest="${segment#cd}"
        path=$(_guard_first_shell_arg "$rest" 2>/dev/null || echo "")
        active_dir=$(_guard_resolve_directory "$active_dir" "$path" 2>/dev/null || echo "")
        if [ -z "$active_dir" ]; then
          all_trunk_direct=0
        fi
        ;;
      git[[:space:]]*)
        seen_target=1
        target_dir="$active_dir"
        rest="${segment#git}"
        rest=$(printf '%s\n' "$rest" | sed -E 's/^[[:space:]]+//')
        case "$rest" in
          -C[[:space:]]*)
            rest="${rest#-C}"
            path=$(_guard_first_shell_arg "$rest" 2>/dev/null || echo "")
            target_dir=$(_guard_resolve_directory "$target_dir" "$path" 2>/dev/null || echo "")
            ;;
        esac
        workflow=$(_guard_git_workflow_from_dir "$target_dir")
        if [ "$workflow" != "trunk-direct" ]; then
          all_trunk_direct=0
        fi
        ;;
      gh[[:space:]]*)
        seen_target=1
        command_for_match=$(guard_sanitize_command "$segment")
        if echo "$command_for_match" | grep -qE '(^|[[:space:]])(--repo|-R)(=|[[:space:]])'; then
          all_trunk_direct=0
        else
          workflow=$(_guard_git_workflow_from_dir "$active_dir")
          if [ "$workflow" != "trunk-direct" ]; then
            all_trunk_direct=0
          fi
        fi
        ;;
      *)
        # command prefix や未対応構文に git/gh が含まれる場合、別 repo を見落として
        # 緩和しないよう target 不明として扱う。
        command_for_match=$(guard_sanitize_command "$segment")
        if echo "$command_for_match" | grep -qE '(^|[[:space:]])(git|gh)[[:space:]]'; then
          seen_target=1
          all_trunk_direct=0
        fi
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
# 空白に潰す。二重引用符内の ( ) ` はコマンド置換として実行され得るため分割する。
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
    BEGIN { SQ = sprintf("%c", 39) }
    {
      line = $0
      n = length(line)
      out = ""
      q = ""
      prev = ""
      for (i = 1; i <= n; i++) {
        c = substr(line, i, 1)
        if (q != "") {
          if (c == q && !(q == "\"" && prev == "\\")) {
            q = ""
            out = out c
          } else if (q == "\"" && (c == "(" || c == ")" || c == "`")) {
            out = out "\n"   # 二重引用符内でも $( ) や ` は実行される
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
            out = out "\n"
          } else if (c == "|") {
            if (mode == "pipeline") out = out c
            else out = out "\n"
          } else {
            out = out c
          }
        }
        prev = c
      }
      print out
    }
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
