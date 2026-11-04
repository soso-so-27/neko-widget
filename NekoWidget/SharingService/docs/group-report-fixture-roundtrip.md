# 運営閲覧用の合成資料を作る前の検査

通常写真の2byte長のgroupFieldsと、通報NW3.MODERATION-REPORTの4byte長AADは異なる。SQL・暗号文のhashだけを照合して、閲覧できる資料と判断しない。

1. 資料生成器の暗号化関数を、宛先公開鍵を引数に取る同じ関数として使う。検査のために別の暗号化実装を作らない。
2. ローカルだけで新しい合成X25519鍵を作り、1pxの合成canonical JPEGと試験用metadataをその関数へ渡す。通常写真・利用者の鍵は使わない。
3. 生成されたmetadata・暗号文・合成秘密鍵を、製品の `scripts/group-moderation-report-lib.mjs` の `decryptGroupModerationReport` に渡す。返ったcanonical JPEGの全byteと寸法が元の合成画像と一致することを確認する。decoderや期限・署名・hashの検査は変えない。
4. 検査に使ったJPEGと合成秘密鍵のメモリーを消去する。復号結果や鍵をログ・JSON・スクリーンショットへ出さない。
5. 成功後に限り、同じ暗号化関数の宛先を承認済みの公開鍵へ変えて別のreport ID/objectを生成する。本番秘密鍵による事前復号はしない。この手順の成功だけでD1/R2への追加が承認されたとは扱わない。
6. 追加が別途承認されている場合は、元の行・objectを上書きせず追加後のhash、対象件数、対象外の不変、外部キー、通知抑止を読み戻す。最後の運営画面の認証・閲覧・判断保存は別の通し確認である。

1102zrの修正版生成器はこの方式で確認した。最初の2byte生成器は再利用しない。受信側の回帰検査は `test/group-moderation-bound-review.node-tests.mjs` の誤形式→別資料と、`test/group-moderation-operator.integration.test.ts` の同じowner sessionでの失敗→別caseを含む。

## 閲覧失敗の記録

運営hostのローカルstderrには、失敗時の固定component/phase・経過ミリ秒・cancelledだけを記録する。HTTP応答、認証条件、鍵保護、監査、期限は変更しない。例外本文、case/人物/写真の識別子、object path、鍵、暗号文、JPEGを記録しない。再試行を自動実行せず、その回の監査と失敗段階を確認する。

この診断の追加は、過去の修正版初回409の原因を特定したことを意味しない。ローカルで同じ鍵保護を使った誤形式→正常資料は成功しており、過去の記録には失敗段階がなかった。本番で再現を試さず、次の合成試験で段階を確認する。
