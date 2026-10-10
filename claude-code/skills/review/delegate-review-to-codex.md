---
name: codex-review
description: /codex-review と呼ばれた時、または /codex review や review-loop から Codex CLI へ独立レビューを渡す時に使用する。対象・共通指示・確認範囲を含むプロンプトでレビューする。
---

# Codex コードレビュー

Codex CLI の設定済みモデル・認証を使う。モデル名を固定したり、未認証時に別の課金方式へ切り替えたりしない。実装・修正は行わせない。

$ARGUMENTS

## 1. 準備と対象の固定

`codex --version` と `codex login status` で利用可能か確認する。使えなければ、その理由でレビュー未完了と報告する。

呼び出し元が target / scope を指定した場合はそれを保持する。直接 `/codex-review` を呼んだ場合の引数は次の通り。

- 引数なし: main と HEAD の差分。両方を commit に解決して固定する。
- `--base <ref>`: 指定 ref と HEAD を固定する。
- `--uncommitted`: HEAD と staged / unstaged / untracked の変更。
- `--pr <number|URL>`: `gh pr view` の base/head OID を固定する。必要な commit を取得し、同じ head の隔離 checkout または `git show` から調べる。変化する `gh pr diff` だけを渡さない。

変更一覧は固定 SHA の `git diff --name-status <base>...<head>` または指定のローカル scope から取得する。PR の head と異なる worktree を渡さない。ローカル変更では開始時の diff・新規ファイルの内容を保持し、実行後に対象が変わっていないか照合する。

## 2. 実際に送るプロンプトの作成

このファイルの実体と同じディレクトリの `review-loop.md` から、「全レビュアー共通の走査・報告契約」「変更の形から選ぶ確認経路」「レビュアーへ渡す入力」「単発レビューの出力」を読む。symlink でインストールされている場合はリンク元を解決する。参照だけで review-loop の並列実行・自動修正を起動しない。

「レビュアーへ渡す入力」に従って、共通本文・対象・資料・制約・出力形式を含むプロンプトを作る。指示が空のまま、パスだけ、diff だけで開始しない。review-loop の担当として呼ばれた場合は、その JSONL の issue + coverage 形式を渡す。

作業ツリー外に一意の出力先を作る:

```bash
REVIEW_DIR=$(mktemp -d "${TMPDIR:-/tmp}/codex-review.XXXXXX")
REVIEW_PROMPT="$REVIEW_DIR/prompt.md"
RESULT_FILE="$REVIEW_DIR/result.md"
printf '%s\n' "$REVIEW_DIR" "$REVIEW_PROMPT" "$RESULT_FILE"
```

表示された実際の絶対パスを控え、Write 等のファイル書き込みツールで、その `prompt.md` に組み立てた本文を保存する。別の Bash 呼び出しには通常の shell 変数が引き継がれないため、次の呼び出しでも取得済みのパスを設定し直す。動的な PR 本文・diff をシェルの文字列に展開しない。repository 内に一時 AGENTS.md を置いて指示を注入しない。

## 3. stdin で送信

```bash
REVIEW_DIR="{前工程で取得した出力ディレクトリの絶対パス}"
REVIEW_PROMPT="$REVIEW_DIR/prompt.md"
RESULT_FILE="$REVIEW_DIR/result.md"
if codex exec -s read-only -C "{対象と同じ版の repository root}" \
  -o "$RESULT_FILE" - < "$REVIEW_PROMPT" > "$REVIEW_DIR/run.log" 2>&1; then
  REVIEW_EXIT=0
else
  REVIEW_EXIT=$?
fi
printf '%s\n' "$REVIEW_EXIT" > "$REVIEW_DIR/exit-code.txt"
(exit "$REVIEW_EXIT")
```

CLI の引数は `codex exec --help` で対応を確認する。`codex review --base` とカスタム prompt は併用できないため、この経路では stdin 対応の `exec` を使う。ユーザー設定の認証・モデルを保持し、指示を追加する目的で `--ignore-user-config` を使わない。

バックグラウンド実行時も呼び出し側で時間上限と完了を管理する。停止時は当該実行のプロセスが終了したことを確認してから再試行する。

## 4. 結果の確認

終了コード・timeout・最終出力の有無を確認してから `result.md` を読む。終了コードが非 0、出力なし、対象の途中変更、必須の確認範囲の欠落があれば未完了。途中で見つかった指摘は残してよいが、全体を「問題なし」「承認」としない。

`review-loop.md` の「単発レビューの出力」に従い、根拠・反証・未確認範囲を保って伝える。使用モデルを記載する場合は実行情報で確認し、推測や固定ラベルを付けない。

## 5. 投稿（明示的に `--post` が指定された場合のみ）

レビュー結果をファイルに保存し、投稿直前に PR の head を再確認する。固定 head と違う場合は最新レビューとして投稿せず、変更分を再確認する。本文には対象 SHA と未確認範囲を残す。

```bash
RESULT_FILE="{確認済みの結果ファイルの絶対パス}"
gh pr comment "{対象PR}" --body-file "$RESULT_FILE"
```

未完了の結果を投稿する場合も未完了と明記する。review-loop 内の担当は投稿せず、呼び出し元へ結果だけ返す。
