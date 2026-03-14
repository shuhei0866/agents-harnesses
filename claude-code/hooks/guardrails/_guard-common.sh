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
_check_skip() {
  if [ -z "${GUARD_SKIP_LIST:-}" ]; then
    return
  fi

  # source 元スクリプトのファイル名（拡張子なし）を取得
  # BASH_SOURCE スタック: [0]=_guard-common.sh, [1]=_guard-common.sh(トップレベル呼び出し), [N]=呼び出し元
  # 最後の要素が source を実行したスクリプト
  local caller_script
  caller_script=$(basename "${BASH_SOURCE[${#BASH_SOURCE[@]}-1]}" .sh)

  # カンマ区切りリストをチェック
  IFS=',' read -ra SKIP_ARRAY <<< "$GUARD_SKIP_LIST"
  for skip_name in "${SKIP_ARRAY[@]}"; do
    if [ "$skip_name" = "$caller_script" ]; then
      exit 0
    fi
  done
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

# --- レスポンス出力 ---
# guard_respond severity tag message
#   severity: "critical" | "advisory"
#   tag: ガード名（ログ用）
#   message: deny 理由メッセージ
guard_respond() {
  local severity="$1"
  local tag="$2"
  local message="$3"

  if [ "$severity" = "critical" ]; then
    # critical は常に deny
    cat << DENY
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "[${tag}] ${message}"
  }
}
DENY
    exit 0
  fi

  # advisory: GUARD_LEVEL に従う
  if [ "${GUARD_LEVEL:-warn}" = "deny" ]; then
    cat << DENY
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "[${tag}] ${message}"
  }
}
DENY
    exit 0
  fi

  # warn: 警告のみ（実行は許可）
  cat << WARN
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "allow",
    "additionalContext": "[${tag}] WARNING: ${message}"
  }
}
WARN
  exit 0
}

# 初期化: source された時点で設定をロード
_load_guard_level
_load_guard_skip
_check_skip
