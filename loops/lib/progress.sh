#!/usr/bin/env bash
# progress.sh - Progress file read/write utilities for claude-loop.sh
#
# Usage:
#   source lib/progress.sh
#   progress_init "converge" "/path/to/project" "/path/to/progress.txt"
#   progress_round_start 1
#   progress_round_end 1 '{"issues": 5, "fixed": 4, "skipped": 1}'
#   progress_get_prev_issues   # returns previous round's issue count
#   progress_summary           # prints final summary

_PROGRESS_FILE=""
_PROGRESS_MODE=""
_PROGRESS_PROJECT=""
_ROUND_START_TS=""

progress_init() {
  local mode="$1"
  local project="$2"
  local pfile="$3"

  _PROGRESS_MODE="$mode"
  _PROGRESS_PROJECT="$project"
  _PROGRESS_FILE="$pfile"

  mkdir -p "$(dirname "$pfile")"

  local now
  now="$(date -Iseconds 2>/dev/null || date +%Y-%m-%dT%H:%M:%S)"

  cat > "$pfile" <<EOF
# Claude Loop Progress
# Started: $now
# Mode: $mode
# Project: $project
EOF
}

progress_round_start() {
  local round="$1"
  _ROUND_START_TS="$(date +%s)"

  local now
  now="$(date -Iseconds 2>/dev/null || date +%Y-%m-%dT%H:%M:%S)"

  echo "" >> "$_PROGRESS_FILE"
  echo "## Round $round ($now)" >> "$_PROGRESS_FILE"
}

progress_round_end() {
  local round="$1"
  local result_json="$2"

  local now_ts
  now_ts="$(date +%s)"
  local duration=$(( now_ts - _ROUND_START_TS ))

  if [[ "$_PROGRESS_MODE" == "converge" ]]; then
    local issues fixed skipped
    issues="$(echo "$result_json" | _json_field "issues")"
    fixed="$(echo "$result_json" | _json_field "fixed")"
    skipped="$(echo "$result_json" | _json_field "skipped")"

    {
      echo "- Issues found: ${issues:-0}"
      echo "- Issues fixed: ${fixed:-0}"
      [[ -n "$skipped" && "$skipped" != "0" ]] && echo "- Issues skipped: $skipped"
      echo "- Duration: ${duration}s"

      if [[ "${issues:-0}" == "0" ]]; then
        echo "- Status: CONVERGED"
      fi
    } >> "$_PROGRESS_FILE"
  else
    # backlog mode
    local status summary
    status="$(echo "$result_json" | _json_field "status")"
    summary="$(echo "$result_json" | _json_field "summary")"

    {
      echo "- Status: ${status:-unknown}"
      [[ -n "$summary" ]] && echo "- Summary: $summary"
      echo "- Duration: ${duration}s"
    } >> "$_PROGRESS_FILE"
  fi
}

progress_get_prev_issues() {
  if [[ ! -f "$_PROGRESS_FILE" ]]; then
    echo "0"
    return
  fi

  local last_issues
  # grep -oP は PCRE の後読みを使うため BSD grep (macOS 標準) では動かない。
  # sed の BRE なら GNU と BSD の双方で同じ結果になる。
  last_issues="$(sed -n 's/.*Issues found:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$_PROGRESS_FILE" | tail -1)"
  echo "${last_issues:-0}"
}

progress_summary() {
  if [[ ! -f "$_PROGRESS_FILE" ]]; then
    echo "No progress file found."
    return
  fi

  local total_rounds
  total_rounds="$(grep -c '## Round' "$_PROGRESS_FILE" || true)"

  local final_status="INCOMPLETE"
  if grep -q "Status: CONVERGED" "$_PROGRESS_FILE"; then
    final_status="CONVERGED"
  elif grep -q "Status: INTERRUPTED" "$_PROGRESS_FILE"; then
    final_status="INTERRUPTED"
  fi

  echo "=== Loop Summary ==="
  echo "Total rounds: $total_rounds"
  echo "Final status: $final_status"
  echo "Progress file: $_PROGRESS_FILE"
}

progress_mark_interrupted() {
  if [[ -n "$_PROGRESS_FILE" && -f "$_PROGRESS_FILE" ]]; then
    echo "" >> "$_PROGRESS_FILE"
    echo "## INTERRUPTED" >> "$_PROGRESS_FILE"
    echo "- Status: INTERRUPTED" >> "$_PROGRESS_FILE"
    echo "- Time: $(date -Iseconds 2>/dev/null || date +%Y-%m-%dT%H:%M:%S)" >> "$_PROGRESS_FILE"
  fi
}

# Simple JSON field extractor (no jq dependency)
_json_field() {
  local field="$1"
  # Handles: "field": "value" and "field": number
  #
  # 値を囲む引用符の有無は \" ではなく \"* で表す。BRE の \? は GNU sed の
  # 拡張で、BSD sed (macOS 標準) はこれをリテラルの ? として扱うため、
  # 引用符つきの値がまったく取れなくなる。JSON の値を囲む引用符は 0 個か
  # 1 個しかないので、\"* に替えても GNU 側の挙動は変わらない。
  sed -n "s/.*\"$field\"[[:space:]]*:[[:space:]]*\"*\([^\",$}]*\)\"*.*/\1/p" | head -1
}
