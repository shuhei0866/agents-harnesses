#!/usr/bin/env bash
# backlog-collect.sh - Collect backlog items from various sources
#
# Usage:
#   backlog-collect.sh <project-dir> [--source=auto|issues|auto+issues|<file>] [--label=tech-debt]
#
# Outputs JSON Lines to stdout. Logs/errors go to stderr.
set -euo pipefail

_escape_json() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

_collect_todos() {
  local project_dir="$1"
  local counter=0

  # grep for TODO, FIXME, HACK, XXX in source files
  # Exclude common non-source directories
  local grep_output
  grep_output="$(grep -rn --include='*.ts' --include='*.tsx' --include='*.js' --include='*.jsx' \
    --include='*.py' --include='*.rs' --include='*.go' --include='*.rb' --include='*.sh' \
    'TODO\|FIXME\|HACK\|XXX' "$project_dir" 2>/dev/null \
    | grep -v 'node_modules/' \
    | grep -v '.git/' \
    | grep -v 'dist/' \
    | grep -v 'build/' \
    || true)"

  if [[ -z "$grep_output" ]]; then
    return
  fi

  while IFS= read -r match; do
    counter=$((counter + 1))
    local file line_num text

    # Format: filepath:linenum:content
    file="$(echo "$match" | cut -d: -f1)"
    line_num="$(echo "$match" | cut -d: -f2)"
    text="$(echo "$match" | cut -d: -f3- | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')"

    # Make path relative to project dir
    file="${file#"$project_dir/"}"

    # Determine priority based on keyword
    local priority="low"
    if [[ "$text" == *FIXME* ]]; then
      priority="medium"
    elif [[ "$text" == *HACK* ]] || [[ "$text" == *XXX* ]]; then
      priority="medium"
    fi

    local escaped_text
    escaped_text="$(_escape_json "$text")"

    printf '{"id":"todo-%d","type":"todo","file":"%s","line":%s,"text":"%s","priority":"%s"}\n' \
      "$counter" "$(_escape_json "$file")" "$line_num" "$escaped_text" "$priority"
  done <<< "$grep_output"
}

_collect_lint_errors() {
  local project_dir="$1"
  local counter=0

  # Try pnpm lint with JSON format
  local lint_output
  if command -v pnpm &>/dev/null && [[ -f "$project_dir/package.json" ]]; then
    lint_output="$(cd "$project_dir" && pnpm lint --format json 2>/dev/null)" || true
  elif command -v npx &>/dev/null && [[ -f "$project_dir/package.json" ]]; then
    lint_output="$(cd "$project_dir" && npx eslint . --format json 2>/dev/null)" || true
  fi

  # Parse ESLint JSON output if available
  if [[ -n "${lint_output:-}" ]] && command -v jq &>/dev/null; then
    while IFS= read -r item; do
      counter=$((counter + 1))
      local file line_num text severity priority

      file="$(echo "$item" | jq -r '.file' 2>/dev/null)"
      file="${file#"$project_dir/"}"
      line_num="$(echo "$item" | jq -r '.line' 2>/dev/null)"
      text="$(echo "$item" | jq -r '.text' 2>/dev/null)"
      severity="$(echo "$item" | jq -r '.severity' 2>/dev/null)"

      priority="low"
      [[ "$severity" == "2" ]] && priority="medium"

      printf '{"id":"lint-%d","type":"lint","file":"%s","line":%s,"text":"%s","priority":"%s"}\n' \
        "$counter" "$(_escape_json "$file")" "$line_num" "$(_escape_json "$text")" "$priority"
    done < <(echo "$lint_output" | jq -r '
      .[] | select(.errorCount > 0 or .warningCount > 0) |
      .filePath as $file |
      .messages[] |
      {
        file: $file,
        line: .line,
        text: .ruleId,
        severity: .severity
      } | @json
    ' 2>/dev/null || true)
  fi
}

_collect_github_issues() {
  local project_dir="$1"
  local label="${2:-tech-debt}"

  if ! command -v gh &>/dev/null; then
    echo "Warning: gh CLI not found, skipping GitHub Issues" >&2
    return
  fi

  local issues_json
  issues_json="$(cd "$project_dir" && gh issue list --label "$label" --json number,title,body --limit 50 2>/dev/null)" || return 0

  if [[ -z "$issues_json" ]] || [[ "$issues_json" == "[]" ]]; then
    return
  fi

  while IFS= read -r item; do
    local number title
    number="$(echo "$item" | jq -r '.number' 2>/dev/null)"
    title="$(echo "$item" | jq -r '.title' 2>/dev/null)"

    printf '{"id":"issue-%s","type":"github","number":%s,"title":"%s","priority":"high"}\n' \
      "$number" "$number" "$(_escape_json "$title")"
  done < <(echo "$issues_json" | jq -r '.[] | @json' 2>/dev/null || true)
}

_collect_tsc_errors() {
  local project_dir="$1"
  local counter=0

  # Only run if npx is available and project has tsconfig
  if ! command -v npx &>/dev/null; then
    return
  fi
  if [[ ! -f "$project_dir/tsconfig.json" ]] && [[ ! -f "$project_dir/tsconfig.base.json" ]]; then
    # Also check for any tsconfig
    local has_tsconfig=false
    for f in "$project_dir"/tsconfig*.json; do
      [[ -f "$f" ]] && has_tsconfig=true && break
    done
    if ! $has_tsconfig; then
      return
    fi
  fi

  local tsc_output
  tsc_output="$(cd "$project_dir" && npx tsc --noEmit 2>&1)" || true

  if [[ -z "$tsc_output" ]]; then
    return
  fi

  # Parse lines like: src/foo.ts(10,5): error TS2322: Type 'string' is not ...
  while IFS= read -r line; do
    if [[ "$line" =~ ^(.+)\(([0-9]+),[0-9]+\):\ error\ (TS[0-9]+):\ (.+)$ ]]; then
      counter=$((counter + 1))
      local file="${BASH_REMATCH[1]}"
      local line_num="${BASH_REMATCH[2]}"
      local ts_code="${BASH_REMATCH[3]}"
      local message="${BASH_REMATCH[4]}"

      # Make path relative to project dir
      file="${file#"$project_dir/"}"

      local escaped_text
      escaped_text="$(_escape_json "$ts_code: $message")"

      printf '{"id":"tsc-%d","type":"tsc","file":"%s","line":%s,"text":"%s","priority":"high"}\n' \
        "$counter" "$(_escape_json "$file")" "$line_num" "$escaped_text"
    fi
  done <<< "$tsc_output"
}

_collect_from_file() {
  local filepath="$1"
  if [[ ! -f "$filepath" ]]; then
    echo "Error: backlog file not found: $filepath" >&2
    exit 1
  fi
  cat "$filepath"
}

_dedup_items() {
  # Remove duplicate items with same file + line combination.
  # When duplicates exist, keep the one with highest priority.
  # Input: JSON Lines from stdin
  # Output: Deduplicated JSON Lines to stdout
  local -A seen_keys=()
  local -a lines_data=()

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue

    # Extract file and line for dedup key
    local file_val line_val priority_val
    # Simple extraction without jq dependency
    file_val="$(echo "$line" | sed -n 's/.*"file":"\([^"]*\)".*/\1/p')"
    line_val="$(echo "$line" | sed -n 's/.*"line":\([0-9]*\).*/\1/p')"
    priority_val="$(echo "$line" | sed -n 's/.*"priority":"\([^"]*\)".*/\1/p')"

    local key="${file_val}:${line_val}"

    if [[ -n "${seen_keys[$key]+x}" ]]; then
      # Duplicate - keep the one with higher priority
      local existing_idx="${seen_keys[$key]}"
      local existing_priority
      existing_priority="$(echo "${lines_data[$existing_idx]}" | sed -n 's/.*"priority":"\([^"]*\)".*/\1/p')"

      local new_rank existing_rank
      new_rank="$(_priority_rank "$priority_val")"
      existing_rank="$(_priority_rank "$existing_priority")"

      if (( new_rank > existing_rank )); then
        lines_data[$existing_idx]="$line"
      fi
    else
      local idx="${#lines_data[@]}"
      seen_keys[$key]="$idx"
      lines_data+=("$line")
    fi
  done

  for item in "${lines_data[@]+"${lines_data[@]}"}"; do
    echo "$item"
  done
}

_priority_rank() {
  case "$1" in
    high) echo 3 ;;
    medium) echo 2 ;;
    low) echo 1 ;;
    *) echo 0 ;;
  esac
}

_sort_by_priority() {
  # Sort JSON Lines by priority: high > medium > low
  # Input: JSON Lines from stdin
  # Output: Sorted JSON Lines to stdout
  local -a high_items medium_items low_items

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    local priority_val
    priority_val="$(echo "$line" | sed -n 's/.*"priority":"\([^"]*\)".*/\1/p')"
    case "$priority_val" in
      high) high_items+=("$line") ;;
      medium) medium_items+=("$line") ;;
      *) low_items+=("$line") ;;
    esac
  done

  for item in "${high_items[@]+"${high_items[@]}"}"; do
    echo "$item"
  done
  for item in "${medium_items[@]+"${medium_items[@]}"}"; do
    echo "$item"
  done
  for item in "${low_items[@]+"${low_items[@]}"}"; do
    echo "$item"
  done
}

# --- Main ---
main() {
  local project_dir="${1:-.}"
  shift || true

  local source="auto"
  local label="tech-debt"
  local max_items=50

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --source=*)
        source="${1#--source=}"
        ;;
      --label=*)
        label="${1#--label=}"
        ;;
      --max-items=*)
        max_items="${1#--max-items=}"
        ;;
      *)
        echo "Unknown argument: $1" >&2
        exit 1
        ;;
    esac
    shift
  done

  project_dir="$(cd "$project_dir" && pwd)"

  local raw_output
  case "$source" in
    auto)
      raw_output="$(_collect_todos "$project_dir"; _collect_lint_errors "$project_dir"; _collect_tsc_errors "$project_dir")"
      ;;
    issues)
      raw_output="$(_collect_github_issues "$project_dir" "$label")"
      ;;
    auto+issues)
      raw_output="$(_collect_todos "$project_dir"; _collect_lint_errors "$project_dir"; _collect_tsc_errors "$project_dir"; _collect_github_issues "$project_dir" "$label")"
      ;;
    *)
      # Treat as file path
      raw_output="$(_collect_from_file "$source")"
      ;;
  esac

  if [[ -z "$raw_output" ]]; then
    return
  fi

  # Pipeline: dedup -> sort by priority -> limit to max_items
  echo "$raw_output" \
    | _dedup_items \
    | _sort_by_priority \
    | head -n "$max_items"
}

main "$@"
