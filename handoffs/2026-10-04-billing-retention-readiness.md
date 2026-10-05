# 購入・保管の運用準備

現在の公開方針（`docs/privacy/index.html`）と期限台帳は、会員有効期間終了後12暦月、最終通知の配達後最低30日の猶予で一致する。通知・期限削除の一般運用は準備中であり、今回も本番通知・永久削除・クラウド設定変更を行わない。`retention-ledger.ts` の `yearInMonths = 12` / `nextYear`、`thirtyDays` がこの12暦月/30日と対応する。unknownは失効と扱わず時計を停止し、再契約で期限・旧通知を解除する。

購入検証には段階を分ける。既存の `billing-authority.test.ts` はApple Sandbox状態1/4/2/3/5と、古い証拠・閉じたゲートを検証する。追加の `membership-links.test.ts` は同一ownerについて有効会員→期限前の解約（activeのまま）→失効→請求不明→同じ本人で再ログイン・再契約の遷移を通し、新規保管と既存記録の閲覧を区別する。これは合成authorityによる検証で、StoreKit購入やApple復元の実施証拠ではない。

実機Sandboxの残る段階は、既存Apple有料契約・Sandbox商品の取得、private Gatewayの現在の設定/versionとD1ゲートの読み取り確認、既存TestFlight購入設定の照合、Sandbox本人による購入・購入シート取消・自動更新取消・購入復元・加速失効・保管可否の実施である。取消直後に期限が残る場合はactive、期限後は新規追加不可で既存記録は読めることを確認する。実課金・新契約・認証設定変更を必要とする操作は含めない。既存の構成・署名を使い、別のpublic gatewayや新規認証を作らない。

## ローカル運用証拠の集約

`node scripts/operating-readiness.mjs <aggregate-evidence.json>`（cwd `NekoWidget/PreservationService`）はローカルJSONだけを読む。remote照会・通知・削除・設定変更は行わない。失効後保管中のownerも参加枠に数え、復旧の履歴版を含む容量・操作/CPU/KMS/通知込み費用・Sandbox実機検証・配置済み容量との一致を要求する。24時間を越えた証拠、未来時刻、不明値、不足項目は停止理由として返しexit 1。結果がreadyでも既存のremote gateを開ける許可、通知許可、削除許可ではない。

入力は本人ID・メール・署名・鍵・tokenを含まない集計だけにする。

```json
{
  "version": 1,
  "observedAt": 0,
  "capacityMatchesDeployedConfiguration": false,
  "usage": { "activeOwners": 0, "retainedOwners": 0, "primaryBytes": 0,
    "recoveryBytesIncludingVersions": 0 },
  "cost": { "confirmedAt": 0, "forecastMonthlyYen": 0,
    "includesRetainedOwnersAndHistoricalVersions": false,
    "includesOperationsComputeKmsAndNotices": false },
  "sandbox": { "confirmedAt": 0, "purchase": false, "purchaseSheetCancel": false, "cancelBeforeExpiry": false,
    "restore": false, "expiry": false, "preservationAccess": false }
}
```

この例は未確認状態であり、ゼロ使用量の実測ではない。集約ツールは入力の真正性を認証しないため、freshな既存の管理read-only証拠と突き合わせる。`pilot-plan.json` の現在のpilotは3人・1GiB/200件で、5GB/1,000件の販売案に置き換えない。失効ownerとS3履歴を含めた実使用量・現在の料金/残枠は今回未照会であり、10月2日の記録をfresh証拠に再利用しない。

費用のローカル算術は既存 `node scripts/estimate-pilot-budget.mjs` を使う。価格は保存された仮定であり最新料金や請求上限ではない。公式料金・実使用量のfresh確認を伴わず受付ONにしない。警告1,800円・受付停止2,200円・月目標3,000円の既存境界を維持する。

期限後の処理も既存retention/notice/owner purgeの安全装置を維持する。fresh private billing、現在episode/revision、同じ連絡先への実配達証拠、最低30日、現在の全コピーinventory、claim/fenceと再契約の再照合を経る。scan/reviewは削除権限ではない。ドライランと実通知・実削除を分け、今回実データへ通知・永久削除は実行しない。

## この環境での検証

- `node --test test/operating-readiness.node-tests.mjs`: 6件成功。
- `npm run typecheck`: 成功。
- `npm test -- test/membership-links.test.ts test/billing-authority.test.ts test/retention-ledger.test.ts test/intake-control.test.ts test/notice-dispatch.test.ts test/owner-purge-preflight.test.ts`: Windowsのesbuild親ディレクトリ読み取り拒否とMiniflare作業ディレクトリ作成EPERMで起動前停止、0件実行。追加遷移テストも未実行であり、成功扱いしない。

権限回避やACL変更は行わない。上記6suiteと通常のService全検証を実行できる正式な環境で通し、実機Sandboxの結果は別証拠として残す。実配達/期限削除の運用準備を、mockの通過だけで完了扱いしない。

購入シート取消は自動更新停止とは別の証拠 `sandbox.purchaseSheetCancel` を要求する。旧集計にこのfieldがなければnot ready。`PlusPurchaseStore.purchase` の `.userCancelled` は `.cancelled` を返し、entitlementState/pendingProductID更新・検証transaction送信・server entitlement refreshのsuccess経路には入らない（静的確認）。実StoreKitテストは未実行。正式なiOS環境では未加入で購入シートを取消し、新たな権利・保管許可・pendingが発生しないことを確認する。既加入の場合も取消自体で既存権利が変わらず、実際のApple状態更新と混同しない。
