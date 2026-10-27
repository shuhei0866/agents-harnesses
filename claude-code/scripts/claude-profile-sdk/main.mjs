// claude-profile の本体: 1Password の公式 SDK で、専用の保管庫だけを読み書きする。
// 入口は ../claude-profile（使い方と準備はそちらの冒頭と README）。トークンはここで
// macOS のキーチェーンから読み、SDK にだけ渡す。引数・出力・エラーには出さない。
import { execFileSync } from "node:child_process";
import os from "node:os";
import { fileURLToPath, pathToFileURL } from "node:url";

const VAULT = process.env.CLAUDE_PROFILE_VAULT || "Claude";
const TOKEN_SERVICE = process.env.CLAUDE_PROFILE_TOKEN_SERVICE || "claude-profile-op-token";
// テスト専用の差し替え。偽の SDK とトークンを両方そろえたときだけ効き、そのときは
// 本物のキーチェーンを読まない（片方だけ指定して本物のトークンを偽物へ渡すことを防ぐ）
const TEST_SDK = process.env.CLAUDE_PROFILE_TEST_SDK || "";
const TEST_TOKEN = process.env.CLAUDE_PROFILE_TEST_TOKEN || "";

const USAGE = `使い方:
  claude-profile status                  キーチェーンのトークンで保管庫に届くか
  claude-profile list                    項目名
  claude-profile get <項目> [<キー>]      項目のメモ全体、または「キー: 値」の値だけ
  claude-profile set <項目> < 値           項目を作成または上書き（標準入力をメモにする）
  claude-profile rename <項目> <新しい名前>  項目名を変える（メモとほかの欄はそのまま）
  claude-profile untag <項目> <タグ>       項目からタグを1つ外す（ほかの欄はそのまま）
  claude-profile archive <項目>          項目をアーカイブする（1Password アプリのアーカイブから戻せる）
`;

let token = "";

// トークンそのものと、トークンに見える文字列を伏せる
function mask(text) {
  let s = String(text);
  if (token) s = s.split(token).join("ops_***");
  return s.replace(/ops_[A-Za-z0-9_.+/=-]+/g, "ops_***");
}

function die(message) {
  process.stderr.write(`claude-profile: ${mask(message)}\n`);
  process.exit(1);
}

// SDK や fetch のエラーの文面にはメモの中身やリクエストの情報が載りうるので、そのまま出さずに分類だけ出す
function reason(e) {
  const text = [e?.name, e?.message ?? e, e?.cause?.code, e?.cause?.message].filter(Boolean).join(" ");
  if (/fetch failed|ENOTFOUND|ECONNREFUSED|ECONNRESET|ETIMEDOUT|EAI_AGAIN|proxy|certificate|TLS|socket/i.test(text)) {
    return "通信に失敗しました（ネットワーク・プロキシ・証明書のどれか）";
  }
  if (/unauthori[sz]ed|forbidden|\b40[13]\b|\btoken\b|\bauth/i.test(text)) {
    return "認証に失敗しました（トークンが失効しているか、保管庫への権限がありません）";
  }
  // SDK は ASCII 以外の文字を含むタグの項目を保存しない（取り込みで入れ子のタグになったフォルダ名など）
  if (/tags list contains non-ascii/i.test(text)) {
    return "この項目のタグに ASCII 以外の文字があり、1Password の SDK では保存できません（claude-profile untag でそのタグを外すか、ユーザーがアプリで直してください）";
  }
  return `1Password の操作に失敗しました（${e?.name || "Error"}）`;
}

process.on("unhandledRejection", (e) => die(reason(e)));
process.on("uncaughtException", (e) => die(reason(e)));

function validName(name) {
  if (!name) die("項目名が空です");
  if (name.startsWith("/") || name.endsWith("/") || name.includes("//") || name.includes("..") || /[\n\t]/.test(name)) {
    die(`項目名が不正です: ${name}`);
  }
}

function readToken() {
  if (TEST_SDK || TEST_TOKEN) {
    if (!TEST_SDK || !TEST_TOKEN) {
      die("テスト用の差し替えは CLAUDE_PROFILE_TEST_SDK と CLAUDE_PROFILE_TEST_TOKEN をそろえて指定してください");
    }
    return TEST_TOKEN;
  }
  let value = "";
  try {
    value = execFileSync(
      "/usr/bin/security",
      ["find-generic-password", "-a", process.env.USER || os.userInfo().username, "-s", TOKEN_SERVICE, "-w"],
      { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] },
    ).trim();
  } catch {
    value = "";
  }
  if (!value) {
    die(`1Password のトークンがキーチェーンにありません（service: ${TOKEN_SERVICE}）。ユーザーが自分のターミナルで登録してください`);
  }
  return value;
}

async function loadSdk() {
  try {
    const mod = TEST_SDK ? await import(pathToFileURL(TEST_SDK).href) : await import("@1password/sdk");
    return mod.default ?? mod;
  } catch {
    const dir = fileURLToPath(new URL(".", import.meta.url));
    die(`1Password SDK が入っていません。ユーザーが自分のターミナルで npm ci --ignore-scripts --prefix ${dir} を実行してください`);
  }
}

async function readStdin() {
  const chunks = [];
  for await (const chunk of process.stdin) chunks.push(chunk);
  return Buffer.concat(chunks).toString("utf8");
}

// 比べるための形: 更新の記録と、書き換えてよい欄（set はメモ、rename はタイトル、untag はタグ）を除き、キーを並べた JSON
function stableStringify(v) {
  if (v instanceof Date) return JSON.stringify(v.toISOString());
  if (Array.isArray(v)) return `[${v.map(stableStringify).join(",")}]`;
  if (v && typeof v === "object") {
    return `{${Object.keys(v).sort().map((k) => `${JSON.stringify(k)}:${stableStringify(v[k])}`).join(",")}}`;
  }
  return JSON.stringify(v ?? null);
}

function shape(item, changeable) {
  const { version, updatedAt, [changeable]: _changeable, ...rest } = item;
  return stableStringify(rest);
}

// NODE_USE_ENV_PROXY は v22.21.0 と v24.0.0 で入った。古い Node ではサンドボックスのプロキシを通らない
function nodeSupportsEnvProxy() {
  const [major, minor] = process.versions.node.split(".").map(Number);
  return major >= 24 || (major === 22 && minor >= 21);
}

async function main() {
  if (!nodeSupportsEnvProxy()) {
    die(`Node ${process.versions.node} では動きません。22.21 以降（23 系は不可）か 24 以降を入れてください`);
  }
  const [cmd, ...args] = process.argv.slice(2);
  if (!["status", "list", "get", "set", "rename", "untag", "archive"].includes(cmd)) {
    process.stdout.write(USAGE);
    process.exit(1);
  }
  const usageOf = {
    get: "使い方: claude-profile get <項目> [<キー>]",
    set: "使い方: claude-profile set <項目> < 値",
    rename: "使い方: claude-profile rename <項目> <新しい名前>",
    untag: "使い方: claude-profile untag <項目> <タグ>",
    archive: "使い方: claude-profile archive <項目>",
  };
  if (cmd in usageOf) {
    if (args.length < (cmd === "rename" || cmd === "untag" ? 2 : 1)) die(usageOf[cmd]);
    validName(args[0]);
    if (cmd === "rename") validName(args[1]);
    if (cmd === "untag" && !args[1]) die("タグが空です");
  }
  if (cmd === "rename" && args[0] === args[1]) die("新しい名前が今の名前と同じです");
  let value = "";
  if (cmd === "set") {
    value = (await readStdin()).replace(/\n+$/, "");
    if (!value) die("標準入力が空です");
  }

  token = readToken();
  const sdk = await loadSdk();
  let client;
  try {
    client = await sdk.createClient({ auth: token, integrationName: "claude-profile", integrationVersion: "v2.0.0" });
  } catch (e) {
    die(reason(e));
  }

  const vault = (await client.vaults.list()).find((v) => v.id === VAULT || v.title === VAULT);
  if (!vault) die(`保管庫 ${VAULT} が見つかりません。サービスアカウントの権限を確かめてください`);

  // アーカイブした項目は数えない（同じ名前を残したままの作り直しで「複数」にならないように）
  async function activeItems() {
    return (await client.items.list(vault.id)).filter((i) => (i.state ?? "active") === "active");
  }

  // 項目名（タイトル）から ID を1つに決める。見つからなければ null
  async function resolve(name) {
    const hits = (await activeItems()).filter((i) => i.title === name);
    if (hits.length > 1) die(`同じ名前の項目が複数あります: ${name}`);
    return hits[0]?.id ?? null;
  }

  async function notesOf(id) {
    return ((await client.items.get(vault.id, id)).notes ?? "").replace(/\n+$/, "");
  }

  // SDK が扱いきれない属性は前後の比較でも守れないので、確かめた種類だけを書き換える
  function assertWritable(item, name) {
    if (![sdk.ItemCategory.Login, sdk.ItemCategory.SecureNote].includes(item.category)) {
      die(`この種類の項目（${item.category}）は claude-profile では書き換えません。ユーザーがアプリで直してください: ${name}`);
    }
  }

  switch (cmd) {
    case "status":
      process.stdout.write(`1Password の保管庫 ${vault.title} に接続できます\n`);
      break;
    case "list": {
      const titles = (await activeItems()).map((i) => i.title).sort();
      if (titles.length) process.stdout.write(`${titles.join("\n")}\n`);
      break;
    }
    case "get": {
      const [name, key] = args;
      const id = await resolve(name);
      if (!id) die(`項目が見つかりません: ${name}`);
      const notes = await notesOf(id);
      if (key === undefined) {
        process.stdout.write(`${notes}\n`);
      } else {
        const prefix = `${key}: `;
        const hits = notes.split("\n").filter((line) => line.startsWith(prefix)).map((line) => line.slice(prefix.length));
        if (!hits.length) die(`キーが見つかりません: ${key}`);
        process.stdout.write(`${hits.join("\n")}\n`);
      }
      break;
    }
    case "set": {
      const name = args[0];
      const id = await resolve(name);
      if (id) {
        // メモだけを置き換え、他の欄・タグ・URL はそのまま戻す。前後で形が違えば止める
        const item = await client.items.get(vault.id, id);
        assertWritable(item, name);
        const before = shape(item, "notes");
        item.notes = value;
        await client.items.put(item);
        if (shape(await client.items.get(vault.id, id), "notes") !== before) {
          die(`メモ以外の欄が変わりました: ${name}（1Password の項目の履歴から元に戻せます）`);
        }
      } else {
        await client.items.create({ category: sdk.ItemCategory.SecureNote, vaultId: vault.id, title: name, notes: value });
      }
      const savedId = await resolve(name);
      if (!savedId) die(`保存後の一覧に見つかりません: ${name}`);
      if ((await notesOf(savedId)) !== value) die(`保存後に読み戻した内容が一致しません: ${name}`);
      process.stdout.write(`保存しました: ${name}\n`);
      break;
    }
    case "rename": {
      const [name, newName] = args;
      const id = await resolve(name);
      if (!id) die(`項目が見つかりません: ${name}`);
      if (await resolve(newName)) die(`同じ名前の項目がすでにあります: ${newName}`);
      // タイトルだけを置き換える。メモを含む他の欄が前後で違えば止める
      const item = await client.items.get(vault.id, id);
      assertWritable(item, name);
      const before = shape(item, "title");
      item.title = newName;
      await client.items.put(item);
      if (shape(await client.items.get(vault.id, id), "title") !== before) {
        die(`名前以外の欄が変わりました: ${newName}（1Password の項目の履歴から元に戻せます）`);
      }
      if ((await resolve(newName)) !== id || (await resolve(name))) {
        die(`名前を変えた後の一覧が合いません: ${name} → ${newName}`);
      }
      process.stdout.write(`名前を変えました: ${name} → ${newName}\n`);
      break;
    }
    case "untag": {
      const [name, tag] = args;
      const id = await resolve(name);
      if (!id) die(`項目が見つかりません: ${name}`);
      // タグを1つだけ外す。メモを含む他の欄が前後で違えば止める
      const item = await client.items.get(vault.id, id);
      assertWritable(item, name);
      const tags = item.tags ?? [];
      if (!tags.includes(tag)) die(`タグが見つかりません: ${tag}（この項目のタグ: ${tags.join(", ") || "なし"}）`);
      const before = shape(item, "tags");
      item.tags = tags.filter((t) => t !== tag);
      await client.items.put(item);
      const saved = await client.items.get(vault.id, id);
      if (shape(saved, "tags") !== before) {
        die(`タグ以外の欄が変わりました: ${name}（1Password の項目の履歴から元に戻せます）`);
      }
      if (stableStringify(saved.tags ?? []) !== stableStringify(item.tags)) die(`タグを外した後の内容が合いません: ${name}`);
      process.stdout.write(`タグを外しました: ${name}（${tag}）\n`);
      break;
    }
    case "archive": {
      const name = args[0];
      const id = await resolve(name);
      if (!id) die(`項目が見つかりません: ${name}`);
      await client.items.archive(vault.id, id);
      if (await resolve(name)) die(`アーカイブした後も一覧に残っています: ${name}`);
      process.stdout.write(`アーカイブしました: ${name}（1Password アプリのアーカイブから戻せます）\n`);
      break;
    }
  }
}

main().catch((e) => die(reason(e)));
