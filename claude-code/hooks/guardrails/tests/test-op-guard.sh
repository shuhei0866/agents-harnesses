#!/usr/bin/env bash
# Tests for guardrails/op-guard.sh
# （op の直接実行とキーチェーンの秘密の読み出しを止め、claude-profile 経由と単なる言及は通すことを固定する）
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/../op-guard.sh"

PASS=0
FAIL=0
TMPDIR_TEST="$(mktemp -d "${TMPDIR:-/tmp}/test-op-guard.XXXXXX")" || { echo "一時ディレクトリを作れませんでした" >&2; exit 1; }

cleanup() {
  if [ -n "${TMPDIR_TEST:-}" ] && [ -d "$TMPDIR_TEST" ]; then
    rm -rf "$TMPDIR_TEST"
  fi
}
trap cleanup EXIT

OUT=""
ERR=""
STATUS=0
run_guard() {
  local cmd="$1"
  local errf="$TMPDIR_TEST/stderr"
  OUT=$( (cd "$TMPDIR_TEST" && jq -n --arg c "$cmd" '{tool_input:{command:$c}}' \
    | env -u CLAUDE_PROJECT_DIR -u GUARD_SKIP -u GUARD_LEVEL -u GUARD_FORCE_DENY -u GIT_WORKFLOW bash "$GUARD" 2>"$errf") )
  STATUS=$?
  ERR=$(cat "$errf" 2>/dev/null || echo "")
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

assert_pass() {
  local desc="$1"
  if [ "$STATUS" -eq 0 ] && [ -z "$ERR" ] && [ -z "$OUT" ]; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc"
    echo "    expected: 素通し / status: $STATUS / stderr: ${ERR:-無し} / output: ${OUT:-（出力なし）}"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== op の直接実行はブロックする ==="
run_guard 'op item list';                                      assert_deny "op item list"
run_guard 'op read op://Example/item/notesPlain';              assert_deny "op read"
run_guard 'op';                                                assert_deny "サブコマンドなしの op"
run_guard '/opt/homebrew/bin/op item get x';                   assert_deny "絶対パスの op"
run_guard 'OP_SERVICE_ACCOUNT_TOKEN=x op vault list';          assert_deny "変数の代入を前に付けた op"
run_guard 'env op item list';                                  assert_deny "env 経由"
run_guard 'xargs -n 1 op item get';                            assert_deny "xargs 経由"
run_guard 'env -u FOO op item list';                           assert_deny "値を取る env -u の後ろの op"
run_guard 'sudo -u root op vault list';                        assert_deny "値を取る sudo -u の後ろの op"
run_guard 'xargs -I {} op item get {}';                        assert_deny "値を取る xargs -I の後ろの op"
run_guard 'timeout -s KILL 5 op read x';                       assert_deny "値を取る timeout -s の後ろの op"
run_guard 'cd /tmp && op item list';                           assert_deny "&& の後ろの op"
run_guard "cd /tmp
op item list";                                                 assert_deny "改行の後ろの op"
run_guard 'echo $(op item get x)';                             assert_deny "\$( ) の中の op"
run_guard 'echo "$(op read x)"';                               assert_deny "二重引用符の中の \$( )"
run_guard 'echo `op item get x`';                              assert_deny "バッククォートの中の op"
run_guard "bash -c 'op item list'";                            assert_deny "bash -c の中の op"
run_guard "python3 -c \"import subprocess; subprocess.run(['op','item','list'])\""; assert_deny "python から op を呼ぶ"
run_guard "o''p item list";                                    assert_deny "空の引用符で分けた o''p"
run_guard 'if op item list; then :; fi';                       assert_deny "if の条件の op"
run_guard 'if op unknown-subcommand; then :; fi';              assert_deny "if の条件の、サブコマンドの分からない op"
run_guard '! op item list';                                    assert_deny "! の後ろの op"
run_guard 'for i in 1; do op item list; done';                 assert_deny "do の後ろの op"
run_guard '{ op item list; }';                                 assert_deny "{ } の中の op"
run_guard 'find . -maxdepth 0 -exec op item list \;';          assert_deny "find -exec の後ろの op"
run_guard "bash -c 'op --account x item list'";                assert_deny "bash -c の中でオプションを挟んだ op"
run_guard "bash -c 'op --format json item list'";              assert_deny "bash -c の中で値を取るオプションを挟んだ op"
run_guard "echo 'op item list' | bash";                        assert_deny "パイプでシェルに渡す op"
run_guard "\"bash\" -c 'op item list'";                        assert_deny "引用符で囲んだシェルの名前"
run_guard "python3 <<'EOF'
import subprocess
subprocess.run(['op', 'item', 'list'])
EOF";                                                          assert_deny "python の heredoc から op を呼ぶ"

echo ""
echo "=== キーチェーンの秘密の読み出しはブロックする ==="
run_guard 'security find-generic-password -s claude-profile-op-token -w'; assert_deny "トークンを名指しする -w"
run_guard 'security find-generic-password -l claude-profile-op-token -g'; assert_deny "label でトークンを名指しする -g"
run_guard 'security find-generic-password -gs claude-profile-op-token';   assert_deny "まとめて書いた -gs でトークンを名指し"
run_guard 'security find-generic-password -a me -w';                 assert_deny "service も label も指定しない -w"
run_guard 'x="$(security find-generic-password -w -s claude-profile-op-token)"'; assert_deny "\$( ) でトークンを変数に読む"
run_guard 'env -u FOO security find-generic-password -s claude-profile-op-token -w'; assert_deny "値を取る env -u の後ろの security"
run_guard '/usr/bin/security dump-keychain -d';                      assert_deny "dump-keychain"
run_guard "printf 'find-generic-password -s x -w\\n' | security -i"; assert_deny "標準入力から読む security -i"
run_guard "bash -c 'security find-generic-password -s claude-profile-op-token -w'"; assert_deny "bash -c の中の security"
run_guard "bash -c 'security find-generic-password -a me -w'";      assert_deny "bash -c の中で service を指定しない -w"
run_guard "bash -c 'security find-generic-password -a me -w'; ls -l"; assert_deny "別のコマンドの -l を label の指定と数えない"
run_guard 'if security find-generic-password -s claude-profile-op-token -w; then :; fi'; assert_deny "if の条件の security"
run_guard 'while ! security find-generic-password -a me -w; do :; done'; assert_deny "while ! の後ろの security"
run_guard 'security -qi';                                            assert_deny "まとめて書いた -qi（対話）"
run_guard "bash -c 'security -q -i'";                                assert_deny "bash -c の中で、ほかのオプションの後ろに置いた -i"
run_guard "bash -c 'security find-generic-password -a me -w' -- -s example-api-key"; assert_deny "bash -c の外側の -s を、内側の service の指定と数えない"
run_guard "bash -c 'security find-generic-password -a me -w' -s example-api-key";    assert_deny "-- が無くても、外側の -s を内側の指定と数えない"
run_guard 'security find-generic-password -a me -w login.keychain-db -s example-api-key'; assert_deny "鍵束の名前の後ろの -s は service の指定にならない"
run_guard 'security find-generic-password -a me -w -- -s example-api-key'; assert_deny "-- の後ろの -s は service の指定にならない"
run_guard "bash -c 'security find-generic-password -a me -w login.keychain-db -s example-api-key'"; assert_deny "bash -c の中でも、鍵束の名前の後ろの -s は指定にならない"
run_guard 'security find-generic-password -sclaude-profile-op-token -w';   assert_deny "値を続けて書いた -s でトークンを名指し"
run_guard 'security find-generic-password 2>/dev/null -a me -w';           assert_deny "リダイレクトを挟んでも後ろの -w を数える"
run_guard 'security find-generic-password -a 2>/dev/null me -w';           assert_deny "値の前にリダイレクトを挟んでも、値と -w を取り違えない"
run_guard "bash -c 'security find-generic-password -a \"My User\" -w'";    assert_deny "bash -c の中で空白を含む値の後ろの -w"

echo ""
echo "=== claude-profile の差し替え変数はブロックする ==="
run_guard 'CLAUDE_PROFILE_TEST_SDK=/tmp/x.mjs CLAUDE_PROFILE_TEST_TOKEN=x claude-profile get 電話番号'; assert_deny "差し替え変数を付けた claude-profile"
run_guard 'export CLAUDE_PROFILE_TEST_SDK=/tmp/x.mjs';               assert_deny "差し替え変数の export"

echo ""
echo "=== 許可する ==="
run_guard 'op --version';                                       assert_pass "op --version"
run_guard '~/agents-harnesses/claude-code/scripts/claude-profile get 電話番号'; assert_pass "claude-profile 経由"
run_guard 'grep -n op README.md';                               assert_pass "引数としての op"
run_guard 'ls ~/.config/op';                                    assert_pass "パスの一部としての op"
run_guard 'git commit -m "use op service account in claude-profile"'; assert_pass "引用符で囲んだ文章の中の op"
run_guard "cat > notes.md <<'EOF'
op item list
EOF";                                                           assert_pass "heredoc 本文の中の op"
run_guard 'security find-generic-password -s example-token';    assert_pass "属性だけの確認（-w なし）"
run_guard 'key="$(security find-generic-password -w -a "$USER" -s example-api-key)"'; assert_pass "別のサービスの鍵を値を出さずに変数へ読む"
run_guard 'security find-internet-password -s example.com -g'; assert_pass "別のサービスを名指しする -g"
run_guard 'security list-keychains';                            assert_pass "security list-keychains"
run_guard 'bash claude-code/scripts/tests/test-claude-profile.sh'; assert_pass "テストの実行"
run_guard 'npm run stop';                                       assert_pass "op を含む別の語"
run_guard 'command -v op';                                      assert_pass "op が入っているかの確認"
run_guard 'if [ -x "$(command -v op)" ]; then echo ok; fi';     assert_pass "\$( ) の中の command -v op"
run_guard 'git commit -m "fix: op item list in docs"';          assert_pass "引用符で囲んだ文章の中の op <サブコマンド>"
run_guard 'if security find-generic-password -s example-token >/dev/null; then echo ok; fi'; assert_pass "if の条件で属性だけを確認する"
run_guard 'git commit -m "fix: bash wrapper for op item list"'; assert_pass "引用符で囲んだ文章の中のシェルの名前と op <サブコマンド>"
run_guard "gh pr create --title fix --body \"bash -c 'security find-generic-password -a me -w' is now blocked\""; assert_pass "本文の中のシェルの名前と security の例"
run_guard 'command -v op whoami';                               assert_pass "command -v に複数の名前を渡す"
run_guard 'type op whoami';                                     assert_pass "type で種類を表示する"
run_guard 'security find-internet-password -sexample.com -g';   assert_pass "値を続けて書いた -s で別のサービスを名指しする -g"
run_guard 'security find-generic-password -gsexample-api-key';  assert_pass "まとめて書いた -gs に値を続けて書く"
run_guard 'key="$(security find-generic-password -w -a "$USER" -s example-api-key 2>/dev/null)"'; assert_pass "リダイレクトの付いた、別のサービスの鍵の読み込み"
run_guard "key=\"\$(security find-generic-password -w -a 'My User' -s example-api-key)\""; assert_pass "空白を含む値の後ろに service を指定する鍵の読み込み"

echo ""
echo "=== 結果: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
