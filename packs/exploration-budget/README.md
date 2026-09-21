# Exploration Budget Pack

探索型のセッションに、ゴールの代わりに「時間予算」と「方針」を渡すための小さなパックです。
台帳・境界フック・runner の 3 つでできています。

## なぜ

- **ゴールには終端状態がある。** エージェントはゴールに達した（と判断した）瞬間に止まります。「候補は 10 件まで」のような数値の上限も終端状態になり、2 時間の予算を 25 分で切り上げる形で予算を切り詰めます。
- **方針には終端状態がない。** 「まだ特徴づけていない近傍を増やす」のような方針を渡すと、残る停止条件は予算だけになります。
- **エージェントは時間を知覚できない。** 予算は境界でだけ見せます。毎ツール呼び出しに残り時間を付けると、急かされた浅い作業になります。
- **早期停止はエージェントの自己判断で決めない。** 予算の満了と、直近の一区切りで新規が続けて 0 だったこと（収率の低下）だけを外側で測って止めます。台帳が空のときは「新規 0」を収率ゼロと見なしません。未計測を停止の理由にすると、「終わった感」による早期停止が測定の顔をして戻ってくるためです。

## 何をするか

| 部品 | 役割 |
|---|---|
| 台帳（SQLite） | 触れた対象、新規かどうか、成果物、一区切り（checkpoint）、探索の根、人の判定を記録する。プロジェクトのディレクトリごとに 1 つで、session をまたいで既出判定を持つ |
| Stop hook | エージェントが停止しようとするたびに、予算が残っていれば「残り時間・直近の収率・方針・記録の仕方」を返して続けさせる。予算が尽きたか、直近 K 回の checkpoint で新規が 0 なら通す |
| PostToolUse hook | 経過 50% と 80% を通過したときだけ、一度ずつ告げる（秒読み） |
| runner | `claude -p` を round で回す。Claude Code は Stop hook の連続 block を既定 8 回で打ち切るため、`--resume` で同じ会話を再開し、時計は外側の runner が持つ |

他の 3 つは全部、台帳を読みます。何を「対象」として数えるか（人物 ID、ファイル、仮説…）はプロジェクト側で決めてください。パックは意味を持ちません。

## 必要なもの

- Python 3.9 以降
- Claude Code（runner と hook を使う場合）

## 5 分で試す

```bash
git clone https://github.com/shuhei0866/agents-harnesses.git
cd agents-harnesses
PACK="$PWD/packs/exploration-budget"

# 1. hooks を配線する（examples/settings.hooks.json を参考に ~/.claude/settings.json へ）
# 2. 方針を書く（人が書く。エージェントに生成させない）
cp "$PACK/examples/policy.example.md" ./policy.md

# 3. 対象のプロジェクトで、計画だけ確認する
cd path/to/project
"$PACK/bin/exploration-budget" run --budget 60m --policy-file ../policy.md --dry-run

# 4. 実行する。無人で回すなら --skip-permissions を検討する（作業ディレクトリと許可の範囲を先に確認）
"$PACK/bin/exploration-budget" run --budget 60m --policy-file ../policy.md

# 5. 朝に読む
"$PACK/bin/exploration-budget" report
"$PACK/bin/exploration-budget" verdict known <id> <id> ...
```

有人の対話セッションで使う場合は、そのセッションの cwd で `start --budget 60m --policy-file policy.md` を実行してから作業します。Stop hook が境界で予算と方針を返します。連続 block の上限を上げたいときは、Claude Code の起動前に `CLAUDE_CODE_STOP_HOOK_BLOCK_CAP` を設定してください。

## 配線（~/.claude/settings.json）

```json
"Stop":        { "command": ".../packs/exploration-budget/bin/exploration-budget hook stop" },
"PostToolUse": { "matcher": "Bash|Write|Edit",
                 "command": ".../packs/exploration-budget/bin/exploration-budget hook post-tool" }
```

完全な形は [examples/settings.hooks.json](examples/settings.hooks.json) にあります。active な session が無いディレクトリでは、どちらの hook も何も出力しません。

## エージェントが使う記録コマンド

hook と runner が返す文面に、そのまま書いてあります。

| コマンド | 意味 |
|---|---|
| `touch <id> [--kind k] [--root r]` | 触れた対象を記録する。`novel` か `seen` を返す |
| `checkpoint --note "<何を終えたか>"` | 一区切り。収率はこの区切りごとに数える |
| `artifact <path> [--kind k]` | 成果物を記録する |
| `root <軸> <値> --brief "<一行>"` | 探索の根を変えたことを記録する |
| `status` / `delta` | 経過・残り・直近の収率 |
| `end --reason "<理由>"` | 進めなくする真の blocker があるときだけ。理由と時点は報告に載る |

## 停止条件

| ended_by | 誰が | 条件 |
|---|---|---|
| `budget` | hook / runner | 予算を使い切った |
| `yield` | hook / runner | 直近 `--yield-window` 回（既定 3）の checkpoint で新規が全部 0。触れた対象が 1 件も無いときは発火しない |
| `cap` | hook | Stop hook の block が `--max-blocks`（既定 200）に達した |
| `agent` | エージェント | `end --reason` を実行した。報告に「N% の時点で終了した: 理由」と出る |
| `rounds` / `error` | runner | round 上限、または claude の起動・実行が連続で失敗した |

## データの置き場

`${XDG_DATA_HOME:-~/.local/share}/agents-harnesses/exploration-budget/` の下に置きます。`EXPLORATION_BUDGET_HOME` で変えられます。

```
active/<slug>.json                      # active な session のマーカー（hook はここから cwd を引く）
projects/<slug>/ledger.sqlite           # 台帳
projects/<slug>/runs/<session>/round-N.prompt.md / .out.json / .err.log
```

Git には置きません。`<slug>` はプロジェクトの絶対パスから作るので、worktree は別の台帳になります。既出判定を本体と共有したいときは `--project-dir` で本体のディレクトリを指してください。hook は cwd がその配下にあれば一致します。

## 環境変数

| 変数 | 意味 |
|---|---|
| `EXPLORATION_BUDGET_HOME` | データの置き場 |
| `EXPLORATION_BUDGET_DISABLE=1` | 両 hook を無効化する（子プロセスの claude に渡す kill switch） |
| `EXPLORATION_BUDGET_CLAUDE_CMD` | runner が起動する claude コマンド |
| `EXPLORATION_BUDGET_NOW` | 現在時刻の上書き（テスト用、epoch 秒） |
| `CLAUDE_CODE_STOP_HOOK_BLOCK_CAP` | Claude Code 側の連続 block 上限。runner は子に `--block-cap`（既定 100）を渡す |

## 実測（Claude Code 2.1.278）

- Stop hook が block を返し続けると、`claude -p` は 9 回目の hook 呼び出しのあと会話を終える（公式ドキュメントは「8 回連続で override する」）。終了は `subtype: success`、`result` は空で、エラーにはならない。
- `claude -p --resume <session_id>` で再開すると、同じ会話のまま再び block が効く。
- `CLAUDE_CODE_STOP_HOOK_BLOCK_CAP=25` で 26 回まで効いた。
- hook の stdin には `cwd`、`session_id`、`stop_hook_active`、`last_assistant_message` が入る。この pack は `cwd` と `session_id` だけを使う。

## 設計上の注意

- この Stop hook は `stop_hook_active` を見ても素通ししません。他の Stop hook（レビュー検証など）は無限ループ防止のために素通ししますが、この hook は予算が尽きるまで繰り返し止めるのが仕事です。上限は「予算の満了」「収率の低下」「max_blocks」の 3 つで、いずれも台帳で測ります。
- hook は fail-open です。台帳が読めない、stdin が JSON でない、などの場合は何も出さずに会話を通します。
- 方針は人が書きます。エージェントに新しい方針文を生成させると、分布の最頻値に落ちます。
- 返す文面は事実（残り時間、直近の収率）と方針と記録の仕方だけで、急がせる言葉は入れていません。

## 今後

どちらも台帳を読む形で、この pack に足す予定です。

- **層化抽出器**: 軸は人が書き、値は外部データから引いて、収率が落ちたときに新しい根を渡す。到達の失敗（近傍が尽きた）は、エージェントの発想ではなく外から引いた根でしか直らないため。
- **評価者**: 別プロンプトで、直近の checkpoint が方針の量を増やしたかを照らし、却下理由だけ返す。枠の失敗（方針からの漂流）はこちらで直す。

## テスト

```bash
bash packs/exploration-budget/tests/test-exploration-budget.sh
```
