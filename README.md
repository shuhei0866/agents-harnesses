# agents-harnesses

AI コーディングエージェント（Claude Code / Codex）の生産性を高めるスキル・ループ・Hooks のコレクション。

## ディレクトリ構成

```
agents-harnesses/
├── claude-code/
│   ├── skills/
│   │   ├── review/      # レビュー系スキル
│   │   ├── release/     # リリース系スキル
│   │   ├── dev/         # 開発ユーティリティ
│   │   ├── design/      # 設計・委譲
│   │   └── platforms/   # プラットフォーム固有
│   ├── hooks/
│   │   ├── guardrails/           # PreToolUse ガードレール群
│   │   ├── discord-mention/      # PreToolUse Discord メンション検証
│   │   ├── line-ending-fix/      # PostToolUse CRLF→LF 変換
│   │   ├── pr-review/            # PostToolUse レビュースレッドリマインド
│   │   ├── discord-response-poll/ # PostToolUse Discord 応答待ちリマインド
│   │   ├── merge-diagnose/       # PostToolUse マージ失敗診断
│   │   ├── subagent-rules/       # PostToolUse サブエージェントルール注入
│   │   ├── review-enforcement/   # Stop レビュー実行検証
│   │   ├── release-completion/   # Stop リリース完了検証
│   │   └── friction-feedback/    # Stop 摩擦検出・Issue 作成
│   ├── agents/          # サブエージェント定義
│   ├── scripts/         # 通知・MCP 等のユーティリティ
│   └── templates/       # テンプレート
├── codex/               # （プレースホルダー — .gitkeep のみ）
└── loops/               # 決定論的ループランナー（エージェント非依存）
    ├── claude-loop.sh
    ├── claude-loop.md
    ├── lib/             # ライブラリ (backlog-collect, progress)
    ├── prompts/         # プロンプトテンプレート
    └── tests/           # テスト
```

## Claude Code

### Skills (`claude-code/skills/`)

#### review/ — レビュー系

| スキル | 説明 | 呼び出し |
|--------|------|----------|
| **review-loop** | 4-5 並列レビュアーによる収束型コードレビューループ。新規指摘 0 件で収束 | `/review-loop` |
| **review-now** | 独立コンテキストでの単発コードレビュー。PR 前のクイックチェックに | `/review-now` |
| **review-pr** | 既存の PR を独立コンテキストでレビューし、結果を PR コメントとして投稿 | `/review-pr` |
| **delegate-review-to-codex** | Codex CLI (gpt-5.3-codex) による独立コードレビュー。`/review-now` と並列で多角的レビュー | `/codex-review` |

#### release/ — リリース系

| スキル | 説明 | 呼び出し |
|--------|------|----------|
| **release** | コミット履歴から GitHub Release を自動作成 | `/release` |
| **release-ready** | テスト・レビュー・リスク評価を一括実行するリリース前セルフチェック | `/release-ready` |
| **ship-to-develop** | release/* から develop への PR 作成→承認ポーリング→マージを一気通貫実行 | `/ship-to-develop` |

#### dev/ — 開発ユーティリティ

| スキル | 説明 | 呼び出し |
|--------|------|----------|
| **tdd** | サブエージェントでテスト駆動開発。Red-Green-Refactor サイクルを並列処理で高速化 | `/tdd` |
| **task-decompose** | 大規模タスクを独立サブタスクに分解し、worktree + サブエージェントで並列実行 | `/task-decompose` |
| **git-worktrees** | 隔離された git worktree を作成し、安全に並列作業 | `/git-worktrees` |
| **env-secrets** | 環境変数・シークレットの安全な取り扱い方法を提供 | `/env-secrets` |
| **port-kill** | 指定ポートで動いているプロセスを停止 | `/port-kill` |
| **worktree-clean** | 不要な git worktree を整理・削除 | `/worktree-clean` |
| **dedupe** | 類似 GitHub Issue の重複候補を検索してコメント | `/dedupe` |
| **browser-context** | ブラウザの状態（URL・タブ名・ページ内容）を取得してコンテキストに注入 | `/browser-context` |

#### design/ — 設計・委譲

| スキル | 説明 | 呼び出し |
|--------|------|----------|
| **dig** | 曖昧な要件を構造化された質問で掘り下げ、意思決定を記録 | `/dig` |
| **delegate** | タスクの委譲先モデル/エージェントを決定し、品質メトリクスを記録 | `/delegate` |

#### platforms/ — プラットフォーム固有

| スキル | 説明 | 呼び出し |
|--------|------|----------|
| **vercel-debug** | Vercel CLI で本番ログ取得・デプロイ状況確認・エラーデバッグ | `/vercel-debug` |
| **mintlify** | Mintlify ベースのドキュメント管理を支援 | `/mintlify` |
| **keyd** | Ubuntu 上の keyd キーバインド設定を管理 | `/keyd` |

### Hooks (`claude-code/hooks/`)

Hooks は `settings.json` で設定する。シンボリックリンクではなく、`.claude/settings.json`（または `~/.claude/settings.json`）に hook 定義を追加する。

#### PreToolUse（ツール実行前のガード）

| Hook | ディレクトリ | 説明 |
|------|-------------|------|
| **gh-guard** | `guardrails/` | PR の自己 approve・保護ブランチへの直接マージをブロック |
| **commit-guard** | `guardrails/` | main/develop への直接コミット、`--no-verify`、force push を防止 |
| **secret-guard** | `guardrails/` | シークレットの平文出力（echo, printenv 等）をブロック |
| **heredoc-guard** | `guardrails/` | heredoc 構文をブロックし、コピペ事故を防止 |
| **pr-merge-ready-guard** | `guardrails/` | 未解決レビュースレッド・マージコンフリクトがある PR のマージを防止 |
| **toolchain-guard** | `guardrails/` | sudo npm/node をブロック、gh 認証チェック |
| **worktree-guard** | `guardrails/` | メインワークツリーでの直接編集を制限（worktree 分離を強制） |
| **migration-guard** | `guardrails/` | マイグレーション番号の重複を警告 |
| **discord-mention** | `discord-mention/` | Discord メッセージの `@username` を `<@USER_ID>` 形式に変換を促す |

#### PostToolUse（ツール実行後の自動処理）

| Hook | ディレクトリ | 説明 |
|------|-------------|------|
| **fix-crlf** | `line-ending-fix/` | Write/Edit 後に CRLF → LF を自動変換 |
| **resolve-reminder** | `pr-review/` | git push 後に未解決レビュースレッドをリマインド |
| **discord-response-poll** | `discord-response-poll/` | Discord 送信後に応答待ちをリマインド |
| **merge-diagnose** | `merge-diagnose/` | `gh pr merge` 失敗時に未解決スレッドを自動検出 |
| **subagent-rules/inject** | `subagent-rules/` | サブエージェント起動時にエージェント種別に応じたルールを注入 |

#### Stop（セッション終了時の検証）

| Hook | ディレクトリ | 説明 |
|------|-------------|------|
| **review-enforcement** | `review-enforcement/` | release/* ブランチでのレビューステップ実行を検証 |
| **release-completion** | `release-completion/` | develop 向け PR のマージ完了を検証 |
| **friction-feedback** | `friction-feedback/` | セッション中の摩擦（deny/block）を検出し Issue 作成を促す |

#### settings.json 設定例

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "~/agents-harnesses/claude-code/hooks/guardrails/gh-guard.sh"
          },
          {
            "type": "command",
            "command": "~/agents-harnesses/claude-code/hooks/guardrails/commit-guard.sh"
          },
          {
            "type": "command",
            "command": "~/agents-harnesses/claude-code/hooks/guardrails/secret-guard.sh"
          },
          {
            "type": "command",
            "command": "~/agents-harnesses/claude-code/hooks/guardrails/toolchain-guard.sh"
          }
        ]
      },
      {
        "matcher": "Write",
        "hooks": [
          {
            "type": "command",
            "command": "~/agents-harnesses/claude-code/hooks/guardrails/migration-guard.sh"
          }
        ]
      },
      {
        "matcher": "mcp__discord__*",
        "hooks": [
          {
            "type": "command",
            "command": "~/agents-harnesses/claude-code/hooks/discord-mention/check.sh"
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Write|Edit",
        "hooks": [
          {
            "type": "command",
            "command": "~/agents-harnesses/claude-code/hooks/line-ending-fix/fix-crlf.sh"
          }
        ]
      },
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "~/agents-harnesses/claude-code/hooks/pr-review/resolve-reminder.sh"
          },
          {
            "type": "command",
            "command": "~/agents-harnesses/claude-code/hooks/merge-diagnose/check.sh"
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "~/agents-harnesses/claude-code/hooks/review-enforcement/check.sh"
          },
          {
            "type": "command",
            "command": "~/agents-harnesses/claude-code/hooks/release-completion/check.sh"
          },
          {
            "type": "command",
            "command": "~/agents-harnesses/claude-code/hooks/friction-feedback/check.sh"
          }
        ]
      }
    ]
  }
}
```

### Agents (`claude-code/agents/`)

| エージェント | 説明 |
|-------------|------|
| **metrics-recorder** | タスク委譲後の品質メトリクスを Notion DB に記録する専門エージェント |
| **release-manager** | GitHub リリース作成・管理専門エージェント。`/release` から呼び出される |

### Templates (`claude-code/templates/`)

| テンプレート | 説明 |
|-------------|------|
| **release-spec** | リリース仕様書のテンプレート。ブランチ情報・分類・チェックリストを定型化 |

### Scripts (`claude-code/scripts/`)

| スクリプト | 説明 |
|-----------|------|
| **notify-discord.sh** | Discord 通知（Webhook / Bot Token 対応） |
| **hook-stop-notify.sh** | セッション終了時の自動 Discord 通知（Stop hook 用） |
| **launch-discord-mcp.sh** | Discord MCP サーバー起動 |
| **browser-context.sh** | ブラウザの状態（URL, タイトル, タブ一覧, ページ内容）を JSON で出力 (macOS) |

## Codex

（プレースホルダー — `.gitkeep` のみ。hooks / skills を順次追加予定）

## Loop Runner (`loops/`)

`claude-loop.sh` はエージェントをラップする bash スクリプトで、ループ制御を AI ではなくシェルが担う。

```bash
# レビュー収束ループ（指摘 0 件まで繰り返す）
./loops/claude-loop.sh --mode converge --max-rounds 5

# 技術的負債バッチ処理（TODO/lint/tsc/GitHub Issues を順次処理）
./loops/claude-loop.sh --mode backlog --source auto+issues --label tech-debt
```

### 設計原則

- **決定論的制御**: ループ判定は bash が行い、AI の暴走を防止
- **コンテキスト分離**: 各ラウンドで新しいプロセスを起動し、前ラウンドのバイアスを排除
- **構造化出力**: JSON Lines で指摘事項を出力、`<loop-result>` タグでラウンド完了を通知
- **安全停止**: 収束条件達成 or 最大ラウンド数で停止、Ctrl+C で即座に中断可能

### 構成

- `claude-loop.sh` — メインスクリプト
- `claude-loop.md` — Claude Code スキル定義
- `lib/` — ライブラリ（`backlog-collect.sh`, `progress.sh`）
- `prompts/` — プロンプトテンプレート（`review-converge.md`, `debt-sweep.md`）
- `tests/` — テスト

## セットアップ

```bash
git clone git@github.com:shuhei0866/agents-harnesses.git ~/agents-harnesses

# Claude Code スキルをシンボリックリンク（サブディレクトリ内の .md をすべてリンク）
ln -s ~/agents-harnesses/claude-code/skills/*/*.md ~/.claude/commands/

# Hooks は settings.json で設定する（上記の settings.json 設定例を参照）
# ~/.claude/settings.json または プロジェクトの .claude/settings.json に hook 定義を追加

# Scripts をシンボリックリンク
mkdir -p ~/.claude/scripts
ln -s ~/agents-harnesses/claude-code/scripts/*.sh ~/.claude/scripts/
```

## ライセンス

MIT
