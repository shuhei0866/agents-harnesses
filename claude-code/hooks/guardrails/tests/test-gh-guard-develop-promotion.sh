#!/usr/bin/env bash
# Tests for guardrails/gh-guard.sh — develop を持たない repo の main 向けマージ
#
# gh-guard は「develop → main の昇格は人間が行う」運用を前提にしている。develop を
# 持たない repo では feature → main が唯一の経路なので、その前提は成立しない。
# ここでは develop の有無で警告が出分かれること、判定できないときは従来どおり
# 警告側へ倒れること（fail closed）を固定する。
#
# gh は PATH 先頭の mock で差し替え、MOCK_DEVELOP で挙動を切り替える:
#   exists:  branches/develop が 200 を返す（develop あり）
#   missing: branches/develop が 404 を返す（develop なし）
#   error:   通信断（判定不能）
# PR の base は常に main を返す。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/../gh-guard.sh"

PASS=0
FAIL=0
TMPDIR_TEST="$(mktemp -d)"

cleanup() {
  rm -rf "$TMPDIR_TEST"
}
trap cleanup EXIT

# --- mock gh ---
mkdir -p "$TMPDIR_TEST/bin"
cat > "$TMPDIR_TEST/bin/gh" << 'MOCK'
#!/bin/bash
# gh pr view ... --json baseRefName  → main
# gh api repos/<owner>/<repo>/branches/develop --jq .name → MOCK_DEVELOP 次第
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "view" ]; then
  printf 'main\n'
  exit 0
fi
if [ "${1:-}" = "api" ]; then
  case "${MOCK_DEVELOP:-exists}" in
    exists)  printf 'develop\n'; exit 0 ;;
    missing) echo 'gh: Not Found (HTTP 404)' >&2; exit 1 ;;
    error)   echo 'error connecting to api.github.com' >&2; exit 1 ;;
  esac
fi
exit 0
MOCK
chmod +x "$TMPDIR_TEST/bin/gh"

# --- current branch 解決用の fake git repo ---
git init -q "$TMPDIR_TEST/repo"
git -C "$TMPDIR_TEST/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

OUT=""
ERR=""
STATUS=0
run_guard() {
  local develop="$1" cmd="$2"
  local errf="$TMPDIR_TEST/stderr"
  OUT=$( (cd "$TMPDIR_TEST" && jq -n --arg c "$cmd" --arg cwd "$TMPDIR_TEST/repo" '{tool_input:{command:$c}, cwd:$cwd}' \
    | env -u CLAUDE_PROJECT_DIR -u GUARD_SKIP -u GUARD_LEVEL -u GUARD_FORCE_DENY -u GIT_WORKFLOW -u CLAUDE_CLOUD \
        PATH="$TMPDIR_TEST/bin:$PATH" MOCK_DEVELOP="$develop" bash "$GUARD" 2>"$errf") )
  STATUS=$?
  ERR=$(cat "$errf" 2>/dev/null || echo "")
}

assert_warn() {
  local desc="$1"
  if [ "$STATUS" -eq 0 ] && [ -z "$ERR" ] \
     && echo "$OUT" | jq -e '.hookSpecificOutput.additionalContext | test("WARNING")' >/dev/null 2>&1; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc"
    echo "    expected: warn（exit 0・stderr 無し・additionalContext に WARNING）"
    echo "    status:   $STATUS"
    echo "    stderr:   ${ERR:-（無し）}"
    echo "    output:   ${OUT:-（出力なし＝許可）}"
    FAIL=$((FAIL + 1))
  fi
}

assert_silent_allow() {
  local desc="$1"
  if [ "$STATUS" -eq 0 ] && [ -z "$ERR" ] && [ -z "$OUT" ]; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc"
    echo "    expected: 無言で許可（exit 0・stderr 無し・出力無し）"
    echo "    status:   $STATUS"
    echo "    stderr:   ${ERR:-（無し）}"
    echo "    output:   ${OUT:-（出力なし）}"
    FAIL=$((FAIL + 1))
  fi
}

echo "gh-guard: develop を持つ repo では従来どおり警告する"
run_guard exists 'gh pr merge 60 --repo owner/name --merge'
assert_warn "develop がある repo の main 向け merge は警告する"

run_guard exists 'gh pr review 60 --repo owner/name --approve'
assert_warn "develop がある repo の main 向け approve は警告する"

echo "gh-guard: develop を持たない repo では警告しない"
run_guard missing 'gh pr merge 60 --repo owner/name --merge'
assert_silent_allow "develop が無い repo の main 向け merge は通す"

run_guard missing 'gh pr review 60 --repo owner/name --approve'
assert_silent_allow "develop が無い repo の main 向け approve は通す"

echo "gh-guard: 判定できないときは従来どおり警告する（fail closed）"
run_guard error 'gh pr merge 60 --repo owner/name --merge'
assert_warn "develop の有無を確認できないときは警告側へ倒す"

echo
echo "PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
