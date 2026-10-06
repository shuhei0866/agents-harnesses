#!/usr/bin/env bash
# Tests for guardrails/commit-guard.sh — 静的解析とシェルの実行意味論がずれる入力
#
# commit-guard はコマンド文字列だけを読んで対象リポジトリを決める。同一コマンド内の
# 変数を展開しようとすると、予約語・条件付き代入・使用後の代入・改行・代入以外の
# 変更操作・quote・コメント・quote 内の `;` で、シェルが実際に使う値と食い違う。
# 過去にこの領域を触った実装は、既存テストが green のまま fail-open を作っていた。
#
# ここでは各入力について次の 2 点を確かめる。
#   (1) 実シェルで実行すると main ブランチのリポジトリが対象になる（入力の前提）
#   (2) ガードは advisory を返す（素朴に展開すると feature ブランチ側を見て無言で
#       許可する形に組んであるので、fail-open へ倒れたらここで落ちる）
#
# 判定は文言ではなく permissionDecision と additionalContext の有無で表明する。
# GUARD_LEVEL=warn（既定）では advisory は allow + additionalContext、critical は deny になる。
set -euo pipefail

for required_cmd in bash dirname mktemp mkdir rm git jq env; do
  command -v "$required_cmd" >/dev/null 2>&1 || {
    printf 'required command is unavailable: %s\n' "$required_cmd" >&2
    exit 1
  }
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/../commit-guard.sh"

PASS=0
FAIL=0
TMPDIR_TEST="$(mktemp -d)" || exit 1
FIXTURE_MARKER=".commit-guard-target-resolution-fixture"
: > "$TMPDIR_TEST/$FIXTURE_MARKER"

cleanup() {
  [ -n "$TMPDIR_TEST" ] || return 0
  [ -f "$TMPDIR_TEST/$FIXTURE_MARKER" ] || return 0
  rm -rf "$TMPDIR_TEST"
}
trap cleanup EXIT

# 入力にはパスを quote せずに埋め込むので、空白やメタ文字を含む一時ディレクトリでは組めない。
case "$TMPDIR_TEST" in
  *[!A-Za-z0-9/._-]*)
    printf 'temporary directory contains characters this test cannot embed: %s\n' "$TMPDIR_TEST" >&2
    exit 1
    ;;
esac

# --- fixture ---
make_repo() {
  local dir="$1" branch="$2"
  mkdir -p "$dir/.claude"
  printf 'GIT_WORKFLOW="worktree-pr"\n' > "$dir/.claude/harness.config"
  git init -q "$dir"
  git -C "$dir" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  git -C "$dir" symbolic-ref HEAD "refs/heads/$branch"
  git -C "$dir" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "on $branch"
}

# 誤って解決したときに無言で許可される側。
BRANCH_REPO="$TMPDIR_TEST/repo"
# 実シェルが対象にする側。`D+=-main` で BRANCH_REPO から到達できる名前にしてある。
MAIN_REPO="$TMPDIR_TEST/repo-main"
# quote 内の `;` で切ると BRANCH_REPO と同じ文字列が残る名前。
SEMICOLON_REPO="$TMPDIR_TEST/repo;name"
# 変数が空のまま使われる入力では cwd が対象になるので、cwd 自体を main のリポジトリにする。
CWD_MAIN_REPO="$TMPDIR_TEST/cwd-main"
# quote 内の `$D` は展開されないので、その名前のディレクトリを main のリポジトリにする。
LITERAL_CWD="$TMPDIR_TEST/literal"

make_repo "$BRANCH_REPO" feature/work
make_repo "$MAIN_REPO" main
make_repo "$SEMICOLON_REPO" main
make_repo "$CWD_MAIN_REPO" main
mkdir -p "$LITERAL_CWD"
make_repo "$LITERAL_CWD/\$D" main

NEUTRAL="$TMPDIR_TEST/neutral"
mkdir -p "$NEUTRAL"

OUT=""
STATUS=0
# ガードの終了コードは assertion の材料なので、set -e に中断させずに保持する。
run_guard() {
  local cwd="$1" cmd="$2"
  if OUT=$(jq -n --arg c "$cmd" --arg cwd "$cwd" '{tool_input:{command:$c}, cwd:$cwd}' \
    | env -u CLAUDE_PROJECT_DIR -u GUARD_SKIP -u GUARD_LEVEL -u GUARD_FORCE_DENY -u GIT_WORKFLOW -u CLAUDE_CLOUD \
        bash "$GUARD" 2>/dev/null); then
    STATUS=0
  else
    STATUS=$?
  fi
}

# 同じ入力を実シェルで実行し、git が実際に向くリポジトリのブランチを得る。
# git だけを関数で差し替え、-C の値（無ければ cwd）の HEAD を出力させる。
SHELL_BRANCH=""
run_shell() {
  local cwd="$1" cmd="$2"
  SHELL_BRANCH=$(cd "$cwd" && env -u D bash --norc --noprofile -c '
git() {
  if [ "$1" = "-C" ]; then
    command git -C "$2" rev-parse --abbrev-ref HEAD
  else
    command git rev-parse --abbrev-ref HEAD
  fi
}
'"$cmd" </dev/null 2>/dev/null) || SHELL_BRANCH=""
}

decision_of() {
  printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // ""' 2>/dev/null || printf ''
}

context_of() {
  printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null || printf ''
}

record() {
  local ok="$1" desc="$2" detail="$3"
  if [ "$ok" -eq 1 ]; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc"
    printf '%s\n' "$detail"
    FAIL=$((FAIL + 1))
  fi
}

assert_advisory() {
  local desc="$1" decision="" context="" ok=0
  decision=$(decision_of)
  context=$(context_of)
  if [ "$STATUS" -eq 0 ] && [ "$decision" = "allow" ] && [ -n "$context" ]; then
    ok=1
  fi
  record "$ok" "$desc" "    expected: advisory（exit 0・permissionDecision=allow・additionalContext あり）
    status:   $STATUS
    output:   ${OUT:-（出力なし＝無言で許可）}"
}

assert_denied() {
  local desc="$1" decision="" ok=0
  decision=$(decision_of)
  if [ "$decision" = "deny" ]; then
    ok=1
  fi
  record "$ok" "$desc" "    expected: permissionDecision=deny
    status:   $STATUS
    output:   ${OUT:-（出力なし＝無言で許可）}"
}

assert_silent_allow() {
  local desc="$1" ok=0
  if [ "$STATUS" -eq 0 ] && [ -z "$OUT" ]; then
    ok=1
  fi
  record "$ok" "$desc" "    expected: 無言で許可（exit 0・出力無し）
    status:   $STATUS
    output:   ${OUT:-（出力なし）}"
}

assert_shell_targets_main() {
  local desc="$1" ok=0
  if [ "$SHELL_BRANCH" = "main" ]; then
    ok=1
  fi
  record "$ok" "$desc" "    expected: 実シェルでは main のリポジトリが対象になる（入力の組み方の前提）
    actual:   ${SHELL_BRANCH:-（取得できず）}"
}

# 実シェルで main が対象になることと、ガードが advisory を返すことを同じ入力で確かめる。
check_case() {
  local desc="$1" cwd="$2" cmd="$3"
  run_shell "$cwd" "$cmd"
  assert_shell_targets_main "$desc — 実シェルでは main が対象"
  run_guard "$cwd" "$cmd"
  assert_advisory "$desc — ガードは advisory"
}

echo "commit-guard: fixture の前提（対象を正しく解決できたときの判定）"
run_guard "$NEUTRAL" "git -C $MAIN_REPO commit -m x"
assert_advisory "main のリポジトリへのリテラル指定は advisory"
run_guard "$NEUTRAL" "git -C $BRANCH_REPO commit -m x"
assert_silent_allow "feature ブランチのリポジトリへのリテラル指定は無言で許可（ここへ誤解決すると fail-open）"

echo "commit-guard: 予約語で始まる segment"
check_case "if の中の再代入" "$NEUTRAL" \
  "D=$BRANCH_REPO; if true; then D=$MAIN_REPO; fi; git -C \"\$D\" commit -m x"

echo "commit-guard: 条件付きで実行されない代入"
check_case "&& の右辺の代入は実行されない" "$NEUTRAL" \
  "D=$MAIN_REPO; [ -d $TMPDIR_TEST/does_not_exist ] && D=$BRANCH_REPO; git -C \"\$D\" commit -m x"

echo "commit-guard: 使用箇所より後ろの代入"
check_case "使用後の代入は効かない" "$CWD_MAIN_REPO" \
  "git -C \"\$D\" commit -m x; D=$BRANCH_REPO"

echo "commit-guard: 改行区切りの再代入"
# 改行を空白へ潰すと、2 つ目の代入が git の prefix 代入に見えて引数展開に効かなくなる。
check_case "改行の前の再代入" "$NEUTRAL" \
  "D=$BRANCH_REPO; D=$MAIN_REPO"$'\n'"git -C \"\$D\" commit -m x"

echo "commit-guard: 代入の形をしていない変更操作"
check_case "D+= による追記" "$NEUTRAL" \
  "D=$BRANCH_REPO; D+=-main; git -C \"\$D\" commit -m x"
check_case "D[0]= による要素代入" "$NEUTRAL" \
  "D=$BRANCH_REPO; D[0]=$MAIN_REPO; git -C \"\$D\" commit -m x"
check_case "unset D" "$CWD_MAIN_REPO" \
  "D=$BRANCH_REPO; unset D; git -C \"\$D\" commit -m x"
check_case "read D" "$NEUTRAL" \
  "D=$BRANCH_REPO; read -r D <<< $MAIN_REPO; git -C \"\$D\" commit -m x"

echo "commit-guard: quote 内は展開されない"
check_case "cd '\$D'" "$LITERAL_CWD" \
  "D=$BRANCH_REPO; cd '\$D'; git commit -m x"
check_case "git -C \"\\\$D\"" "$LITERAL_CWD" \
  "D=$BRANCH_REPO; git -C \"\\\$D\" commit -m x"

echo "commit-guard: コメント以降は実行されない"
check_case "# の後ろの代入" "$CWD_MAIN_REPO" \
  "git -C \"\$D\" commit -m x #; D=$BRANCH_REPO"

echo "commit-guard: quote 内の ; を含むパス"
check_case "D=\"…;…\"" "$NEUTRAL" \
  "D=\"$SEMICOLON_REPO\"; git -C \"\$D\" commit -m x"

echo "commit-guard: prefix 代入は引数展開の後に効く"
# `D=… git -C "$D"` の prefix 代入は git の環境にだけ入り、"$D" の展開には効かない。
check_case "prefix 代入は直前の値を上書きしない" "$NEUTRAL" \
  "D=$MAIN_REPO; D=$BRANCH_REPO git -C \"\$D\" commit -m x"

echo "commit-guard: commit と push --force は経路が違う"
# 同じ「変数で渡された -C」でも、commit は advisory、push --force は critical の deny になる。
run_guard "$NEUTRAL" 'git -C "$WT" commit -m x'
assert_advisory "変数を渡した commit は advisory"
run_guard "$NEUTRAL" 'git -C "$WT" push --force'
assert_denied "変数を渡した push --force は critical の deny"

echo
echo "PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
