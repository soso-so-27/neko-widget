# 保管：管理ログインが不要な残件の仕上げ

2026-10-02。既確認の実写真の保管・同じApple本人での復元・ZIPは保持する。今回は運用CLIと導入準備だけで、アプリ画面・Worker製品コード・実設定・期限・一般受付・課金は変更しない。最新内部236のAppleアップロード成功を、購入試験完了とは扱わない。

## 購入設定を扱う経路

旧 `billing-staging-runtime-gate.mjs` はfull family source/report ONと `/health` が前提だった。現用のfrozen familyへこの設定を当てると範囲が合わない。

新しい `NekoWidget/SharingService/scripts/billing-private-gateway-runtime-gate.mjs` は、固定の非公開Sandbox Gateway設定を検証し、購入DBだけを扱う。通常callerの確認先は `/v1/billing/health`。

- `--plan` は設定とmanifestを検証するだけ。DBコマンド・ネットワークなし。
- `--status` はSELECTとcaller healthを照合。世代と8操作の全状態がmanifestと一致しなければ停止する。
- `--confirm-<状態名>` は同じfresh照合を先に行い、世代と全状態が一致する場合だけ1回のCAS更新をする。更新後もcaller healthを照合。結果が不明なら変更済みの可能性を伝え、自動再試行しない。
- 旧CLIの既定経路は維持する。新CLIはfamily/Gatewayのdeploy、上位flagの変更、一般受付、購入開始を行うツールではない。

設定名は `wrangler.billing-private-gateway-staging-on.jsonc`、manifestは既存 `billing-staging-runtime-gate-manifest.json`。作業cwdは `NekoWidget/SharingService`。候補のJSONは `C:/dev/neko-evidence/preservation-offline-20261002/private-gateway-on-candidate.json` と `step-1-bootstrap-only.json`～`step-7-recovery-on.json`。状態名を間違えたconfirm、未知設定、別account/DB、Production、公開URL、History ONは拒否する。

**実操作前は、稼働中Gatewayの設定・version・Artifactをfreshに読む。** 下位gateがOFFだとhealthで上位flagの不一致を見分けられない場合がある。ローカルの候補設定とhealthだけで上位設定を確認済みと扱わない。今日の管理読取は7403で失敗しており、gen0の7段階候補は適用していない。状態が違えば候補を組み直す。上位flagを変更する工程では購入下位gate OFFと非公開Sandboxを保ち、frozen familyを再build/再配備しない。

製品の13テストは成功し、独立レビューで明確な問題なし。fresh SELECTとhealth、1回CAS、失敗後の非再試行、旧経路維持を確認した。実DBへ書いた結果の検証ではない。

## 圧縮を導入する準備

圧縮codecと新旧readerは既にmainにあるため再実装しない。現sourceの2ファイル・17件をローカルWorkerdで実行し、旧形式と圧縮形式、所有者拘束、破損・展開上限を確認。4.84秒、失敗・skip0。D1/S3/鍵は合成fixtureで、実クラウドの復元試験ではない。

`compression-rollout-plan.json` に、10月1日の保存済み設定、現在のsource hashes、変更する1変数、実導入の前提、復旧手順を用意した。候補変数は `OWNER_RECOVERY_COMPRESSION_ENABLED: NO → YES` だけ。容量・受付・本人削除・鍵binding・期限を維持し、新しい復旧一覧の世代だけを圧縮する。旧世代の書換え・削除・backfillはしない。

実導入時は、全readerが新旧形式を読めることを配備Artifactで確定し、書込みOFFで先に揃える。その後最新設定から1変数だけの候補を組み直す。これはWorker全体のflagであり、owner別の限定flagはない。管理されたpilot時間帯に合成ownerで実S3の旧形式/圧縮形式の読戻し・別owner拒否・版本hashを確認してから利用範囲を広げる。戻す場合は圧縮書込みだけNOへ戻し、両形式readerは維持する。旧readerを再配備しない。

この準備JSONはレビュー資料で、Cloudflareへそのまま送る設定payloadではない。保存済み10月1日のversionを現稼働versionと扱わない。実flagは今回変更していない。

## 容量と会員案内の条件

`capacity-display-contract.json` に各状態の表示とデータ源を確定した。現在の内部試験は1GiB/200件。一般向け5GB（十進）/1,000件・最初3人は未承認の候補で、現在のプランや設定へ混ぜない。試験・会員終了後の保管中ownerも人数・物理版本量・費用に含める。

価格・7日体験の対象可否は実StoreKit、使用量とbyte上限は同一本人のusage API、会員状態と新しい保管の可否はサーバーの確認結果、持ち出し期限はretention応答から表示する。通信失敗を空の保管先と扱わない。会員終了や上限到達後も、保存済みコピーの閲覧・メモ編集・削除・持ち出しは維持する。ただし編集の追加byteは実容量の範囲内。

一般容量を案内する購入候補へまとめる必要のある点が2つある。

1. usage APIは現在、保存/準備中件数と追加停止を返すが、実際の件数上限を返していない。販売で1,000件を約束する前に `maximumRecords` を応答へ追加し、画面で件数と上限を表示する。
2. 現在の画面はbinary単位。十進5GBを設定すると約4.66の表示になるため、販売案内とusage表示の単位を揃える。保存済みbyte会計は変更しない。

この2つを実装・描画済みとは扱わない。容量・実費・購入受付が確定した一般向け購入候補へ含める。今日、試験画面の文言だけのTestFlightは作らない。保管枠がない状態で保管特典を約束する購入案内は出さない。12か月保管・送達後30日の猶予は維持し、期限通知/消去の自動運用は利用者が決めた後続扱いのまま。

## 次に必要な操作

管理ログインができる日に、Apple契約と実商品、Gateway設定/version・D1 gate、費用・空き受入枠を1回まとめてfresh確認する。以後、購入の内部Sandbox設定と実購入/復元/期限切れをまとめた1候補を作る。実際の保管・復元・ZIPを利用者にもう一度繰り返させない。

今回のCIは運用CLI専用のUbuntu plan内Node境界確認だけ。選択器の導入は製品とは別のCI候補で検証し、未知/混在/mode変更は対象外にする。native/Widget画面・アップロード証拠には使えない。個々の操作と所要時間は `operator-pre-ci-review.json` とCI結果に残す。保管全体の初回候補10月1日18:29:38 JSTからの経過を新branchでリセットしない。
