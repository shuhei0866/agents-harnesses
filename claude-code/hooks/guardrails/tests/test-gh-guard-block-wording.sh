#!/usr/bin/env bash
# Tests for guardrails/gh-guard.sh — 「ブロック」の宣言と実際の判定を一致させる
#
# gh-guard の main 向け merge / approve は advisory であり、既定の GUARD_LEVEL=warn では
# permissionDecision=allow を返す。従来はそのときも「ブロックされています」
# 「安全のためブロックしました」と書いていたため、読んだ人や agent は操作が
# 実行されなかったと信じ、実際には成功していたマージを再試行しかねなかった。
#
# hook が返せるのは判定だけで、実行するかどうかは harness が決める。そこで
# ここでは harness を最小限に模す: hook の出力が deny なら何もしない、それ以外なら
# コマンドを mock gh で実際に実行する。mock gh は pr merge / pr review を
# ログへ記録するので、「ブロックと書いた ⇔ 操作が実行されなかった」をケースごとに
# 確かめられる。
#
# あわせて、PR のターゲットブランチを判定できなかったときは「判定できなかった」と
# 書くこと、warn のときは実行を止めていないと書くことを固定する。
#
# mock gh の挙動は環境変数で切り替える:
#   MOCK_BASE:   main → baseRefName に main を返す / unknown → 解決できない
#   MOCK_AUTHOR: PR 作成者の login（gh api user は常に me を返す）
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
args=" $* "
if [ "${1:-}" = "pr" ] && { [ "${2:-}" = "merge" ] || [ "${2:-}" = "review" ]; }; then
  printf '%s\n' "$*" >> "$MOCK_OP_LOG"
  exit 0
fi
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "view" ]; then
  case "$args" in
    *" baseRefName "*)
      if [ "${MOCK_BASE:-main}" = "unknown" ]; then
        echo 'could not resolve to a PullRequest' >&2
        exit 1
      fi
      printf '%s\n' "$MOCK_BASE"
      exit 0
      ;;
    *" author "*) printf '%s\n' "${MOCK_AUTHOR:-me}"; exit 0 ;;
  esac
  exit 0
fi
if [ "${1:-}" = "api" ]; then
  case "$args" in
    *" user "*) printf 'me\n'; exit 0 ;;
    *"/branches/develop"*) printf 'develop\n'; exit 0 ;;
  esac
  exit 0
fi
exit 0
MOCK
chmod +x "$TMPDIR_TEST/bin/gh"

# --- hook cwd 用の fake git repo（harness.config 無し = trunk-direct ではない）---
git init -q "$TMPDIR_TEST/repo"
git -C "$TMPDIR_TEST/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

OP_LOG="$TMPDIR_TEST/ops.log"
OUT=""
DECISION=""
TEXT=""

# run_case <GUARD_LEVEL|""> <GUARD_FORCE_DENY|""> <CLAUDE_CLOUD> <MOCK_BASE> <MOCK_AUTHOR> <cmd>
run_case() {
  local level="$1" force="$2" cloud="$3" base="$4" author="$5" cmd="$6"
  local -a envs=(PATH="$TMPDIR_TEST/bin:$PATH" MOCK_BASE="$base" MOCK_AUTHOR="$author"
    MOCK_OP_LOG="$OP_LOG" CLAUDE_CLOUD="$cloud")
  [ -n "$level" ] && envs+=(GUARD_LEVEL="$level")
  [ -n "$force" ] && envs+=(GUARD_FORCE_DENY="$force")

  : > "$OP_LOG"
  OUT=$( (cd "$TMPDIR_TEST" && jq -n --arg c "$cmd" --arg cwd "$TMPDIR_TEST/repo" '{tool_input:{command:$c}, cwd:$cwd}' \
    | env -u CLAUDE_PROJECT_DIR -u GUARD_SKIP -u GUARD_LEVEL -u GUARD_FORCE_DENY -u GIT_WORKFLOW -u CLAUDE_CLOUD \
        "${envs[@]}" bash "$GUARD" 2>/dev/null) )
  DECISION=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // ""' 2>/dev/null || printf '')
  TEXT=$(printf '%s' "$OUT" | jq -r '(.hookSpecificOutput.permissionDecisionReason // "") + (.hookSpecificOutput.additionalContext // "")' 2>/dev/null || printf '')

  # harness の模倣: deny 以外ならコマンドを実行する。
  if [ "$DECISION" != "deny" ]; then
    (cd "$TMPDIR_TEST/repo" && env "${envs[@]}" bash -c "$cmd" >/dev/null 2>&1) || true
  fi
}

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() {
  echo "  FAIL: $1"
  echo "    decision: ${DECISION:-（出力なし）}"
  echo "    text:     ${TEXT:-（無し）}"
  echo "    executed: $(tr '\n' '|' < "$OP_LOG")"
  FAIL=$((FAIL + 1))
}

# 宣言と実挙動の一致: 「ブロック」と書いたなら操作は実行されていない、
# 実行されたなら「ブロック」と書いていない。
assert_declaration_matches() {
  local desc="$1" claims_block=0 executed=0
  printf '%s' "$TEXT" | grep -q 'ブロック' && claims_block=1
  [ -s "$OP_LOG" ] && executed=1
  if [ -n "$TEXT" ] && [ "$claims_block" -ne "$executed" ]; then
    pass "$desc"
  else
    fail "$desc（ブロック宣言=$claims_block, 実行=$executed）"
  fi
}

assert_blocked() {
  local desc="$1"
  if [ "$DECISION" = "deny" ] && [ ! -s "$OP_LOG" ]; then
    pass "$desc"
  else
    fail "$desc（deny され、操作が実行されないこと）"
  fi
}

assert_warned_and_executed() {
  local desc="$1"
  if [ "$DECISION" = "allow" ] && [ -s "$OP_LOG" ]; then
    pass "$desc"
  else
    fail "$desc（警告のみで操作は実行されること）"
  fi
}

assert_text() {
  local desc="$1" pattern="$2"
  if printf '%s' "$TEXT" | grep -q -- "$pattern"; then
    pass "$desc"
  else
    fail "$desc（文言に /$pattern/ を含むこと）"
  fi
}

assert_no_text() {
  local desc="$1" pattern="$2"
  if printf '%s' "$TEXT" | grep -q -- "$pattern"; then
    fail "$desc（文言に /$pattern/ を含まないこと）"
  else
    pass "$desc"
  fi
}

MERGE='gh pr merge 523 --merge'
APPROVE='gh pr review 60 --approve'
# 2026-10-06 の再現例と同じ形の compound コマンド
COMPOUND="gh pr merge 73 -R owner/name --merge --match-head-commit 5356199d30ef273f9b8d9084a68dcf197dbcb742; gh pr view 73 -R owner/name --json state,mergedAt,mergeCommit -q '.state'; for n in 60 61 62; do gh issue view \$n -R owner/name --json number,state -q '.state'; done"

echo "gh-guard: 既定（warn）の merge は警告のみで、ブロックとは書かない"
run_case "" "" 0 main me "$MERGE"
assert_warned_and_executed "main 向け merge は warn では実行される"
assert_declaration_matches "main 向け merge（warn）の宣言が実挙動と一致する"
assert_text "warn では実行を止めていないと明記する" "実行は止めていません"

run_case "" "" 0 unknown me "$MERGE"
assert_warned_and_executed "ターゲット不明の merge は warn では実行される"
assert_declaration_matches "ターゲット不明の merge（warn）の宣言が実挙動と一致する"
assert_text "判定できなかったことを書く" "判定できませんでした"
assert_text "判定不能（warn）でも実行を止めていないと明記する" "実行は止めていません"

run_case "" "" 0 main me "$COMPOUND"
assert_warned_and_executed "2026-10-06 形の compound merge は warn では実行される"
assert_declaration_matches "compound merge（warn）の宣言が実挙動と一致する"

echo "gh-guard: deny 設定の merge は実際に止め、ブロックと書く"
run_case deny "" 0 main me "$MERGE"
assert_blocked "GUARD_LEVEL=deny の main 向け merge は実行されない"
assert_declaration_matches "main 向け merge（deny）の宣言が実挙動と一致する"
assert_no_text "deny では実行を止めていないとは書かない" "実行は止めていません"

run_case deny "" 0 unknown me "$MERGE"
assert_blocked "GUARD_LEVEL=deny のターゲット不明 merge は実行されない"
assert_declaration_matches "ターゲット不明の merge（deny）の宣言が実挙動と一致する"
assert_text "deny でも判定できなかったことを書く" "判定できませんでした"

run_case "" gh-guard 0 main me "$COMPOUND"
assert_blocked "GUARD_FORCE_DENY=gh-guard の compound merge は実行されない"
assert_declaration_matches "compound merge（force deny）の宣言が実挙動と一致する"

echo "gh-guard: approve も同じ規則に従う"
run_case "" "" 0 main me "$APPROVE"
assert_warned_and_executed "main 向け approve は warn では実行される"
assert_declaration_matches "main 向け approve（warn）の宣言が実挙動と一致する"

run_case deny "" 0 unknown me "$APPROVE"
assert_blocked "GUARD_LEVEL=deny のターゲット不明 approve は実行されない"
assert_declaration_matches "ターゲット不明の approve（deny）の宣言が実挙動と一致する"

echo "gh-guard: クラウド環境の approve も同じ規則に従う"
run_case "" "" 1 main me "$APPROVE"
assert_warned_and_executed "クラウドの自己 approve は warn では実行される"
assert_declaration_matches "クラウドの自己 approve（warn）の宣言が実挙動と一致する"

run_case deny "" 1 main me "$APPROVE"
assert_blocked "GUARD_LEVEL=deny のクラウド自己 approve は実行されない"
assert_declaration_matches "クラウドの自己 approve（deny）の宣言が実挙動と一致する"

run_case "" "" 1 main other "$APPROVE"
assert_warned_and_executed "クラウドの main 向け代理 approve は warn では実行される"
assert_declaration_matches "クラウドの代理 approve（warn）の宣言が実挙動と一致する"

run_case deny "" 1 unknown other "$APPROVE"
assert_blocked "GUARD_LEVEL=deny のクラウド代理 approve（ターゲット不明）は実行されない"
assert_declaration_matches "クラウドの代理 approve（deny・ターゲット不明）の宣言が実挙動と一致する"
assert_text "クラウドでも判定できなかったことを書く" "判定できませんでした"

echo
echo "PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
