#!/usr/bin/env bash
# Tests for lib/progress.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"

PASS=0
FAIL=0
TMPDIR_TEST="$(mktemp -d)"

cleanup() {
  rm -rf "$TMPDIR_TEST"
}
trap cleanup EXIT

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc"
    echo "    expected: '$expected'"
    echo "    actual:   '$actual'"
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc"
    echo "    expected to contain: '$needle'"
    echo "    actual: '$haystack'"
    FAIL=$((FAIL + 1))
  fi
}

assert_file_exists() {
  local desc="$1" path="$2"
  if [[ -f "$path" ]]; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (file not found: $path)"
    FAIL=$((FAIL + 1))
  fi
}

# --- Test: progress_init creates file with header ---
test_progress_init() {
  echo "test_progress_init:"
  local pfile="$TMPDIR_TEST/init-test/progress.txt"

  source "$LIB_DIR/progress.sh"
  progress_init "converge" "/home/user/project" "$pfile"

  assert_file_exists "creates progress file" "$pfile"

  local content
  content="$(cat "$pfile")"
  assert_contains "has mode header" "Mode: converge" "$content"
  assert_contains "has project header" "Project: /home/user/project" "$content"
  assert_contains "has title" "# Claude Loop Progress" "$content"
}

# --- Test: progress_round_start writes round header ---
test_progress_round_start() {
  echo "test_progress_round_start:"
  local pfile="$TMPDIR_TEST/round-start/progress.txt"

  source "$LIB_DIR/progress.sh"
  progress_init "converge" "/tmp/proj" "$pfile"
  progress_round_start 1

  local content
  content="$(cat "$pfile")"
  assert_contains "has round header" "## Round 1" "$content"
}

# --- Test: progress_round_end appends results ---
test_progress_round_end() {
  echo "test_progress_round_end:"
  local pfile="$TMPDIR_TEST/round-end/progress.txt"

  source "$LIB_DIR/progress.sh"
  progress_init "converge" "/tmp/proj" "$pfile"
  progress_round_start 1
  progress_round_end 1 '{"issues": 5, "fixed": 4, "skipped": 1}'

  local content
  content="$(cat "$pfile")"
  assert_contains "has issues found" "Issues found: 5" "$content"
  assert_contains "has issues fixed" "Issues fixed: 4" "$content"
  assert_contains "has issues skipped" "Issues skipped: 1" "$content"
  assert_contains "has duration" "Duration:" "$content"
}

# --- Test: progress_get_prev_issues returns correct count ---
test_progress_get_prev_issues() {
  echo "test_progress_get_prev_issues:"
  local pfile="$TMPDIR_TEST/prev-issues/progress.txt"

  source "$LIB_DIR/progress.sh"
  progress_init "converge" "/tmp/proj" "$pfile"
  progress_round_start 1
  progress_round_end 1 '{"issues": 5, "fixed": 4, "skipped": 1}'

  local prev
  prev="$(progress_get_prev_issues)"
  assert_eq "returns previous issue count" "5" "$prev"
}

# --- Test: progress_get_prev_issues returns 0 when no rounds ---
test_progress_get_prev_issues_no_rounds() {
  echo "test_progress_get_prev_issues_no_rounds:"
  local pfile="$TMPDIR_TEST/prev-none/progress.txt"

  source "$LIB_DIR/progress.sh"
  progress_init "converge" "/tmp/proj" "$pfile"

  local prev
  prev="$(progress_get_prev_issues)"
  assert_eq "returns 0 when no rounds" "0" "$prev"
}

# --- Test: progress_summary outputs summary ---
test_progress_summary() {
  echo "test_progress_summary:"
  local pfile="$TMPDIR_TEST/summary/progress.txt"

  source "$LIB_DIR/progress.sh"
  progress_init "converge" "/tmp/proj" "$pfile"
  progress_round_start 1
  progress_round_end 1 '{"issues": 5, "fixed": 4, "skipped": 1}'
  progress_round_start 2
  progress_round_end 2 '{"issues": 0, "fixed": 0, "skipped": 0}'

  local summary
  summary="$(progress_summary)"
  assert_contains "shows total rounds" "Total rounds: 2" "$summary"
  assert_contains "shows final status" "CONVERGED" "$summary"
}

# --- Test: backlog mode round end ---
test_backlog_round_end() {
  echo "test_backlog_round_end:"
  local pfile="$TMPDIR_TEST/backlog/progress.txt"

  source "$LIB_DIR/progress.sh"
  progress_init "backlog" "/tmp/proj" "$pfile"
  progress_round_start 1
  progress_round_end 1 '{"status": "done", "summary": "Fixed TODO in foo.ts"}'

  local content
  content="$(cat "$pfile")"
  assert_contains "has status" "Status: done" "$content"
  assert_contains "has summary" "Summary: Fixed TODO in foo.ts" "$content"
}

# --- Test: _json_field handles the value shapes we actually emit ---
#
# ここが壊れると round_end の出力が丸ごと unknown / 0 になるが、上の
# assert_contains は「何が欠けたか」しか言わない。値の形ごとに直接あてる。
# BSD sed (macOS) が BRE の \? を解さず、引用符つきの値を 1 つも取れて
# いなかった回帰がここに当たる。
test_json_field_fixtures() {
  echo "test_json_field_fixtures:"

  source "$LIB_DIR/progress.sh"

  # 文字列値
  assert_eq "文字列値を取る" "done" \
    "$(echo '{"status": "done", "summary": "Fixed TODO in foo.ts"}' | _json_field "status")"
  assert_eq "空白を含む文字列値を取る" "Fixed TODO in foo.ts" \
    "$(echo '{"status": "done", "summary": "Fixed TODO in foo.ts"}' | _json_field "summary")"

  # 数値
  assert_eq "数値を取る" "5" \
    "$(echo '{"issues": 5, "fixed": 4, "skipped": 0}' | _json_field "issues")"
  assert_eq "0 を取る（空と区別する）" "0" \
    "$(echo '{"issues": 5, "fixed": 4, "skipped": 0}' | _json_field "skipped")"

  # 空値
  assert_eq "空文字列は空で返す" "" \
    "$(echo '{"status": "done", "summary": ""}' | _json_field "summary")"
  assert_eq "存在しないフィールドは空で返す" "" \
    "$(echo '{"status": "done"}' | _json_field "summary")"

  # 区切りの空白が無い形（LLM の出力は整形されているとは限らない）
  assert_eq "コロン前後に空白が無くても取る" "tight" \
    "$(echo '{"status":"done","summary":"tight"}' | _json_field "summary")"
}

# --- Run all tests ---
echo "=== progress.sh tests ==="
test_progress_init
test_progress_round_start
test_progress_round_end
test_progress_get_prev_issues
test_progress_get_prev_issues_no_rounds
test_progress_summary
test_backlog_round_end
test_json_field_fixtures

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] || exit 1
