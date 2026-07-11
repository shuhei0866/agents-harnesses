#!/bin/bash
# merged-pr-push-guard: PreToolUse (Bash) - merge 済み PR の branch への push をブロック
#
# merge 済み PR の head branch へさらに push すると、そのコミットはどの PR にも
# 載らない孤児になり、cherry-pick での回収が必要になる。merge 状態は GitHub 側に
# あって作業コンテキストに自然には入らないため、push の時点で gh に問い合わせて
# 機械的に止める。
#
# 挙動:
#   - push 先 branch の最新 PR が MERGED → deny（critical: GUARD_LEVEL に依らない）
#   - open PR がある / PR が無い / main・master・develop への push → 許可
#   - 連結コマンド内の複数 push はすべて検査する
#   - 実行ディレクトリは git -C > コマンド内の cd > hook 入力の cwd の順で解決する
#   - gh が無い・gh が失敗する環境 → fail-open（警告を残して許可する）
#   - opt-out: リポジトリの .claude/harness.config に GUARD_SKIP="merged-pr-push-guard"
#     を追記する（意図的に merge 済み branch を再利用する場合はユーザーに確認してから）
#
# 対象外（fail-open 方針）: --delete・--tags・--all・--branches・--mirror・
# refs/tags/ の push は branch 更新ではないため判定しない。

set -uo pipefail

GUARD_COMMON="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_guard-common.sh"
source "$GUARD_COMMON"

INPUT=$(cat)

if command -v jq &>/dev/null; then
  COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
  INPUT_CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
else
  exit 0
fi

if [ -z "${COMMAND:-}" ]; then
  exit 0
fi

# heredoc 本文（データ）と引用符内の 'git push' に反応しないよう、本文を落として
# 引用符を意識したセグメント分割を行い、コマンド先頭位置の git push だけを拾う
STRIPPED=$(guard_strip_heredoc_bodies "$COMMAND")

PFX='([A-Za-z_][A-Za-z_0-9]*=[^[:space:]]*[[:space:]]+)*(sudo[[:space:]]+)?(command[[:space:]]+)?'
PUSH_RE="^[[:space:]]*${PFX}git([[:space:]]+-C[[:space:]]+[^[:space:]]+)?[[:space:]]+push([[:space:]]|$)"

# --- push セグメントの収集（cd の文脈も追跡する）---
PUSH_SEGS=""
LAST_CD=""
while IFS= read -r seg; do
  if echo "$seg" | grep -qE "^[[:space:]]*${PFX}cd[[:space:]]"; then
    LAST_CD=$(echo "$seg" | sed -E "s/^[[:space:]]*${PFX}cd[[:space:]]+//" | awk '{print $1}')
  fi
  if echo "$seg" | grep -qE "$PUSH_RE"; then
    PUSH_SEGS="${PUSH_SEGS}${seg}@@CD@@${LAST_CD}"$'\n'
  fi
done <<< "$(guard_split_segments "$STRIPPED")"

if [ -z "$PUSH_SEGS" ]; then
  exit 0
fi

# gh が無い環境では merge 状態を判定できない → ポリシーどおり警告つきで許可
if ! command -v gh &>/dev/null; then
  cat << 'WARN'
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "allow",
    "additionalContext": "[merged-pr-push ガード] WARNING: gh が見つからないため merge 済み PR の判定をスキップしました。push 先 branch の PR が merge 済みでないか手動で確認してください。"
  }
}
WARN
  exit 0
fi

fail_open_warn() {
  cat << 'WARN'
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "allow",
    "additionalContext": "[merged-pr-push ガード] WARNING: gh で PR 状態を確認できなかったため、merge 済み判定をスキップして許可しました。push 先 branch の PR が merge 済みでないか手動で確認してください。"
  }
}
WARN
  exit 0
}

# --- 各 push セグメントを検査 ---
while IFS= read -r entry; do
  [ -z "$entry" ] && continue
  seg="${entry%%@@CD@@*}"
  seg_cd="${entry##*@@CD@@}"

  # 実行ディレクトリの解決: git -C > コマンド内の直前の cd > hook 入力の cwd
  WORK_DIR=$(echo "$seg" | grep -oE -- '-C[[:space:]]+[^[:space:]]+' | head -1 | sed -E 's/^-C[[:space:]]+//')
  if [ -z "$WORK_DIR" ]; then
    WORK_DIR="$seg_cd"
  fi
  if [ -z "$WORK_DIR" ]; then
    WORK_DIR="$INPUT_CWD"
  fi
  WORK_DIR="${WORK_DIR/#\~/$HOME}"
  WORK_DIR=$(echo "$WORK_DIR" | sed -E "s/^[\"']//; s/[\"']$//")
  if [ -n "$WORK_DIR" ] && [ ! -d "$WORK_DIR" ]; then
    WORK_DIR=""
  fi

  # --- push 引数の解析 ---
  ARGS=$(echo "$seg" | sed -E "s/^[[:space:]]*${PFX}git[[:space:]]+(-C[[:space:]]+[^[:space:]]+[[:space:]]+)?push//")
  read -ra TOKENS <<< "$ARGS"

  REMOTE=""
  REFSPECS=()
  skip_next=0
  skip_seg=0
  for tok in ${TOKENS[@]+"${TOKENS[@]}"}; do
    if [ "$skip_next" = "1" ]; then
      skip_next=0
      continue
    fi
    case "$tok" in
      --delete|-d) skip_seg=1; break ;;                      # branch 削除は孤児コミットを生まない
      --tags|--all|--branches|--mirror) skip_seg=1; break ;; # 一括 push は branch 単位で判定できない
      -o|--push-option|--receive-pack|--exec) skip_next=1 ;;
      -*) ;;                                                 # その他の flag は値を取らない前提で無視
      *[\<\>]*) ;;                                           # リダイレクトは positional として扱わない
      *)
        tok="${tok#[\"\']}"                                  # 引用符付き refspec を素の値に戻す
        tok="${tok%[\"\']}"
        if [ -z "$REMOTE" ]; then
          REMOTE="$tok"
        else
          REFSPECS+=("$tok")
        fi
        ;;
    esac
  done
  if [ "$skip_seg" = "1" ]; then
    continue
  fi

  # --- 対象 branch の決定 ---
  BRANCHES=()
  if [ ${#REFSPECS[@]} -eq 0 ]; then
    if [ -n "$WORK_DIR" ]; then
      CUR=$(git -C "$WORK_DIR" branch --show-current 2>/dev/null || echo "")
    else
      CUR=$(git branch --show-current 2>/dev/null || echo "")
    fi
    [ -z "$CUR" ] && continue
    BRANCHES+=("$CUR")
  else
    for rs in "${REFSPECS[@]}"; do
      rs="${rs#+}"
      case "$rs" in
        :*) continue ;;                                      # :branch はリモート側の削除
        refs/tags/*|*:refs/tags/*) continue ;;
      esac
      if [[ "$rs" == *:* ]]; then
        rs="${rs#*:}"                                        # src:dst の PR head はリモート側 dst
      fi
      rs="${rs#refs/heads/}"
      if [ "$rs" = "HEAD" ]; then
        if [ -n "$WORK_DIR" ]; then
          rs=$(git -C "$WORK_DIR" branch --show-current 2>/dev/null || echo "")
        else
          rs=$(git branch --show-current 2>/dev/null || echo "")
        fi
      fi
      [ -n "$rs" ] && BRANCHES+=("$rs")
    done
  fi

  if [ ${#BRANCHES[@]} -eq 0 ]; then
    continue
  fi

  # --- gh で PR 状態を確認 ---
  for BR in "${BRANCHES[@]}"; do
    # trunk への直接 push はこの guard の対象外（commit-guard の領分）
    case "$BR" in
      main|master|develop) continue ;;
    esac

    if [ -n "$WORK_DIR" ]; then
      PR_JSON=$(cd "$WORK_DIR" 2>/dev/null && gh pr view "$BR" --json state,number,url 2>&1)
    else
      PR_JSON=$(gh pr view "$BR" --json state,number,url 2>&1)
    fi
    RC=$?

    if [ $RC -ne 0 ]; then
      if echo "$PR_JSON" | grep -qi "no pull requests found"; then
        continue                                             # PR がまだ無い branch への push は通常運用
      fi
      fail_open_warn                                         # ネットワーク断・認証切れ等 → 警告つき許可
    fi

    STATE=$(echo "$PR_JSON" | jq -r '.state // empty' 2>/dev/null)
    if [ "$STATE" = "MERGED" ]; then
      NUM=$(echo "$PR_JSON" | jq -r '.number // empty' 2>/dev/null)
      URL=$(echo "$PR_JSON" | jq -r '.url // empty' 2>/dev/null)
      guard_respond "critical" "merged-pr-push ガード" "branch '${BR}' の PR #${NUM} は既に MERGED です（${URL}）。この push はどの PR にも載らない孤児コミットになります。\n\n対処法: 新しい branch を切ってから cherry-pick してください。\n  git checkout -b ${BR}-followup && git cherry-pick <sha>\n\n意図的に merge 済み branch を再利用する場合は、ユーザーに確認した上で .claude/harness.config の GUARD_SKIP に merged-pr-push-guard を追加して再実行してください。"
    fi
  done
done <<< "$PUSH_SEGS"

exit 0
