---
name: claude-loop
description: 決定論的 bash ループで Claude Code を繰り返し実行する。レビュー収束ループ（converge）と技術的負債バッチ（backlog）の2モード。/claude-loop と呼ばれた時に使用する。
allowed-tools:
  - Bash
  - Read
  - Glob
  - Grep
  - AskUserQuestion
---

# Claude Loop - 決定論的 bash ループランナー

Claude Code を外側の bash ループから繰り返し起動し、レビュー収束や技術的負債の逐次処理を自動化します。
各ラウンドは独立した Claude Code プロセスとして実行されるため、コンテキスト肥大化を避けながら収束的に品質を向上させます。

**Announce at start:** "Claude Loop を開始します。モードと設定を確認します。"

## 引数

$ARGUMENTS

### オプション一覧

| オプション | デフォルト | 説明 |
|-----------|-----------|------|
| `--mode=converge\|backlog` | (必須) | 実行モード |
| `--project=<path>` | `.` | 対象プロジェクトのパス |
| `--max-rounds=N` | `5` | 最大ラウンド数 |
| `--prompt=<path>` | (モード別デフォルト) | プロンプトテンプレートファイル |
| `--log-dir=<path>` | `.claude/loop-logs/` | ログ出力先 |
| `--source=<source>` | `auto` | backlog モードのソース: `auto\|issues\|auto+issues\|<file>` |
| `--label=<label>` | `tech-debt` | `--source=issues` 時の GitHub Issues ラベル |
| `--dry-run` | (なし) | 実行せずに計画を表示 |

### モード説明

- **converge**: レビュー -> 修正 -> 再レビューを issue が 0 になるまで繰り返す。PR 前の品質向上に最適
- **backlog**: TODO コメント、lint エラー、GitHub Issues などのバックログアイテムを1つずつ処理する。技術的負債の解消に最適

## ワークフロー

### Phase 1: 引数の解釈とモード選択

1. `$ARGUMENTS` をパースし、`--mode`, `--project`, `--max-rounds` 等を抽出する
2. 引数が空、またはモードが指定されていない場合は AskUserQuestion で確認する:

```
どのモードで実行しますか？

1. **converge** - レビュー収束ループ（コード品質向上）
2. **backlog** - 技術的負債バッチ処理

追加で指定したいオプションがあれば教えてください:
- プロジェクトパス (--project)
- 最大ラウンド数 (--max-rounds)
- backlog のソース (--source=auto|issues|auto+issues)
```

### Phase 2: 事前確認（推奨）

実行前に `--dry-run` での確認をユーザーに提案する:

```bash
~/claude-skills/loops/claude-loop.sh --mode=<mode> --project=<path> --max-rounds=<N> --dry-run
```

dry-run の出力を確認し、問題がなければ本実行に進む。

### Phase 3: 実行

#### 実行環境の注意事項

本実行の前に以下を表示する:

> **注意**: claude-loop は長時間実行される可能性があります（各ラウンドで Claude Code プロセスを起動するため）。
>
> - **tmux または screen** での実行を強く推奨します。SSH 切断やターミナル閉鎖でプロセスが中断されます
> - 各ラウンドの進捗は `progress.txt`（ログディレクトリ内）でリアルタイムに確認できます
> - 中断する場合は `Ctrl+C` で安全に停止できます（現在のラウンド完了後に停止）

#### 実行コマンド

Bash ツールで以下を実行する。**timeout を十分に長く設定すること**（1ラウンドあたり数分かかる場合がある）:

```bash
~/claude-skills/loops/claude-loop.sh \
  --mode=<mode> \
  --project=<project_path> \
  --max-rounds=<N> \
  [--source=<source>] \
  [--label=<label>] \
  [--prompt=<prompt_path>] \
  [--log-dir=<log_dir>]
```

実行は `run_in_background` を使用し、完了通知を待つ。ユーザーには進捗確認方法を伝える:

```bash
# 進捗確認（別ターミナルまたは後続のプロンプトで）
cat <log_dir>/progress.txt
```

### Phase 4: 結果の表示

実行完了後、以下の順で結果を収集・表示する:

1. **progress.txt を読む**: ループ全体の進捗サマリー

```bash
cat <log_dir>/progress.txt
```

2. **各ラウンドのログを確認**: 必要に応じて個別ラウンドの詳細を確認

```bash
ls <log_dir>/
```

3. **結果サマリーを出力**:

```markdown
## Claude Loop 完了

**モード**: converge | backlog
**ラウンド**: {completed}/{max}
**ステータス**: 収束 | 最大ラウンド到達 | エラー終了
**ログ**: <log_dir>/

### ラウンド別結果
| ラウンド | ステータス | 概要 |
|---------|-----------|------|
| 1       | completed | ... |
| 2       | completed | ... |
| ...     | ...       | ... |

### 次のアクション
- (収束した場合) 変更をレビューしてコミットしてください
- (未収束の場合) 残存する問題の手動対応を検討してください
```

## 使用例

### 例 1: PR 前のレビュー収束

```
/claude-loop --mode=converge --project=~/my-project
```

### 例 2: 技術的負債の自動解消

```
/claude-loop --mode=backlog --source=auto+issues --max-rounds=10
```

### 例 3: 特定ラベルの Issues を処理

```
/claude-loop --mode=backlog --source=issues --label=refactor --max-rounds=5
```

### 例 4: dry-run で事前確認

```
/claude-loop --mode=converge --dry-run
```

### 例 5: 引数なし（インタラクティブ）

```
/claude-loop
```

## 設計原則

1. **決定論的ループ**: ループ制御は bash スクリプトが行い、Claude Code は各ラウンドの実行に専念する。AI がループ判断をしないため、予測可能な動作を保証
2. **コンテキスト分離**: 各ラウンドは独立した Claude Code プロセス。前ラウンドの文脈に引きずられず、新鮮な視点でレビュー/修正を行う
3. **漸近的収束**: converge モードでは各ラウンドが前回の修正済みコードをレビューするため、問題が単調減少する
4. **安全な中断**: Ctrl+C で現在のラウンド完了後に安全停止。途中結果はログに残る
5. **可観測性**: progress.txt とラウンド別ログにより、実行状況をリアルタイムで追跡可能
