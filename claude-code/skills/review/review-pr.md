---
name: review-pr
description: 既存の PR をレビューしたい時、PR の URL や番号が提示された時、または /review-pr と呼ばれた時に使用する。独立コンテキストでレビューし、結果を PR コメントとして投稿する。
context: fork
agent: code-reviewer
---

# PR レビュー

指定された PR を独立したコンテキストで客観的にレビューしてください。

## 手順

### 1. メモリの確認

エージェントメモリを確認し、過去のレビューで発見したパターンや頻出する問題を思い出す。

同じ skill ソースディレクトリの `review-loop.md`「全レビュアー共通の走査・報告契約」を適用する。インストール先ではインストール済み `review-loop` skill の本文を参照する。これは手順の参照であり、review-loop 全体の起動は不要。memory は検証する仮説とし、repository の指示と現行コードを優先する。

### 2. PR 情報の取得

```bash
# PR 情報を取得（引数から PR 番号または URL を抽出）
gh pr view $ARGUMENTS --json number,title,body,headRefName,baseRefName,headRefOid,baseRefOid,files,additions,deletions
```

取得した base/head OID を固定する。ローカルに対象 commit が無ければ取得し、隔離した読み取り用 checkout または `git show <head>:<path>` でその内容を読む。`git diff --name-status <base>...<head>` とファイルごとの差分を使い、API の files 一覧が切れても取りこぼさない。取得不能なら未完了として報告する。変化する `gh pr diff` と異なる checkout の内容を混ぜない。

### 3. レビュー実行

`review-loop.md` の「レビュアーへ渡す入力」に沿って、共通契約・変更に応じた確認経路・固定対象・repository の指示を適用する。別の reviewer に委譲する場合は本文を実プロンプトへ渡す。変更行から caller / consumer、保存・表示、仕様・検査までたどり、反証を確認して指摘する。

命名、一般的なテスト不足、使っていない技術のチェック項目を一律に指摘しない。適用される契約と具体的な影響を示す。

### 4. 結果の出力

PR の番号・タイトル・base/head SHA とともに、`review-loop.md` の「単発レビューの出力」を返す。担当範囲が未確認なら Approve とせず、未完了の理由を残す。issue の有無とレビューの完了状態を分ける。

### 5. PR にコメント投稿

`--dry-run` オプションが指定されていない場合、レビュー結果を PR にコメントとして投稿する:

投稿直前に PR head を再確認し、変わっていたら旧結果を最新レビューとして投稿しない。本文には対象 SHA を含める。inline 投稿へ切り替える場合も API の commit 指定を固定 head に合わせる。

結果本文を Write 等で一時ファイルへ保存してから、本文をシェルへ展開せずに投稿する。

```bash
gh pr comment "{対象PR}" --body-file "{結果ファイル}"
```

### 6. 知見の扱い

指摘を新しい規則として自動蓄積しない。撤回・反証・修正の根拠を確認し、記録を依頼された場合にだけ repository の正本と運用規約に従って残す。
