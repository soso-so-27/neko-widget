# Apple通知履歴staging訓練

この手順は、Apple Notification Historyによる通知欠落回復を、通常の課金操作から分離して確認するためのものです。Production変更、購入、TestFlight配布、HistoryのON操作を許可する手順ではありません。

## 現在の境界

- Worker、D1、隔離VerifierのHistory Gateは既定OFFです。
- 通常の課金controllerはHistory ON状態を認識せず、引き続き拒否します。
- この専用controllerが行えるのは、ローカルplan、read-only status、History lower Gateの緊急OFFだけです。ON、deploy、migration、blocked復旧、期間変更は実装していません。
- `status`はD1からcursor、lease token、通知UUID、payload hash、account、JWSを読まず、回復状態、固定期間、件数、試行数、安全なerror codeだけを表示します。
- 緊急OFFはHistory lower Gateだけを1回のgeneration CASで0へ戻します。他の7 Gateを変更しません。遅延responseはlower Gate generation fencingでpage commitできません。

## 資格情報なしで行う確認

次のtestは合成データだけを使い、Apple、Cloudflare、D1 remote、Verifierへ接続しません。

```powershell
npm run check:billing-notification-history-staging-control
npm test -- --run test/billing-notification-history-client.test.ts test/billing-notification-history-state.integration.test.ts test/billing-notification-history-recovery.integration.test.ts
```

`billing-notification-history-staging:plan`もnetworkへ接続しませんが、固定対象をreviewするため、ignoredの通常課金configと専用manifestが必要です。manifestは次のキーだけを持たせ、実IDをcommit、画面共有、ログ出力しません。

```json
{
  "schemaVersion": 1,
  "accountId": "32文字のstaging account ID",
  "databaseId": "staging D1 UUID",
  "workerName": "neko-window-sharing-staging",
  "origin": "https://neko-window-sharing-staging.nakanishisoya.workers.dev",
  "expectedGeneration": 0,
  "expectedStoreEnvironment": null,
  "expectedBundleId": null,
  "expectedGates": {
    "account_bootstrap_enabled": 0,
    "transaction_ingestion_enabled": 0,
    "apple_notification_ingestion_enabled": 0,
    "subscription_reconciliation_enabled": 0,
    "effective_entitlement_enabled": 0,
    "window_sponsorship_enabled": 0,
    "account_recovery_enabled": 0,
    "apple_notification_history_recovery_enabled": 0
  }
}
```

```powershell
npm run billing-notification-history-staging:plan
```

PASSは、固定Worker／D1／origin、exact Gate snapshot、通常の課金configを検証したことだけを意味します。Historyを有効化できる状態だとは証明しません。

## read-only status

Cloudflareのread権限と、review済みの現在generation／Gate値をmanifestへ記入してから実行します。

```powershell
npm run billing-notification-history-staging:status
```

この操作は固定D1へのSELECTと同一originの`GET /health`だけを行います。次を確認します。

1. manifestとD1のgeneration・8 lower Gateがexact一致する。
2. History lower Gateと実効Gateを分けて表示する。lower ON／effective OFFはupperが閉じている状態であり、取得成功を意味しない。
3. review済みenvironment／bundle IDとD1の回復identityがexact一致する。
4. 回復generation、固定期間、state、page／record件数、retry／cursor reset、last errorを表示する。
5. `blocked`は自動再開しない。原因と同じ固定期間をreviewするまで手動SQLを実行しない。

## 緊急OFF

ON操作はこのrepositoryにありません。将来、別のreview済み手順で隔離stagingのHistoryをONにした場合だけ、現在のD1 generationと8 Gateをmanifestへexact記入し、History lower Gateが1であることを2人で確認します。

```powershell
npm run billing-notification-history-staging:plan
npm run billing-notification-history-staging:status
npm run billing-notification-history-staging:emergency-off
```

最後のコマンドは`--confirm-history-emergency-off`を固定で渡し、History lower Gateだけを0へ変更します。成功後、新generationとHistory=0へmanifestを更新してstatusを再実行し、同一originの実効HistoryもOFFであることを確認します。その後、active WorkerとVerifierのHistory upper switchをreview済みOFF構成へ戻します。controller自身はdeployしません。

CAS失敗、generation不一致、unknown Gate組み合わせ、health不一致の場合は再実行せずstatus用manifestを作り直します。監査ledger、History page receipt、通知event、課金authority observationを削除しません。

## ON前に残る外部条件

History ONは、隔離Verifier／Tunnel／Access、Redis、Apple Sandbox Server API credential、固定bundle／environment、active deployment attestation、監視、blocked復旧manifestが揃い、実Apple pageで署名・保持期間・paginationを訓練するまでrelease blockerです。この文書とcontrollerだけでは満たしません。
