# 本人限定テストの端末準備と検証範囲

- 基準 main: `b8b35379e57645d51c18a5f434d4a63d38aeb115`。
- 対象製品候補: `0833fd957bebed42359e608f34c9c40d313b516c`。本人の241では既存pendingがなく、読取画面から進めないと実機報告あり。
- 変更: 明示操作で既存StoreKit権利の全走査後に端末内のpendingだけを準備する。既存情報、異なるinstall、登録済み、読取失敗は上書きしない。購入、サーバー登録、送信、Plus権利付与は開始しない。
- 元の読取操作は書込みなし。新規導線はsandboxReceipt・media-staging・固定保管先の内部版限定。製品候補は独立sourceレビュー済み。保管済みの写真・メモには変更なし。

## CI制御のみの候補

既存 `app-private-data-ui-v1` へ今回の5ファイルの完全before/afterだけを登録。3つのbilling製品ファイルのいずれかが変わる場合、5ファイル全部と正規化digestの一致を要求する。以後の未知の購入/復元/鍵/画面変更には流用しない。

XcodeのWidget Sourcesの実fileRef/path検査も維持する。共有モデル・Widget・project・workflow差分を含めない。Build内のprivacy・migration、Photos、両OS runtime、全アプリUI shardを維持し、入力不変のWidget Gallery3系統だけを除外。変更・削除・skipで合格基準を下げない。製品候補とは別commitで制御だけを先に確認する。

レビューで最初のdigest生成が既存 `source_digest` と改行末尾の扱いが違うことを検出。既存関数で再生成し、実際の製品Git blob全差分で `app-private-data-ui-v1` の選択をローカルで確認した。模擬テストだけを根拠にしない。

## 実行計画・未確認

- 調査開始証拠: 2026-10-07 14:09:41 UTC。端末報告後に最初の製品候補を作成し、今回の累計に含める。
- 廉価な直接証拠: 実機のpending不在報告、実ソースの保存経路、実candidate選択、独立sourceレビュー。26件のbilling/購入/内部診断source契約テスト成功。
- 次は既存 `testMembershipOfferPreviewReturnsToPurpose` に追加した端末準備の操作をfocused診断する。元の購入案内assertionも維持。StoreKit scanの実権利確認は本人実機が必要で、DEBUG fixtureで確認済みとは扱わない。
- 診断経路の直近4実績: 約13〜18分。配布必須経路はpreflightの実測資料から別途計画する。制御CI成功をiOS成功や配布完了とは扱わない。
- 本番課金、受付期限更新、一般公開、配布対象拡大はこの変更に含めない。

## 配布CIの実測を踏まえた限定経路

初期制御PR174は38秒のUbuntu検証後にmain反映。製品の広いCIは起動していない。直近の全件run37602574693のapp-ui-otherは64.8分。製品差分の通常StoreKit走査本体・既存Keychain操作・保管・共有・起動が不変と独立レビューで再確認し、今回だけの `billing-local-preparation-v1` に限定する。

完全5ファイルhashとWidget対象証明は変えず、既存の会員3操作（戻る/端末準備、確認待ち/復元、期限説明）を全部残す。Build内のprivacy/migration/既存billing検証、Photos bootstrap、両OS runtimeを維持。無関係な全画面UIとGalleryは起動しない。未知変更はfull。計測だけのCIは増やさず、必要な製品検証で初回時間を記録する。
