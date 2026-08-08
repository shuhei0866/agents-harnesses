# Git Safety Pack

Claude Code の Bash 実行前に、Git 運用で起きやすい事故を検出する小さな導入パックです。
既存の `settings.json` を保ったまま、次の4ガードだけを配線します。

- 保護ブランチへの直接 commit、`--no-verify`、force push
- 危険な `gh pr approve/merge` と GitHub API の直接呼び出し
- merge 済み PR branch への追加 push
- `.worktrees/` 配下への再帰 `rm`

## 必要なもの

- Python 3
- Git
- `jq`（必須。ない場合、既存ガードは fail-open になります）
- GitHub CLI `gh`（推奨。ない場合、merge 済み PR の判定は fail-open になります）

## 5分で試す

```bash
git clone https://github.com/shuhei0866/agents-harnesses.git
cd agents-harnesses

# 変更予定だけ確認
./packs/git-safety/bin/git-safety install --mode advisory --dry-run

# 導入して診断
./packs/git-safety/bin/git-safety install --mode advisory
./packs/git-safety/bin/git-safety doctor
```

導入先はデフォルトで `~/.claude/settings.json` と
`${XDG_DATA_HOME:-~/.local/share}/agents-harnesses/git-safety-pack` です。
既存の settings を変更する場合は、同じディレクトリにタイムスタンプ付きバックアップを作ります。

## モード

| mode | 通常リスク | 重大操作 |
|------|------------|----------|
| `advisory` | 警告をコンテキストへ追加して許可 | 遮断 |
| `enforce` | 遮断 | 遮断 |

重大操作には `--no-verify`、main/master への force push、merge 済み PR branch への
push、`.worktrees/` の再帰削除などが含まれます。`advisory` は完全な observe-only ではありません。

モードは再実行で変更できます。hook は重複しません。

```bash
./packs/git-safety/bin/git-safety install --mode enforce
```

## 診断と削除

```bash
./packs/git-safety/bin/git-safety doctor
./packs/git-safety/bin/git-safety uninstall --dry-run
./packs/git-safety/bin/git-safety uninstall
```

`uninstall` は所有者マーカーに記録した hook と runtime だけを除去します。
所有者不明のディレクトリや、同じ runtime を参照する手動 hook がある場合は安全のため停止します。

テストや別プロファイルでは `--settings PATH` と `--data-dir PATH` で導入先を上書きできます。

## 現在の範囲

このMVPの自動配線先は Claude Code の `settings.json` です。ガード本体は
`claude-code/hooks/guardrails/` の既存実装をコピーするため、導入元の clone を移動・削除しても動作します。
