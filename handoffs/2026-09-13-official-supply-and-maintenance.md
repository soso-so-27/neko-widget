# 公式まど：1週間分の素材と定期保守

2026-09-13。N08の続き。アプリ変更なし、TestFlightは1.0 (161)のまま。

## 結果

- 新しいAI猫画像3枚を生成・目視確認し、既存publisherで公開用JPEGにした。1週間分の予定を私的なqueueへ保存。今日まとめて掲載してはいない。
- 同じCodexタスクのheartbeat「ねこのまどの配信保守」を毎日09:00・21:00（JST）で登録。automation IDは`automation`、statusはACTIVE、targetはこのタスク。登録・設定の読取確認済み。最初の予定実行の成功はまだ未確認。
- 現在配信中のcatalogはどこかの猫4枚・おひるね2枚。2026-09-13T09:13:15.234Zの実HTTPSでcatalog一致、全6経路のJPEG hash一致、Worker version一致を確認。
- 今の素材を使った初回保守判定は2026-09-13T09:18:13Zに`no-change`。予定前の3枚を配信せず、候補bundleも作らないことを確認した。

## 写真の予定

| 掲載目安（JST） | 写真 | 届け先 |
|---|---|---|
| 9月15日 09:00 | 窓辺で眠る茶トラ | どこかの猫・おひるね |
| 9月17日 09:00 | 紙玉が気になる三毛猫 | どこかの猫 |
| 9月19日 09:00 | 椅子で眠る白黒猫 | どこかの猫・おひるね |

生成画像は「ねこのまど（AI生成）」のcreditを保持。実在の飼い主・投稿実績・撮影日を作らない。許可期限は9月27日09:00 JST、新規写真の掲載期間は実際の初回掲載から7日と許可期限の早い方。既存写真の期限延長はこのqueueで行わない。

予定到来順に1回最大1枚。同じ1枚を2つのまどへ載せることは可能。PC休止から戻っても複数の未掲載写真を一度に流さず、残りは次回へ引き継ぐ。更新頻度は内部運用の目安で、利用者に定時到着を約束するものではない。

## 実装と記録

- [保守手順](../OfficialWindowService/MAINTENANCE.md)：配備済み版との照合、pendingによる排他、固定Wranglerのdry-run、成功時だけ状態更新、中断からの処理。
- [キュー処理](../OfficialWindowService/tools/README-maintenance.md)：予定追加、期限更新、全まど保持、履歴・停止・取り下げの維持、未掲載残数。
- [原本とプロンプト](C:/dev/neko-official-supply-20260913/output/supply-week-20260913/originals/PROMPTS.md)、[私的queue](C:/dev/neko-official-supply-20260913/output/supply-week-20260913/queue.json)。これらの原本・内部記録は公開assetsに含めない。
- 実行状態：`C:/dev/neko-official-supply-20260913/output/runtime/current.json`。同階層に初回HTTP証拠と`runs/setup-20260913/plan.json`。stateは実測checkedAtを保存する。
- 初期の実配備bundle：`C:/dev/neko-public-window-ops-20260913/output/official-ops-20260913/edition-001/bundle`。Worker version `b64fcd09-88d4-4796-a38c-e48661692257`。

これらのローカルデータと固定checkoutは自動処理が参照するので維持する。Codexの履歴データを削除・移動・圧縮する作業は行っていない。

## 検証と限界

`npm test`は62件成功（保守の20件と実version選択の1件を含む、2.1秒）。`check-development-flow.py`も33.3秒で成功。配信中のHTTPS照合も上記のとおり成功。アプリ・Widgetコード・CI構成を変えていないため、新しいiOS CIやTestFlightは起動しない。JPEG metadata/寸法の取り違えと、排他取得前後の別配備の競合を独立レビューで指摘し、対処した。

この方式はPCが起動し、Codexアプリが動き、Cloudflare認証とローカルファイルが使えることが条件。[OpenAIの実行条件](https://learn.chatgpt.com/docs/automations?surface=app)。常駐サーバーcronの完成とは異なる。catalog失効時は記録したWorker版が一致する場合だけ期限保守し、写真の失効や取り下げを復活させない。

残数3枚未満になった時点で、次の1週間分の補充が必要と1回知らせる。同じ不足・変更なし・正常な期限保守は逐次報告しない。新写真配信、失敗、在庫ゼロなどの変化は知らせる。未掲載在庫の自動生成・ユーザー投稿受付・会員制度は開始していない。

**未確認**：初回の自動実行、9月15日からの実配信、利用者のWidgetへの反映時刻。設定の登録やHTTP成功で、これらを完了扱いにしない。
