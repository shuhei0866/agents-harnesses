#!/usr/bin/env bash
# Tests for scripts/claude-profile
# （本物の lpass の代わりにスタブを差し込み、Claude/ の外を読まないことと、
#   書き込み後に同期して一覧で確かめることを固定する）
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE="$SCRIPT_DIR/../claude-profile"

PASS=0
FAIL=0
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

# --- スタブ lpass: 呼び出しを記録し、決まった応答を返す ---
cat > "$T/lpass" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUB_DIR/calls"
case "$1" in
  status)
    [ "${STUB_LOGGED_OUT:-0}" = "1" ] && exit 1
    echo "Logged in as test@example.com." ;;
  ls)
    printf 'Claude/電話番号 [id: 1]\nClaude/氏名 [id: 2]\n'
    [ -f "$STUB_DIR/added" ] && sed 's/$/ [id: 9]/' "$STUB_DIR/added"
    exit 0 ;;
  show)
    name="${@: -1}"
    case "$name" in
      Claude/電話番号) echo "080-0000-0000" ;;
      Claude/氏名) printf '氏名: 山田 太郎\nフリガナ: ヤマダ タロウ\n' ;;
      *) echo "Error: Could not find specified account(s)." >&2; exit 1 ;;
    esac ;;
  add)
    cat > /dev/null
    echo "${@: -1}" >> "$STUB_DIR/added" ;;
  edit)
    cat > /dev/null ;;
  sync)
    exit 0 ;;
esac
STUB
chmod +x "$T/lpass"
export STUB_DIR="$T" LPASS_BIN="$T/lpass" LPASS_HOME="$T/lpass-home" CLAUDE_PROFILE_SYNC_WAIT=1
mkdir -p "$LPASS_HOME/upload-queue"

check() {
  local desc="$1" expected_status="$2" expected_out="$3"
  if [ "$STATUS" -eq "$expected_status" ] && printf '%s' "$OUT" | grep -qF -- "$expected_out"; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc"
    echo "    expected: status=$expected_status, 出力に「${expected_out}」 / actual: status=$STATUS, 出力=$OUT"
    FAIL=$((FAIL + 1))
  fi
}

run() {
  : > "$T/calls"
  OUT=$("$PROFILE" "$@" 2>&1 < "${STDIN_FILE:-/dev/null}")
  STATUS=$?
}

echo "=== 読み出し ==="
run get 電話番号;                check "項目のメモを返す" 0 "080-0000-0000"
grep -qx 'show --notes Claude/電話番号' "$T/calls" && { echo "  PASS: Claude/ を付けて show する"; PASS=$((PASS+1)); } \
  || { echo "  FAIL: Claude/ を付けて show する"; cat "$T/calls"; FAIL=$((FAIL+1)); }
run get 氏名 フリガナ;           check "キーの値だけを返す" 0 "ヤマダ タロウ"
run get 氏名 本籍;               check "無いキーはエラー" 1 "キーが見つかりません"
run get ../Personal/Bank;        check "親ディレクトリへの参照を拒む" 1 "項目名が不正"
run get /Personal/Bank;          check "絶対名を拒む" 1 "項目名が不正"
run get 無い項目;                check "無い項目はエラー" 1 "項目が見つかりません"
run list;                        check "一覧は Claude/ を外して返す" 0 "電話番号"

echo ""
echo "=== 書き込み ==="
printf '東京都千代田区1-1' > "$T/in"; STDIN_FILE="$T/in"
run set 住所;                    check "新規は add して一覧で確かめる" 0 "保存しました: Claude/住所"
grep -q '^add .*Claude/住所$' "$T/calls" && grep -qx 'sync' "$T/calls" \
  && { echo "  PASS: add のあとに sync する"; PASS=$((PASS+1)); } \
  || { echo "  FAIL: add のあとに sync する"; cat "$T/calls"; FAIL=$((FAIL+1)); }
run set 電話番号;                check "既存は edit で上書きする" 0 "保存しました: Claude/電話番号"
grep -q '^edit .*--notes Claude/電話番号$' "$T/calls" \
  && { echo "  PASS: 既存項目は edit を使う"; PASS=$((PASS+1)); } \
  || { echo "  FAIL: 既存項目は edit を使う"; cat "$T/calls"; FAIL=$((FAIL+1)); }
touch "$LPASS_HOME/upload-queue/stuck"
run set 郵便番号;                check "キューが空にならなければ失敗を返す" 1 "送信待ちキューが空になりません"
rm -f "$LPASS_HOME/upload-queue/stuck"
unset STDIN_FILE

echo ""
echo "=== ログインしていない ==="
STUB_LOGGED_OUT=1 run get 電話番号; check "ログインを促して止まる" 1 "lpass にログインしていません"

echo ""
echo "=== 結果: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
