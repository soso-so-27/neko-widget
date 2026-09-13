# 承認済み写真を予定で切り替える運用

既存の内部TestFlight向けpreviewの3まどだけを扱う。配信予定を最大14日分まとめてWorkerへ配備し、サーバー時刻で現在の版を選ぶ。PC・Codex・Wranglerのログインを日々の写真切替の条件にしない。新しい写真の生成、掲載判断、期限の延長は自動化しない。

## 何が変わるか

以前はCodexが定期的にcatalogを作って配備し直していた。予定方式では、今後の写真追加・掲載期限による削除・catalogの更新を先に生成して一度だけ配備する。公開URLとアプリのデータ形式は同じ。未来のcatalogやJPEG、予定表、私的な掲載履歴は公開URLから読めない。

各catalogは従来どおり最大48時間、追加写真は掲載から7日以内か承認期限まで。既存の写真の日付・期限を引き延ばさない。予定全体の終了後は503になり、古い版を自動で再公開しない。終了までに補充・次の予定の配備を行う必要がある。

写真は予定の切替時刻から配信可能になる。利用者のホーム画面で更新される時刻はWidgetKit次第で、通知や定時到着は約束しない。受信者が一人でも百人でも、同じまどは同じ現在版を返す。

## 次回の補充

実配備状態は固定checkoutの `output/runtime/current.json` を正本とする。`mode: scheduled` の場合、`currentBundle` は予定bundleであり、未来の最終版を基点にしてはならない。

1. `pending.json` があれば新しい更新を開始せず、その操作を照合して復旧する。
2. `verify_schedule.mjs` でWorker versionと現在時刻のcatalog/JPEGを照合する。失敗時は原因を確認してから次へ進む。
3. `restore_schedule.mjs` で**今、有効な版だけ**を新規フォルダーへ取り出す。未来の版の履歴は使わない。
4. 承認済みqueueの旧行を保持して新しい行を加える。日時、原本、出自、掲載判断、JPEG hash、各猫のIDを確認する。同時刻に複数の新写真を予定しない。期限を過ぎた予定を今へ集め直す場合も、担当者が日程を決める。
5. 復元した版から `prepare_schedule.mjs` で次の有限予定を作り、日付と窓別の写真数を確認する。queueと履歴はassetsへ入れない。
6. 変更対象のテストと固定Wranglerのdry-runを通す。pendingを排他的に作成し、直前のWorker version・current・queueが変わっていないことを再確認してから、既存previewへ一度配備する。
7. 配備後の現在版・旧JPEGの拒否・内部/未来URLの拒否を照合する。成功時だけcurrentを原子的に更新し、pendingを同じrunの完了記録へ移す。

```powershell
node tools/restore_schedule.mjs --bundle C:/review/deployed/bundle --output C:/review/current-edition
node tools/prepare_schedule.mjs --previous C:/review/current-edition --queue C:/private/approved-queue.json --output C:/review/next-schedule --through 2026-09-27T00:00:00Z
```

上の日付・パスは例。実際のpointer・新しい出力先・承認範囲を使う。既存の出力フォルダーを上書きしたり、予定の最終版を掲載実績として復元しない。

## 停止・取り下げ

現在版を復元し、既存 `prepare_update.mjs` の `paused:true` または `withdraw:[photoID]` を適用したうえで、**残りの予定全体**を再生成して配備する。未掲載の写真を取りやめる場合は承認済みqueueからその行を外す。過去のID/hashの履歴は削除しない。

当日分だけ直して未来の予定を残すと再登場するため、その操作はしない。旧予定bundleへのrollbackも復活を起こすため禁止。曖昧な配備失敗は同じ操作を繰り返さず、Worker versionを読んで照合する。

サーバーから取得できなくなることと、端末内の取得済みキャッシュの失効は別。オフライン端末や保存済み写真からの即時回収はできない。

予定を補充できないまま終了した場合は、自動復活させない。明示的な `--allow-expired` で記録した同一Worker versionと全まどの503を照合し、最後の版を過去の掲載履歴として復元する。履歴と承認済み新queueから新予定を作り、期限切れ写真は落とす。現在より先の版を指定する機能はなく、履歴を紛失した場合は復旧を進めない。

## 定期確認

既存の09:00・21:00 JST heartbeatは読取専用の監視へ変更する。新写真の生成・queue追加・再配備を行わず、現在のWorker/catalog/JPEG、窓別在庫、予定の終了時刻を確認する。終了まで72時間以内、公式の未掲載3枚未満、キジ白の未掲載2枚未満、実際の失敗だけを必要に応じて通知する。同じ不足を繰り返し通知しない。

問い合わせ・安全対応・共有サービスの停止は [運用窓口](../handoffs/2026-09-13-operating-desk.md)にまとめる。定期監視の正常結果を実機Widgetや写真送受信の確認済みとは扱わない。

## 設計根拠

Cloudflareの[Workerを先に実行するルーティング](https://developers.cloudflare.com/workers/static-assets/routing/worker-script/)と[Static Assets binding](https://developers.cloudflare.com/workers/static-assets/binding/)を利用する。`run_worker_first:true` を維持し、Worker内部だけで現在版のassetを読み出す。追加の保存サービスや常駐PCを必要としない、現在の少数まどに合わせた構成。
