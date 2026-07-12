#!/usr/bin/env bash
# Tests for GIT_WORKFLOW-aware guard behavior.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMIT_GUARD="$SCRIPT_DIR/../commit-guard.sh"
GH_GUARD="$SCRIPT_DIR/../gh-guard.sh"
WORKTREE_GUARD="$SCRIPT_DIR/../worktree-guard.sh"
WORKTREE_RM_GUARD="$SCRIPT_DIR/../worktree-rm-guard.sh"
MERGED_PUSH_GUARD="$SCRIPT_DIR/../merged-pr-push-guard.sh"
DESTRUCTIVE_GUARD="$SCRIPT_DIR/../destructive-guard.sh"

PASS=0
FAIL=0
TMPDIR_TEST="$(mktemp -d)"
TMPDIR_TEST="$(cd "$TMPDIR_TEST" && pwd -P)"
REPO="$TMPDIR_TEST/repo"
REPO_B="$TMPDIR_TEST/repo b"
REPO_C="$TMPDIR_TEST/repo-c"

cleanup() {
  rm -rf "$TMPDIR_TEST"
}
trap cleanup EXIT

mkdir -p "$REPO/.claude" "$REPO/src" "$REPO_B/.claude" "$REPO_B/src" "$REPO_C/.claude" "$REPO_C/src" "$TMPDIR_TEST/bin"
git init -q "$REPO"
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$REPO" branch -M main
git init -q "$REPO_B"
git -C "$REPO_B" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$REPO_B" branch -M main
git init -q "$REPO_C"
git -C "$REPO_C" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$REPO_C" branch -M main

# commit-guard / gh-guard / merged-pr-push-guard が必要とする gh 応答を1つの mock で返す。
cat > "$TMPDIR_TEST/bin/gh" <<'MOCK'
#!/bin/bash
[ -n "${MOCK_GH_LOG:-}" ] && printf '%s\n' "$*" >> "$MOCK_GH_LOG"
if [[ "$*" == *"--json baseRefName"* && -n "${MOCK_GH_DEVELOP_CWD:-}" && "$PWD" == "$MOCK_GH_DEVELOP_CWD" ]]; then
  printf 'develop\n'
  exit 0
fi
case "$*" in
  *"--repo foo/bar"*"--json baseRefName"*)
    printf 'develop\n'
    ;;
  "pr view develop "*"--json baseRefName"*)
    printf 'develop\n'
    ;;
  *"--repo safe/develop"*"--json baseRefName"*)
    printf 'develop\n'
    ;;
  *"--json state,number,url"*)
    printf '{"state":"MERGED","number":12,"url":"https://example.com/pull/12"}\n'
    ;;
  *"--json baseRefName,headRefName"*)
    printf '{"baseRefName":"main","headRefName":"feature/policy"}\n'
    ;;
  *"--json baseRefName"*)
    printf 'main\n'
    ;;
  *"--json author"*)
    printf 'author\n'
    ;;
  "api user"*)
    printf 'reviewer\n'
    ;;
esac
MOCK
chmod +x "$TMPDIR_TEST/bin/gh"

set_config() {
  printf '%s\n' "$1" > "$REPO/.claude/harness.config"
}

set_config_b() {
  printf '%s\n' "$1" > "$REPO_B/.claude/harness.config"
}

set_config_c() {
  printf '%s\n' "$1" > "$REPO_C/.claude/harness.config"
}

OUT=""
ERR=""
STATUS=0

run_guard_json() {
  local guard="$1" input="$2" workflow="$3" level="$4" force_deny="$5"
  local cloud="${6-__UNSET__}" gh_repo="${7-__UNSET__}"
  local errf="$TMPDIR_TEST/stderr"
  local -a env_args
  : > "$TMPDIR_TEST/gh.log"
  env_args=(
    env
    -u GIT_WORKFLOW
    -u GUARD_SKIP
    -u GUARD_LEVEL
    -u GUARD_FORCE_DENY
    -u CLAUDE_CLOUD
    -u GH_REPO
    "CLAUDE_PROJECT_DIR=$REPO"
    "GUARD_LEVEL=$level"
    "PATH=$TMPDIR_TEST/bin:$PATH"
    "MOCK_GH_LOG=$TMPDIR_TEST/gh.log"
    "MOCK_GH_DEVELOP_CWD=$REPO_C"
  )
  if [ "$workflow" != "__UNSET__" ]; then
    env_args+=("GIT_WORKFLOW=$workflow")
  fi
  if [ "$force_deny" != "__UNSET__" ]; then
    env_args+=("GUARD_FORCE_DENY=$force_deny")
  fi
  if [ "$cloud" != "__UNSET__" ]; then
    env_args+=("CLAUDE_CLOUD=$cloud")
  fi
  if [ "$gh_repo" != "__UNSET__" ]; then
    env_args+=("GH_REPO=$gh_repo")
  fi

  OUT=$(cd "$REPO" && printf '%s\n' "$input" | "${env_args[@]}" /bin/bash "$guard" 2>"$errf")
  STATUS=$?
  ERR=$(cat "$errf" 2>/dev/null || echo "")
}

run_bash_guard() {
  local guard="$1" cmd="$2" workflow="${3-__UNSET__}" level="${4:-deny}" force_deny="${5:-__UNSET__}" cloud="${6-__UNSET__}" gh_repo="${7-__UNSET__}"
  local input
  input=$(jq -n --arg c "$cmd" --arg cwd "$REPO" '{tool_input:{command:$c},cwd:$cwd}')
  run_guard_json "$guard" "$input" "$workflow" "$level" "$force_deny" "$cloud" "$gh_repo"
}

run_bash_guard_with_cwd() {
  local guard="$1" cmd="$2" hook_cwd="$3" workflow="${4-__UNSET__}" level="${5:-deny}" force_deny="${6:-__UNSET__}"
  local input
  input=$(jq -n --arg c "$cmd" --arg cwd "$hook_cwd" '{tool_input:{command:$c},cwd:$cwd}')
  run_guard_json "$guard" "$input" "$workflow" "$level" "$force_deny"
}

run_write_guard() {
  local workflow="${1-__UNSET__}" level="${2:-deny}" force_deny="${3:-__UNSET__}"
  local input
  input=$(jq -n --arg p "$REPO/src/app.txt" '{tool_input:{file_path:$p}}')
  run_guard_json "$WORKTREE_GUARD" "$input" "$workflow" "$level" "$force_deny"
}

assert_deny() {
  local desc="$1"
  if [ "$STATUS" -eq 0 ] && [ -z "$ERR" ] \
     && echo "$OUT" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc"
    echo "    expected: deny / status: $STATUS / stderr: ${ERR:-無し} / output: ${OUT:-（出力なし）}"
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
    echo "    expected: silent allow / status: $STATUS / stderr: ${ERR:-無し} / output: ${OUT:-（出力なし）}"
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local desc="$1" needle="$2"
  if echo "$OUT" | grep -q -- "$needle"; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc"
    echo "    expected to contain: $needle / output: ${OUT:-（出力なし）}"
    FAIL=$((FAIL + 1))
  fi
}

assert_gh_log_contains() {
  local desc="$1" needle="$2"
  if grep -q -- "$needle" "$TMPDIR_TEST/gh.log"; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc"
    echo "    expected gh log to contain: $needle / log: $(cat "$TMPDIR_TEST/gh.log" 2>/dev/null || echo '（無し）')"
    FAIL=$((FAIL + 1))
  fi
}

assert_gh_log_not_contains() {
  local desc="$1" needle="$2"
  if ! grep -q -- "$needle" "$TMPDIR_TEST/gh.log"; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc"
    echo "    expected gh log not to contain: $needle / log: $(cat "$TMPDIR_TEST/gh.log" 2>/dev/null || echo '（無し）')"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== GIT_WORKFLOW: load order and validation ==="

set_config 'GIT_WORKFLOW="trunk-direct"'
run_bash_guard "$COMMIT_GUARD" 'git commit -m test'
assert_silent_allow "harness.config の trunk-direct を読み main direct commit を許可する"

run_bash_guard "$COMMIT_GUARD" "git commit -m 'document \$(foo)'"
assert_silent_allow "single-quote 内の literal command substitution は workflow を曖昧化しない"

run_bash_guard "$COMMIT_GUARD" "git commit -m 'document \`foo\`'"
assert_silent_allow "single-quote 内の literal backtick は workflow を曖昧化しない"

run_bash_guard "$COMMIT_GUARD" 'env GIT_AUTHOR_NAME=bot git commit -m test'
assert_silent_allow "env assignment wrapper 後の git は config の trunk-direct を使う"

run_bash_guard "$COMMIT_GUARD" 'env -u HOME GIT_AUTHOR_NAME=bot git commit -m test'
assert_silent_allow "env option と assignment wrapper 後の git も trunk-direct を使う"

run_bash_guard "$COMMIT_GUARD" 'if true; then git commit -m controlled; fi'
assert_silent_allow "config-based trunk-direct は control flow 内の direct commit も許可する"

set_config 'GIT_WORKFLOW="worktree-pr"'
run_bash_guard "$COMMIT_GUARD" 'git commit -m test' trunk-direct
assert_silent_allow "環境変数 trunk-direct が config worktree-pr より優先される"

set_config 'GIT_WORKFLOW="trunk-direct"'
run_bash_guard "$COMMIT_GUARD" 'git commit -m test' worktree-pr
assert_deny "環境変数 worktree-pr が config trunk-direct より優先される"

run_bash_guard "$COMMIT_GUARD" 'git commit -m test' invalid-policy
assert_deny "不正な環境変数値は config にfallbackせず緩和しない"

run_bash_guard "$COMMIT_GUARD" 'git commit -m test' ''
assert_deny "空の環境変数値も config にfallbackせず緩和しない"

set_config 'GIT_WORKFLOW="trunk- direct"'
run_bash_guard "$COMMIT_GUARD" 'git commit -m test'
assert_deny "config value の内部空白を除去して trunk-direct に正規化しない"

set_config 'GIT_WORKFLOW="worktree-pr"'
run_bash_guard "$COMMIT_GUARD" 'git checkout main'
assert_silent_allow "worktree-pr でも protected branch への通常switchは許可する"

run_bash_guard "$COMMIT_GUARD" 'git checkout main -- README.md'
assert_silent_allow "protected revision からの pathspec restore は許可する"

run_bash_guard "$COMMIT_GUARD" 'git checkout main README.md'
assert_deny "-- のない ambiguous checkout は従来どおりdenyする"

set_config ''
run_bash_guard "$COMMIT_GUARD" 'git commit -m test'
assert_deny "未設定は既存の main direct commit 防御を維持する"

run_bash_guard "$GH_GUARD" 'gh pr merge 42'
assert_deny "未設定は既存の main 向け gh pr merge 防御を維持する"

run_write_guard __UNSET__ deny
assert_deny "未設定は既存の main worktree edit 防御を維持する"

echo ""
echo "=== command target selects per-repo workflow ==="

set_config 'GIT_WORKFLOW="trunk-direct"'
set_config_b 'GIT_WORKFLOW="worktree-pr"'
set_config_c 'GIT_WORKFLOW="worktree-pr"'

set_config 'GIT_WORKFLOW="worktree-pr"'
set_config_b 'GIT_WORKFLOW="trunk-direct"'
ln -s "$REPO_B" "$TMPDIR_TEST/tilde-trunk"
HOME="$TMPDIR_TEST" run_bash_guard "$COMMIT_GUARD" "cd '~/tilde-trunk'; git commit -m test"
assert_deny "quoted tilde path を HOME 展開して別 repo policy に切り替えない"
HOME="$TMPDIR_TEST" run_bash_guard "$COMMIT_GUARD" "git -C ~/tilde-trunk commit -m '~ cleanup'"
assert_silent_allow "unquoted tilde path は別の quoted tilde argument に影響されず展開する"
ln -s "$REPO_B" "$TMPDIR_TEST/repo~name"
HOME="$TMPDIR_TEST" run_bash_guard "$COMMIT_GUARD" "git -C ~/'repo~name' commit -m test"
assert_silent_allow "leading unquoted tilde は後続 quoted tilde に影響されず展開する"
HOME="$TMPDIR_TEST" run_bash_guard "$COMMIT_GUARD" "cd ''~/tilde-trunk; git commit -m test"
assert_deny "empty quote prefix 後の tilde を HOME 展開しない"
HOME="$TMPDIR_TEST" run_bash_guard "$COMMIT_GUARD" "cd ~''/tilde-trunk; git commit -m test"
assert_deny "leading tilde と slash の間の empty quote を無視して展開しない"
HOME="$TMPDIR_TEST" run_bash_guard "$COMMIT_GUARD" "git -C~/tilde-trunk commit -m test"
assert_deny "attached -C の word-middle tilde を HOME 展開しない"
mkdir -p "$REPO/__GUARD_LITERAL_TILDE__~/repo"
git init -q "$REPO/__GUARD_LITERAL_TILDE__~/repo"
git -C "$REPO/__GUARD_LITERAL_TILDE__~/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$REPO/__GUARD_LITERAL_TILDE__~/repo" branch -M main
mkdir -p "$REPO/__GUARD_LITERAL_TILDE__~/repo/.claude"
printf '%s\n' 'GIT_WORKFLOW="worktree-pr"' > "$REPO/__GUARD_LITERAL_TILDE__~/repo/.claude/harness.config"
HOME="$TMPDIR_TEST" run_bash_guard "$COMMIT_GUARD" "git -C __GUARD_LITERAL_TILDE__~/repo commit -m test"
assert_deny "literal path から tilde metadata を偽装できない"
run_bash_guard "$COMMIT_GUARD" "if false; then cd \"$REPO_B\"; fi; git commit -m test"
assert_deny "未実行の conditional cd から trunk-direct policy を後続 commit に漏らさない"
run_bash_guard "$COMMIT_GUARD" $'if false\nthen\n  cd '"\"$REPO_B\""$'\nfi\ngit commit -m test'
assert_deny "改行された conditional cd からも trunk-direct policy を漏らさない"
run_bash_guard "$COMMIT_GUARD" $'if true\nthen\n  if false\n  then\n    cd '"\"$REPO_B\""$'\n  fi\nfi\ngit commit -m test'
assert_deny "nested conditional cd からも trunk-direct policy を漏らさない"
run_bash_guard "$COMMIT_GUARD" "if false; then command fi; cd \"$REPO_B\"; fi; git commit -m test"
assert_deny "fi という executable name で conditional depth を閉じない"
run_bash_guard "$COMMIT_GUARD" "if false; then 'fi'; cd \"$REPO_B\"; fi; git commit -m test"
assert_deny "quoted fi を shell terminator と誤認しない"
run_bash_guard "$COMMIT_GUARD" "if true; then :; else if false; then :; fi; cd \"$REPO_B\"; fi; git commit -m test"
assert_deny "else if の nested conditional depth を保持する"
run_bash_guard "$COMMIT_GUARD" "{ cd \"$REPO_B\"; }; git commit -m test"
assert_silent_allow "unconditional command group の cd は後続 commit に反映する"
run_bash_guard "$COMMIT_GUARD" "time cd \"$REPO_B\"; git commit -m test"
assert_silent_allow "time prefix の cd は後続 commit に反映する"
run_bash_guard "$COMMIT_GUARD" "'time' cd \"$REPO_B\"; git commit -m test"
assert_deny "quoted time executable を shell keyword と誤認しない"
run_bash_guard "$COMMIT_GUARD" "! cd \"$REPO_B\"; git commit -m test"
assert_silent_allow "negation prefix の cd 自体は実行されるため後続 commit に反映する"
set_config 'GIT_WORKFLOW="trunk-direct"'
set_config_b 'GIT_WORKFLOW="worktree-pr"'
run_bash_guard "$COMMIT_GUARD" "git commit -m test; if false; then cd \"$REPO_B\"; fi"
assert_silent_allow "後続 conditional cd は先に解決済みの trunk-direct commit を否定しない"
set_config 'GIT_WORKFLOW="trunk-direct"'
set_config_b 'GIT_WORKFLOW="worktree-pr"'

run_bash_guard "$COMMIT_GUARD" "git -C $REPO_C commit -m test"
assert_deny "git -C の unquoted absolute target は target repo の worktree-pr を使う"

run_bash_guard "$COMMIT_GUARD" "git -C \"$REPO_B\" commit -m test"
assert_deny "git -C の quoted absolute target は target repo の worktree-pr を使う"

run_bash_guard "$COMMIT_GUARD" "git -c user.name=test -C \"$REPO_B\" commit -m test"
assert_deny "別の git global option 後の -C も target repo の worktree-pr を使う"

run_bash_guard "$COMMIT_GUARD" "GIT_DIR=\"$REPO_B/.git\" GIT_WORK_TREE=\"$REPO_B\" git commit -m test"
assert_deny "GIT_DIR/GIT_WORK_TREE assignment で target が変わる commit は fail closed"

run_bash_guard "$COMMIT_GUARD" "env GIT_DIR=\"$REPO_B/.git\" GIT_WORK_TREE=\"$REPO_B\" git commit -m test"
assert_deny "env 内の GIT_DIR/GIT_WORK_TREE assignment も fail closed"

run_bash_guard "$COMMIT_GUARD" "git -P -C \"$REPO_B\" commit -m test"
assert_deny "pager global option 後の -C でも direct commit advisory を維持する"

git -C "$REPO" switch -q -c feature/quoted-cd-context
run_bash_guard "$COMMIT_GUARD" "'cd' \"$REPO_B\" && git commit -m test"
assert_deny "quoted cd builtin でも target repo の worktree-pr を使う"

run_bash_guard "$COMMIT_GUARD" "c''d \"$REPO_B\" && git commit -m test"
assert_deny "quote-concatenated cd builtin でも target repo policy を使う"

run_bash_guard "$COMMIT_GUARD" "builtin cd \"$REPO_B\" && git commit -m test"
assert_deny "builtin cd prefix でも target repo policy を使う"

run_bash_guard "$COMMIT_GUARD" "command cd \"$REPO_B\" && git commit -m test"
assert_deny "command cd prefix でも target repo policy を使う"

run_bash_guard "$COMMIT_GUARD" "command -p cd \"$REPO_B\" && git commit -m test"
assert_deny "command -p cd prefix でも target repo policy を使う"

run_bash_guard "$COMMIT_GUARD" "command -- cd \"$REPO_B\" && git commit -m test"
assert_deny "command -- cd prefix でも target repo policy を使う"

run_bash_guard "$COMMIT_GUARD" "builtin -- cd \"$REPO_B\" && git commit -m test"
assert_deny "builtin -- cd prefix でも target repo policy を使う"

run_bash_guard "$COMMIT_GUARD" "pushd \"$REPO_B\" >/dev/null && git commit -m test"
assert_deny "pushd による untracked cwd change は fail closed する"
git -C "$REPO" switch -q main

run_bash_guard "$COMMIT_GUARD" 'git commit -m pushd'
assert_silent_allow "commit message の pushd は cwd change と誤認しない"

run_bash_guard "$COMMIT_GUARD" 'echo pushd && git commit -m test'
assert_silent_allow "通常commandの引数にある pushd は cwd change と誤認しない"

run_bash_guard "$COMMIT_GUARD" "git --no-replace-objects -C \"$REPO_B\" checkout feature/policy"
assert_deny "global option 後の -C でも checkout advisory を target repo に適用する"

run_bash_guard "$COMMIT_GUARD" "git -p -C \"$REPO_B\" merge feature/policy"
assert_deny "global option 後の -C でも merge advisory を target repo に適用する"

run_bash_guard "$COMMIT_GUARD" "git -C \"$REPO_B\" stash apply"
assert_deny "git -C でも stash advisory を target repo に適用する"

run_bash_guard "$COMMIT_GUARD" "cd $REPO_C && git commit -m test"
assert_deny "cd の unquoted target は target repo の worktree-pr を使う"

run_bash_guard "$GH_GUARD" "cd \"$REPO_B\" && gh pr merge 42"
assert_deny "cd の quoted target は gh-guard でも target repo の worktree-pr を使う"

set_config 'GIT_WORKFLOW="worktree-pr"'
set_config_b 'GIT_WORKFLOW="trunk-direct"'
set_config_c 'GIT_WORKFLOW="trunk-direct"'

run_bash_guard "$COMMIT_GUARD" 'git -C ../repo-c commit -m test'
assert_silent_allow "git -C の relative target は target repo の trunk-direct を使う"

run_bash_guard "$COMMIT_GUARD" "cd \"$REPO_B\" && git commit -m test"
assert_silent_allow "cd の quoted target は target repo の trunk-direct を使う"

run_bash_guard "$GH_GUARD" "cd \"$REPO_B\" && gh pr merge 42"
assert_silent_allow "cd target は gh-guard でも target repo の trunk-direct を使う"

run_bash_guard_with_cwd "$COMMIT_GUARD" 'git commit -m test' "$REPO_B"
assert_silent_allow "command context がなければ hook input cwd の trunk-direct を使う"

run_bash_guard "$COMMIT_GUARD" "cd \"$REPO_B\" | true; git commit -m test"
assert_deny "pipeline 内の cd は後続 command context に継承せず fail closed"

run_bash_guard "$COMMIT_GUARD" "echo \"\$(cd '$REPO_B' && git status)\"; git commit -m test"
assert_deny "command substitution 内の cd は後続 context に継承せず fail closed"

run_bash_guard "$COMMIT_GUARD" "echo \`cd '$REPO_B' && git status\`; git commit -m test"
assert_deny "backtick substitution 内の cd は後続 context に継承せず fail closed"

set_config 'GIT_WORKFLOW="trunk-direct"'
set_config_b 'GIT_WORKFLOW="worktree-pr"'
set_config_c 'GIT_WORKFLOW="worktree-pr"'

run_bash_guard "$GH_GUARD" 'gh pr merge 42 --repo other/repo'
assert_deny "明示 --repo を local config に対応付けられなければ fail closed"

run_bash_guard "$GH_GUARD" 'gh pr merge 42 -Rother/repo'
assert_deny "attached -Rowner/repo も explicit repo として fail closed"
assert_gh_log_contains "get_pr_base は attached -R の repo を --repo で引き渡す" "--repo other/repo --json baseRefName"

run_bash_guard "$GH_GUARD" 'gh pr merge 42' __UNSET__ deny __UNSET__ __UNSET__ other/repo
assert_deny "ambient GH_REPO も explicit repo として fail closed"
assert_gh_log_contains "ambient GH_REPO を merge lookup に引き渡す" "--repo other/repo --json baseRefName"

set_config 'GIT_WORKFLOW="worktree-pr"'
run_bash_guard "$GH_GUARD" 'env -u GH_REPO gh pr merge 42' __UNSET__ deny __UNSET__ __UNSET__ other/develop
assert_deny "env -u GH_REPO 後は ambient selector を使わず local main merge を deny"
assert_gh_log_not_contains "unset 済み GH_REPO を lookup に引き渡さない" "--repo other/develop"

run_bash_guard "$GH_GUARD" 'env -i gh pr merge 42' __UNSET__ deny __UNSET__ __UNSET__ other/develop
assert_deny "env -i 後も ambient selector を使わず local main merge を deny"
assert_gh_log_not_contains "clear 済み environment の GH_REPO を lookup に引き渡さない" "--repo other/develop"
set_config 'GIT_WORKFLOW="trunk-direct"'

run_bash_guard "$GH_GUARD" 'gh -Rother/repo pr merge 42'
assert_deny "gh root位置の attached -R でも merge を検出する"
assert_gh_log_contains "root位置の selector を merge lookup に引き渡す" "--repo other/repo --json baseRefName"

run_bash_guard "$GH_GUARD" 'gh --repo other/repo pr review 42 --approve'
assert_deny "gh root位置の separated --repo でも review を検出する"

run_bash_guard "$GH_GUARD" 'gh pr -R=other/repo merge 42'
assert_deny "pr と subcommand 間の equals -R でも merge を検出する"

run_bash_guard "$GH_GUARD" '"gh" pr merge 42 -Rother/repo'
assert_deny "quoted gh executable でも merge を検出する"

run_bash_guard "$GH_GUARD" 'gh pr merge -Rother/repo'
assert_deny "PR番号省略時も explicit repo の main merge を deny する"
assert_gh_log_contains "PR番号省略時も repo selector を lookup に引き渡す" "--repo other/repo --json baseRefName"

run_bash_guard "$GH_GUARD" 'gh pr view 7 -Rsafe/develop && gh pr merge 42 -Rother/repo'
assert_deny "別 gh segment の selector を merge lookup に流用しない"
assert_gh_log_contains "merge segment 自身の selector を lookup に使う" "--repo other/repo --json baseRefName"

run_bash_guard "$GH_GUARD" 'gh pr merge 1 -Rsafe/develop && gh pr merge 2 -Rother/repo'
assert_deny "複数 merge segment をすべて評価して後続 main target を見逃さない"

run_bash_guard "$GH_GUARD" 'gh pr merge -A develop 42 -Rother/repo'
assert_deny "merge option の author-email 値を PR target と誤認しない"
assert_gh_log_contains "author-email 後の実 PR target を lookup に使う" "pr view 42 --repo other/repo"

run_bash_guard "$GH_GUARD" 'gh pr merge -- -Rfoo/bar' worktree-pr
assert_deny "-- 後の -R-prefixed branch を repo selector と誤認しない"
assert_gh_log_contains "-- 後の token を PR target として lookup する" "pr view -Rfoo/bar --json baseRefName"
assert_gh_log_not_contains "-- 後の token を --repo に変換しない" "--repo foo/bar"

run_bash_guard "$GH_GUARD" "cd \"$REPO_C\" && gh pr view 1; cd \"$REPO_B\" && gh pr merge 42"
assert_deny "各 gh segment に対応する cd context で target branch を評価する"

run_bash_guard_with_cwd "$GH_GUARD" "env -C \"$REPO_B\" gh pr merge 42" "$REPO_C"
assert_deny "env -C 経由の gh target context は fail closed する"

run_bash_guard "$GH_GUARD" 'GH_REPO=other/repo gh pr merge 42'
assert_deny "command-local GH_REPO の main target を deny する"
assert_gh_log_contains "GH_REPO を lookup の repo selector に引き渡す" "--repo other/repo --json baseRefName"

run_bash_guard "$GH_GUARD" 'gh pr review 42 --approve -F -Rdecoy/repo'
assert_silent_allow "-F の値を repo selector と誤認せず trunk-direct を維持する"
assert_gh_log_not_contains "body-file 値を --repo に変換しない" "--repo decoy/repo"

run_bash_guard "$GH_GUARD" $'gh pr review 42 --approve --body "hello\nworld" -Rother/repo'
assert_deny "multiline quoted body 後の real repo selector を見逃さない"
assert_gh_log_contains "multiline body 後の selector を lookup に引き渡す" "--repo other/repo --json baseRefName"

run_bash_guard "$GH_GUARD" 'gh pr review 42 --approve -Rother/repo' worktree-pr deny __UNSET__ 1
assert_deny "cloud review の attached -Rowner/repo も main approve を deny"
assert_gh_log_contains "is_proxy_approve は attached -R の repo を --repo で引き渡す" "--repo other/repo --json author"

run_bash_guard "$COMMIT_GUARD" "git -C \"$REPO_B\" commit -m test" trunk-direct
assert_silent_allow "明示した環境変数 trunk-direct は command target config より優先する"

run_bash_guard "$COMMIT_GUARD" "git -C $REPO status && git -C $REPO_C commit -m test"
assert_deny "複合コマンドに異なる repo policy が混在すれば fail closed"

set_config ''
set_config_b ''
set_config_c ''

echo ""
echo "=== universal critical checks run before workflow advisories ==="

run_bash_guard "$COMMIT_GUARD" 'git commit -m test --no-verify' __UNSET__ warn
assert_deny "未設定でも main direct commit の --no-verify を critical deny する"
assert_contains "未設定でも --no-verify 専用理由で deny する" "--no-verify"

run_bash_guard "$COMMIT_GUARD" 'git commit -m test --no-verify' worktree-pr warn
assert_deny "worktree-pr でも main direct commit の --no-verify を critical deny する"
assert_contains "worktree-pr でも --no-verify 専用理由で deny する" "--no-verify"

run_bash_guard "$COMMIT_GUARD" 'git commit -m test && git push origin main --force' worktree-pr warn
assert_deny "worktree advisory より先に main force push を critical deny する"

run_bash_guard "$COMMIT_GUARD" 'git -P commit -m test --no-verify' trunk-direct warn
assert_deny "git global option 後の commit でも --no-verify を critical deny する"

run_bash_guard "$COMMIT_GUARD" 'git --no-lazy-fetch commit -m test --no-verify' trunk-direct warn
assert_deny "no-value global option 後の commit でも critical check を維持する"

run_bash_guard "$COMMIT_GUARD" 'git commit -m "fix (parser)" --no-verify' trunk-direct warn
assert_deny "double-quote 内の literal parentheses 後も --no-verify をcritical denyする"

run_bash_guard "$COMMIT_GUARD" 'git commit -m "fix (parser)"' trunk-direct warn
assert_silent_allow "double-quote 内の literal parentheses は message data として保持する"

run_bash_guard "$COMMIT_GUARD" 'git push "$(echo origin)" main --force' trunk-direct warn
assert_deny "quoted command substitution 後の main force push をcritical denyする"

run_bash_guard "$COMMIT_GUARD" 'git commit -m "$(echo message)" --no-verify' trunk-direct warn
assert_deny "quoted command substitution 後の --no-verify をcritical denyする"

run_bash_guard "$COMMIT_GUARD" 'git commit -m "$(echo message)" "--no-verify"' trunk-direct warn
assert_deny "quoted command substitution 後の quoted --no-verify もcritical denyする"

run_bash_guard "$COMMIT_GUARD" 'echo "$(git commit --no-verify -m nested)"' trunk-direct warn
assert_deny "command substitution body 内のcritical git commandも検査する"

run_bash_guard "$COMMIT_GUARD" 'if true; then git commit --no-verify -m controlled; fi' trunk-direct warn
assert_deny "if/then control flow 内の --no-verify もcritical denyする"

run_bash_guard "$COMMIT_GUARD" 'for x in one; do git push origin main --force; done' trunk-direct warn
assert_deny "for/do control flow 内の main force push もcritical denyする"

run_bash_guard "$COMMIT_GUARD" "env -S 'git commit --no-verify -m split'" trunk-direct warn
assert_deny "env -S payload 内の --no-verify をcritical denyする"

run_bash_guard "$COMMIT_GUARD" 'env "--split-string=git commit --no-verify -m split"' trunk-direct warn
assert_deny "env --split-string= payload 内の --no-verify もcritical denyする"

run_bash_guard "$COMMIT_GUARD" "env -S 'git commit -m split'" worktree-pr deny
assert_deny "env -S payload 内の direct commit を workflow advisory でdenyする"

run_bash_guard "$COMMIT_GUARD" 'git --no-optional-locks push origin main --force' trunk-direct warn
assert_deny "no-value global option 後の push でも critical check を維持する"

run_bash_guard "$COMMIT_GUARD" 'git --no-advice branch -D develop' trunk-direct warn
assert_deny "no-value global option 後の branch でも critical check を維持する"

run_bash_guard "$COMMIT_GUARD" 'git --exec-path=/tmp commit -m test --no-verify' trunk-direct warn
assert_deny "attached-value global option 後も critical check を維持する"

run_bash_guard "$COMMIT_GUARD" 'git --future-global commit -m test --no-verify' trunk-direct warn
assert_deny "未知の global option 後も危険 subcommand を fail closed する"

run_bash_guard "$COMMIT_GUARD" $'git commit -m "hello\nworld" --no-verify' trunk-direct warn
assert_deny "multiline commit message 後の --no-verify も critical deny する"

run_bash_guard "$COMMIT_GUARD" 'git merge feature/policy -m hotfix/bypass' worktree-pr
assert_deny "merge message の hotfix/ を actual hotfix revision と誤認しない"

run_bash_guard "$COMMIT_GUARD" 'git checkout feature/policy && git branch -D develop' worktree-pr warn
assert_deny "worktree advisory より先に develop 削除を critical deny する"

run_bash_guard "$COMMIT_GUARD" 'git commit -nam test' trunk-direct warn
assert_deny "結合 short option に含まれる commit -n も critical deny する"

run_bash_guard "$COMMIT_GUARD" 'git branch --delete develop' trunk-direct warn
assert_deny "git branch --delete develop も critical deny する"

run_bash_guard "$COMMIT_GUARD" 'git push origin -d develop' trunk-direct warn
assert_deny "git push -d develop も critical deny する"

run_bash_guard "$COMMIT_GUARD" 'git push origin --delete refs/heads/develop' trunk-direct warn
assert_deny "完全 ref の remote develop 削除も critical deny する"

run_bash_guard "$COMMIT_GUARD" 'git push origin :refs/heads/develop' trunk-direct warn
assert_deny "delete refspec による remote develop 削除も critical deny する"

run_bash_guard "$COMMIT_GUARD" 'git push origin +HEAD:main' trunk-direct warn
assert_deny "+ refspec による main force push も critical deny する"

run_bash_guard "$COMMIT_GUARD" 'git commit "--no-verify" -m test' trunk-direct warn
assert_deny "quoted --no-verify も critical deny する"

run_bash_guard "$COMMIT_GUARD" 'git commit "-n" -m test' trunk-direct warn
assert_deny "quoted commit -n も critical deny する"

run_bash_guard "$COMMIT_GUARD" 'git push origin "main" --force' trunk-direct warn
assert_deny "quoted main への force push も critical deny する"

run_bash_guard "$COMMIT_GUARD" 'git push origin "+HEAD:main"' trunk-direct warn
assert_deny "quoted + refspec による main force push も critical deny する"

run_bash_guard "$COMMIT_GUARD" 'git branch -D "develop"' trunk-direct warn
assert_deny "quoted develop の local branch 削除も critical deny する"

run_bash_guard "$COMMIT_GUARD" 'git push origin --delete "develop"' trunk-direct warn
assert_deny "quoted develop の remote branch 削除も critical deny する"

run_bash_guard "$COMMIT_GUARD" 'git commit -m "--no-verify"' trunk-direct warn
assert_silent_allow "commit message の --no-verify は option と誤検出しない"

run_bash_guard "$COMMIT_GUARD" 'git commit -mno' trunk-direct warn
assert_silent_allow "-m の attached value 内の n は no-verify と誤検出しない"

run_bash_guard "$COMMIT_GUARD" 'git push -ofoo origin main' trunk-direct warn
assert_silent_allow "push-option の attached value 内の f は force と誤検出しない"

run_bash_guard "$COMMIT_GUARD" 'git push -rfoo origin main' trunk-direct warn
assert_silent_allow "receive-pack の attached value 内の f は force と誤検出しない"

run_bash_guard "$COMMIT_GUARD" 'git push -odeploy origin develop' trunk-direct warn
assert_silent_allow "push-option の attached value 内の d は delete と誤検出しない"

run_bash_guard "$COMMIT_GUARD" 'command git commit --no-verify -m test' trunk-direct warn
assert_deny "command prefix 経由の --no-verify も critical deny する"

run_bash_guard "$COMMIT_GUARD" 'env git push origin main --force' trunk-direct warn
assert_deny "env prefix 経由の main force push も critical deny する"

run_bash_guard "$COMMIT_GUARD" '/usr/bin/git branch -D develop' trunk-direct warn
assert_deny "absolute git path 経由の develop 削除も critical deny する"

run_bash_guard "$COMMIT_GUARD" 'FOO=bar git commit --no-verify -m test' trunk-direct warn
assert_deny "assignment prefix 経由の --no-verify も critical deny する"

run_bash_guard "$COMMIT_GUARD" 'sudo git commit --no-verify -m test' trunk-direct warn
assert_deny "sudo prefix 経由の --no-verify も critical deny する"

run_bash_guard "$COMMIT_GUARD" '"git" commit --no-verify -m test' trunk-direct warn
assert_deny "quoted git executable 経由の --no-verify も critical deny する"

run_bash_guard "$COMMIT_GUARD" '"/usr/bin/git" branch -D develop' trunk-direct warn
assert_deny "quoted absolute git executable 経由の develop 削除も critical deny する"

run_bash_guard "$COMMIT_GUARD" 'git commit -S --no-verify -m test' trunk-direct warn
assert_deny "bare -S の後の --no-verify を option value と誤認せず critical deny する"

run_bash_guard "$COMMIT_GUARD" 'git commit -u --no-verify -m test' trunk-direct warn
assert_deny "bare -u の後の --no-verify を option value と誤認せず critical deny する"

run_bash_guard "$COMMIT_GUARD" 'git push --force' trunk-direct warn
assert_deny "current main からの implicit force push を critical deny する"

run_bash_guard "$COMMIT_GUARD" 'git push origin --force' trunk-direct warn
assert_deny "origin のみ指定した implicit main force push を critical deny する"

run_bash_guard "$COMMIT_GUARD" 'git push --force-with-lease' trunk-direct warn
assert_deny "implicit main force-with-lease を critical deny する"

git -C "$REPO" switch -q -c feature/force-all
run_bash_guard "$COMMIT_GUARD" 'git push --force --all origin' trunk-direct warn
assert_deny "feature branch 上でも --force --all は main を含むため critical deny する"

run_bash_guard "$COMMIT_GUARD" 'git push --branches --force origin' trunk-direct warn
assert_deny "--branches alias の force push も critical deny する"

run_bash_guard "$COMMIT_GUARD" 'git push --mirror origin' trunk-direct warn
assert_deny "--mirror による protected refs の force 更新・削除を critical deny する"
git -C "$REPO" switch -q main

run_bash_guard "$COMMIT_GUARD" 'git push origin main --no-verify' trunk-direct warn
assert_deny "push の --no-verify も critical deny する"

run_bash_guard "$COMMIT_GUARD" 'git commit --trailer "--no-verify" -m test' trunk-direct warn
assert_silent_allow "trailer value の --no-verify は option と誤検出しない"

git -C "$REPO_B" switch -q -c feature/implicit-force
run_bash_guard "$COMMIT_GUARD" "cd \"$REPO_B\" | true; git push --force" trunk-direct warn
assert_deny "pipeline 内の cd を implicit force の branch context に漏洩させない"

run_bash_guard "$COMMIT_GUARD" "(cd \"$REPO_B\"); git push --force" trunk-direct warn
assert_deny "subshell 内の cd を implicit force の branch context に漏洩させない"
git -C "$REPO_B" switch -q main

git -C "$REPO" switch -q -c feature/source-context
run_bash_guard "$COMMIT_GUARD" "env -C \"$REPO_B\" git push --force" trunk-direct warn
assert_deny "env -C target の main branch への implicit force push を deny する"
git -C "$REPO" switch -q main

echo ""
echo "=== trunk-direct: commit workflow checks only relax ==="

run_bash_guard "$COMMIT_GUARD" 'git commit -m test' trunk-direct
assert_silent_allow "check0: main direct commit を許可する"

run_bash_guard "$COMMIT_GUARD" 'git checkout feature/policy' trunk-direct
assert_silent_allow "check3: main worktree の checkout を許可する"

run_bash_guard "$COMMIT_GUARD" 'git switch feature/policy' trunk-direct
assert_silent_allow "check3: main worktree の switch を許可する"

run_bash_guard "$COMMIT_GUARD" 'git merge feature/policy' trunk-direct
assert_silent_allow "check4: main への direct merge を許可する"

run_bash_guard "$COMMIT_GUARD" 'gh pr merge 42' trunk-direct
assert_silent_allow "check4b: main 向け gh pr merge を許可する"

run_bash_guard "$COMMIT_GUARD" 'git stash apply' trunk-direct
assert_silent_allow "check6: main worktree の stash apply を許可する"

run_bash_guard "$COMMIT_GUARD" 'git stash pop' trunk-direct
assert_silent_allow "check6: main worktree の stash pop を許可する"

run_bash_guard "$COMMIT_GUARD" 'git commit -m test --no-verify' trunk-direct warn
assert_deny "check1: trunk-direct でも --no-verify を deny する"
assert_contains "--no-verify 専用理由で deny する" "--no-verify"

run_bash_guard "$COMMIT_GUARD" 'git -C . commit -m test --no-verify' trunk-direct warn
assert_deny "check1: trunk-direct でも git -C 経由の --no-verify を deny する"
assert_contains "git -C でも --no-verify 専用理由で deny する" "--no-verify"

run_bash_guard "$COMMIT_GUARD" 'git push origin main --force' trunk-direct warn
assert_deny "check2: trunk-direct でも main force push を deny する"

run_bash_guard "$COMMIT_GUARD" 'git -C . push origin master --force' trunk-direct warn
assert_deny "check2: trunk-direct でも git -C 経由の master force push を deny する"

run_bash_guard "$COMMIT_GUARD" 'git branch -D develop' trunk-direct warn
assert_deny "check5: trunk-direct でも develop 削除を deny する"

echo ""
echo "=== trunk-direct: gh universal checks remain ==="

run_bash_guard "$GH_GUARD" 'gh pr review 42 --approve' trunk-direct
assert_silent_allow "main 向け gh pr approve workflow check を許可する"

run_bash_guard "$GH_GUARD" 'gh pr merge 42' trunk-direct
assert_silent_allow "main 向け gh pr merge workflow check を許可する"

run_bash_guard "$GH_GUARD" 'gh api repos/o/r/pulls/42/merge -X PUT' trunk-direct warn
assert_deny "trunk-direct でも API direct merge を deny する"

run_bash_guard "$GH_GUARD" '"/opt/homebrew/bin/gh" api repos/o/r/pulls/42/merge -X PUT' trunk-direct warn
assert_deny "quoted gh executable の API direct merge も deny する"

run_bash_guard "$GH_GUARD" "env -S 'gh api repos/o/r/pulls/42/merge -X PUT'" trunk-direct warn
assert_deny "env -S payload 内の gh API direct merge も deny する"

run_bash_guard "$GH_GUARD" 'gh api repos/o/r/pulls/42/reviews -f event=APPROVE' trunk-direct warn
assert_deny "trunk-direct でも API direct approve を deny する"

run_bash_guard "$GH_GUARD" '"curl" -X POST https://api.github.com/repos/o/r/pulls/42/reviews -d event=APPROVE' trunk-direct warn
assert_deny "quoted curl executable の API direct approve も deny する"

run_bash_guard "$GH_GUARD" 'env "--split-string=curl -X POST https://api.github.com/repos/o/r/pulls/42/reviews -d event=APPROVE"' trunk-direct warn
assert_deny "env --split-string= payload 内の curl API direct approve も deny する"

run_bash_guard "$GH_GUARD" 'gh pr merge 42' worktree-pr
assert_deny "worktree-pr は main 向け gh pr merge 防御を維持する"

run_bash_guard "$GH_GUARD" "env -S 'gh pr merge 42'" worktree-pr
assert_deny "env -S payload 内の gh pr merge も worktree-pr で deny する"

run_bash_guard "$GH_GUARD" 'gh pr review 42 --approve' worktree-pr
assert_deny "worktree-pr は main 向け gh pr approve 防御を維持する"

run_bash_guard "$GH_GUARD" "env -S 'gh pr review 42 --approve'" worktree-pr
assert_deny "env -S payload 内の gh pr approve も worktree-pr で deny する"

run_bash_guard "$GH_GUARD" 'gh pr merge 42' invalid-policy
assert_deny "不正値は main 向け gh pr merge 防御を緩和しない"

echo ""
echo "=== worktree policy and universal guards ==="

run_write_guard trunk-direct
assert_silent_allow "trunk-direct は main worktree edit を許可する"

run_write_guard trunk-direct warn worktree-guard
assert_deny "trunk-direct でも GUARD_FORCE_DENY=worktree-guard を優先する"

run_write_guard worktree-pr warn worktree-guard
assert_deny "worktree-pr + GUARD_FORCE_DENY は main worktree edit を deny する"

run_write_guard invalid-policy warn worktree-guard
assert_deny "不正値は worktree force-deny を緩和しない"

run_bash_guard "$WORKTREE_RM_GUARD" 'rm -rf .worktrees/old' trunk-direct warn
assert_deny "trunk-direct でも worktree-rm-guard は常時有効"

run_bash_guard "$MERGED_PUSH_GUARD" 'git push origin feat/merged' trunk-direct warn
assert_deny "trunk-direct でも merged-pr-push-guard は常時有効"

run_bash_guard "$DESTRUCTIVE_GUARD" 'rm -rf /etc/nginx' trunk-direct warn
assert_deny "trunk-direct でも critical path の再帰削除は常時 deny"

echo ""
echo "結果: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
