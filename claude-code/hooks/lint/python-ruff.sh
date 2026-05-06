#!/bin/bash
# PostToolUse hook: Python ファイル編集後に ruff check を実行
# Edit|Write ツールで *.py ファイルが変更された場合のみ発火

# ツール入力から file_path を取得
FILE_PATH=$(echo "$CLAUDE_TOOL_INPUT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('file_path',''))" 2>/dev/null)

# Python ファイルでなければスキップ
if [[ "$FILE_PATH" != *.py ]]; then
  exit 0
fi

# ファイルが存在しなければスキップ
if [[ ! -f "$FILE_PATH" ]]; then
  exit 0
fi

# ruff check 実行（フルパスで指定、PATH に無い場合がある）
RUFF="/Library/Frameworks/Python.framework/Versions/3.13/bin/ruff"
if [[ ! -x "$RUFF" ]]; then
  RUFF=$(command -v ruff 2>/dev/null)
fi

if [[ -z "$RUFF" ]]; then
  exit 0
fi

OUTPUT=$("$RUFF" check "$FILE_PATH" 2>&1)
if [[ $? -ne 0 ]]; then
  echo "⚠️ ruff check found issues in $FILE_PATH:"
  echo "$OUTPUT"
  # hook は warning のみ、ブロックはしない
  exit 0
fi
