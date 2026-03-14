#!/bin/bash
# setup-hooks.sh: git hooks のインストールと .sensitive-patterns.local のセットアップ
#
# 使い方:
#   ./scripts/setup-hooks.sh

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
HOOK_SRC="$REPO_ROOT/scripts/hooks/pre-commit"
HOOK_DST="$REPO_ROOT/.git/hooks/pre-commit"
LOCAL_PATTERNS="$REPO_ROOT/.sensitive-patterns.local"
LOCAL_EXAMPLE="$REPO_ROOT/.sensitive-patterns.local.example"

echo "=== agents-harnesses: フックセットアップ ==="
echo ""

# --- pre-commit hook のインストール ---
if [ -f "$HOOK_DST" ] && [ ! -L "$HOOK_DST" ]; then
  echo "⚠  既存の pre-commit hook があります: $HOOK_DST"
  echo "   バックアップを作成して上書きします。"
  cp "$HOOK_DST" "$HOOK_DST.backup.$(date +%Y%m%d%H%M%S)"
fi

ln -sf "../../scripts/hooks/pre-commit" "$HOOK_DST"
chmod +x "$HOOK_SRC"
echo "✅ pre-commit hook をインストールしました"

# --- .sensitive-patterns.local のセットアップ ---
if [ -f "$LOCAL_PATTERNS" ]; then
  echo "✅ .sensitive-patterns.local は既に存在します"
else
  if [ -f "$LOCAL_EXAMPLE" ]; then
    cp "$LOCAL_EXAMPLE" "$LOCAL_PATTERNS"
    echo "📝 .sensitive-patterns.local を作成しました（テンプレートからコピー）"
    echo "   → エディタで個人情報パターンを記入してください: $LOCAL_PATTERNS"
  else
    echo "⚠  .sensitive-patterns.local.example が見つかりません"
  fi
fi

echo ""
echo "=== セットアップ完了 ==="
echo ""
echo "次のステップ:"
echo "  1. .sensitive-patterns.local を編集して個人情報パターンを追加"
echo "  2. テストコミットで動作確認:"
echo "     echo 'your-name@example.com' > test-file.txt"
echo "     git add test-file.txt && git commit -m 'test'"
