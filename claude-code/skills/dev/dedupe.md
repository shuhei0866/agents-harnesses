---
name: dedupe
allowed-tools: Bash(gh issue view:*), Bash(gh search:*), Bash(gh issue list:*), Bash(./scripts/comment-on-duplicates.sh:*)
description: Find similar GitHub issues
---

指定された GitHub Issue の重複候補を最大 3 件まで見つけてコメントします。

必ず次の手順で実行してください:

1. まず TODO を作る。
2. 対象 Issue が closed、または重複判定に不向きな内容（広い要望・ポジティブフィードバックのみ等）、または既に同種コメントがある場合は何もしない。
3. 対象 Issue を要約する。
4. 5 本の並列エージェントで、異なる検索語・検索戦略を使って重複候補を探索する。
5. 最後に統合エージェントで候補を精査し、偽陽性を除外する。候補がなければ何もしない。
6. 候補が 1 件以上あれば、次のスクリプトでコメントする:
   ```bash
   ./scripts/comment-on-duplicates.sh --base-issue <issue-number> --potential-duplicates <dup1> <dup2> <dup3>
   ```

注意:

- GitHub 操作は `gh` のみを使用する。
- 上記以外のツールは使わない（ファイル編集、別 MCP、外部 API 直叩きなどは禁止）。
- 候補は「本当に同じ不具合/要望か」を重視し、タイトル一致だけで判断しない。
