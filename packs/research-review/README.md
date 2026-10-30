# Research Review Pack

XやWebの調査をGrok Botなどへ渡し、返却された本文・付録・証拠台帳を
同じ版でレビューするための小さなパックです。

- **スキル**: [SKILL.md](SKILL.md)。Claude Code / Codexなど、ファイルを読めるエージェントが使う共通の手順。
- **契約とlint**: 1つの`bundle.json`が原資料、主張、本文・付録、レビュー記録を結ぶ。
- **Grokアダプター**: 既に許可されたWebhookへ1回だけ送信。UI経由の場合の手順も含む。
- **Macの日常利用**: [任意のローカルruntime](references/runtime.md)。専用routineと
  非公開のDrive出力先を最初に許可し、鍵をKeychainへ保存すると、通常の依頼ごとの鍵入力と
  画面からのファイル回収を省ける。設定と実接続テストが済むまでは利用可能とみなさない。

## 最小の流れ

Python 3.9以降の標準ライブラリだけを使います。

```bash
PACK="$PWD/packs/research-review"
RUN_DIR="$(mktemp -d)/public-research"
python3 "$PACK/scripts/research_review.py" init "$RUN_DIR" \
  --question '公開投稿で新機能の具体的な利用例と制約を調べる' \
  --recipient 'Research coordinator' --max-chars 1200
python3 "$PACK/scripts/research_review.py" brief "$RUN_DIR/bundle.json" > "$RUN_DIR/request.txt"
```

`bundle.json`の期間、タイムゾーン、許可範囲などを編集してから`brief`を作り直し、
依頼文と[契約](references/contract.md)を調査担当へ渡します。設定済みのGrok Webhookなら:

```bash
# URLとキーは既存の秘密管理からプロセス環境へ渡す。コマンドに値を書かない。
python3 "$PACK/scripts/grok_webhook.py" "$RUN_DIR/bundle.json"
```

`GROK_BOT_WEBHOOK_URL`と`GROK_BOT_WEBHOOK_KEY`、別途照合した接続先originを
`GROK_BOT_WEBHOOK_ORIGIN`として渡します。本文・秘密値・
応答本文は標準出力へ出しません。送信前の範囲確認、受付不明時の扱い、手動経路は
[Grokアダプター](references/grok-bot.md)を参照してください。
**受付は完了ではありません。** チャットで成果物を確認してダウンロードします。
設定済みのローカルruntimeでは、専用Driveフォルダの実ファイルを回収します。

資格情報は`--credentials-stdin`でも受け取れます。許可済みの秘密管理または本人の
非表示入力から`endpoint`と`key`だけを持つJSONを直接渡し、originは別に照合します。
秘密値をチャット・引数・一時ファイルへ貼らないでください。送信する実行環境で先に
公開originへの疎通を確かめ、通信制限された別のruntimeを迂回する中継は作りません。

受付不明のあとに本人が再試行を判断した場合は、同じtask・payload・元markerに結びつく
非秘密の確認記録を用意し、`--reconciled-retry PATH`で1回だけ明示的に試せます。
元markerは保持し、再試行用markerを送信前に予約します。確認記録だけで許可が生まれる
ものではなく、自動再送や送達保証にもなりません。詳しい条件は上のアダプター文書にあります。

```bash
# 以下は調査担当が返したbundle.jsonと実ファイルに対して実行する
python3 "$PACK/scripts/research_review.py" target "$RUN_DIR/bundle.json"
# レビュー担当が実物を読んで、返されたdigestに結びつくreviewを記入
python3 "$PACK/scripts/research_review.py" lint "$RUN_DIR/bundle.json"
```

`lint`のexit 0は**宣言された構造が整合する**という意味だけです。exit 1は未照合・
修正要求・版ずれ、exit 2は壊れた入力です。確認不能でも、claimを`unknown`とし、
使用する全artifactの`unknown_claim_ids`に記録し、レビューがその扱いを確認したものは
構造上の提出条件を満たせます。実際の文章にも留保があるか、人またはエージェントが確認します。

## 保証しないこと

原文の真偽、本文での引用の網羅、実質的な独立レビュー、送信の成否や重複排除、
Grokの継続稼働はlintでは分かりません。JSONの役名だけでは独立性も証明できません。
Webhookの応答を失ったときは**自動再送しません**。同じrunフォルダでの二重実行は
送信前のattempt markerで拒否しますが、別端末・別フォルダの重複までは防げません。
task IDは結果を対応づけるためのもので、
サーバーの冪等性キーではありません。

Bot・routine・権限・課金・接続先を新設・変更するinstallerは含みません。
実行記録を収集する常駐プロセスや新しい中央台帳も作りません。利用者が選んだrunフォルダ内の
送信試行markerと、
返却されたbundleを使います。研究原本や実案件のデータをこのpublic repoへ保存しないでください。

## 導入と検証

任意のスキルローダーでこのフォルダを参照するか、既存のスキル配置手順でフォルダごと
導入してください。Grokの非公開スキルへの反映は手動で行い、正本のバージョンを残します。
これは自動インポート機能の存在を主張するものではありません。

```bash
python3 -m unittest discover -s packs/research-review/tests -v
```

テストは架空の原資料・成果物とHTTPモックを使うローカル契約検証です。
Grokの実行、X検索の品質、実アカウントのWebhook E2Eや費用は検証していません。
