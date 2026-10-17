# 本人の自動保存試験を再開（2026-10-18）

月額980円を維持。利用者の「残っている保存テスト受付とSandbox契約の確認も進めて、自動保存を実機で試せる状態に」に基づく、既存本人だけの有限受付。アプリ・Worker製品コードは変更せず、259と既存の成功した検査を保持する。

## 実機と費用の直接確認

利用者の実画像で、Apple管理sheetの `[Sandbox]`、ねこのまどプレミアム月額、10月8日の終了を確認した。本人が「サブスクリプションに登録」を操作した後の画像に、月980円・更新日10月18日・キャンセル操作が表示された。利用資格リセット、履歴消去、アカウント変更、管理者grantなし。Appleの実管理sheet表示は確認できたが、サーバーのactive/graceは別の観測で判定する。

同じAWS account `164892691568` の認証済み請求画面（10月18日03:02:02 JST更新）で、FREE、残119.29 USD・160日、当月差引0.00 USDを確認。東京gross0.52 USD、KMS key0.523 key月、request1,384回・従量0。CE APIを呼ばず、Paidへ変更していない。Cloudflareの同accountは既存Workers Paid/R2 Paid、9/22〜10/21周期、10/17までの従量表示0・全項目included内。

現在の暦月/請求周期使用量の費目別最大に、確認用/JPEG用それぞれ最大10時間分を加えても、memory20.877757 GiBh / disk83.511028 GBh / CPU18,154.92秒で、既存共通枠25/200/22,500以内。両runtime Workerの現settings/deploymentは旧費用根拠と一致した。DO内の実予約残量は読取専用経路がなく、未取得のまま。設定10時間を残量と扱わず、上限・失敗時停止を保持し、費用審査と可用性を区別した。

旧製品codecの100PUT/2復元/自動cleanup測定は入力を保持して再利用。最新請求と期間で再計算した既存固定費込みの月末cloudモデルは税10%仮定1,209.02円、受付forecast1,210円、停止2,200円。これは追加支払い額でも通常の1人原価でもない。追加現金従量は既存枠・AWS credit内で0円見込み。強制請求上限・無料保証ではない。旧S3全版本一覧に毎時metadataの増分を加えた包絡を使い、最新全版本一覧取得と偽っていない。一般利用の全原価はこの計算の対象外。

## 保存受付の反映

10月18日03:09:14 JST、独立レビュー後、期限切れ `pa_intake_control` の全列CASを1回実行した。既存General経路は既に有効なためsettings再配備は0。期限は10月19日03:09:12 JST、owner1・新規登録0・追加100PUT/128MiBと新規記録100試行/128MiB。counterと日/月markerを保持し、上限だけを現在期間の実効使用量＋増分へ設定。31記録・旧trial各表・owner/key/link・archive version `f531b6fa-ac26-48a5-92f4-52fe34ee4d00` を保持した。

同一のSQL/guardを使うオフラインSQLite16境界検査成功（非ゼロcounter保持、日跨ぎ、drift・本人変更・未期限切れ・未来時刻・古いreview・月跨ぎ拒否）。これは実D1/実機成功の代用にせず、実CASのreceiptと保持照合を別に記録した。

## 続く確認

再登録済み本人だけのnegative cache再確認窓を03:09:25〜05:09:25 JSTの2時間に設定した。live versionは `24672ff8-7820-473e-8552-0270712c7f4d`、実bundle SHA256 `b42c4f136303502efdfcdf42c12602230b1890625fb5f8f409341c34e145de9d`。一回PATCHは受理されたが、Cloudflareがversion管理annotationのcommit_sha/messageを落としたため、旧writerの事後assertは失敗したまま保持。再PATCHせず、fresh GET・実bundle byte・全binding/secret参照/runtime/cron/exposureの一致を確認し、独立レビューで管理metadata差分のみと分類して別completionを記録した。API失敗や製品不具合へ読み替えず、partial PATCH receiptを全binding一致の根拠にしていない。旧購入受付の期限は延長せず、private retention observerを既存15分cronから観測する。cron変更・手動実行はしない。03:15:58 JSTのApple権威観測と03:16台のD1読取で、同じbilling account・同じoriginal transaction lineageの新取引を確認。Sandbox/PURCHASED/apple_status1/materialized active/grantsPlus1となり、retentionもactive、旧expired/due/paused日時はNULLへ戻った。既存cronの終了errorはNULL。管理者の会員書込や手動observer/cron呼出し0で、実確認の予算は足りて動いた。これは月間残量を観測した証拠ではない。サーバー側は実機自動保存を試せる状態になった。実際の端末の初回同意・通常編集からの自動保存と復元は、利用者の結果とmetadataで別途確認する。

証拠は `C:/dev/neko-evidence/automatic-test-20261018/`。個人識別子を含むprivate JSONは外部へ添付しない。新規有料契約、実課金、AWS Paid、一般公開、新規登録、管理者grant、旧trial reset、Codex定期の追加/更新/再実行は0。

今回の開始は10月18日02:58:34 JST。サーバー有効確認は03:16台（約18分、途中の管理annotation照合失敗と定期処理待ちを含む）。前の製品候補〜259配布の42時間22分11秒は別の履歴として維持する。

## 初回の実機自動保存（03:23 JST追記）

本人は259の「保存中…」を報告し、操作を繰り返さず待機した後に「保存済み」になったと回答した。サーバーの読取では03:20に記録51・転送予約あり、03:21に61へ進行。件数の増加や予約0だけを完成の証拠にはせず、03:23:46 JSTに同ownerのlive head revision1 → live index revision1の参照を確認した。head/indexのIDは03:09の受付切替直後の31記録に存在せず、古いheadを今回の完了と誤認していない。indexはsource種別indexかつrecord_id=snapshot_id。必要な32部品はすべてliveで、残る転送予約は0だった。

今回の内部構成は写真24部品・JSON8部品・index1・head1の34記録で、旧31と合わせて65。これは写真枚数・ツール件数の表示ではない。旧31記録はすべてlive、revision・photo_bytes・quota_bytesが受付前と一致した。復号や本文閲覧はせず、D1 SELECTのrows_writtenは0。`save-publication-v2-20261017T182346Z-summary.json`、対応するprivate JSON、`read-save-publication-v2.py`、利用者の「保存済み」回答を証拠とする。独立読解でhead公開とUI ACKの条件を確認し、元の集計だけでは既存headを区別できないとの指摘を受け、受付前ID比較を追加した。

これで初回同意からクラウド確定・実機「保存済み」までを確認できた。通常編集からの自動送信と新しい自動復元は別の実機確認として残す。旧手動コピーの復元成功を代用しない。確認のための追加PUT、管理者grant、設定変更、cron/observer手動実行、Codex定期変更、課金・新契約は0。製品コード・CI入力は変わらず、259と既存成功検査を維持する。開始02:58:34から初回保存確認03:23台まで約25分（既存定期の待機と実写真転送を含む）。
