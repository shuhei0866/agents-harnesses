---
name: browser-context
description: ブラウザの状態（URL・タブ名・ページ内容）を取得してコンテキストに注入する。/browser-context と呼ばれた時、またはユーザーが「このページ」「タブ見て」「ブラウザ」「今開いてる」と言った時に使用する。
---

# /browser-context

ブラウザの現在の状態を取得し、Claude Code のコンテキストとして利用可能にする。

## トリガー

以下のいずれかに該当する場合、このスキルを実行する:

- ユーザーが `/browser-context` と明示的に呼び出した
- ユーザーの発言に以下のキーワード/意図が含まれる:
  - 「このページ」「今見てるページ」「開いてるページ」
  - 「タブ見て」「タブ一覧」「開いてるタブ」
  - 「ブラウザ」「URL 教えて」「何開いてる」
  - 「今開いてる」「さっき見てた」

## 使い方

```
/browser-context              # アクティブタブの URL + タイトル
/browser-context --all-tabs   # 全タブの情報
/browser-context --content    # ページのテキスト内容も取得
/browser-context --browser safari  # ブラウザ指定
# 注意: --all-tabs と --content は同時指定不可
```

## 手順

### 1. ブラウザ状態を取得

ユーザーの意図に応じてオプションを選択:

```bash
# 基本: アクティブタブ (デフォルト)
~/.claude/scripts/browser-context.sh

# 「タブ一覧」「全部見せて」→ 全タブ
~/.claude/scripts/browser-context.sh --all-tabs

# 「このページの内容」「ページ読んで」→ テキスト内容も取得
~/.claude/scripts/browser-context.sh --content

# ブラウザ指定
~/.claude/scripts/browser-context.sh --browser safari
~/.claude/scripts/browser-context.sh --browser arc
```

### 2. 出力例

**アクティブタブ:**
```json
{
  "browser": "chrome",
  "url": "https://docs.anthropic.com/en/docs/agents",
  "title": "Building agents | Anthropic"
}
```

**--content:**
```json
{
  "browser": "chrome",
  "url": "https://docs.anthropic.com/en/docs/agents",
  "title": "Building agents | Anthropic",
  "content": "Building agents\nAgents are AI systems that...",
  "content_length": 8432
}
```

**--all-tabs:**
```json
{
  "browser": "chrome",
  "tabs": [
    {"url": "https://github.com/...", "title": "Pull Request #42"},
    {"url": "https://docs.anthropic.com/...", "title": "API Reference"}
  ],
  "tab_count": 2
}
```

### 3. コンテキストとして活用

取得した情報をもとに、ユーザーの質問に答える:

- **URL**: リンク先の内容について質問されている場合、WebFetch で詳細を取得
- **タブ一覧**: 関連する複数のリソースを一括把握
- **ページ内容** (`--content`): ドキュメントの内容を直接参照して回答

## 対応ブラウザ

| ブラウザ | URL/タイトル | 内容取得 | 備考 |
|---------|------------|---------|------|
| Chrome  | OK | OK | デフォルト (自動検出) |
| Arc     | OK | OK | `--browser arc` |
| Safari  | OK | OK | `--browser safari` (--content は開発メニューで JS 許可が必要) |
| Firefox | NG | NG | osascript 非対応 |

## セットアップ

```bash
# スクリプトをシンボリックリンク
mkdir -p ~/.claude/scripts
ln -sf ~/agents-harnesses/claude-code/scripts/browser-context.sh ~/.claude/scripts/
```

macOS のみ対応。初回実行時にアクセシビリティ許可を求められる場合あり。

## CLAUDE.md への組み込み (推奨)

プロジェクトや `~/.claude/CLAUDE.md` に以下を追記すると、`/browser-context` を明示的に呼ばなくても
「このページ見て」等の自然な指示でブラウザコンテキストが自動的に取得される:

```markdown
## Browser Context
ユーザーが「このページ」「タブ見て」「ブラウザ」「今開いてる」等と言った場合、
`~/.claude/scripts/browser-context.sh` を実行してブラウザの状態を取得し、
コンテキストとして活用すること。
- アクティブタブ: `browser-context.sh`
- 全タブ: `browser-context.sh --all-tabs`
- ページ内容: `browser-context.sh --content`
```
