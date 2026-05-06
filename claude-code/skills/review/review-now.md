---
name: review-now
description: ローカルの未コミット変更をレビューしたい時、PR 作成前の品質チェック時、または /review-now と呼ばれた時に使用する。独立コンテキストで客観的なコードレビューを実行する。
---

# ローカル変更レビュー

ローカルの変更を独立したコンテキストで客観的にレビューします。サブエージェント（Agent ツール）を使用して、現在の会話コンテキストに影響されない客観的なレビューを実行してください。

**Announce at start:** "独立コンテキストでコードレビューを開始します。"

## 手順

### 1. 変更内容の取得

まず変更内容を確認します：

```bash
# デフォルト: ステージング済み + 未ステージングの全変更
git diff HEAD --stat
git diff HEAD
```

引数で制御:
- `--staged`: ステージング済みの変更のみ (`git diff --cached`)
- `--file=<path>`: 特定ファイルの変更のみ (`git diff HEAD -- <path>`)
- `--focus=security|performance|all`: 特定の観点に絞る

$ARGUMENTS

### 2. サブエージェントでレビュー実行

Agent ツールを使用して、独立したコンテキストでレビューを実行します。以下のプロンプトでサブエージェントを起動してください：

- **subagent_type**: `general-purpose`
- **model**: `opus`（高品質なレビューのため）
- **prompt**: 変更内容（diff）と以下のレビュー観点を含める

### 3. レビュー観点

#### セキュリティ (Critical)
- SQL インジェクション、XSS、コマンドインジェクション
- 認証・認可の不備
- 機密情報のハードコード

#### バグの可能性 (High)
- 境界値・エッジケースの未処理
- null/undefined の未チェック
- 非同期処理の競合状態
- エラーハンドリングの不備

#### パフォーマンス (Medium)
- N+1 クエリ
- 不要な再レンダリング・再計算

#### 可読性・保守性 (Medium)
- 複雑すぎるロジック
- 命名の不適切さ、重複コード

#### OSS upstream contribution のメタ記述検出 (Critical, 外部 OSS 向け時のみ)

**適用条件**: `git remote get-url origin` が個人 fork ではない外部 OSS リポジトリを指している場合に強制実行。

メンテナ心理や review 戦略を主題にしたメタ記述が、PR description / commit message / code comment / README / changelog / 投下予定コメントに混入していないか検出する。

**観点**:
- 地の文に登場する個人名 (mention `@xxx` の慣習的使用以外)
- 説得目的の動詞や心理操作系語彙
- review 戦略を露わにする語彙
- bilingual ドラフト (日本語意図解説 + 英語投下文の二段構造) の誤投下

**実行**:
1. `git diff HEAD` と投下予定の本文を取得
2. ユーザーの運用 NG パターン辞書 (memory entry) を参照
3. 検出箇所を行番号付きで報告 + 書き換え案を提示

**書き換えの一般原則**: 説得・心理操作の意図を残したまま婉曲化するのではなく、技術選択の事実と効果だけを残す。

### 4. 結果の出力

レビュー結果を以下のフォーマットで出力:

```markdown
## Code Review Summary

### Critical Issues
- [ ] **[ファイル名:行番号]** 問題の説明

### Suggestions
- **[ファイル名:行番号]** 改善提案

### Good Points
- 良かった点

### Overall Assessment
総合評価と理由
```
