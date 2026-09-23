#!/usr/bin/env bash
# Tests for lib/backlog-collect.sh
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

assert_line_count() {
  local desc="$1" expected="$2" text="$3"
  local actual
  if [[ -z "$text" ]]; then
    actual=0
  else
    actual="$(echo "$text" | wc -l | tr -d ' ')"
  fi
  if [[ "$expected" == "$actual" ]]; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc"
    echo "    expected $expected lines, got $actual"
    echo "    content: '$text'"
    FAIL=$((FAIL + 1))
  fi
}

assert_valid_jsonl() {
  local desc="$1" text="$2"
  local valid=true
  while IFS= read -r line; do
    # Check each line has "id" and "type" fields (basic JSON structure check)
    if [[ ! "$line" =~ \"id\" ]] || [[ ! "$line" =~ \"type\" ]]; then
      valid=false
      break
    fi
  done <<< "$text"
  if $valid; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (invalid JSONL)"
    echo "    content: '$text'"
    FAIL=$((FAIL + 1))
  fi
}

# backlog-collect.sh の stderr は捨てない。以前は各テストが 2>/dev/null で
# 捨てていたので、bash 3.2 で起動できなかったとき（local: -A: invalid option）も
# set -e で黙って止まるだけで、原因がテストの出力から読めなかった (IAM-175)。

# --- Setup: create a fake project with TODOs ---
setup_todo_project() {
  local proj="$TMPDIR_TEST/todo-project"
  mkdir -p "$proj/src"
  cat > "$proj/src/foo.ts" <<'CODE'
// TODO: refactor this function
function foo() {
  return 42;
}

// FIXME: handle edge case
function bar() {
  return null;
}
CODE
  cat > "$proj/src/bar.ts" <<'CODE'
// HACK: temporary workaround
function baz() {
  return "hack";
}
CODE
  echo "$proj"
}

# --- Test: detects TODO/FIXME/HACK comments ---
test_todo_detection() {
  echo "test_todo_detection:"
  local proj
  proj="$(setup_todo_project)"

  local output
  output="$("$LIB_DIR/backlog-collect.sh" "$proj" --source=auto)"

  # Should find 3 items: TODO, FIXME, HACK
  assert_line_count "finds 3 TODO/FIXME/HACK items" "3" "$output"
  assert_contains "detects TODO" '"type":"todo"' "$output"
  assert_contains "detects FIXME in text" "FIXME" "$output"
  assert_contains "detects HACK in text" "HACK" "$output"
  assert_valid_jsonl "output is valid JSONL" "$output"
}

# --- Test: each line has required fields ---
test_todo_fields() {
  echo "test_todo_fields:"
  local proj
  proj="$(setup_todo_project)"

  local output
  output="$("$LIB_DIR/backlog-collect.sh" "$proj" --source=auto)"

  local first_line
  first_line="$(echo "$output" | head -1)"

  assert_contains "has id field" '"id"' "$first_line"
  assert_contains "has type field" '"type"' "$first_line"
  assert_contains "has file field" '"file"' "$first_line"
  assert_contains "has line field" '"line"' "$first_line"
  assert_contains "has text field" '"text"' "$first_line"
  assert_contains "has priority field" '"priority"' "$first_line"
}

# --- Test: empty project produces no output ---
test_empty_project() {
  echo "test_empty_project:"
  local proj="$TMPDIR_TEST/empty-project"
  mkdir -p "$proj/src"
  echo "// clean code" > "$proj/src/clean.ts"

  local output
  output="$("$LIB_DIR/backlog-collect.sh" "$proj" --source=auto)" || true

  assert_eq "empty project produces no output" "" "$output"
}

# --- Test: manual backlog file ---
test_manual_file() {
  echo "test_manual_file:"
  local proj="$TMPDIR_TEST/manual-project"
  mkdir -p "$proj"
  local backlog_file="$TMPDIR_TEST/backlog.jsonl"
  cat > "$backlog_file" <<'JSONL'
{"id":"manual-1","type":"manual","file":"src/x.ts","line":1,"text":"Fix this","priority":"high"}
{"id":"manual-2","type":"manual","file":"src/y.ts","line":5,"text":"Fix that","priority":"low"}
JSONL

  local output
  output="$("$LIB_DIR/backlog-collect.sh" "$proj" --source="$backlog_file")"

  assert_line_count "reads 2 items from manual file" "2" "$output"
  assert_contains "has manual-1" '"manual-1"' "$output"
  assert_contains "has manual-2" '"manual-2"' "$output"
}

# --- Test: TypeScript type errors collected via mock tsc ---
test_tsc_errors() {
  echo "test_tsc_errors:"
  local proj="$TMPDIR_TEST/tsc-project"
  mkdir -p "$proj/src"
  echo "// clean code" > "$proj/src/clean.ts"

  # Add tsconfig.json so tsc collection is triggered
  echo '{}' > "$proj/tsconfig.json"

  # Create a mock tsc that outputs fake errors
  local mock_bin="$TMPDIR_TEST/mock-bin"
  mkdir -p "$mock_bin"
  cat > "$mock_bin/npx" <<'MOCK'
#!/usr/bin/env bash
if [[ "$1" == "tsc" && "$2" == "--noEmit" ]]; then
  echo "src/foo.ts(10,5): error TS2322: Type 'string' is not assignable to type 'number'."
  echo "src/bar.ts(20,3): error TS7006: Parameter 'x' implicitly has an 'any' type."
  exit 1
fi
# fallback for other commands
exec /usr/bin/env npx "$@"
MOCK
  chmod +x "$mock_bin/npx"

  local output
  output="$(PATH="$mock_bin:$PATH" "$LIB_DIR/backlog-collect.sh" "$proj" --source=auto)"

  assert_contains "detects tsc error type" '"type":"tsc"' "$output"
  assert_contains "has TS2322 error" 'TS2322' "$output"
  assert_contains "has TS7006 error" 'TS7006' "$output"

  # tsc errors should be high priority
  local tsc_lines
  tsc_lines="$(echo "$output" | grep '"type":"tsc"' || true)"
  assert_contains "tsc errors are high priority" '"priority":"high"' "$tsc_lines"
}

# --- Test: priority sorting (high > medium > low) ---
test_priority_sort() {
  echo "test_priority_sort:"
  local proj="$TMPDIR_TEST/sort-project"
  mkdir -p "$proj/src"

  # Create files with TODO (low), FIXME (medium)
  cat > "$proj/src/mixed.ts" <<'CODE'
// TODO: low priority item
function a() { return 1; }
// FIXME: medium priority item
function b() { return 2; }
CODE

  # Add tsconfig.json so tsc collection is triggered
  echo '{}' > "$proj/tsconfig.json"

  # Create mock tsc for a high-priority type error
  local mock_bin="$TMPDIR_TEST/mock-bin-sort"
  mkdir -p "$mock_bin"
  cat > "$mock_bin/npx" <<'MOCK'
#!/usr/bin/env bash
if [[ "$1" == "tsc" && "$2" == "--noEmit" ]]; then
  echo "src/mixed.ts(5,1): error TS2322: Type error here."
  exit 1
fi
exec /usr/bin/env npx "$@"
MOCK
  chmod +x "$mock_bin/npx"

  local output
  output="$(PATH="$mock_bin:$PATH" "$LIB_DIR/backlog-collect.sh" "$proj" --source=auto)"

  # First line should be high priority, last should be low
  local first_line last_line
  first_line="$(echo "$output" | head -1)"
  last_line="$(echo "$output" | tail -1)"

  assert_contains "first item is high priority" '"priority":"high"' "$first_line"
  assert_contains "last item is low priority" '"priority":"low"' "$last_line"
}

# --- Test: deduplication (same file + same line) ---
test_dedup() {
  echo "test_dedup:"
  local proj="$TMPDIR_TEST/dedup-project"
  mkdir -p "$proj/src"

  # This file has TODO and FIXME on same line — unlikely in practice
  # but we'll use a manual backlog file approach to simulate duplicates
  # Better approach: mock tsc returning same file:line as a TODO
  cat > "$proj/src/dup.ts" <<'CODE'
// TODO: fix this thing
function a() { return 1; }
CODE

  # Add tsconfig.json so tsc collection is triggered
  echo '{}' > "$proj/tsconfig.json"

  # Mock tsc to return an error on the same file:line as the TODO
  local mock_bin="$TMPDIR_TEST/mock-bin-dedup"
  mkdir -p "$mock_bin"
  cat > "$mock_bin/npx" <<'MOCK'
#!/usr/bin/env bash
if [[ "$1" == "tsc" && "$2" == "--noEmit" ]]; then
  echo "src/dup.ts(1,1): error TS2322: Duplicate on same line."
  exit 1
fi
exec /usr/bin/env npx "$@"
MOCK
  chmod +x "$mock_bin/npx"

  local output
  output="$(PATH="$mock_bin:$PATH" "$LIB_DIR/backlog-collect.sh" "$proj" --source=auto)"

  # Should have exactly 1 item (deduplication removes the duplicate file:line)
  assert_line_count "dedup reduces to 1 item" "1" "$output"
  # 同じ行の TODO (low) と tsc (high) では、優先度の高い tsc が残る
  assert_contains "重複は優先度の高い方（tsc）を残す" '"type":"tsc"' "$output"
}

# --- Test: dedup treats only identical file:line keys as duplicates ---
# bash 3.2 には連想配列が無いので、_dedup_items は既出のキーを文字列照合で
# 探す (IAM-175)。部分一致や glob として一致すると、別の行を重複とみなして
# 捨ててしまう。紛れやすいキーの組を並べ、残る id とその並びをそのまま比べる。
test_dedup_exact_key() {
  echo "test_dedup_exact_key:"
  local proj="$TMPDIR_TEST/dedup-key-project"
  mkdir -p "$proj"
  local backlog_file="$TMPDIR_TEST/dedup-key.jsonl"
  cat > "$backlog_file" <<'JSONL'
{"id":"k1","type":"manual","file":"src/a.ts","line":10,"text":"a10","priority":"low"}
{"id":"k2","type":"manual","file":"src/a.ts","line":1,"text":"a1","priority":"low"}
{"id":"k3","type":"manual","file":"src/a.ts","line":1,"text":"a1 higher","priority":"high"}
{"id":"k4","type":"manual","file":"src/b.ts","line":2,"text":"b2","priority":"medium"}
{"id":"k5","type":"manual","file":"src/b.ts","line":2,"text":"b2 lower","priority":"low"}
{"id":"k6","type":"manual","file":"my file.ts","line":3,"text":"space in path","priority":"low"}
{"id":"k7","type":"manual","file":"file.ts","line":3,"text":"tail of k6 path","priority":"low"}
{"id":"k8","type":"manual","file":"app/d/page.tsx","line":1,"text":"plain","priority":"low"}
{"id":"k9","type":"manual","file":"app/[id]/page.tsx","line":1,"text":"brackets","priority":"low"}
JSONL

  local output
  output="$("$LIB_DIR/backlog-collect.sh" "$proj" --source="$backlog_file")"

  local ids
  ids="$(echo "$output" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p' | tr '\n' ' ')"
  # k2 は k3 (high) に負け、k5 は k4 (medium) に負ける。ほかは別のキーなので残る。
  # 並びは high → medium → low で、同じ優先度の中は入力の順
  assert_eq "同じ file:line だけを重複として扱う" "k3 k4 k1 k6 k7 k8 k9" "${ids% }"
}

# --- Test: --max-items limits output ---
test_max_items() {
  echo "test_max_items:"
  local proj="$TMPDIR_TEST/max-project"
  mkdir -p "$proj/src"

  # Create a file with many TODOs
  {
    for i in $(seq 1 10); do
      echo "// TODO: item $i"
      echo "function f$i() { return $i; }"
    done
  } > "$proj/src/many.ts"

  local output
  output="$("$LIB_DIR/backlog-collect.sh" "$proj" --source=auto --max-items=3)" || true

  assert_line_count "max-items=3 limits to 3 items" "3" "$output"
}

# --- Test: --max-items default is 50 ---
test_max_items_default() {
  echo "test_max_items_default:"
  local proj="$TMPDIR_TEST/max-default-project"
  mkdir -p "$proj/src"

  # Create a file with 60 TODOs
  {
    for i in $(seq 1 60); do
      echo "// TODO: item $i"
      echo "function f$i() { return $i; }"
    done
  } > "$proj/src/lots.ts"

  local output
  output="$("$LIB_DIR/backlog-collect.sh" "$proj" --source=auto)" || true

  assert_line_count "default max-items=50 limits to 50 items" "50" "$output"
}

# --- Run all tests ---
echo "=== backlog-collect.sh tests ==="
test_todo_detection
test_todo_fields
test_empty_project
test_manual_file
test_tsc_errors
test_priority_sort
test_dedup
test_dedup_exact_key
test_max_items
test_max_items_default

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] || exit 1
