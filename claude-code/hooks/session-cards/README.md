# session-cards — セッションカード（常時蒸留）

Claude Code の全対話セッションについて、「現在地 / 次の一手 / ブロッカー」を
蒸留したカードを `~/.claude/session-cards/<project-slug>/<session-id>.md` に
自動維持する hook 群。

## なぜ

セッションには「終わりの瞬間」が無い（閉じるのは放置の結果として起きる）ため、
SessionEnd や手動の儀式（/summarize 等）に捕捉を頼ると必ず取りこぼす。
そこで毎ターンの Stop hook で常時カードを最新化し、
**どのセッションをいつ放置・クローズしてもカードが残る**状態を保証する。
カードは resume 索引を兼ねる（frontmatter の `resume:` をそのまま実行すれば蘇生できる）。

人間の規律をロードベアリングにしない・pull 型で見る、という設計原則の全体像は
my-skynet-hub の `docs/workspace/decisions.md` (D-001) にある。
カードの消費者は my-skynet-hub の `scripts/open_loops.py` と `scripts/briefing.py`。

## 構成

| ファイル | 役割 |
|---|---|
| `card-stop-hook.sh` | Stop hook の入口 wrapper。~0.5s で復帰し、蒸留は detach。5 分デバウンス（sidecar stamp）、多重起動ロック、対話セッション判定 |
| `distill.sh` | 蒸留本体。transcript 末尾を haiku で要約し、カードを temp+mv で原子的に書く |
| `card-flag.sh` | `waiting_on_input` フラグの同期反転（LLM なし）。permission prompt で待ちに入った/解けたを刻む |

## 配線（~/.claude/settings.json）

```json
"Stop":             { "command": ".../session-cards/card-stop-hook.sh" }
"Notification":     { "matcher": "permission_prompt",
                      "command": ".../session-cards/card-flag.sh waiting" }
"UserPromptSubmit": { "command": ".../session-cards/card-flag.sh active" }
```

## 安全設計

- **再帰遮断 3 層**: ①子 claude には `CLAUDE_SESSION_CARDS_DISABLE=1` を渡し wrapper が最初に見る ②子は `--settings '{"disableAllHooks":true}'` で全 hook 無効 ③ライブレジストリ（`~/.claude/sessions/*.json`）で `kind=interactive` かつ `entrypoint=cli` のセッションだけをカード化する。`claude -p` の一発物は `entrypoint=sdk-cli` で登録されるため弾かれる（2.1.207 実測）
- **injection 耐性**: 子は `--tools "" --strict-mcp-config` でツール・MCP を持たず、LLM 出力は常にデータとして扱い、ファイル書き込みはスクリプト側だけが行う
- **非ブロッキング**: 蒸留は `nohup … &` で stdio を閉じて切り離し、hook の 60s timeout やユーザーの次ターンに掛けない

## 環境変数

| 変数 | 既定 | 意味 |
|---|---|---|
| `CLAUDE_SESSION_CARDS_ROOT` | `~/.claude/session-cards` | カードの置き場所 |
| `CLAUDE_SESSION_CARDS_DEBOUNCE` | `300` | 蒸留の最短間隔（秒） |
| `CLAUDE_SESSION_CARDS_DISABLE` | `0` | `1` で全スクリプトが即終了（再帰ガード兼 kill switch） |
| `CLAUDE_BIN` | PATH の `claude` | 蒸留に使う claude バイナリ |
