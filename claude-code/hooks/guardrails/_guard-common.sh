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
_check_skip
_check_branch_context
