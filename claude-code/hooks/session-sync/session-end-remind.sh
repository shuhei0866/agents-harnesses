#!/usr/bin/env bash
# session-end-remind.sh
# UserPromptSubmit フックで「セッション終了っぽい発言」を検知し、
# /summarize でVault保存するようリマインドする。
#
# 入力: stdin から JSON（Claude Code hook 形式）
# 出力: stdout に JSON（メッセージがあれば）

set -euo pipefail

INPUT=$(cat)
PROMPT=$(echo "$INPUT" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    # hook の形式に応じて prompt を取得
    if isinstance(data, dict):
        print(data.get('prompt', data.get('message', '')))
    else:
        print('')
except:
    print('')
" 2>/dev/null || echo "")

# セッション終了シグナルのパターン
if echo "$PROMPT" | grep -qiE '(おやすみ|お疲れ|また(後で|明日|今度)|終わり(にする|にしよう|で)|ありがとう.*また|じゃあね|bye|good night|wrap up|done for (today|now)|that.s (all|it) for)'; then
  echo '{"message": "[Session End Reminder] セッション記録を Vault に保存しますか？ → /summarize"}'
fi
