---
name: keyd
description: >
  キーバインド・キーマッピングの追加・変更・修正を依頼されたとき、
  または keyd の設定について質問されたときに使用する。
  例: 「Cmd+Xで○○したい」「Ctrl+○が効かない」「キーバインド追加して」「keydの設定見せて」
---

# keyd 設定スキル

## 概要
Ubuntu 上で Mac ライクなキーバインドを実現する keyd の設定を管理する。

## ファイル
- 設定ファイル: `~/my-ubuntu-settings/keyd/default.conf`
  - `/etc/keyd/default.conf` からシンボリックリンクされている
- 仕様書: `~/my-ubuntu-settings/keyd/SPEC.md`

## 手順

1. まず `~/my-ubuntu-settings/keyd/SPEC.md` を読んで現在の設計方針とマッピング一覧を把握する
2. `~/my-ubuntu-settings/keyd/default.conf` を読んで現在の設定を確認する
3. 設定ファイルを編集する（Edit ツールで直接編集可能）
4. `sudo /usr/bin/systemctl restart keyd` でリロードする（sudoers 設定済み、パスワード不要）
5. 変更内容に応じて SPEC.md のマッピング一覧も更新する

## keyd 設定の注意点

- 修飾キーレイヤーをオーバーライドする場合はベース修飾子を付ける（例: `[control:C]`）。付けないと他のキーの修飾が失われる
- composite layer（例: `[control+shift]`）にはベース修飾子を付けない。明示的マッピングに加算されて意図しない動作になる
- `[command:C]` の仮想 Ctrl は `[control]` レイヤーの影響を受ける
- コマンド実行が必要な場合は `command()` を使う（例: `q = command(loginctl lock-session)`）
- GNOME 側のキーバインドと競合する場合は `gsettings` で GNOME 側を無効化する
