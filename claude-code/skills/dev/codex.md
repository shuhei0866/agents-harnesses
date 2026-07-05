---
name: codex
description: >
  Codex CLI にタスクを委譲する統合スキル。コードレビュー、実装、分析を非同期で Codex に委譲し、
  結果を設計文脈と照合して評価する。「Codex に任せて」「Codex でレビュー」「Codex で実装して」
  または /codex と呼ばれた時に使用する。
---

# /codex - Codex 委譲スキル

**Announce at start:** "Codex に委譲します。"

## 概要

Claude Code がオーケストレーター、Codex が実行者として協働するためのスキル。
Claude Code は設計対話・文脈理解・結果評価を担い、Codex はコード分析・実装・レビューを担う。

## 使用方法

```
/codex review                          # 現在の変更をレビュー
/codex review --base develop           # develop からの差分をレビュー
/codex impl <タスクの説明>              # 実装を委譲
/codex analyze <対象の説明>             # コード分析を委譲
```

$ARGUMENTS

## Step 1: タスク分類

引数とユーザーの意図から、以下のいずれかに分類する:

| モード | 判定基準 | sandbox | 作業場所 |
|--------|---------|---------|---------|
| `review` | レビュー・品質チェック依頼 | `read-only` | カレントディレクトリ |
| `impl` | 実装・修正・追加の依頼 | `workspace-write` | **worktree** |
| `analyze` | 分析・調査・改善提案の依頼 | `read-only` | カレントディレクトリ |

**判断に迷ったらユーザーに確認する。**

## Step 2: プロンプト生成

### 最重要原則: 指示粒度はタスク種別で変える

実験により判明した最適パターン:

- **review / analyze** → **曖昧に任せる。** 観点を絞りすぎない。Codex はドメイン知識を自由に活用し、指示が曖昧なほど深い分析を出す。
- **impl** → **中粒度。** 「何を」「なぜ」「制約」を伝え、「どう実装するか」は指定しない。詳細仕様は Codex のドメイン知識を殺す。

### プロンプト構造

```markdown
# ゴール
{ユーザーが達成したいこと — 1-3 文}

# 背景
{設計対話で決まったことがあれば。なければ省略}

# 制約
{やってはいけないこと、触ってはいけないファイル — あれば}
```

### 生成ルール

1. **「どう実装するか」は書かない。** ライブラリ選択、アルゴリズム、設計パターンは Codex に委ねる
2. **設計対話の決定事項は明記する。** ユーザーとの対話で決まった方針は背景として含める
3. **スコープは明確にする。** 対象ファイル・ディレクトリの範囲は示す
4. **制約は具体的に。** 「既存 I/F を変えない」「外部ライブラリ追加不可」など

## Step 3: 実行

### 共通の事前確認

```bash
codex --version  # CLI の存在確認
```

### review モードの実行

```bash
# 結果ファイルのパスを生成
RESULT_FILE="/tmp/codex-$(date +%s)-review.md"

# ビルトイン review を使う場合（diff ベースのレビュー）
codex review --base {base_branch} 2>&1 | tee "$RESULT_FILE"

# exec を使う場合（より自由な分析）
codex exec \
  --full-auto \
  --sandbox read-only \
  -o "$RESULT_FILE" \
  -C "{project_dir}" \
  "{生成したプロンプト}"
```

**使い分け:**
- `codex review` — diff が明確な場合（PR、ブランチ差分）
- `codex exec` — ファイルやディレクトリ全体の分析

**バックグラウンド実行:** Bash ツールの `run_in_background: true` を使用する。
完了通知が届くまで、ユーザーとの対話を継続できる。

### impl モードの実行

```bash
# 1. worktree を作成（実装はメインブランチから隔離する）
TS=$(date +%s)
BRANCH_NAME="codex/$TS"
WORKTREE_DIR="/tmp/codex-worktree-$TS"
git worktree add "$WORKTREE_DIR" -b "$BRANCH_NAME"
# Codex 実行前の base SHA を sidecar に記録する（Step 4/5 の差分基準）。
# HEAD~1 は Codex のコミット数が 0 や複数だと別物を指すので使わない。
git -C "$WORKTREE_DIR" rev-parse HEAD > "$WORKTREE_DIR.base"

# 2. 結果ファイルのパスを生成
RESULT_FILE="/tmp/codex-$(date +%s)-impl.md"

# 3. Codex を実行（バックグラウンド）
codex exec \
  --full-auto \
  --sandbox workspace-write \
  -o "$RESULT_FILE" \
  -C "$WORKTREE_DIR" \
  "{生成したプロンプト}"
```

**バックグラウンド実行:** Bash ツールの `run_in_background: true` を使用する。

### analyze モードの実行

```bash
RESULT_FILE="/tmp/codex-$(date +%s)-analyze.md"

codex exec \
  --full-auto \
  --sandbox read-only \
  -o "$RESULT_FILE" \
  -C "{project_dir}" \
  "{生成したプロンプト}"
```

**バックグラウンド実行:** Bash ツールの `run_in_background: true` を使用する。

## Step 4: 結果の受信と評価

バックグラウンドタスクの完了通知を受けたら、結果ファイルを読む:

```bash
cat "$RESULT_FILE"
```

### review / analyze の評価

1. **結果ファイルを読む** — Codex の自然言語レポート
2. **設計文脈と照合** — ユーザーとの対話で決まったことと矛盾する指摘がないか
3. **取捨選択** — Codex の指摘のうち、この文脈で本当に重要なものを判断
4. **翻訳して伝える** — Codex の出力をそのまま貼るのではなく、自分の言葉でユーザーに伝える

### impl の評価

1. **結果ファイルを読む** — 何をしたか、テスト結果、判断事項
2. **差分を確認**（コミット数に依存しない。base SHA から取る）:
   ```bash
   BASE_SHA=$(cat "$WORKTREE_DIR.base")
   git -C "$WORKTREE_DIR" add -A          # Codex が未コミットのまま残した変更も差分に含める
   git -C "$WORKTREE_DIR" diff --stat "$BASE_SHA"
   git -C "$WORKTREE_DIR" diff "$BASE_SHA"
   ```
3. **設計意図との整合性チェック** — 対話で決めた方針に沿っているか
4. **テスト再実行** — Codex のレポートにテスト結果が無い、または impl がテスト対象コードを変更した場合は worktree 内でテストを走らせる（それ以外は省略可）
5. **ユーザーに提示** — 変更サマリーと評価を伝え、取り込み判断を仰ぐ

## Step 5: 取り込み（impl のみ）

ユーザーが承認した場合:

```bash
# worktree の変更をメインの作業ブランチに取り込む（base SHA から。コミット有無で分岐）
BASE_SHA=$(cat "$WORKTREE_DIR.base")
if git -C "$WORKTREE_DIR" log --oneline "$BASE_SHA"..HEAD | grep -q .; then
  # コミットあり → 履歴を保って cherry-pick / merge する
  git cherry-pick "$BASE_SHA"..HEAD
else
  # 未コミット変更 → パッチ適用
  git -C "$WORKTREE_DIR" add -A
  git -C "$WORKTREE_DIR" diff "$BASE_SHA" | git apply
fi

# worktree の後片付け
git worktree remove "$WORKTREE_DIR"
git branch -D "$BRANCH_NAME"
```

ユーザーが却下した場合:

```bash
git worktree remove --force "$WORKTREE_DIR"
git branch -D "$BRANCH_NAME"
```

## Claude Code の付加価値

このスキルにおける Claude Code の役割は **Codex の出力をそのまま中継することではない。**

Claude Code が加える価値:
- **設計対話の文脈** — ユーザーとの対話で決まった背景をプロンプトに込め、結果を文脈で評価する
- **指摘の取捨選択** — Codex の指摘が現状の設計判断に照らして妥当かを判断する
- **ユーザーへの翻訳** — 技術的な出力をユーザーの関心に合わせて要約・解説する
- **次のアクションの提案** — 結果を踏まえて、次に何をすべきかを対話的に決める

## 注意事項

- Codex は `codex exec` で非対話実行する。対話モードは使わない
- 実装の worktree は必ず後片付けする（承認・却下どちらの場合も）
- Codex の実行中もユーザーとの対話は継続する（非同期の利点）
- `--json` オプションは通常不要。`-o` の自然言語レポートで十分
- Codex 側にもスキル（TDD 等）があり、自動適用される。Claude Code 側から Codex のスキル使用を強制しない
