# agents-harnesses 開発方針

このリポジトリは **public** な汎用 agent harness。再利用可能な skill / hook / agent / loop を集約する場所として位置付ける。

## Scope

### 持ち込んでよいもの

- 汎用的に再利用可能な skill / hook / agent / loop
- 一般的なガードレール (commit-guard, secret-guard, gh-guard 等)
- ツールチェーン依存だが、特定 project に依存しない仕組み

### 持ち込んではいけないもの

- 特定 project 名を含むファイル (個別プロジェクトの prefix を持つ hook / skill 名)
- hardcode された個人 path (例: `/Users/<user>/Documents/<project>/` の直書き)
- 個人名・組織名・メンテナ名を grep / pattern として直書き
- 特定の private project や個人事情に依存したロジック

## 理由

- **public repository であるため**、commit 内容は世界に晒される
- 特定 project の運用情報 (fork 位置 / upstream 名 / 進行中の活動 / 関わるメンテナ名) が public に出ると、当該 project の戦略や個人活動が露見する
- このリポジトリの意義は「**他のプロジェクトでも使える共通基盤**」。project-specific を混入させると意義が薄れる

## Project-specific な仕組みの置き場

該当 project の repository 内に閉じる:
- project-specific hook → `<project>/.claude/hooks/`
- project-specific skill → `<project>/.claude/skills/`
- project-specific guardrail → 個別 project 配下

## 関連 skill

`/review-now` には OSS upstream contribution 投下前の meta-content 検出観点を組み込んでいる (`claude-code/skills/review/review-now.md`)。具体的な検出パターン辞書は public 側に置かず、利用者の運用 memory 等に閉じ込める方針。
