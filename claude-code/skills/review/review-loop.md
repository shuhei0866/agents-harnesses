---
name: review-loop
description: コードレビューと修正を収束するまで繰り返すフィードバックループ。PR 前の品質向上、ボットレビュー対策、コード品質の段階的改善に使用する。/review-loop と呼ばれた時に使用する。
allowed-tools:
  - Bash
  - Read
  - Edit
  - Write
  - Glob
  - Grep
  - Agent
  - AskUserQuestion
---

# Review Loop - 収束型コードレビュー

ローカルの変更に対して「レビュー → 修正 → 再レビュー」をレビュワーが新たな問題を発見しなくなる（または最大ラウンド数に達する）まで繰り返します。
LLM レビューは1回ごとに新しい視点で問題を発見するため、複数ラウンド回すことで品質が漸近的に向上します。
`--severity` は自動修正の対象を制御するが、収束判定は全 severity の新規発見数で行う。

**Announce at start:** "Review Loop を開始します。変更を分析して、観点別の並列レビューを収束するまで繰り返します。"

## 引数

$ARGUMENTS

- `--max-rounds=N` (default: 5): 最大ラウンド数
- `--severity=critical|high|medium|all` (default: high): 自動修正する最低重要度（収束判定は全 severity で行う）
- `--auto-fix` (default: true): 発見した問題を自動修正する。false なら報告のみ
- `--scope=staged|all|file=<path>` (default: all): レビュー対象
- `--codex` (default: false): OpenAI Codex にも並列でレビューさせる（モデル多様性）
- `--coderabbit` (default: false): CodeRabbit CLI にも並列でレビューさせる（ルールベース + AI のハイブリッド視点）

## ワークフロー

### Phase 1: 変更の把握

1. `git diff HEAD --stat` で変更ファイル一覧を取得
2. `git diff HEAD` で全 diff を取得
3. プロジェクトの言語・フレームワークを検出（Cargo.toml, package.json, go.mod 等）
4. ビルドコマンドとテストコマンドを特定

### Phase 2: レビューループ

以下を `max-rounds` 回まで繰り返す:

#### Step 2a: 観点別並列レビュー

**各ラウンドで 4〜5 個のサブエージェントを同時起動する。** 各エージェントは異なる観点に特化し、独立コンテキストで動く。これにより広さと深さの両方を確保する。

**重要**: 毎ラウンド新しいサブエージェントを起動すること（前ラウンドの修正バイアスを避けるため）。

全サブエージェントを **1つのメッセージ内で並列に Agent ツール呼び出し** して同時起動すること。

##### Reviewer 1: セキュリティ & メモリ安全性

- **subagent_type**: `general-purpose`
- **model**: `opus`
- **チェック項目**:
  - インジェクション (SQL, XSS, コマンド, パストラバーサル)
  - 認証・認可の不備、権限昇格
  - 機密情報のハードコード・ログ出力
  - バッファオーバーフロー、unbounded allocation、OOM
  - デッドロック、TOCTOU、競合状態
  - 暗号・乱数の誤用
  - FFI 安全性 — 以下の具体パターンを必ずチェック:
    - `CString::new(...).unwrap()` — 内部 NUL バイトで panic。`CString::new(...)?` または NUL 除去が必要
    - raw pointer の null チェック漏れ（特に fat pointer / dyn Trait は data pointer のみ is_null 可能）
    - unsafe ブロック内のライフタイム仮定 — 参照先が呼び出し元で Drop されていないか
    - FFI コールバックの userdata ポインタ — 登録時と呼び出し時でポインタが有効か
    - C 文字列の所有権 — free すべきか、借用か。二重 free やリーク
    - 型サイズの不一致 — C の `int` (i32) vs Rust の `usize`、プラットフォーム間の差異

##### Reviewer 2: ロジック & 正確性

- **subagent_type**: `general-purpose`
- **model**: `opus`
- **チェック項目**:
  - 境界値・エッジケースの未処理 (空配列、0、MAX、負数)
  - null/None/undefined の未チェック
  - エラーハンドリング不備 (unwrap/panic in production paths)
  - API 契約違反 (引数の型・範囲、戻り値の意味)
  - リソースリーク (未 close、未 dispose、未 drop)
  - 状態遷移の不整合、イベント順序の前提違反
  - off-by-one エラー、型変換の truncation/overflow
  - UI 状態と表示の同期:
    - モデル変更後にビュー/ウィジェットが再描画されるか
    - イベントハンドラがモデル変更と UI 更新の両方を行っているか
    - 選択状態変更後に関連ビューが更新されるか
  - テストコードの正確性:
    - assert なしの式（`matches!(...)` が `assert!()` で囲まれていない等）
    - テストが実際にテスト対象のコードを実行しているか（dead test）

##### Reviewer 3: パフォーマンス & 設計

- **subagent_type**: `general-purpose`
- **model**: `opus`
- **チェック項目**:
  - O(n^2) 以上のアルゴリズム、N+1 クエリ
  - 不要なクローン/コピー/アロケーション
  - ブロッキング I/O in async コンテキスト
  - 入力バリデーション不足 (外部入力の信頼)
  - timeout/上限なしのネットワーク・ファイル操作
  - ロック粒度の粗さ、ホットパスの非効率

##### Reviewer 4: 完成度 & 整合性

- **subagent_type**: `general-purpose`
- **model**: `opus`
- **チェック項目**:
  - デッドコード検出:
    - diff で追加された関数・型・定数が実際に呼び出されているか（Grep で検索）
    - 定義はあるが呼び出し元がない関数 → 未完成の機能として報告
  - 仕様準拠:
    - 環境変数の扱いが公式仕様に従っているか（XDG Base Directory Spec 等）
    - ファイルパーミッション、ソケット設定が OS/プロトコル仕様に合致するか
    - **WebSearch ツールで公式仕様を検索して裏取りすること**
  - 機能完成度:
    - API が成功を返すが実際には未実装（プレースホルダー）→ エラーを返すべき
    - capabilities/feature list に未実装メソッドが載っている
    - 保存はあるが復元がない、登録はあるが解除がない等の非対称
  - ビルド・設定の整合性:
    - Cargo.lock が .gitignore に入っているが、バイナリクレートでは VCS にコミットすべき
    - build.rs の rerun-if-changed が適切か
    - 依存バージョンの不整合
  - UI フレームワーク固有:
    - ウィジェット追加/削除後に親コンテナが再レイアウトされるか
    - 状態変更後にシグナル/通知が発火して関連ビューが更新されるか
    - dispose/cleanup チェーンが正しく呼ばれるか（フレームワーク仕様を確認）

##### Reviewer 5 (オプション: --codex 指定時): Codex レビュー

`--codex` が指定された場合、追加で Codex にもレビューさせる。
Bash ツールで `codex` CLI を呼び出し、diff を渡してレビュー結果を取得する。
異なるモデルファミリーは異なる盲点を持つため、多様性が品質を高める。

##### Reviewer 6 (オプション: --coderabbit 指定時): CodeRabbit レビュー

`--coderabbit` が指定された場合、追加で CodeRabbit CLI にもレビューさせる。
Bash ツールで `coderabbit` コマンドを呼び出し、レビュー結果を取得する。
CodeRabbit は LLM + ルールベース解析のハイブリッドで、Opus 単体では見落としやすいパターン（依存脆弱性、ライセンス問題、フレームワーク固有の anti-pattern 等）を補完する。

```bash
# 未コミット変更をレビュー（トークン効率重視の出力）
coderabbit review --prompt-only --type uncommitted --no-color

# 通常の詳細出力が欲しい場合
coderabbit review --plain --type uncommitted --no-color
```

CodeRabbit の出力はテキスト形式のため、統合時に以下のルールで severity を判定する:
- "critical", "security", "vulnerability" を含む → critical
- "bug", "error", "incorrect" を含む → high
- それ以外 → medium

**前提条件**: `coderabbit` CLI がインストール済みであること (`npm install -g coderabbit`)。
未インストールの場合はスキップし、他のレビュワーの結果のみで続行する。

#### 各レビュワー共通のプロンプトテンプレート

各サブエージェントのプロンプトに以下を含める。**diff を渡すだけでなく、ツール使用と調査プロセスを明示的に指示する**ことが品質の鍵。

```
あなたは {観点名} の専門レビュワーです。
以下の diff と変更ファイル一覧に対し、あなたの専門観点のみから深く精密なレビューを行ってください。
他の観点（例: セキュリティ担当なのにスタイルを指摘する）は別のレビュワーが担当するので不要です。

## レビュー方法論 — 必ずこの手順に従うこと

### Step 1: 変更の全体像を掴む
diff を読み、各ファイルで「何が変わったか」を把握する。

### Step 2: 周辺コードを読む（重要）
**diff だけを見て判断してはいけない。** 変更されたファイルの全体を Read ツールで読み、以下を確認すること:
- 変更された関数の完全な実装（diff の前後だけでなく、関数全体）
- 変更された構造体/型の定義とそのフィールド
- 同ファイル内の関連する関数やメソッド

### Step 3: 呼び出し元・呼び出し先を追跡する
Grep ツールで変更された関数/メソッドの呼び出し元を検索し、以下を確認すること:
- この関数に渡される引数の実際の値の範囲
- 戻り値がどこでどう使われるか
- エラーケースが呼び出し元で適切に処理されているか
- **呼び出し元が 0 件の場合 → デッドコードの可能性。未完成機能として報告**

例: `Grep pattern="function_name" glob="*.rs"` で呼び出し元を特定し、Read で該当箇所を読む。

### Step 3.5: 仕様・ベストプラクティスの裏取り
コードが外部仕様に依存している場合（ファイルパーミッション、環境変数、プロトコル、API 規約等）:
- **WebSearch ツールで公式仕様を検索**して正しい値・挙動を確認すること
- 例: `WebSearch query="XDG_RUNTIME_DIR specification permissions"` で仕様を確認
- 例: `WebSearch query="Unix socket file permissions best practice"` でベストプラクティスを確認
- 仕様と実装が乖離している場合、仕様側の URL を evidence に含めること

### Step 4: データフローをトレースする
外部入力（ユーザー入力、ネットワーク、ファイル、環境変数）から変更されたコードに至るデータフローを追跡すること:
- その値はどこで生成・入力されるか？
- 途中でバリデーション/サニタイズされているか？
- 変換・キャスト・パース時にデータが失われないか？

### Step 5: エッジケースを列挙する
変更されたコードが処理する入力について、**具体的な問題値**を列挙すること:
- 空文字列、空配列、null/None、0、負数、MAX_VALUE
- 同時実行（2スレッドが同時に同じ関数を呼ぶケース）
- 異常な順序（初期化前に呼ばれる、dispose 後に呼ばれる等）

### Step 6: 修正起因リグレッションの検出（ラウンド 2+ で特に重要）

過去のラウンドで issue を修正した箇所は、**修正自体が新たなバグを導入している可能性が高い**。以下を重点チェック:

- **エッジケース**: 修正コードが特殊入力（空値、境界値、特殊環境）で正しく動作するか
- **横断パターンの不整合**: 1 箇所だけ修正して他が未修正のパターン（例: `.unwrap()` を 1 箇所だけ `lock_or_recover` に変えて他は放置）
  → **Grep で同じパターンの全出現箇所を検索**して不整合を報告
- **代替アプローチの副作用**: 修正が手法を変えた場合（例: `umask` → `set_permissions`）、新手法固有の問題がないか
- **コメントと実装の乖離**: 修正後にコメントが古いまま残っていないか
- **API 契約の破壊**: クライアント/サーバー間で、修正がシリアライゼーション形式を変えていないか

### Step 7: 自己検証（false positive 排除）
issue を報告する前に、以下を確認すること:
- **到達可能性**: その問題コードは本当に実行されるか？dead code ではないか？
- **前提条件**: 呼び出し元が既にバリデーションしていないか？
- **言語/フレームワークの保証**: 言語仕様やフレームワークが既に防いでいないか？
- **実際の影響**: 「理論上可能」ではなく「実際に起こりうる」か？
- **同時保持の検証**: デッドロックを報告する場合、2 つのロックが**実際に同時保持されるか**確認（文ごとに acquire/release される場合はデッドロックにならない）

**確認できない指摘は報告しない。** 推測だけの指摘は false positive になり、修正者の時間を浪費する。

## 対象コード

{diff の内容}

## 変更ファイル一覧

{git diff --stat の出力}

## プロジェクトコンテキスト

- 言語/フレームワーク: {検出結果}
- 変更ファイル数: {N}
- 変更行数: {M}
- リポジトリルート: {path}

## チェック項目

{Reviewer ごとのチェック項目リストをここに挿入}

## 重要度の定義

- **critical**: 本番で確実に問題になる。データ損失、セキュリティ侵害、クラッシュ。再現手順が明確
- **high**: 高確率でバグになる。特定の入力・タイミング・環境でのみ発現する可能性
- **medium**: 改善すべきだが直ちに問題にはならない。ベストプラクティス違反
- **low**: あれば良い程度の改善（これは報告しなくてよい）

## 出力フォーマット

各 issue を以下の JSON Lines で出力すること（説明テキスト不要、JSON のみ）:

{"severity":"critical|high|medium","file":"path/to/file.rs","line":42,"title":"短い要約","description":"問題の詳細。①何が問題か ②どの入力/条件で発生するか ③影響は何か ④呼び出し元を確認した結果","evidence":"問題を裏付ける具体的なコード箇所・呼び出し元の引用","fix_code":"そのまま適用可能な修正後コード（関数単位またはブロック単位）"}

### description の必須要素
1. **問題の本質**: 何が起きるか、一文で
2. **トリガー条件**: どの具体的な入力・状態・タイミングで発生するか
3. **影響範囲**: クラッシュ、データ破壊、セキュリティ侵害、メモリリーク等
4. **検証結果**: 呼び出し元を確認したか、到達可能であることを確認したか

### fix_code の要件
- **「検討してください」「追加を推奨」のような曖昧な提案は禁止。**
- 具体的な修正後コードを書くこと。そのままファイルに適用可能な形式で。
- 修正箇所のファイルパスと行番号を明示すること。

issue がない場合は以下を出力:
{"severity":"none","title":"No issues found"}
```

#### なぜこのプロンプトが長いのか

CodeRabbit のようなレビューボットが高品質な指摘を出せる理由は:
1. **コード全体を読んでいる** — diff の外にあるコンテキストを理解している
2. **呼び出し元を追跡している** — 関数単体ではなく、システム全体でのデータフローを見ている
3. **具体的** — 「〜の可能性がある」ではなく「X が Y を呼び、Z が未チェックで渡される」
4. **自己検証している** — false positive を出さないよう、到達可能性を確認している
5. **修正案が動くコード** — 「〜を追加してください」ではなく実際のコードを提示

このプロンプトは、同じ品質をサブエージェントに求めるために必要な長さ。

#### Step 2b: 結果の統合 & 重複排除

1. 全レビュワーの出力を収集
2. JSON Lines をパース
3. 同一ファイル・同一行の重複 issue をマージ（複数レビュワーが同じ問題を指摘 → 確信度が高い）
4. **自動修正対象**を severity でフィルタリング（`--severity` で指定）:
   - `--severity=critical` → critical のみ修正
   - `--severity=high` → critical + high を修正 (デフォルト)
   - `--severity=medium` → critical + high + medium を修正
   - `--severity=all` → 全部修正
   - **注意**: 修正対象外の issue も記録し、収束判定に含める
5. 複数レビュワーが指摘した issue は severity を1段階上げる（cross-validated）

#### Step 2c: 修正の適用

`--auto-fix` が true の場合:

1. 各 issue を severity 順（critical → high → medium）、次にファイル順に処理
2. 該当ファイルを Read で読み、Edit で修正を適用
3. 修正後、直ちにビルド確認:
   - Rust: `cargo check` (+ `cargo test` があれば実行)
   - TypeScript/JS: `npx tsc --noEmit` or `npm run build`
   - Python: `python -m py_compile`
   - Go: `go vet ./...` && `go build ./...`
4. ビルド/テストが壊れた場合は修正をリバートし、issue をスキップ

#### Step 2c-bis: 修正リグレッション検証（重要）

**修正コード自体が新たなバグを生むパターンが最も多い指摘原因。** 修正を適用した後、以下の 3 つの検証を必ず実行する:

##### 1. エッジケース検証
各修正について、修正後のコードが以下の入力で正しく動作するか確認:
- 空値（空文字、None、0、空配列）
- 境界値（MAX、-1、1文字）
- 特殊環境（HOME="/"、XDG_RUNTIME_DIR 未設定、root ユーザー）

例: `strip_prefix` を `Path::strip_prefix` に変えた場合、HOME が "/" のケースで `strip_prefix("/")` が任意のパスにマッチしないか確認。

##### 2. 横断パターン検証
修正が「パターンの修正」（例: `.lock().unwrap()` → `lock_or_recover`）の場合:
- **Grep で同じパターンの全出現箇所を検索**し、修正漏れがないか確認
- テストコード以外の production コードで統一されているか確認
- 1 箇所だけ直して他を残すと、レビューボットが不整合を指摘する

例: `Grep pattern=".lock\(\).unwrap\(\)" glob="*.rs"` で残存箇所を確認。

##### 3. 代替アプローチの副作用評価
修正が「アプローチの変更」（例: `umask` → `set_permissions`）の場合:
- 新アプローチの既知の問題を確認（TOCTOU、スレッド安全性、プラットフォーム差異）
- コメントが修正後のコードと一致しているか確認（古いコメントが残ると指摘される）
- 呼び出し元・呼び出し先に新アプローチの前提条件が満たされているか確認

例: `set_permissions` は `chmod(path)` であり `fchmod(fd)` ではない。コメントに "fchmod" と書くと嘘になる。

##### 4. API 契約の往復検証
クライアント/サーバー間のコードを修正した場合:
- クライアントが送る JSON とサーバーが期待する JSON が一致するか確認
- `Option<T>` を `serde_json::json!` でシリアライズすると `null` になる — サーバー側のパーサーが `null` を正しく処理するか確認
- エラーレスポンスのフォーマットがクライアントの表示ロジックと整合するか確認

#### Step 2d: ラウンド結果の保存

各ラウンド完了時に `.claude/reviews/` に Markdown ファイルを書き出す。

**ファイルパス**: `.claude/reviews/{YYYY-MM-DD}-{short-description}-round{N}.md`

**フォーマット**:

```markdown
# Review Round {N} — {date}

## Context
- **Branch**: {branch name}
- **Diff stat**: {files changed, insertions, deletions}
- **Language**: {detected language/framework}
- **Severity filter**: {threshold}

## Reviewer Results

### Security & Memory Safety (opus)
{JSON Lines output from reviewer, as-is}

### Logic & Correctness (opus)
{JSON Lines output from reviewer, as-is}

### Performance & Design (opus)
{JSON Lines output from reviewer, as-is}

### Completeness & Integration (opus)
{JSON Lines output from reviewer, as-is}

### Codex (if --codex)
{output from codex, if applicable}

### CodeRabbit (if --coderabbit)
{output from coderabbit, if applicable}

## Aggregated Issues (after dedup + cross-validation)
| # | Severity | File | Line | Title | Reviewers | Status |
|---|----------|------|------|-------|-----------|--------|
| 1 | critical | path | 42   | ...   | Sec+Logic | Fixed  |

## Fixes Applied
{brief description of each fix, or "Report only (--auto-fix=false)"}

## Build Verification
- `cargo check`: {pass/fail}
- `cargo test`: {pass/fail, N tests}
```

Write ツールで `.claude/reviews/` ディレクトリに書き出す。ディレクトリが存在しない場合は作成する。

#### Step 2e: 収束判定

収束は「レビュワーが新たな問題を発見しなくなった」ことで判定する:

- 今ラウンドで**全 severity を通じて新規 issue が 0件** → **収束**。ループ終了
  - 「新規」= 前ラウンドで既に報告された issue の再指摘は除外
  - severity threshold 以下の issue が残っていても、新規発見がなければ収束
- issue が前ラウンドより増えた → 修正が新たな問題を生んでいる可能性。ユーザーに確認
- 最大ラウンドに到達 → 残存 issue を報告して終了

**なぜ全 severity で収束判定するか**: severity=high で修正を打ち切っても、medium の指摘が毎ラウンド新たに出続けるなら、コードにはまだ改善余地がある。レビュワーが「もう何も見つからない」と言うまで回すことで、真の品質収束を達成する。

### Phase 3: 結果サマリーの保存と出力

最終サマリーを `.claude/reviews/{YYYY-MM-DD}-{short-description}-summary.md` に保存し、コンソールにも出力する。

最終的に以下を出力・保存:

```markdown
## Review Loop Summary

**Rounds:** {completed}/{max}
**Status:** Converged (zero new findings) | Max rounds reached | Stopped by user
**Reviewers:** Security(opus) + Logic(opus) + Performance(opus) + Completeness(opus) [+ Codex] [+ CodeRabbit]

### Issues by Round
| Round | Reviewers | Found | Fixed | Skipped | Cross-validated |
|-------|-----------|-------|-------|---------|-----------------|
| 1     | 3         | 8     | 7     | 1       | 3               |
| 2     | 3         | 2     | 2     | 0       | 0               |
| 3     | 3         | 0     | -     | -       | Converged       |

### Cross-validated Issues (複数レビュワーが同時指摘)
これらは複数の独立した視点が同じ問題を発見したため、信頼度が高い:
- **[file:line]** description (指摘元: Security + Logic)

### Remaining Issues (if any)
- [ ] **[file:line]** description (reason skipped)

### Changes Made
{git diff --stat の出力}
```

## 設計原則

1. **観点の分離**: 各レビュワーは自分の専門領域のみに集中。「セキュリティ担当がスタイルを指摘する」ような雑音を排除し、深いレビューを実現
2. **4 軸カバレッジ**: Security / Logic / Performance / Completeness の 4 軸で、実行時バグだけでなくデッドコード・仕様乖離・UI 不整合もカバー。これは PR ボット（CodeRabbit, Cubic 等）の検出パターンを分析して導出した軸
3. **モデル多様性**: 異なるモデル（Opus + Codex + CodeRabbit）は異なる盲点を持つ。複数モデルで同じ問題を発見したら確信度が上がる
4. **並列実行**: 4〜5 レビュワーを同時起動し、待ち時間を最小化
5. **独立コンテキスト**: 各ラウンド・各レビュワーは新しいサブエージェント。修正バイアスを排除
6. **cross-validation**: 複数レビュワーが同じ問題を独立に発見 → severity を上げる。単独指摘より信頼度が高い
7. **仕様裏取り**: WebSearch で公式仕様を確認し、「なんとなく正しそう」ではなく仕様準拠を検証
8. **段階的収束**: 各ラウンドは前回の修正コードをレビューするため、見落としが段階的に減る
9. **安全な修正**: ビルドが壊れたら即リバート。品質を下げる修正は適用しない
10. **コスト意識**: max-rounds で上限制御。ラウンドが進むにつれ issue は減るので、コストも漸減する
11. **修正リグレッション防止**: 修正コード自体のエッジケース・副作用・横断パターンの不整合を検証する Step 2c-bis を設けることで、「修正が新たなバグを生む → 再指摘」のサイクルを断つ。PR ボットが繰り返し指摘する最大の原因は修正起因のリグレッションであり、これを防ぐことが収束速度を最も改善する
