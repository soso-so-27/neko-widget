# 通報確認のローカル画面

base `00639d2c189439e50f096a558b9d4c4b72461899`。本人が実際に確認する入口を、既存の署名付き `review_start` へ接続する候補。写真本文の開示や最終判断を開始記録と混同しない。

## 今回の動作

- local triage の `/operator/console` はidentity・case・鍵・tokenを埋め込まないHTML shell。既存本番Workerはimportせず、runtimeをYESにしても利用できない。
- 一覧はAccess署名、最新admission/credential、triage role、Origin、監査、quotaを通る。認証・依存失敗では一覧を消し、別画面への移動では処理をabortして遅い応答を無視する。
- 実IAB観測で同一origin GETはOriginなし、POSTはOriginあり。そのため既存GETの条件は維持し、bodyなしPOST readを追加。JSからOriginを書き換える方法は採らない。
- 確認期限、未確認/確認中/確定待ち、有効証拠の有無、現在のAI補助理由だけを返す。AI結果の新旧と期限はD1 transaction内のcurrent jobs viewで照合し、期限が切れた結果を隠す。raw本文・写真・report/participant ID・credential・JWTを返さない。AIの失敗やholdはqueueに残り、期限順を下げない。
- 1回20件で、期限と照合番号をcursorにして次のページへ進む。同一期限22件を20+2件で欠落/重複なく確認。更新は先頭に戻る。未bindingの通報数も残す。
- 確認開始は既存challenge→認証器署名→先行attempt消費→D1確定を使用。challengeのpath/RP/期限と応答のcaseをbrowser側でも照合。署名は自動再送しない。CSP nonce、no-store、textContentによる描画。

## 検証の境界

証拠は `C:/dev/neko-evidence/launch-readiness-20261009/moderation-console/`。実ブラウザの合成response表示と、実Access/WebAuthn署名・D1 integrationは別々に記録する。合成previewの503操作を署名成功と数えない。

local Sharing全検査430件成功（172.20秒）後、ページ送り追加のtypecheckとtriage23件を成功（21.22秒）。以前の署名/replay/失効/原子的rollback・現在AI結果の境界を維持。最初の追加testの監査digest期待値は改行連結と誤記して失敗し、既存のJSON配列canonical bytesへ訂正。製品のdigest方式は変更していない。ブラウザでは実HTMLを合成responseで描画し、通常/空一覧/401/503/不正response/次ページを直接確認した。

本人の実認証器とのbrowser往復は未確認。raw credential IDは既存DBに保存しないため、allowCredentialsなしで発見できる登録か、実環境で確認が必要。コードと合成署名だけで互換性を断定しない。

本番の運営者登録、写真・本文の閲覧、本人の最終判断、共有copy非表示、返答送信は未接続。アプリを変更しないためTestFlight再配布は不要、最新本人用247の実機検証とは別。

## 次の判断記録・返答の実装条件（独立レビュー済み設計）

1. 新owner限定policyを固定operator ID・policy revision・credential/admission epochへ束縛。triage所持だけで本人判断権限を与えず、旧0013の別operator privacy承認を維持する。
2. 新domainのchallengeにcase/evidence/current-state版、判断・理由、対象範囲、返答templateとrecipient bindingを固定。確認開始に判断を偽装しない。
3. 同一credentialを使うなら、新旧の署名receiptと登録counterを合算して最大値を両方のDB境界で比較。owner receiptだけにcounter検査を加える設計は不可。
4. 最終確定時に本人・epoch・期限・証拠をDB内で再照合し、immutable decisionと短命outboxを原子的に保存。競合・replay・REPLACE・途中失敗のrollbackを検証。
5. 新ownerの終端判断を0030のlive-source条件へ反映し、判断後のAI送信・古い結果表示を止める。
6. 返答先はcase→moment_reports.reporter_participant_idからDBで解決。UIやAIがrecipientを選ばない。被通報者への連絡は別目的・別template。report削除/期限でoutboxの宛先・内容を落とし、最小receiptだけ残す。
7. outboxの作成・送信失敗・到達不明・到達確認を区別。到達不明を自動再送しない。非表示は別overlayで実装し、元のblock/unlink/TTL/鍵失効を解除しない。

live接続が必要になった時点で、本人grant・認証器登録・開示/AI最小送信範囲・返答先を固定した差分を提示する。AIや本人の別アカウントを独立運営者に見立てない。
