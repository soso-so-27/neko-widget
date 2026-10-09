# 通報写真のsource照合と隔離復号

base `315f7a21100c2398bda57cbd9b67bd994945db0a`。本人による通報確認へつなぐ内部部品。現在のconsoleへ写真権限を与える変更ではない。

## 実装した境界

- `readLocalModerationReviewSource` はversioned case referenceからDBのreport行を解決する。committed/tombstone/期限/旧終端判断に加え、object keyまたはreport IDに一致する削除jobがあれば拒否。ブラウザからreport IDやobject keyを指定させないための内部adapterであり、認証・grantではない。
- `withBoundModerationReview` はNode隔離復号を維持。現行Workerへ鍵を移さない。case/key版、report ID、object key、暗号文size/SHA、commit/expiryを固定し、既存reviewed key ID/fingerprint照合とX25519/HKDF/ChaCha復号を利用する。既存AADにはreport IDが含まれないため、DB sourceとの一致を別途必須にする。
- trusted hostが提供するsource/鍵/監査/固定UI sinkだけを使う。source取得は毎回、本人のcontent-read scope・最新credential/session epoch・現在のDB sourceを確認する契約。triageやreview_startの成功をcontent-read許可にしない。live adapter、owner grant、WebAuthn content-read ceremonyはまだない。
- 読出し前・鍵取得前・開示直前にsourceを再照合する。監査開始/開示予定の永続化失敗ではsinkへ渡さない。全awaitに共通の最長60秒deadlineとAbortSignalを適用。timeout後の遅延完了から開示を再開しない。sink失敗・監査未確定は成功扱いせず自動再送もしない。
- 画像・鍵・個人IDは監査へ残さず、case HMAC、source digest、phaseだけ。返すreceiptも閲覧許可/最終判断/画像exportの証明ではない。自身が所有するbuffer copyはfinallyで消去する。上流adapterやブラウザに渡ったcopyの完全消去・回収を保証しない。

## 直接検証

証拠: `C:/dev/neko-evidence/launch-readiness-20261009/moderation-review-evidence/`。

D1/workerdのsource20件とNodeの実暗号合成27件。初回D1 testのassertが存在しないtable名を指定して失敗し、実在するactions/role_eventsの非変更確認へ訂正。製品条件は変更していない。独立レビューで無期限awaitの保持リスクを指摘され、各stepのdeadline/abortと遅延完了拒否を追加。同期完了がtimerより先に期限を越える場合も拒否する。

別々のDB fixture検証とNode暗号検証を実ユーザーの一連成功とは呼ばない。ブラウザは実Node暗号合成JPEG（1×1画素）の復号→描画/除去を直接観測した検証用sink。これは本番console画面でも実本人認証でもない。既存写真・メモ・実通報・実鍵・AI通信を使っていない。

## 次の接続

固定本人policy/credential epochに結ぶ新content-read challenge・durable一回scope・閲覧監査と上記adapterの接続が必要。その後、閲覧したsource digestに結ぶ本人の新署名判断→対象限定restriction→DBが解決するreporter宛の短命outboxを原子的に確定する。既存export/削除の独立承認、個人保管、元TTLを変えない。production Workerは未接続、実利用者への送信も未実装。

native appは変更しない。本人向けTestFlightは247のまま。一般公開完了・実運用可能とは扱わない。
