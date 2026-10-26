#!/bin/bash
# op-guard: PreToolUse (Bash) - 1Password CLI の直接実行と、キーチェーンの秘密の読み出しをブロック
#
# claude-code/scripts/claude-profile は、専用の保管庫だけに権限を持つ 1Password のサービス
# アカウントで読み書きし（1Password の SDK を使う）、そのトークンを macOS のキーチェーンに
# 置く。エージェントが op を直接呼んだり、キーチェーンから秘密を読み出したりすると、トークンや
# 保管庫の値が会話ログに平文で残る。読める範囲を claude-profile に絞るため、次を止める。
#   - op の直接実行（op --version / op --help だけは許す）
#   - キーチェーンから claude-profile のトークンを出しうる security の操作:
#     find-generic-password / find-internet-password の -w・-g のうち、トークンの service 名
#     （CLAUDE_PROFILE_TOKEN_SERVICE、既定は claude-profile-op-token）を名指しするものと、
#     service（-s）も label（-l）も指定しないもの。dump-keychain と、標準入力からコマンドを
#     読む security -i / -p は常に止める
#     （ほかのサービスの API キーを値を出さずに変数へ読む使い方は、既存の作業手順にあるので通す）
#   - claude-profile の SDK とトークンを差し替える環境変数（CLAUDE_PROFILE_TEST_SDK /
#     CLAUDE_PROFILE_TEST_TOKEN。テスト専用）をコマンドで指定すること
#
# 判定（誤って許可するより、誤って拒否する側に倒す）:
#   1) 高速経路: 引用符とバックスラッシュを外した文字列に op・security・差し替えの変数が
#      語として無ければ素通しする
#   2) 別の実行経路: $( )・バッククォート・シェル（bash/sh/zsh/ksh/dash/fish）・eval/source/exec・
#      インタプリタ（python*/pypy*/node/deno/bun/ruby/perl/php/osascript/awk）があり、
#      「op <サブコマンド>」か security の秘密を出す操作が現れるなら拒否する
#   3) 直接実行: heredoc 本文を除き、コマンドの区切りごとにシェルの語に分けて見る
#      （引用符で囲んだ文字列は 1 語）。
#      a) どの位置でも、op の後ろに同じ区切りの中でサブコマンドが続くものと、security の
#         秘密を出す操作は止める。if・!・{ } や find -exec の後ろに置いても実行されるため
#      b) 先頭の語が op なら、サブコマンドが無くても止める。変数の代入、if・while・! などの
#         予約語、env・sudo・xargs などの前置きは飛ばす。command -v / -V は場所を表示する
#         だけなので数えない
#      grep op のように、サブコマンドの続かない引数としての op は止めない
#
# 許可されるもの:
#   - claude-profile 経由の読み書き（このフックからは内部の op / security の呼び出しが見えない）
#   - 引用符で囲んだ文章（git commit -m "use op ..." など）と heredoc 本文の中の言及
#   - security find-generic-password の属性だけの確認（-w / -g なし）や list-keychains
#   - command -v op（入っているかの確認）
#
# 限界: 変数展開、実行時に組み立てる名前、ファイルに書いたスクリプトの中身は、文字列の
#   照合では検出できない。env -S・watch・ssh・tmux や cmux の send のように、引用符で囲んだ
#   文字列を別の場所で実行させる前置きも数えない。事故と素朴な指示の注入を止めるための
#   もので、敵対的な回避への完全な防御ではない。

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

MSG="op の直接実行と、キーチェーンから秘密を読み出す操作はブロックされています。1Password の専用保管庫の読み書きは ~/agents-harnesses/claude-code/scripts/claude-profile を使ってください（例: claude-profile get 電話番号）。パスワードやカード番号の項目は、ユーザーがブラウザの自動入力やログイン操作で扱います。"

deny() {
  guard_respond "critical" "1Password ガード" "$MSG"
}

TOKEN_SERVICE="${CLAUDE_PROFILE_TOKEN_SERVICE:-claude-profile-op-token}"
OP_WORD='(^|[^[:alnum:]_.-])op([^[:alnum:]_-]|$)'
SECURITY_WORD='(^|[^[:alnum:]_.-])security([^[:alnum:]_-]|$)'
OVERRIDE_RE='CLAUDE_PROFILE_TEST_(SDK|TOKEN)'

# 1) 高速経路: 引用符とバックスラッシュを外した形で判定する
NORM=$(printf '%s' "$COMMAND" | tr -d "\"'\\\\")
if ! printf '%s' "$NORM" | grep -qE "$OP_WORD|$SECURITY_WORD|$OVERRIDE_RE"; then
  exit 0
fi

# 差し替えの変数はテストの中でだけ使う。コマンドで指定したら止める
if printf '%s' "$NORM" | grep -qE "${OVERRIDE_RE}="; then
  deny
fi

# security の秘密を出す操作が文字列のどこかにあるか（別の実行経路の判定に使う）
security_secret_anywhere() {
  printf '%s' "$NORM" | grep -qE "$SECURITY_WORD" || return 1
  printf '%s' "$NORM" | grep -qE '(^|[^[:alnum:]_-])dump-keychain([^[:alnum:]_-]|$)' && return 0
  printf '%s' "$NORM" | grep -qE '(^|[^[:alnum:]_.-])security[[:space:],]+-[ip]([^[:alnum:]_-]|$)' && return 0
  # find-*-password は、コマンドの区切りごとに、その中だけで秘密の出力と指定の有無を見る
  # （ls -l の -l のような、別のコマンドの引数を service / label の指定と数えない）
  local piece
  while IFS= read -r piece; do
    printf '%s' "$piece" | grep -qE "$SECURITY_WORD" || continue
    printf '%s' "$piece" | grep -qE '(^|[^[:alnum:]_-])find-(generic|internet)-password([^[:alnum:]_-]|$)' || continue
    printf '%s' "$piece" | grep -qE '(^|[^[:alnum:]_-])-[[:alpha:]]*[wg][[:alpha:]]*([^[:alnum:]_-]|$)' || continue
    # トークンを名指しするか、service / label を指定せずに秘密を出すものだけを止める
    printf '%s' "$piece" | grep -qF -- "$TOKEN_SERVICE" && return 0
    printf '%s' "$piece" | grep -qE '(^|[^[:alnum:]_-])-[[:alpha:]]*[sl]([^[:alnum:]_-]|$)' || return 0
  done < <(printf '%s\n' "$NORM" | tr ';&|()`' '\n')
  return 1
}

# 2) 別の実行経路: 引用符の中の文字列も実行されうる。op の後ろに --account x や --format=json の
#    ようなオプションを挟んでも、サブコマンドが続けば実行とみなす
OP_SUBCOMMANDS='item vault read run inject signin signout account service-account document user group environment whoami connect events-api plugin update completion daemon'
OP_SUB_RE="(^|[^[:alnum:]_.-])op([[:space:],]+-[^[:space:],]*([[:space:],]+[^-[:space:],][^[:space:],]*)?)*[[:space:],]+(${OP_SUBCOMMANDS// /|})([^[:alnum:]_-]|$)"
EXEC_RE='(^|[;&|[:space:](/])((ba|z|k|da|a)?sh|fish|eval|source|exec|python[0-9.]*|pypy[0-9.]*|node|deno|bun|ruby|perl|php|osascript|g?awk)([[:space:];&|<>)]|$)'
if printf '%s' "$COMMAND" | grep -qF -e '$(' -e '`' || printf '%s' "$NORM" | grep -qE "$EXEC_RE"; then
  if printf '%s' "$NORM" | grep -qE "$OP_SUB_RE" || security_secret_anywhere; then
    deny
  fi
fi

is_op_subcommand() {
  case "$1" in ''|*[[:space:]]*) return 1 ;; esac
  case " $OP_SUBCOMMANDS " in *" $1 "*) return 0 ;; esac
  return 1
}

# words[$1] が security のとき、同じ区切りの中の後ろの語が秘密を出す操作か
security_reveals_secret() {
  local j=$(($1 + 1)) sub="" w secret=0 selector=0 names_token=0
  while [ "$j" -lt "$n" ]; do
    case "${words[$j]}" in
      -i|-p) return 0 ;;
      -*) j=$((j + 1)) ;;
      *) sub="${words[$j]}"; break ;;
    esac
  done
  case "$sub" in
    dump-keychain) return 0 ;;
    find-generic-password|find-internet-password) ;;
    *) return 1 ;;
  esac
  # 秘密を出す -w / -g があり、トークンを名指しするか service / label の指定が無ければ止める
  j=$((j + 1))
  while [ "$j" -lt "$n" ]; do
    w="${words[$j]}"
    case "$w" in
      --*) ;;
      -*)
        case "$w" in -*[wg]*) secret=1 ;; esac
        case "$w" in -*[sl]) selector=1 ;; esac ;;
    esac
    [ "$w" = "$TOKEN_SERVICE" ] && names_token=1
    j=$((j + 1))
  done
  [ "$secret" -eq 1 ] && { [ "$names_token" -eq 1 ] || [ "$selector" -eq 0 ]; }
}

# 3) 直接実行: コマンドの区切りごとに、シェルの語に分けて見る
STRIPPED=$(guard_strip_heredoc_bodies "$COMMAND")
while IFS= read -r seg; do
  [ -n "$seg" ] || continue
  words=()
  while IFS= read -r w; do
    words+=("$w")
  done < <(guard_shell_tokens "$seg")
  n=${#words[@]}

  # a) どの位置でも、op の後ろにサブコマンドが続くものと、security の秘密を出す操作を止める
  t=0
  while [ "$t" -lt "$n" ]; do
    case "${words[$t]##*/}" in
      op)
        k=$((t + 1))
        while [ "$k" -lt "$n" ]; do
          is_op_subcommand "${words[$k]}" && deny
          k=$((k + 1))
        done ;;
      security)
        security_reveals_secret "$t" && deny ;;
    esac
    t=$((t + 1))
  done

  # b) 先頭の語が op なら、サブコマンドが無くても止める
  i=0
  while [ "$i" -lt "$n" ]; do
    case "${words[$i]}" in
      [A-Za-z_]*=*) i=$((i + 1)); continue ;;
      # if・while・! などの後ろの語もコマンドとして実行される
      if|then|elif|else|while|until|do|'!'|'{') i=$((i + 1)); continue ;;
    esac
    case "${words[$i]##*/}" in
      env|sudo|command|exec|nohup|time|xargs|nice|caffeinate|stdbuf|timeout|doas)
        # command -v / -V は場所を表示するだけで実行しない
        if [ "${words[$i]##*/}" = command ]; then
          case "${words[$((i + 1))]:-}" in -v|-V) i=$n; break ;; esac
        fi
        i=$((i + 1))
        while [ "$i" -lt "$n" ]; do
          case "${words[$i]}" in
            -*|[0-9]*|[A-Za-z_]*=*) i=$((i + 1)) ;;
            *) break ;;
          esac
        done
        # env -u NAME や sudo -u user のように値を取るオプションの値を、実行するコマンドと
        # 取り違えないよう、前置きの後ろに op があればそれを実行対象とみなす
        # （xargs grep -n op のような誤拒否は、誤って許可するよりよいとして受け入れる）
        k=$i
        while [ "$k" -lt "$n" ]; do
          if [ "${words[$k]##*/}" = op ]; then
            i=$k
            break
          fi
          k=$((k + 1))
        done
        continue ;;
    esac
    break
  done
  [ "$i" -lt "$n" ] || continue
  if [ "${words[$i]##*/}" = op ]; then
    case "${words[$((i + 1))]:-}" in
      --version|--help|-h) ;;
      *) deny ;;
    esac
  fi
done <<< "$(guard_split_segments "$STRIPPED")"

exit 0
