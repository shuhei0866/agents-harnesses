#!/usr/bin/env bash
# Tests for scripts/claude-profile
# （1Password の SDK の代わりに偽物を差し込み、専用の保管庫の外を読まないこと、トークンを
#   出力に出さないこと、上書きでメモ以外の欄を壊さないこと、名前の変更でタイトル以外の欄を、
#   タグを外すときにタグ以外の欄を壊さないこと、日本語のタグがある項目は SDK で保存できないと
#   知らせること、アーカイブした項目を数えないこと、差し替えは両方そろえたときだけ効くこと、
#   本体には決まった環境変数だけを渡すことを固定する）
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE="$SCRIPT_DIR/../claude-profile"

PASS=0
FAIL=0
T="$(mktemp -d "${TMPDIR:-/tmp}/test-claude-profile.XXXXXX")" || { echo "一時ディレクトリを作れませんでした" >&2; exit 1; }
trap 'if [ -n "${T:-}" ] && [ -d "$T" ]; then rm -rf "$T"; fi' EXIT

TOKEN_VALUE="ops_testtoken"

# --- 偽の SDK: 呼び出しを記録し、保管庫を JSON のファイルで真似る ---
cat > "$T/fake-sdk.mjs" <<'STUB'
import fs from "node:fs";
const dir = process.env.CLAUDE_PROFILE_TEST_DIR;
const statePath = `${dir}/state.json`;
const log = (entry) => fs.appendFileSync(`${dir}/calls`, `${JSON.stringify(entry)}\n`);
const load = () => JSON.parse(fs.readFileSync(statePath, "utf8"));
const save = (s) => fs.writeFileSync(statePath, JSON.stringify(s));
export const ItemCategory = { SecureNote: "SecureNote", Login: "Login" };
export async function createClient({ auth }) {
  log({ op: "createClient", authOk: auth === "ops_testtoken", envKeys: Object.keys(process.env).sort() });
  if (process.env.CLAUDE_PROFILE_TEST_FAIL === "1") throw new Error(`boom ${auth} ops_SECRETTOKEN123 住所: 東京都`);
  if (process.env.CLAUDE_PROFILE_TEST_FAIL === "net") throw new TypeError("fetch failed");
  if (process.env.CLAUDE_PROFILE_TEST_FAIL === "auth") throw new Error(`Unauthorized: invalid service account token ${auth}`);
  return {
    vaults: {
      list: async () => [{ id: "v1", title: "Claude" }, { id: "v2", title: "Private" }],
    },
    items: {
      list: async (vaultId) => {
        log({ op: "items.list", vaultId });
        return load().items.filter((i) => i.vaultId === vaultId)
          .map(({ id, title, vaultId, tags, state }) => ({ id, title, vaultId, tags, state: state ?? "active" }));
      },
      get: async (vaultId, id) => {
        log({ op: "items.get", vaultId, id });
        const item = load().items.find((i) => i.id === id && i.vaultId === vaultId);
        if (!item) throw new Error("not found");
        return structuredClone(item);
      },
      put: async (item) => {
        log({ op: "items.put", vaultId: item.vaultId, id: item.id });
        // 本物の SDK と同じく、ASCII 以外の文字を含むタグの項目は保存しない
        if ((item.tags ?? []).some((t) => /[^\x00-\x7f]/.test(t))) {
          throw new Error("invalid user input: encountered the following errors: tags list contains non-ascii characters");
        }
        const s = load();
        const next = structuredClone(item);
        if (process.env.CLAUDE_PROFILE_TEST_PUT_DROPS_FIELD === "1") next.fields = next.fields.filter((f) => f.id !== "username");
        next.version = (next.version ?? 0) + 1;
        s.items = s.items.map((i) => (i.id === item.id ? next : i));
        save(s);
        return next;
      },
      create: async (params) => {
        log({ op: "items.create", vaultId: params.vaultId, category: params.category, title: params.title });
        const s = load();
        const item = { id: `n${s.items.length}`, fields: [], sections: [], tags: [], websites: [], version: 1, ...params };
        s.items.push(item);
        save(s);
        return item;
      },
      archive: async (vaultId, id) => {
        log({ op: "items.archive", vaultId, id });
        const s = load();
        const item = s.items.find((i) => i.id === id && i.vaultId === vaultId);
        if (!item) throw new Error("not found");
        item.state = "archived";
        save(s);
      },
    },
  };
}
STUB

# --- 保管庫の中身（架空のデータ）。別の保管庫に同じ名前の項目を置き、混ざらないことを見る ---
cat > "$T/state.json" <<'JSON'
{"items":[
 {"id":"i1","title":"電話番号","category":"Login","vaultId":"v1","version":3,
  "fields":[{"id":"username","title":"username","fieldType":"Text","value":"keep-me"}],"sections":[],
  "notes":"080-0000-0000","tags":["Claude","LastPass"],"websites":[{"url":"http://sn","label":"website"}]},
 {"id":"i2","title":"氏名","category":"SecureNote","vaultId":"v1","version":1,"fields":[],"sections":[],
  "notes":"氏名: 山田 太郎\nフリガナ: ヤマダ タロウ","tags":[],"websites":[]},
 {"id":"i3","title":"診察券/〇〇クリニック","category":"SecureNote","vaultId":"v1","version":1,"fields":[],"sections":[],
  "notes":"診察券番号: 0000-1111","tags":[],"websites":[]},
 {"id":"i4","title":"身元","category":"Identity","vaultId":"v1","version":1,"fields":[],"sections":[],
  "notes":"","tags":[],"websites":[]},
 {"id":"p1","title":"電話番号","category":"Login","vaultId":"v2","version":1,"fields":[],"sections":[],
  "notes":"999-should-not-read","tags":[],"websites":[]}
]}
JSON

export CLAUDE_PROFILE_TEST_DIR="$T" CLAUDE_PROFILE_TEST_SDK="$T/fake-sdk.mjs" CLAUDE_PROFILE_TEST_TOKEN="$TOKEN_VALUE"

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

ok() {
  local desc="$1"
  shift
  if "$@"; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc"
    echo "    calls:"; sed 's/^/      /' "$T/calls" 2>/dev/null
    echo "    出力: $OUT"
    FAIL=$((FAIL + 1))
  fi
}

run() {
  : > "$T/calls"
  OUT=$("$PROFILE" "$@" 2>&1 < "${STDIN_FILE:-/dev/null}")
  STATUS=$?
}

json_ok() { jq -e "$1" "$2" >/dev/null; }
only_claude_vault() { jq -se '[.[] | select(.op | startswith("items.")) | .vaultId] | length > 0 and all(. == "v1")' "$T/calls" >/dev/null; }
token_reached_sdk() { jq -se 'any(.[]; .op == "createClient" and .authOk)' "$T/calls" >/dev/null; }
no_token_in_output() { ! printf '%s' "$OUT" | grep -qF "$TOKEN_VALUE"; }
no_calls() { ! grep -q . "$T/calls"; }

echo "=== 読み出し ==="
run get 電話番号;                  check "項目のメモを返す" 0 "080-0000-0000"
ok "専用の保管庫の項目だけを読む" only_claude_vault
ok "トークンは SDK に届く" token_reached_sdk
ok "トークンを出力に出さない" no_token_in_output
run get 氏名 フリガナ;             check "キーの値だけを返す" 0 "ヤマダ タロウ"
run get 氏名 本籍;                 check "無いキーはエラー" 1 "キーが見つかりません"
run get 診察券/〇〇クリニック;     check "階層つきの名前はタイトルそのもので引く" 0 "診察券番号: 0000-1111"
run get ../Personal/Bank;          check "親ディレクトリへの参照を拒む" 1 "項目名が不正"
run get /Personal/Bank;            check "絶対名を拒む" 1 "項目名が不正"
run get 無い項目;                  check "無い項目はエラー" 1 "項目が見つかりません"
run list;                          check "一覧はタイトルを返す" 0 "診察券/〇〇クリニック"
ok "一覧に別の保管庫の項目を混ぜない" bash -c '[ "$(printf "%s\n" "$1" | grep -c .)" -eq 4 ]' _ "$OUT"
run;                               check "コマンドなしは使い方を出す" 1 "使い方:"

echo ""
echo "=== 書き込み ==="
printf '東京都千代田区1-1\n\n' > "$T/in"; STDIN_FILE="$T/in"
run set 住所;                      check "新規はメモの項目として作り、読み戻して確かめる" 0 "保存しました: 住所"
ok "新規作成は専用の保管庫にメモとして作る" jq -se 'any(.[]; .op == "items.create" and .vaultId == "v1" and .category == "SecureNote" and .title == "住所")' "$T/calls"
ok "末尾の改行を落として保存する" json_ok '.items[] | select(.title == "住所") | .notes == "東京都千代田区1-1"' "$T/state.json"
printf '090-1111-2222' > "$T/in"
run set 電話番号;                  check "既存は上書きする" 0 "保存しました: 電話番号"
ok "上書きでメモ以外の欄とタグと URL を残す" json_ok '
  .items[] | select(.id == "i1")
  | (.tags == ["Claude","LastPass"]) and (.websites[0].url == "http://sn")
    and ([.fields[] | select(.id == "username") | .value] == ["keep-me"]) and (.notes == "090-1111-2222")' "$T/state.json"
ok "別の保管庫の同じ名前の項目には触れない" json_ok '.items[] | select(.id == "p1") | .notes == "999-should-not-read"' "$T/state.json"
printf '090-3333-4444' > "$T/in"
CLAUDE_PROFILE_TEST_PUT_DROPS_FIELD=1 run set 電話番号; check "上書きでメモ以外の欄が消えたら止めて知らせる" 1 "メモ以外の欄が変わりました"
printf '東京都' > "$T/in"
run set 身元;                      check "ログインとメモ以外の種類は書き換えない" 1 "この種類の項目（Identity）は claude-profile では書き換えません"
ok "書き換えない種類には put を送らない" bash -c '! grep -q "items.put" "$1"' _ "$T/calls"
: > "$T/empty"; STDIN_FILE="$T/empty"
run set 住所;                      check "空の入力は保存しない" 1 "標準入力が空です"
unset STDIN_FILE

echo ""
echo "=== 名前の変更・タグ・アーカイブ ==="
# 取り込んだままのログインの項目（欄・URL と、取り込みで入れ子になった日本語のタグつき）を足す。
# ほかに、日本語のタグが2つある項目と、欄が消えたときの確かめに使う項目も足す
jq '.items += [
  {"id":"r1","title":"〇〇歯科","category":"Login","vaultId":"v1","version":2,
   "fields":[{"id":"username","title":"username","fieldType":"Text","value":"keep-me"}],"sections":[],
   "notes":"診察券番号: 2222-3333","tags":["Claude/診察券","LastPass"],"websites":[{"url":"http://sn","label":"website"}]},
  {"id":"r2","title":"欄の確かめ1","category":"Login","vaultId":"v1","version":1,
   "fields":[{"id":"username","title":"username","fieldType":"Text","value":"keep-me"}],"sections":[],
   "notes":"x","tags":["Claude"],"websites":[]},
  {"id":"r3","title":"欄の確かめ2","category":"Login","vaultId":"v1","version":1,
   "fields":[{"id":"username","title":"username","fieldType":"Text","value":"keep-me"}],"sections":[],
   "notes":"x","tags":["Claude","LastPass"],"websites":[]},
  {"id":"r4","title":"△△眼科","category":"Login","vaultId":"v1","version":1,
   "fields":[{"id":"username","title":"username","fieldType":"Text","value":"keep-me"}],"sections":[],
   "notes":"x","tags":["Claude/診察券","通院"],"websites":[]}]' \
  "$T/state.json" > "$T/state.next" && mv "$T/state.next" "$T/state.json"
run rename 〇〇歯科 診察券/〇〇歯科;  check "日本語のタグがある項目は SDK で保存できないと知らせる" 1 "タグに ASCII 以外の文字があり"
ok "保存できなかった項目の名前は変わらない" json_ok '.items[] | select(.id == "r1") | .title == "〇〇歯科"' "$T/state.json"
run untag 〇〇歯科 Claude/診察券;    check "タグを外す" 0 "タグを外しました: 〇〇歯科（Claude/診察券）"
ok "外したタグのほかの欄とタグは残る" json_ok '
  .items[] | select(.id == "r1")
  | (.title == "〇〇歯科") and (.notes == "診察券番号: 2222-3333") and (.tags == ["LastPass"])
    and (.websites[0].url == "http://sn") and ([.fields[] | select(.id == "username") | .value] == ["keep-me"])' "$T/state.json"
run rename 〇〇歯科 診察券/〇〇歯科;  check "名前を変える" 0 "名前を変えました: 〇〇歯科 → 診察券/〇〇歯科"
ok "名前だけが変わり、メモ・欄・タグ・URL は残る" json_ok '
  .items[] | select(.id == "r1")
  | (.title == "診察券/〇〇歯科") and (.notes == "診察券番号: 2222-3333") and (.tags == ["LastPass"])
    and (.websites[0].url == "http://sn") and ([.fields[] | select(.id == "username") | .value] == ["keep-me"])' "$T/state.json"
ok "名前の変更は専用の保管庫の中だけで行う" only_claude_vault
run get 診察券/〇〇歯科;             check "新しい名前で引ける" 0 "診察券番号: 2222-3333"
run get 〇〇歯科;                    check "古い名前では引けない" 1 "項目が見つかりません"
run rename 氏名 住所;                check "すでにある名前へは変えない" 1 "同じ名前の項目がすでにあります: 住所"
ok "すでにある名前へは put を送らない" bash -c '! grep -q "items.put" "$1"' _ "$T/calls"
run rename 氏名 氏名;                check "今と同じ名前への変更は止める" 1 "新しい名前が今の名前と同じです"
run rename 無い項目 何か;            check "無い項目の名前は変えない" 1 "項目が見つかりません"
run rename 身元 身元2;               check "ログインとメモ以外の種類の名前は変えない" 1 "この種類の項目（Identity）は claude-profile では書き換えません"
run rename 氏名 ../Personal/x;       check "新しい名前も確かめる" 1 "項目名が不正"
run rename 氏名;                     check "新しい名前が無ければ使い方を出す" 1 "使い方: claude-profile rename"
run rename 氏名 新しい 名前;         check "名前が分かれて引数が余ったら、変えずに使い方を出す" 1 "使い方: claude-profile rename"
ok "引数が余ったら SDK を呼ばない" no_calls
run untag 診察券/〇〇歯科 LastPass 余り; check "untag も引数が余ったら使い方を出す" 1 "使い方: claude-profile untag"
run archive 無い項目 余り;           check "archive も引数が余ったら使い方を出す" 1 "使い方: claude-profile archive"
run list 余り;                       check "list も引数が余ったら使い方を出す" 1 "使い方: claude-profile list"
run untag 診察券/〇〇歯科 無いタグ;  check "無いタグは外さず、今のタグを知らせる" 1 "タグが見つかりません: 無いタグ（この項目のタグ: LastPass）"
ok "無いタグには put を送らない" bash -c '! grep -q "items.put" "$1"' _ "$T/calls"
run untag 身元 Claude;               check "ログインとメモ以外の種類のタグは外さない" 1 "この種類の項目（Identity）は claude-profile では書き換えません"
run untag 診察券/〇〇歯科;           check "タグが無ければ使い方を出す" 1 "使い方: claude-profile untag"
run untag △△眼科 Claude/診察券;      check "日本語のタグが残ると、外しても保存できずアプリで直すよう知らせる" 1 "ユーザーがアプリでタグを直してください"
ok "保存できなかった項目のタグは変わらない" json_ok '.items[] | select(.id == "r4") | .tags == ["Claude/診察券","通院"]' "$T/state.json"
CLAUDE_PROFILE_TEST_PUT_DROPS_FIELD=1 run rename 欄の確かめ1 欄の確かめ1b; check "名前の変更で他の欄が消えたら止めて知らせる" 1 "名前以外の欄が変わりました"
CLAUDE_PROFILE_TEST_PUT_DROPS_FIELD=1 run untag 欄の確かめ2 LastPass;   check "タグを外すときに他の欄が消えたら止めて知らせる" 1 "タグ以外の欄が変わりました"
run archive 住所;                    check "アーカイブする" 0 "アーカイブしました: 住所"
ok "アーカイブは専用の保管庫の項目に送る" jq -se 'any(.[]; .op == "items.archive" and .vaultId == "v1")' "$T/calls"
run list
ok "アーカイブした項目は一覧に出ない" bash -c '[ "$1" -eq 0 ] && ! printf "%s\n" "$2" | grep -qx "住所"' _ "$STATUS" "$OUT"
run archive 無い項目;                check "無い項目はアーカイブしない" 1 "項目が見つかりません"
ok "無い項目には archive を送らない" bash -c '! grep -q "items.archive" "$1"' _ "$T/calls"
printf '東京都' > "$T/in"; STDIN_FILE="$T/in"
run set 住所;                        check "アーカイブした名前で作り直せる" 0 "保存しました: 住所"
unset STDIN_FILE
run;                                 check "使い方に rename と archive を載せる" 1 "claude-profile archive <項目>"

echo ""
echo "=== トークンと差し替え ==="
CLAUDE_PROFILE_TEST_FAIL=1 run list;              check "SDK のエラーは分類だけを出す" 1 "1Password の操作に失敗しました（Error）"
ok "SDK のエラーの文面（トークンやメモ）をそのまま出さない" bash -c '! printf "%s" "$1" | grep -qE "ops_testtoken|ops_SECRETTOKEN123|東京都|boom"' _ "$OUT"
CLAUDE_PROFILE_TEST_FAIL=net run list;            check "通信の失敗はそう分類する" 1 "通信に失敗しました"
CLAUDE_PROFILE_TEST_FAIL=auth run list;           check "認証の失敗はそう分類する" 1 "認証に失敗しました"
ok "認証のエラーにトークンを出さない" no_token_in_output
printf '%s\n' 'import fs from "node:fs";' "fs.writeFileSync(\"$T/injected\", \"x\");" > "$T/inject.mjs"
NODE_OPTIONS="--import=$T/inject.mjs" run get 氏名 フリガナ; check "NODE_OPTIONS を付けても普通に読める" 0 "ヤマダ タロウ"
ok "NODE_OPTIONS で差し込んだコードは動かない" bash -c '[ ! -e "$1" ]' _ "$T/injected"
# OPENSSL_CONF は Node の起動時に読まれ、provider の共有ライブラリを読み込ませられる
# （無い provider を指す設定を読むと、Node は起動の途中で落ちる）
printf '%s\n' 'nodejs_conf = nodejs_init' '[nodejs_init]' 'providers = provider_sect' '[provider_sect]' \
  'evil = evil_sect' '[evil_sect]' "module = $T/no-such-provider.dylib" 'activate = 1' > "$T/evil.cnf"
OPENSSL_CONF="$T/evil.cnf" run get 氏名 フリガナ; check "OPENSSL_CONF を付けても普通に読める" 0 "ヤマダ タロウ"
NODE_DEBUG=fetch UNRELATED_VAR=x run status;      check "決まった変数のほかを付けても動く" 0 "接続できます"
# （__CF_USER_TEXT_ENCODING は macOS が node の起動時に足す文字コードの指定）
ok "本体には決まった環境変数だけが届く" jq -se '[.[] | select(.op == "createClient") | .envKeys[]]
  | length > 0 and all(test("^(HOME|USER|PATH|TMPDIR|NODE_USE_ENV_PROXY|NODE_NO_WARNINGS|https?_proxy|HTTPS?_PROXY|no_proxy|NO_PROXY|CLAUDE_PROFILE_[A-Z_]+|__CF_USER_TEXT_ENCODING)$"))' "$T/calls"
: > "$T/calls"
OUT=$(env -u CLAUDE_PROFILE_TEST_TOKEN "$PROFILE" get 電話番号 2>&1 < /dev/null); STATUS=$?
check "偽の SDK だけを指定したら止める" 1 "そろえて指定してください"
ok "偽の SDK だけでは何も呼ばない" no_calls
OUT=$(env -u CLAUDE_PROFILE_TEST_SDK "$PROFILE" get 電話番号 2>&1 < /dev/null); STATUS=$?
check "偽のトークンだけを指定したら止める" 1 "そろえて指定してください"
OUT=$(bash -x "$PROFILE" get 電話番号 2>&1 < /dev/null)
ok "bash -x で動かしてもトークンを表示しない" no_token_in_output

echo ""
echo "=== 結果: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
