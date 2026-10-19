# 総費用・保存処理・大量復元の確認（2026-10-19）

月980円を維持。新しい有料契約、料金plan、保存class、quota、受付期限、定期taskを変更していない。元データの削除、一般公開、実機依頼は行っていない。

## 採算の判断

以前の約65円は「1写真保存の価格」ではなく、仮定した月間使用量で計算した費用の一部だった。総原価・実請求・確定利益に読み替えない。

今回のroot重複除去前のservice tree f2e26488、有料契約者100人、固定参照費用をこのアプリへ全額配賦、1USD=160円、共通無料枠をaccount全体へ一度だけ適用する比較では、1日1写真＋1メモ、3,650枚時点の確認済み費用は約70円/人月。1日10写真＋1メモ、36,500枚時点は約747円/人月。いずれも利用者が確定した普通の量ではなく調査条件。

税込980円から税10%と税抜価格への15%/26%手数料を仮定した受取額は約757円/659円。実際のApple Partner Shareではない。写真が多い比較では未計上費用を払う余地が約10円〜赤字88円となり、十分な利益を確認できない。全履歴の物理容量、本番runtime、閲覧・復元、解約者保管、実入金・返金、サポート等が未確定。未知を0円として利益を算出しない。

固定費の人数割は有料契約者で行う。Apple ID数や3人という単位は使わない。解約者の残るデータも費用へ含める。無料creditは長期採算へ入れない。

## 実装・直接検査

重複したold-root認証だけを非空delta経路から除き、tree.update内の認証を使う。header-only/idempotentのroot検証、publication readback、最終fence、失効、暗号形式、削除・ACK条件は維持する。同じ3,650枚fixtureのメモ1回でKMS unwrap424→405、S3 GET257→238、wrap133/PUT123/HEAD123/D1 rows-written1,351は同じ。7境界検査と型検査成功。unwrap約4.5%減は総原価4.5%減ではなく、毎日1メモの有料従量単価比較で月約0.31円の小さな差。

大きな削減候補は内部レコードを論理保存としてまとめる方式。現行例は1メモに19内部変更がある。実D1で全件guardの成功・競合/後段失敗の全rollback・idempotent replayを検証したが、新製品API、耐障害journal、native連携は未実装。単に複数UPDATEを並べても0行更新時に先行更新は戻らないため、その方式は採らない。

128写真を保ち同一メモを100回編集した全保存経路では、写真以外のS3履歴が32.39MB、D1 engine報告の保存量が4.27MB増加した。live154件は同じで、旧版不変/未ACK0/使用量整合を確認。後半の増加が大きいため10年への直線外挿は行わない。検査環境のactive timer上限を原因として2回停止し、test-onlyの期限管理を切り分けた成功結果である。製品側のdeadline修正ではない。

## 大量復元

合成写真1,000枚×871,950bytes（約872MB）を実ローカルroute/D1/R2/AES経路で受信し、全hash一致まで153.3秒。初回header96ms、写真261ms、wire1.163GB、36request。初期データ作成96.0秒は復元時間に含めない。実外部通信0で、実本番KMS/Cloudflare/iPhoneの完了時間ではない。50Mbpsで同じwire bytesを運ぶ部分だけなら約3分6秒。最初の3,650枚検査は900秒上限で結果が取れず、受信decodeも切り分けて方法を変更した。3,650/36,500全件や実S3災害復旧の速度確認は残る。

本番Worker invocation上限の適用単位も未確認。ローカルA→B31/32/33/40回は成功し、公式32の上限を再現していない。ローカル成功で本番上限を無視せず、未再現だけで現行製品の障害とも断定しない。

## 追加費用がある保管変更の候補

R2 Standardを維持する。R2 IAは保存差だけよりも請求単位切上げ・取出料が効き、小規模では不利になり得る。S3の古い写真だけGIRへ移す候補は、36,500枚の写真保管部分約195→100円/月に対し移行約117円、全写真各1GETのDR画像部分で追加約199円、最低90日課金がある。通常R2アプリ復元へS3転送料を加えない。GIRはFree plan適格性・写真限定適用・exact version/checksumの実適合が未確認で、まだ実施していない。これは総費用747円が100円になるという意味ではない。

## 反映と残作業

control PR388/389、製品PR390/main `1b0fe07`。同SHAのmain backend全8step（39200416666）とplan3step（39200416669）が初回成功。既存archiveだけversion `da21b43b-5176-459f-b0e3-98ee24e5405a` を100%有効化、bundle照合、保護対象D1・全設定・secret参照・quota・intake・cron・deletion Worker不変を確認した。upload1/activation1、新契約0、DB migration0。

反映前の集計変化は2回upload前に拒否し、書込はなかった。owner ACK187→188→189を各固定snapshotとmetadata/S3 exact-version HEAD/checksumで調べ、gen193の契約確認checked_atから1183ms後、前ACKから約1時間の対応を確認した。request callerの特定ではない。毎15分の既存cronと同状態でも1時間後に観測更新する既存retention経路を読み、重い検査・レビュー成功を保持したうえで境界後に短く完結させた。過去snapshotだけを固定hashで比較し、今後のlive差分を許す例外は作っていない。拒否・空package・旧writer・旧承認を保持。

batch開始03:32UTCからクラウド検証完了04:55:08UTCまで83.13分。製品準備から52.80分で、当初control/backend15〜25分見込みは未達。文字コード準備、test path登録漏れ、歴史的selectorとの重なり、上記2回の集計変化による手戻りを含める。失敗や開始時刻を新branchでリセットしない。

残りは、論理保存の集約の製品実装と失敗復旧、履歴増加の抑制、未計上費用/実受取額を含む採算、実クラウド・実機の大容量復元、S3運営復旧の短縮。内部TestFlight265のnative入力は不変で再upload不要。期限切れの本人受付は再開していない。

private実績・raw証拠・算式は C:/dev/neko-evidence/full-cost-save-restore-20261019。公開repoへ請求明細や個人情報は含めない。関連: [前回の費用削減](2026-10-19-save-cost-reduction.md)。

出典: [Workers](https://developers.cloudflare.com/workers/platform/pricing/)、[R2](https://developers.cloudflare.com/r2/pricing/)、[S3](https://aws.amazon.com/s3/pricing/)、[KMS](https://aws.amazon.com/kms/pricing/)、[Apple日本の決済条件](https://developer.apple.com/jp/support/payment-options-on-the-app-store-in-japan/)。

## 別系統の監視記録

既存のPersonal sharing staging monitor（schedule run39200315741）は、別のSharing Workerのhealth runtime gate不一致で自動失敗していた。今回のpreservation製品検査とは別であり、手動再実行・設定変更を行っていない。expected/actual gateの追加切り分けは残件。
