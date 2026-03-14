---
name: ship-to-develop
description: release/* ブランチの実装・レビュー完了後、develop へのマージまでを一気通貫で実行する。PR 作成→Discord 通知→OpenClaw 承認ポーリング→マージの定型フローを封入。/ship-to-develop と呼ばれた時、または Stop フック (release-completion) に「PR が develop にマージされていません」とブロックされた時に使用する。
---

# Ship to Develop

release/* ブランチから develop への PR 作成・承認・マージを一気通貫で実行する。

**Announce at start:** "develop へのマージフローを開始します。"

## 前提条件

- 現在のブランチが `release/*` であること
- `pnpm check` が通過していること
- `/release-ready` と `/review-now` が実行済みであること（`review-enforcement` Stop フックで検証済み）

## 手順

### 1. 状態確認

```bash
BRANCH=$(git branch --show-current)
if [[ ! "$BRANCH" =~ ^release/ ]]; then
  echo "エラー: release/* ブランチではありません: $BRANCH"
  exit 1
fi
```

リモートにプッシュ済みか確認し、未プッシュならプッシュする:

```bash
git push -u origin "$BRANCH"
```

### 2. PR の作成（既存 PR がなければ）

```bash
EXISTING_PR=$(gh pr list --head "$BRANCH" --base develop --state open --json number -q '.[0].number' 2>/dev/null || echo "")
```

- 既存 PR があればそれを使用
- なければ `/create-pr` スキルで PR を作成（マージ先: `develop`）
- PR description にはレビュー結果 + レポート + 開発洞察を含める
- PR description には図解（Mermaid）を必ず含める（`.claude/reviewer-profile.md` 参照）

### 3. Discord で OpenClaw にレビュー依頼

Discord チャンネル（ID: `$DISCORD_CHANNEL_ID`）にレビュアーをメンションしてレビュー依頼を送信。

メッセージに含める内容:
- メンション: `$DISCORD_REVIEWER_MENTION`
- PR URL
- 変更の概要（1-2行）

### 4. OpenClaw の approve をポーリング

**60秒間隔**で approve を確認する:

```bash
gh pr view <PR番号> --json reviewDecision -q .reviewDecision
```

| 結果 | アクション |
|------|----------|
| `APPROVED` | ステップ 5 へ |
| `CHANGES_REQUESTED` | 指摘を確認し修正。修正後に再度ポーリング |
| 空文字/未レビュー | 60秒待って再確認（最大5回） |

5回（約5分）ポーリングしても approve されない場合、ユーザーにエスカレーション。

### 5. コンフリクト確認と解消

マージ前にコンフリクトの有無を確認する:

```bash
gh pr view <PR番号> --json mergeable -q .mergeable
```

| 結果 | アクション |
|------|----------|
| `MERGEABLE` | ステップ 6 へ |
| `CONFLICTING` | 以下のコンフリクト解消手順を実行 |
| `UNKNOWN` | 数秒待って再確認（GitHub の計算待ち） |

#### コンフリクト解消手順

1. **develop をフェッチして差分を確認**:
   ```bash
   git fetch origin develop
   git log --oneline HEAD..origin/develop  # develop 側の新規コミット
   ```

2. **リベースで解消**（推奨）:
   ```bash
   git rebase origin/develop
   ```
   コンフリクトしたファイルを手動で解消 → `git add` → `git rebase --continue`

3. **ロックファイルのコンフリクト**（最頻出）:
   ```bash
   # pnpm-lock.yaml のコンフリクトは再生成で解消
   git checkout --theirs pnpm-lock.yaml
   pnpm install
   git add pnpm-lock.yaml
   ```

4. **解消後にテスト再実行**:
   ```bash
   pnpm check
   ```

5. **force push して PR を更新**:
   ```bash
   git push --force-with-lease
   ```

6. コンフリクトが複雑で自力解消が困難な場合は、ユーザーにエスカレーション。

### 6. PR をマージ

```bash
gh pr merge <PR番号> --squash
```

**例外**: develop 同期など squash 不可の場合は `--merge` を使用。

### 7. 完了確認

```bash
gh pr view <PR番号> --json state -q .state
# "MERGED" であること
```

マージ完了を確認したら、親エージェントに結果を報告する（サブエージェントの場合）。
