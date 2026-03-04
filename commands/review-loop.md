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

ローカルの変更に対して「レビュー → 修正 → 再レビュー」を issue が 0 になる（または最大ラウンド数に達する）まで繰り返します。
LLM レビューは1回ごとに新しい視点で問題を発見するため、複数ラウンド回すことで品質が漸近的に向上します。

**Announce at start:** "Review Loop を開始します。変更を分析して、収束するまでレビュー→修正を繰り返します。"

## 引数

$ARGUMENTS

- `--max-rounds=N` (default: 5): 最大ラウンド数
- `--severity=critical|high|medium|all` (default: high): 修正対象とする最低重要度
- `--auto-fix` (default: true): 発見した問題を自動修正する。false なら報告のみ
- `--scope=staged|all|file=<path>` (default: all): レビュー対象
- `--focus=security|bugs|performance|all` (default: all): 重点観点

## ワークフロー

### Phase 1: 変更の把握

1. `git diff HEAD --stat` で変更ファイル一覧を取得
2. 変更が大きい場合 (20ファイル超) はファイルをグループ化して並列レビュー
3. プロジェクトの言語・フレームワークを検出（Cargo.toml, package.json, go.mod 等）

### Phase 2: レビューループ

以下を `max-rounds` 回まで繰り返す:

#### Step 2a: レビュー実行

Agent ツールで独立コンテキストのレビューサブエージェントを起動する。

**重要**: 毎ラウンド新しいサブエージェントを起動すること（前ラウンドの修正バイアスを避けるため）。

サブエージェントの設定:
- **subagent_type**: `general-purpose`
- **model**: `sonnet`（コスト効率。Critical issue が見つかった場合のみ opus で再検証）
- **prompt**: 以下を含める:

```
あなたはコードレビュワーです。以下の diff を客観的にレビューしてください。

## レビュー観点 (重要度順)

### Critical (必ず報告)
- セキュリティ脆弱性 (injection, XSS, auth bypass, secrets)
- データ損失の可能性
- デッドロック、無限ループ
- メモリ安全性 (use-after-free, buffer overflow, unbounded allocation)

### High (デフォルトで修正対象)
- バグ: 境界値未処理、null 未チェック、競合状態
- エラーハンドリング不備 (unwrap/panic in production paths)
- リソースリーク (未 close、未 dispose)
- API 契約違反

### Medium
- パフォーマンス: N+1、不要なクローン/コピー、O(n^2)
- 入力バリデーション不足
- エラーメッセージの不親切さ

### Low (報告のみ、修正しない)
- コードスタイル、命名
- ドキュメント不足
- 理想的だが必須ではない改善

## 出力フォーマット

各 issue を以下の JSON Lines で出力してください（説明テキスト不要、JSON のみ）:

{"severity":"critical|high|medium|low","file":"path/to/file.rs","line":42,"title":"短い要約","description":"問題の詳細と修正方針","fix_suggestion":"具体的なコード修正案（あれば）"}

issue がない場合は以下を出力:
{"severity":"none","title":"No issues found"}
```

#### Step 2b: 結果のパース

サブエージェントの出力から JSON Lines を抽出し、severity でフィルタリング:
- `--severity=critical` → critical のみ
- `--severity=high` → critical + high
- `--severity=medium` → critical + high + medium
- `--severity=all` → 全部

#### Step 2c: 修正の適用

`--auto-fix` が true の場合:

1. 各 issue を severity 順（critical → high → medium）に処理
2. 該当ファイルを Read で読み、Edit で修正を適用
3. 修正後、直ちに構文チェック/ビルド確認:
   - Rust: `cargo check`
   - TypeScript/JS: `npx tsc --noEmit` or `npm run build`
   - Python: `python -m py_compile`
   - Go: `go build ./...`
4. テストがあれば実行して regression がないか確認
5. ビルド/テストが壊れた場合は修正をリバートし、issue をスキップ

#### Step 2d: 収束判定

- 今ラウンドで severity >= threshold の issue が **0件** → 収束。ループ終了
- issue が前ラウンドより増えた → 修正が新たな問題を生んでいる可能性。ユーザーに確認
- 最大ラウンドに到達 → 残存 issue を報告して終了

### Phase 3: 結果サマリー

最終的に以下を出力:

```markdown
## Review Loop Summary

**Rounds:** {completed}/{max}
**Status:** Converged | Max rounds reached | Stopped by user

### Issues Found & Fixed
| Round | Found | Fixed | Skipped | Severity Breakdown |
|-------|-------|-------|---------|-------------------|
| 1     | 5     | 5     | 0       | 1C 2H 2M          |
| 2     | 2     | 2     | 0       | 0C 1H 1M          |
| 3     | 0     | -     | -       | Converged          |

### Remaining Issues (if any)
- [ ] **[file:line]** description (reason skipped)

### Changes Made
{git diff --stat の出力}
```

## 設計原則

1. **独立コンテキスト**: 各ラウンドは新しいサブエージェントで実行。前ラウンドの修正を「自分の修正だから正しい」と見なすバイアスを排除
2. **段階的収束**: 各ラウンドは前回の修正コードをレビューするため、見落としが段階的に減る
3. **安全な修正**: ビルドが壊れたら即リバート。品質を下げる修正は適用しない
4. **コスト制御**: sonnet ベースで回し、critical 検出時のみ opus で再検証。max-rounds で上限制御
5. **透過性**: 各ラウンドの開始・結果をユーザーに表示し、進捗が見える
