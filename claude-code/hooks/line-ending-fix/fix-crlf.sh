#!/bin/bash
# line-ending-fix/fix-crlf.sh: PostToolUse (Write|Edit) - CRLF 改行を自動修正
#
# Write/Edit 後にファイルの改行コードをチェックし、CRLF が検出された場合は
# LF に自動変換する。バイナリファイルはスキップ。
#
# macOS (Bash 3.2 / BSD grep・sed) と Linux (GNU) の両方で動くよう、
# `grep -P` や `sed -i` などの GNU 拡張は使わない。

set -uo pipefail

INPUT=$(cat)

# file_path を取得
if command -v jq &>/dev/null; then
  FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
else
  exit 0
fi

if [ -z "${FILE_PATH:-}" ]; then
  exit 0
fi

# ファイルが存在しない / 読み書きできない場合はスキップ
if [ ! -f "$FILE_PATH" ] || [ ! -r "$FILE_PATH" ] || [ ! -w "$FILE_PATH" ]; then
  exit 0
fi

# バイナリファイルはスキップ (file コマンドで判定)
# -b でパス名を除き、-L で実際に書き換えるリンク先を判定する。
if file -b -L -- "$FILE_PATH" 2>/dev/null | grep -qE 'binary|executable|image|archive|compressed'; then
  exit 0
fi

# NUL バイトを含まないバイナリも、file のエンコーディング判定で除外する。
if [ "$(file -b -L --mime-encoding -- "$FILE_PATH" 2>/dev/null)" = "binary" ]; then
  exit 0
fi

# バイナリファイルはスキップ (NUL バイトを含むものはテキストとして扱わない)
# file コマンドが "data" としか言わないバイナリや UTF-16 もここで除外する
TOTAL_BYTES=$(($(wc -c < "$FILE_PATH" 2>/dev/null)))
TEXT_BYTES=$(($(LC_ALL=C tr -d '\000' < "$FILE_PATH" 2>/dev/null | wc -c)))
if [ "$TOTAL_BYTES" -ne "$TEXT_BYTES" ]; then
  exit 0
fi

# リテラルの CR。BSD grep/sed は正規表現中の \r を解釈しないため直接埋め込む
CR=$(printf '\r')

# CRLF チェック (行末の CR を検出)
if ! LC_ALL=C grep -q "${CR}\$" "$FILE_PATH" 2>/dev/null; then
  exit 0
fi

# ファイル末尾 1 バイトを 16 進で返す
last_byte() {
  tail -c 1 "$1" 2>/dev/null | od -An -tx1 | tr -d ' \t\n'
}

TMP_FILE=$(mktemp "${TMPDIR:-/tmp}/fix-crlf.XXXXXX" 2>/dev/null) || exit 0
trap 'rm -f "$TMP_FILE"' EXIT

# 行末の CR のみ除去 (行中の CR は残す)。LC_ALL=C で不正バイト列でも失敗させない
if ! LC_ALL=C sed "s/${CR}\$//" "$FILE_PATH" > "$TMP_FILE" 2>/dev/null; then
  exit 0
fi

# 元ファイルへは上書きで戻す (inode・パーミッション・シンボリックリンクを維持)。
# BSD sed は末尾に改行が無いファイルへ改行を補うので、その場合は取り除く
if [ "$(last_byte "$FILE_PATH")" != "0a" ] && [ "$(last_byte "$TMP_FILE")" = "0a" ]; then
  TMP_BYTES=$(($(wc -c < "$TMP_FILE")))
  head -c "$((TMP_BYTES - 1))" "$TMP_FILE" > "$FILE_PATH" 2>/dev/null || exit 0
else
  cat "$TMP_FILE" > "$FILE_PATH" 2>/dev/null || exit 0
fi

echo "[CRLF 修正] ${FILE_PATH} の改行を LF に変換しました" >&2

exit 0
