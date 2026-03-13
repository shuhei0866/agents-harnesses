#!/bin/bash
# commit-guard: PreToolUse (Bash) - 危険な git 操作をブロック [L5]
#
# メインワークツリーでの保護ブランチ (main/develop) への直接コミット、
# --no-verify によるフックスキップ、force push、ブランチ切り替え、
# main への直接マージ（hotfix 除く）、develop ブランチ削除などを検出してブロックする。
# gh pr merge による main 向け PR マージもブロック（hotfix/*, chore/promote-main-*, develop は除く）。

set -uo pipefail

GUARD_COMMON="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_guard-common.sh"
source "$GUARD_COMMON"

INPUT=$(cat)

# command を取得
if command -v jq &>/dev/null; then
  COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
else
  exit 0
fi

if [ -z "${COMMAND:-}" ]; then
  exit 0
fi

# パターンマッチ用: 引用符内のテキストをプレースホルダーに置換（コマンド引数の誤検出防止）
COMMAND_FOR_MATCH=$(echo "$COMMAND" | sed -E "s/\"[^\"]*\"/_Q_/g; s/'[^']*'/_Q_/g")

# git/gh コマンド以外はスキップ
case "$COMMAND_FOR_MATCH" in
  *git\ *|*gh\ *)
    ;;
  *)
    exit 0
    ;;
esac

# --- チェック 0: メインワークツリーでの git commit (保護ブランチ直接コミット防止) ---
if echo "$COMMAND_FOR_MATCH" | grep -qE 'git\s+(-C\s+\S+\s+)?commit\b'; then
  GIT_C_PATH=$(echo "$COMMAND" | sed -nE 's/.*git[[:space:]]+-C[[:space:]]+"([^"]+)".*/\1/p')
  if [ -z "$GIT_C_PATH" ]; then
    GIT_C_PATH=$(echo "$COMMAND" | sed -nE "s/.*git[[:space:]]+-C[[:space:]]+'([^']+)'.*/\1/p")
  fi
  if [ -z "$GIT_C_PATH" ]; then
    GIT_C_PATH=$(echo "$COMMAND" | sed -nE 's/.*git[[:space:]]+-C[[:space:]]+([^ "'"'"']+).*/\1/p')
  fi

  BEFORE_GIT=$(echo "$COMMAND" | sed -nE 's/(.*)(git[[:space:]]+(-C[[:space:]]+[^ ]+[[:space:]]+)?commit\b.*)/\1/p')
  CD_PATH=$(echo "$BEFORE_GIT" | sed -nE 's/.*cd[[:space:]]+"([^"]+)".*/\1/p')
  if [ -z "$CD_PATH" ]; then
    CD_PATH=$(echo "$BEFORE_GIT" | sed -nE "s/.*cd[[:space:]]+'([^']+)'.*/\1/p")
  fi
  if [ -z "$CD_PATH" ]; then
    CD_PATH=$(echo "$BEFORE_GIT" | sed -nE 's/.*cd[[:space:]]+([^ "&;|'"'"']+).*/\1/p')
  fi

  if [ -n "$GIT_C_PATH" ]; then
    GIT_COMMON_DIR=$(git -C "$GIT_C_PATH" rev-parse --git-common-dir 2>/dev/null || echo "")
    GIT_DIR=$(git -C "$GIT_C_PATH" rev-parse --git-dir 2>/dev/null || echo "")
    BRANCH=$(git -C "$GIT_C_PATH" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  elif [ -n "$CD_PATH" ] && [ -d "$CD_PATH" ]; then
    GIT_COMMON_DIR=$(git -C "$CD_PATH" rev-parse --git-common-dir 2>/dev/null || echo "")
    GIT_DIR=$(git -C "$CD_PATH" rev-parse --git-dir 2>/dev/null || echo "")
    BRANCH=$(git -C "$CD_PATH" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  else
    GIT_COMMON_DIR=$(git rev-parse --git-common-dir 2>/dev/null || echo "")
    GIT_DIR=$(git rev-parse --git-dir 2>/dev/null || echo "")
    BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  fi

  if [ "$GIT_DIR" = "$GIT_COMMON_DIR" ] || [ "$GIT_DIR" = ".git" ]; then
    if [ "$BRANCH" = "main" ] || [ "$BRANCH" = "master" ] || [ "$BRANCH" = "develop" ]; then
      guard_respond "advisory" "コミット衛生ガード" "メインワークツリーの ${BRANCH} ブランチでの直接コミットはブロックされています。ブランチを作成して PR 経由でマージしてください。.claude/ の変更も含め、ワークツリーまたは別ブランチで作業してください。"
    fi
  fi
fi

# --- チェック 1: --no-verify / -n (commit) ---
if echo "$COMMAND_FOR_MATCH" | grep -qE 'git\s+commit\s.*--no-verify|git\s+commit\s.*\s-n\b'; then
  guard_respond "critical" "コミット衛生ガード" "--no-verify の使用はブロックされています。pre-commit フックのエラーを修正してからコミットしてください。lint エラーの場合は \`pnpm lint --fix\` を試してください。"
fi

# --- チェック 2: force push to main/master ---
if echo "$COMMAND_FOR_MATCH" | grep -qE 'git\s+push\s.*--force|git\s+push\s.*-f\b'; then
  if echo "$COMMAND_FOR_MATCH" | grep -qE '\b(main|master)\b'; then
    guard_respond "critical" "コミット衛生ガード" "main/master への force push はブロックされています。"
  fi
fi

# --- チェック 3: メインワークツリーでの git checkout (ブランチ切り替え) ---
if echo "$COMMAND_FOR_MATCH" | grep -qE 'git\s+checkout\s|git\s+switch\s'; then
  GIT_COMMON_DIR=$(git rev-parse --git-common-dir 2>/dev/null || echo "")
  GIT_DIR=$(git rev-parse --git-dir 2>/dev/null || echo "")

  if [ "$GIT_DIR" = "$GIT_COMMON_DIR" ] || [ "$GIT_DIR" = ".git" ]; then
    if echo "$COMMAND_FOR_MATCH" | grep -qE 'git\s+(checkout|switch)\s+(develop|main|master)(\s|$|&|;)'; then
      if ! echo "$COMMAND_FOR_MATCH" | grep -qE 'git\s+(checkout|switch)\s+(develop|main|master)\s+--'; then
        exit 0
      fi
    fi
    guard_respond "advisory" "コミット衛生ガード" "メインワークツリーでの git checkout/switch はブロックされています。\`git worktree add\` でワークツリーを作成してください。未コミットの作業が消失するリスクがあります。（develop/main への切り替えは許可されています）"
  fi
fi

# --- チェック 4: main ブランチへの直接マージ防止（hotfix/* 除く） ---
if echo "$COMMAND_FOR_MATCH" | grep -qE 'git\s+(-C\s+\S+\s+)?merge\s'; then
  if ! echo "$COMMAND_FOR_MATCH" | grep -qE 'git\s+(-C\s+\S+\s+)?merge\s.*hotfix/'; then
    GIT_C_PATH=$(echo "$COMMAND" | sed -nE 's/.*git[[:space:]]+-C[[:space:]]+"([^"]+)".*/\1/p')
    if [ -z "$GIT_C_PATH" ]; then
      GIT_C_PATH=$(echo "$COMMAND" | sed -nE "s/.*git[[:space:]]+-C[[:space:]]+'([^']+)'.*/\1/p")
    fi
    if [ -z "$GIT_C_PATH" ]; then
      GIT_C_PATH=$(echo "$COMMAND" | sed -nE 's/.*git[[:space:]]+-C[[:space:]]+([^ "'"'"']+).*/\1/p')
    fi

    if [ -n "$GIT_C_PATH" ]; then
      CURRENT_BRANCH=$(git -C "$GIT_C_PATH" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    else
      CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    fi

    if [ "$CURRENT_BRANCH" = "main" ] || [ "$CURRENT_BRANCH" = "master" ]; then
      guard_respond "advisory" "ブランチ戦略ガード" "main への直接マージはブロックされています。develop 経由でマージしてください。hotfix の場合は hotfix/* ブランチを使用してください。"
    fi
  fi
fi

# --- チェック 4b: gh pr merge で main 向け PR のマージ防止（hotfix/* 除く） ---
if echo "$COMMAND_FOR_MATCH" | grep -qE '(^|&&|\|\||[;|])\s*gh\s+pr\s+merge'; then
  PR_NUM=$(echo "$COMMAND" | grep -oE '(^|&&|\|\||[;|])\s*gh[[:space:]]+pr[[:space:]]+merge[[:space:]]+([0-9]+)' | grep -oE '[0-9]+' | head -1)

  if [ -n "$PR_NUM" ]; then
    PR_VIEW_ARGS="$PR_NUM"
  else
    PR_VIEW_ARGS=""
  fi

  PR_INFO=$(gh pr view $PR_VIEW_ARGS --json baseRefName,headRefName 2>/dev/null || echo "")
  if [ -n "$PR_INFO" ]; then
    BASE_BRANCH=$(echo "$PR_INFO" | jq -r '.baseRefName // empty')
    HEAD_BRANCH=$(echo "$PR_INFO" | jq -r '.headRefName // empty')

    if [ "$BASE_BRANCH" = "main" ] || [ "$BASE_BRANCH" = "master" ]; then
      if ! echo "$HEAD_BRANCH" | grep -qE '^hotfix/|^chore/promote-main-|^develop$'; then
        guard_respond "advisory" "ブランチ戦略ガード" "${HEAD_BRANCH} → ${BASE_BRANCH} への PR マージはブロックされています。develop を経由してマージしてください。hotfix の場合は hotfix/* ブランチを使用してください。"
      fi
    fi
  fi
fi

# --- チェック 5: develop ブランチの削除 ---
if echo "$COMMAND_FOR_MATCH" | grep -qE 'git\s+branch\s.*-[dD]\s(.*\s)?develop(\s|$)|git\s+push\s.*--delete\s(.*\s)?develop(\s|$)|git\s+push\s.*:develop(\s|$)'; then
  guard_respond "critical" "ブランチ戦略ガード" "develop ブランチの削除はブロックされています。develop は永続ブランチです。"
fi

# --- チェック 6: メインワークツリーでの git stash pop/apply ---
if echo "$COMMAND_FOR_MATCH" | grep -qE 'git\s+stash\s+(pop|apply)'; then
  GIT_COMMON_DIR=$(git rev-parse --git-common-dir 2>/dev/null || echo "")
  GIT_DIR=$(git rev-parse --git-dir 2>/dev/null || echo "")

  if [ "$GIT_DIR" = "$GIT_COMMON_DIR" ] || [ "$GIT_DIR" = ".git" ]; then
    guard_respond "advisory" "コミット衛生ガード" "メインワークツリーでの git stash pop/apply はブロックされています。ワークツリー内で作業してください。"
  fi
fi

exit 0
