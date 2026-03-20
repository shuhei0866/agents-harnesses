#!/usr/bin/env bash
# upstream-check.sh
# PreToolUse (Bash) フックで git push 前に個人情報・デバイス固有情報をチェック
#
# 検出対象:
# - ユーザー名・ホスト名のハードコード
# - 絶対パス（/Users/xxx, /home/xxx）
# - メールアドレス（Co-Authored-By 以外）
# - IP アドレス
# - API キー・トークンパターン
#
# staged されたファイルの diff を検査する。

set -euo pipefail

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    print(data.get('command', data.get('input', {}).get('command', '')))
except:
    print('')
" 2>/dev/null || echo "")

# git push コマンドのみ対象
if ! echo "$COMMAND" | grep -qE '^\s*git\s+push'; then
  exit 0
fi

# staged diff を取得（push 対象のコミット）
# HEAD と remote tracking branch の差分を検査
DIFF=$(git diff @{upstream}..HEAD 2>/dev/null || git diff HEAD~1..HEAD 2>/dev/null || echo "")

if [ -z "$DIFF" ]; then
  exit 0
fi

ISSUES=""

# 1. 絶対パス（/Users/xxx, /home/xxx）— ただしコメントやドキュメントの例示は除外
PATHS=$(echo "$DIFF" | grep "^+" | grep -v "^+++" | grep -oE '/(Users|home)/[a-zA-Z0-9_-]+' | sort -u || true)
if [ -n "$PATHS" ]; then
  ISSUES="${ISSUES}\n- ユーザー固有の絶対パス: ${PATHS}"
fi

# 2. IP アドレス（プライベート含む、localhost 除外）
IPS=$(echo "$DIFF" | grep "^+" | grep -v "^+++" | grep -oE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | grep -v "^127\." | grep -v "^0\." | sort -u || true)
if [ -n "$IPS" ]; then
  ISSUES="${ISSUES}\n- IP アドレス: ${IPS}"
fi

# 3. メールアドレス（Co-Authored-By と noreply を除外）
EMAILS=$(echo "$DIFF" | grep "^+" | grep -v "^+++" | grep -v "Co-Authored-By" | grep -v "noreply" | grep -oE '[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}' | sort -u || true)
if [ -n "$EMAILS" ]; then
  ISSUES="${ISSUES}\n- メールアドレス: ${EMAILS}"
fi

# 4. API キー・トークンパターン
SECRETS=$(echo "$DIFF" | grep "^+" | grep -v "^+++" | grep -oEi '(sk-[a-zA-Z0-9]{20,}|ghp_[a-zA-Z0-9]{36}|xoxb-[a-zA-Z0-9-]+|AKIA[A-Z0-9]{16})' | sort -u || true)
if [ -n "$SECRETS" ]; then
  ISSUES="${ISSUES}\n- シークレットパターン: ${SECRETS}"
fi

if [ -n "$ISSUES" ]; then
  MSG=$(printf "[Upstream Check] push 対象に個人情報・デバイス固有情報の可能性があります:\n%b\n\n確認してから push してください。" "$ISSUES")
  echo "{\"message\": $(python3 -c "import json; print(json.dumps('''$MSG'''))" 2>/dev/null || echo "\"$MSG\"")}"
  exit 1
fi
