#!/bin/bash
# PostToolUse hook: Python ファイル編集後に ruff check を実行
# Edit|Write ツールで *.py ファイルが変更された場合のみ発火
#
# Claude Code hooks は event JSON を stdin で渡す仕様なので、
# cat で受けて tool_input.file_path を抽出する。
# 違反検出時は hookSpecificOutput.additionalContext を JSON で stdout に
# 返すことで会話に表示させる (plain stdout は debug log にしか出ない)。

INPUT=$(cat)

# tool_input.file_path を抽出 (PostToolUse Edit|Write の payload 形式)
FILE_PATH=$(echo "$INPUT" | python3 -c "import json,sys; data=json.load(sys.stdin); print((data.get('tool_input') or {}).get('file_path',''))" 2>/dev/null)

# Python ファイルでなければスキップ
if [[ "$FILE_PATH" != *.py ]]; then
  exit 0
fi

# ファイルが存在しなければスキップ
if [[ ! -f "$FILE_PATH" ]]; then
  exit 0
fi

# ruff check 実行 (フルパスで指定、PATH に無い場合がある)
RUFF="/Library/Frameworks/Python.framework/Versions/3.13/bin/ruff"
if [[ ! -x "$RUFF" ]]; then
  RUFF=$(command -v ruff 2>/dev/null)
fi

if [[ -z "$RUFF" ]]; then
  exit 0
fi

OUTPUT=$("$RUFF" check "$FILE_PATH" 2>&1)
RC=$?

if [[ $RC -ne 0 ]]; then
  # 違反検出: JSON で additionalContext として返す (会話に表示される)
  FILE_PATH="$FILE_PATH" OUTPUT="$OUTPUT" python3 -c "
import json, os
msg = '⚠️ ruff check found issues in ' + os.environ['FILE_PATH'] + ':\n' + os.environ['OUTPUT']
print(json.dumps({'hookSpecificOutput': {'additionalContext': msg}}))
"
fi

exit 0
