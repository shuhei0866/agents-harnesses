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
#   2) 別の実行経路: $( )・バッククォートがあるか、シェル（bash/sh/zsh/ksh/dash/fish）・
#      eval/source/exec・インタプリタ（python*/pypy*/node/deno/bun/ruby/perl/php/osascript/awk）が
#      引用符の外の語としてあり、「op <サブコマンド>」か security の秘密を出す操作が文字列の
#      どこかに現れるなら拒否する。引用符で囲んだ文章の中のシェルの名前
#      （git commit -m "... bash ..." など）は数えない。security の service / label の指定は、
#      引用符で囲んだ文字列ごとにも数え直す（bash -c '...' -s x の外側の -s を、内側の指定と
#      数えない）
#   3) 直接実行: heredoc 本文を除き、コマンドの区切りごとにシェルの語に分けて見る
#      （引用符で囲んだ文字列は 1 語）。command -v / -V・type・which で始まる区切りは、場所や
#      種類を表示するだけなので見ない。
#      a) どの位置でも、op の後ろに同じ区切りの中でサブコマンドが続くものと、security の
#         秘密を出す操作は止める。if・!・{ } や find -exec の後ろに置いても実行されるため
#      b) 先頭の語が op なら、サブコマンドが無くても止める。変数の代入、if・while・! などの
#         予約語、env・sudo・xargs などの前置きは飛ばす
#      grep op のように、サブコマンドの続かない引数としての op は止めない
#   security の引数は /usr/bin/security と同じ getopt の規則で読む。まとめ書き（-qi・-gs <service>・
#   -sexample.com）は 1 文字ずつ見て、値を取る文字は残りの文字か次の語を値にする。最初の位置引数
#   （鍵束の名前）か -- でオプションは終わり、その後ろの -s / -l は指定にならない。リダイレクトは
#   引数に数えない
#
# 許可されるもの:
#   - claude-profile 経由の読み書き（このフックからは内部の op / security の呼び出しが見えない）
#   - 引用符で囲んだ文章（git commit -m "use op ..." など）と heredoc 本文の中の言及
#   - security find-generic-password の属性だけの確認（-w / -g なし）や list-keychains
#   - command -v op（入っているかの確認）
#
# 限界: 変数展開、実行時に組み立てる名前、ファイルに書いたスクリプトの中身は、文字列の
#   照合では検出できない。env -S・watch・ssh・tmux や cmux の send のように、引用符で囲んだ
#   文字列を別の場所で実行させる前置きも数えない（その文字列の中にシェルの名前があっても同じ）。
#   事故と素朴な指示の注入を止めるためのもので、敵対的な回避への完全な防御ではない。

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

STRIPPED=$(guard_strip_heredoc_bodies "$COMMAND")

# security の後ろの引数（$2 以降）が、キーチェーンの秘密を出す操作か。$1 は引数の分け方:
#   strict: シェルの語に正しく分けた引数。/usr/bin/security と同じく、最初の位置引数（鍵束の
#           名前）か -- でオプションの解釈を終える（その後ろの -s / -l は指定にならない）
#   loose:  引用符を外して空白で分けた引数。"My User" が 2 語になるなど語の切れ目が当てに
#           ならないので、位置引数で止めずに最後まで読む（-- や位置引数の後ろの -s で素通しに
#           なる形は、同じ文字列を strict で読む判定が拾う）
security_args_reveal_secret() {
  local mode="$1" w opts c val secret=0 selector=0 names_token=0
  local -a args=()
  shift
  # リダイレクトは security の引数にならないので先に除く（演算子だけなら次の語が行き先）
  while [ "$#" -gt 0 ]; do
    case "$1" in
      [0-9]*[\<\>]|[\<\>]|[\<\>][\<\>]|'<<<') shift; [ "$#" -gt 0 ] && shift ;;
      [0-9]*[\<\>]*|[\<\>]*) shift ;;
      *) args+=("$1"); shift ;;
    esac
  done
  set -- ${args[@]+"${args[@]}"}
  # サブコマンドの前の全体のオプション。-i（対話）と -p（プロンプト付きの対話）は標準入力から
  # コマンドを読むので、ほかの文字とまとめて書いても（-qi）止める。security に長いオプションは
  # 無く、--help のような語は最初の文字で使い方を表示して終わるので数えない
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --) shift; break ;;
      --*) shift ;;
      -*[ip]*) return 0 ;;
      -?*) shift ;;
      *) break ;;
    esac
  done
  case "${1:-}" in
    dump-keychain) return 0 ;;
    find-generic-password|find-internet-password) shift ;;
    *) return 1 ;;
  esac
  while [ "$#" -gt 0 ]; do
    w="$1"
    shift
    case "$w" in
      --|-|[!-]*|'')
        [ "$mode" = strict ] && break
        continue ;;
    esac
    opts="${w#-}"
    while [ -n "$opts" ]; do
      c="${opts:0:1}"
      opts="${opts:1}"
      case "$c" in
        g|w) secret=1; continue ;;
        [aCcDdGjlPprst]) ;;
        *) continue ;;
      esac
      # 値を取る文字は、残りの文字か次の語を値にする（-sexample.com、-gs <service>）
      if [ -n "$opts" ]; then
        val="$opts"
        opts=""
      elif [ "$#" -gt 0 ]; then
        val="$1"
        shift
      else
        continue
      fi
      case "$c" in
        s|l)
          selector=1
          [ "$val" = "$TOKEN_SERVICE" ] && names_token=1 ;;
      esac
    done
  done
  # 秘密を出す -w / -g があり、トークンを名指しするか service / label の指定が無ければ止める
  [ "$secret" -eq 1 ] && { [ "$names_token" -eq 1 ] || [ "$selector" -eq 0 ]; }
}

# 引用符を外した文字列（$1）を、コマンドの区切りごとに語に分け、security の秘密を出す操作が
# あるか見る（python の ['security', '-w'] のような並びも語に分ける）
pieces_reveal_secret() {
  local piece i
  local -a ws
  while IFS= read -r piece; do
    read -r -a ws <<< "$(printf '%s' "$piece" | tr ',[]' '   ')"
    i=0
    while [ "$i" -lt "${#ws[@]}" ]; do
      if [ "${ws[$i]##*/}" = security ] && security_args_reveal_secret loose "${ws[@]:$((i + 1))}"; then
        return 0
      fi
      i=$((i + 1))
    done
  done < <(printf '%s\n' "$1" | tr ';&|()`' '\n')
  return 1
}

# 文字列（$1）をコマンドの区切りごとにシェルの語に分け、security の秘密を出す操作があるか見る
words_reveal_secret() {
  local seg w t
  local -a ws
  while IFS= read -r seg; do
    ws=()
    while IFS= read -r w; do
      ws+=("$w")
    done < <(guard_shell_tokens "$seg")
    t=0
    while [ "$t" -lt "${#ws[@]}" ]; do
      if [ "${ws[$t]##*/}" = security ] && security_args_reveal_secret strict "${ws[@]:$((t + 1))}"; then
        return 0
      fi
      t=$((t + 1))
    done
  done < <(guard_split_segments "$1")
  return 1
}

# 空白を含む語（引用符で囲んだ文字列）を、入れ子の分も含めて 3 段まで NUL 区切りで出す
quoted_texts() {
  local text="$1" depth="$2" seg w
  [ "$depth" -lt 3 ] || return 0
  while IFS= read -r seg; do
    while IFS= read -r w; do
      case "$w" in
        *[[:space:]]*)
          printf '%s\0' "$w"
          quoted_texts "$w" $((depth + 1)) ;;
      esac
    done < <(guard_shell_tokens "$seg")
  done < <(guard_split_segments "$text")
}

# security の秘密を出す操作が文字列のどこかにあるか（別の実行経路の判定に使う）
security_secret_anywhere() {
  printf '%s' "$NORM" | grep -qE "$SECURITY_WORD" || return 1
  printf '%s' "$NORM" | grep -qE '(^|[^[:alnum:]_-])dump-keychain([^[:alnum:]_-]|$)' && return 0
  pieces_reveal_secret "$NORM" && return 0
  # 引用符で囲んだ文字列は、その中をシェルの語に分け直して見る。bash -c '...' -s x のような
  # 外側の引数を、内側の service / label の指定と数えないため
  local text
  while IFS= read -r -d '' text; do
    words_reveal_secret "$text" && return 0
  done < <(quoted_texts "$STRIPPED" 0)
  return 1
}

# 2) 別の実行経路: 引用符の中の文字列も実行されうる。op の後ろに --account x や --format=json の
#    ようなオプションを挟んでも、サブコマンドが続けば実行とみなす
OP_SUBCOMMANDS='item vault read run inject signin signout account service-account document user group environment whoami connect events-api plugin update completion daemon'
OP_SUB_RE="(^|[^[:alnum:]_.-])op([[:space:],]+-[^[:space:],]*([[:space:],]+[^-[:space:],][^[:space:],]*)?)*[[:space:],]+(${OP_SUBCOMMANDS// /|})([^[:alnum:]_-]|$)"
EXEC_WORD_RE='^([^[:space:]]*/)?((ba|z|k|da|a)?sh|fish|eval|source|exec|python[0-9.]*|pypy[0-9.]*|node|deno|bun|ruby|perl|php|osascript|g?awk)([<>].*)?$'

# シェル・インタプリタが引用符の外の語としてあるか（bash -c '...'、... | sh、python3 <<EOF、
# bash<<<'...' など）。引用符で囲んだ文章の中の言及は数えない
exec_word_outside_quotes() {
  local seg tokens=""
  while IFS= read -r seg; do
    tokens+="$(guard_shell_tokens "$seg")"$'\n'
  done < <(guard_split_segments "$STRIPPED")
  grep -qE "$EXEC_WORD_RE" <<< "$tokens"
}

if printf '%s' "$COMMAND" | grep -qF -e '$(' -e '`' || exec_word_outside_quotes; then
  if printf '%s' "$NORM" | grep -qE "$OP_SUB_RE" || security_secret_anywhere; then
    deny
  fi
fi

is_op_subcommand() {
  case "$1" in ''|*[[:space:]]*) return 1 ;; esac
  case " $OP_SUBCOMMANDS " in *" $1 "*) return 0 ;; esac
  return 1
}

# 3) 直接実行: コマンドの区切りごとに、シェルの語に分けて見る
while IFS= read -r seg; do
  [ -n "$seg" ] || continue
  words=()
  while IFS= read -r w; do
    words+=("$w")
  done < <(guard_shell_tokens "$seg")
  n=${#words[@]}

  # 先頭の語: 変数の代入と、if・while・! などの予約語（後ろの語もコマンドとして実行される）を飛ばす
  h=0
  while [ "$h" -lt "$n" ]; do
    case "${words[$h]}" in
      [A-Za-z_]*=*|if|then|elif|else|while|until|do|'!'|'{') h=$((h + 1)) ;;
      *) break ;;
    esac
  done
  [ "$h" -lt "$n" ] || continue

  # command -v / -V・type・which は場所や種類を表示するだけで、後ろの語を実行しない
  case "${words[$h]##*/}" in
    type|which) continue ;;
    command)
      case "${words[$((h + 1))]:-}" in -*[vV]*) continue ;; esac ;;
  esac

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
        security_args_reveal_secret strict "${words[@]:$((t + 1))}" && deny ;;
    esac
    t=$((t + 1))
  done

  # b) 先頭の語が op なら、サブコマンドが無くても止める
  i=$h
  while [ "$i" -lt "$n" ]; do
    case "${words[$i]}" in
      [A-Za-z_]*=*) i=$((i + 1)); continue ;;
      if|then|elif|else|while|until|do|'!'|'{') i=$((i + 1)); continue ;;
    esac
    case "${words[$i]##*/}" in
      env|sudo|command|exec|nohup|time|xargs|nice|caffeinate|stdbuf|timeout|doas)
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
