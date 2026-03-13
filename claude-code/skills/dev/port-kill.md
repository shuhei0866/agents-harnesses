---
name: port-kill
description: 指定したポートで動いているプロセスを停止する。/port-kill と呼ばれた時に使用する。
---

# /port-kill

指定したポートで動いているプロセスを停止するコマンド。

## 使い方

```
/port-kill 3000      # ポート 3000 を停止
/port-kill 3000 3001 # 複数ポートを停止
```

## 実行内容

```bash
# 単一ポート
lsof -ti:3000 | xargs kill -9 2>/dev/null

# 複数ポート
lsof -ti:3000 -ti:3001 | xargs kill -9 2>/dev/null
```

## よく使うポート

| ポート | サービス        |
| ------ | --------------- |
| 3000   | Next.js Web     |
| 8081   | Expo Metro      |
| 54321  | Supabase API    |
| 54322  | Supabase DB     |
| 54323  | Supabase Studio |
