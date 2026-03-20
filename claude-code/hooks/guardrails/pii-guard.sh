#!/bin/bash
# pii-guard: PreToolUse (Bash) - コミット・ファイル書き込み時の個人情報検出
#
# git commit 時に staged diff を検査し、以下を検出して警告:
# - ユーザー固有の絶対パス（/Users/<username>, /home/<username>）
# - IP アドレス（localhost 除外）
# - メールアドレス（Co-Authored-By, noreply 除外）
# - API キー・トークンパターン
#
# upstream-check.sh（push 時）より早い段階で検出する。

set -uo pipefail

GUARD_COMMON="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_guard-common.sh"
source "$GUARD_COMMON"

INPUT=$(cat)

if command -v jq &>/dev/null; then
  COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
else
  exit 0
fi

if [ -z "${COMMAND:-}" ]; then
  exit 0
fi

# git commit コマンドのみ対象
if ! echo "$COMMAND" | grep -qE 'git\s+(-C\s+\S+\s+)?commit\b'; then
  exit 0
fi

# git -C パスの取得
GIT_C_PATH=$(echo "$COMMAND" | sed -nE 's/.*git[[:space:]]+-C[[:space:]]+"([^"]+)".*/\1/p')
if [ -z "$GIT_C_PATH" ]; then
  GIT_C_PATH=$(echo "$COMMAND" | sed -nE 's/.*git[[:space:]]+-C[[:space:]]+([^ "'"'"']+).*/\1/p')
fi

if [ -n "$GIT_C_PATH" ]; then
  DIFF=$(git -C "$GIT_C_PATH" diff --cached 2>/dev/null || echo "")
else
  DIFF=$(git diff --cached 2>/dev/null || echo "")
fi

if [ -z "$DIFF" ]; then
  exit 0
fi

# 追加行のみ抽出（削除行は無視）
ADDED=$(echo "$DIFF" | grep "^+" | grep -v "^+++")

ISSUES=""

# 1. ユーザー固有の絶対パス
# 実際のユーザー名を検出（xxx のようなプレースホルダーは除外）
REAL_USER=$(whoami)
if echo "$ADDED" | grep -qE "/(Users|home)/${REAL_USER}[/\"' ]"; then
  ISSUES="${ISSUES}\n  - 自分のユーザーパス (/${REAL_USER}) がハードコードされています"
fi

# 2. 他の実在しそうなユーザーパス（プレースホルダー xxx, example, user 等は除外）
OTHER_PATHS=$(echo "$ADDED" | grep -oE '/(Users|home)/[a-zA-Z][a-zA-Z0-9_-]{2,}' | \
  grep -vi '/xxx\|/example\|/user\|/username\|/your\|/sal9000\|/root' | \
  sort -u || true)
if [ -n "$OTHER_PATHS" ]; then
  # sal9000 はデバイス名なので除外済み
  # 自分のパスは上で検出済みなので除外
  OTHER_PATHS=$(echo "$OTHER_PATHS" | grep -v "/${REAL_USER}$" || true)
  if [ -n "$OTHER_PATHS" ]; then
    ISSUES="${ISSUES}\n  - ユーザー固有パス: $(echo "$OTHER_PATHS" | tr '\n' ', ')"
  fi
fi

# 3. IP アドレス（127.x, 0.x, 100.x Tailscale は除外、10.x/192.168.x プライベートも除外）
IPS=$(echo "$ADDED" | grep -oE '\b[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\b' | \
  grep -v '^127\.\|^0\.\|^10\.\|^192\.168\.\|^100\.\|^172\.1[6-9]\.\|^172\.2[0-9]\.\|^172\.3[01]\.' | \
  sort -u || true)
if [ -n "$IPS" ]; then
  ISSUES="${ISSUES}\n  - パブリック IP アドレス: $(echo "$IPS" | tr '\n' ', ')"
fi

# 4. メールアドレス（Co-Authored-By, noreply, example.com 除外）
EMAILS=$(echo "$ADDED" | grep -v "Co-Authored-By" | grep -v "noreply" | \
  grep -oE '[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}' | \
  grep -v '@example\.\|@test\.\|@localhost' | \
  sort -u || true)
if [ -n "$EMAILS" ]; then
  ISSUES="${ISSUES}\n  - メールアドレス: $(echo "$EMAILS" | tr '\n' ', ')"
fi

# 5. API キー・トークンパターン
SECRETS=$(echo "$ADDED" | grep -oEi '(sk-[a-zA-Z0-9]{20,}|sk-ant-[a-zA-Z0-9-]+|ghp_[a-zA-Z0-9]{36}|gho_[a-zA-Z0-9]{36}|xoxb-[a-zA-Z0-9-]+|AKIA[A-Z0-9]{16})' | \
  sort -u || true)
if [ -n "$SECRETS" ]; then
  ISSUES="${ISSUES}\n  - シークレットパターン: $(echo "$SECRETS" | tr '\n' ', ')"
fi

if [ -n "$ISSUES" ]; then
  MSG=$(printf "コミット対象に個人情報・デバイス固有情報の可能性があります:%b\n\n環境変数や相対パスへの置き換えを検討してください。" "$ISSUES")
  guard_respond "advisory" "個人情報ガード" "$MSG"
fi

exit 0
