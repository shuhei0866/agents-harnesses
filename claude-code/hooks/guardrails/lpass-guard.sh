#!/bin/bash
# lpass-guard: PreToolUse (Bash) - エージェントによる LastPass CLI の直接実行をブロック
#
# lpass のエージェントがロック解除されているあいだは、同じユーザーで動くプロセスなら
# 保管庫のどの項目でも読める。エージェントがパスワードの項目を表示すると、値が会話ログに
# 平文で残る。読める範囲を専用の窓口 claude-code/scripts/claude-profile（保管庫の Claude/
# フォルダだけを読み書きする）に絞るため、lpass の直接実行を止める。
#
# 判定（誤って許可するより、誤って拒否する側に倒す）:
#   1) 高速経路: 引用符とバックスラッシュを外した文字列に lpass が語として無ければ素通しする
#      （lp''ass や l\pass、"lpass" もシェルは lpass として実行するので、外してから見る）
#   2) 別の実行経路: $( )・バッククォート・シェル（bash/sh/zsh/ksh/dash/fish。パス付き、
#      オプション付き、パイプや here-string で渡すものを含む）・eval/source/exec・インタプリタ
#      （python*/pypy*/node/deno/bun/ruby/perl/php/osascript/awk）があり、lpass が語として
#      現れるなら拒否する。引用符の中の文字列も実行されうるため
#   3) 直接実行: heredoc 本文を除いたコマンドを、引用符とエスケープを外したシェルの単語に
#      分ける。basename が lpass の単語があれば拒否する。直後が status / --version / -v の
#      ときだけ許す（保管庫の中身に触れない）
#
# 許可されるもの:
#   - claude-profile 経由の読み書き（このフックからは内部の lpass 呼び出しが見えない）
#   - 引用符で囲んだ文章の中の言及（git commit -m "add lpass guard" など）と、cat 等に流す
#     heredoc 本文の言及
#   - ~/.lpass や test-lpass-guard.sh のように、パスや名前の一部として出てくるもの
#
# 限界: 変数展開（x=l; ${x}pass）や実行時に組み立てる名前は、文字列の照合では検出できない。
#   事故と素朴な指示の注入を止めるためのもので、敵対的な回避への完全な防御ではない。
#   command -v lpass のような参照も拒否されるので、状態確認は claude-profile status を使う。

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

MSG="lpass の直接実行はブロックされています。保管庫の Claude/ フォルダの読み書きは ~/agents-harnesses/claude-code/scripts/claude-profile を使ってください（例: claude-profile get 電話番号）。パスワードやカード番号の項目は、ユーザーがブラウザの自動入力やログイン操作で扱います。"

# lpass を 1 語として含むか（~/.lpass、lastpass-cli、test-lpass-guard.sh の一部としては数えない）
WORD='(^|[^[:alnum:]_.-])lpass([^[:alnum:]_-]|$)'

# 1) 高速経路: 引用符とバックスラッシュを外した形で判定する
NORM=$(printf '%s' "$COMMAND" | tr -d "\"'\\\\")
case "$NORM" in
  *lpass*) ;;
  *) exit 0 ;;
esac
if ! printf '%s' "$NORM" | grep -qE "$WORD"; then
  exit 0
fi

# 2) 別の実行経路: 引用符の中の文字列も実行されうる
SUBST_RE='\$\(([^)]*[^[:alnum:]_.-])?lpass([^[:alnum:]_-]|$)'
BACKTICK_RE='`([^`]*[^[:alnum:]_.-])?lpass([^[:alnum:]_-]|$)'
EXEC_RE='(^|[;&|[:space:](/])((ba|z|k|da|a)?sh|fish|eval|source|exec|python[0-9.]*|pypy[0-9.]*|node|deno|bun|ruby|perl|php|osascript|g?awk)([[:space:];&|<>)]|$)'
if printf '%s' "$NORM" | grep -qE "$SUBST_RE" \
   || printf '%s' "$NORM" | grep -qE "$BACKTICK_RE" \
   || printf '%s' "$NORM" | grep -qE "$EXEC_RE"; then
  guard_respond "critical" "LastPass ガード" "$MSG"
fi

# 3) 直接実行: heredoc 本文を除き、シェルの単語（引用符・エスケープを外したもの）で判定する。
#    単語に付いたままの区切り記号（status; など）はさらに分ける
STRIPPED=$(guard_strip_heredoc_bodies "$COMMAND")
if guard_shell_tokens "$STRIPPED" | awk '
  {
    n = split($0, parts, /[;&|()<>`]+/)
    for (i = 1; i <= n; i++) {
      w = parts[i]
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", w)
      if (w != "") words[++count] = w
    }
  }
  END {
    bad = 0
    for (i = 1; i <= count; i++) {
      base = words[i]
      sub(/.*\//, "", base)
      if (base == "lpass") {
        next_word = (i < count) ? words[i + 1] : ""
        if (next_word != "status" && next_word != "--version" && next_word != "-v") bad = 1
      }
    }
    exit bad ? 0 : 1
  }'; then
  guard_respond "critical" "LastPass ガード" "$MSG"
fi

exit 0
