# 本人による通報写真確認と対応不要の判断

base `a39f1c2cadcb892d343d04940bb2b903455424e6`。初回候補時刻は2026-10-09 20:50:07 JST。計画は60–90分で、未計測の短縮実績ではない。記録は `C:/dev/neko-evidence/launch-readiness-20261009/moderation-owner-flow/`。

## 今回の結果と範囲

local専用の認証付き通報一覧から写真を開き、確認した写真に対する新しい本人署名で「対応不要」の判断と通報者宛の返信案を一緒に保存する経路を実装した。写真を開くだけでは案件は終わらず、返すread receiptも本人が内容を理解した証明にはしない。返信は未送信で、対応が必要な案件は未完のまま残す。

production Workerはこのhandlerをimportしない。owner policyは既定で空、登録用HTTP APIはない。従来の複数人によるprivacy承認、export・削除条件は変更していない。利用者の実画像・本番鍵・AI API・実返信・権限の有効化・遠隔migration・配備は扱っていない。nativeは不変、本人向けTestFlight247の再配布は不要。

## 権限とデータの境界

- 最新のAccess session、登録admission、credential、owner policyを写真取得と判断の両方で照合。共有counterは旧triageと新操作の最大値を使い、別flowで使った署名・challengeも再利用させない。
- content-readのchallengeはcase版、暗号文、commit/expiry、DB由来のsource全体に束縛。検証の試行は別transactionで先に記録し、成功署名は永続一回claimへ変える。失敗・通信不明でも自動再送しない。
- trusted hostはDBのsourceを再照合し、Nodeの既存隔離復号・鍵fingerprint・canonical JPEG検査を使う。Worker handlerは鍵を受け取らない。hostの監査を開示前に保存し、60秒deadline・AbortSignal・遅いbufferの消去を適用する。
- 判断は同じ有効sourceと完了済みread receiptへの新署名を要求。DBが決めたreporterだけをrecipientとし、判断と短命outboxを原子的に確定する。失敗時は双方rollbackし、署名試行は消さない。
- 対応不要が確定したcaseは確認待ち一覧とAI補助対象から外し、内容由来のAI job・attempt・resultを消す。private snapshot/outboxは元report削除・TTLに従い、期限切れ行の物理cleanupは次の認証済みlocal操作時に行う。時計だけで削除済みとは扱わない。
- 既に発行したDB書込みの応答が遅れた場合、timeoutはcommitそのものを取り消す保証ではない。配送不明として止め、署名・claimを自動再実行しない。

## 検証と修正

実Access JWT/WebAuthn署名とローカルD1で、owner未設定、source変更、失効、別session、再利用、旧counter、監査失敗、recipient固定、decision/outbox原子性を検査。新しいD1境界29件、Node hostの実暗号合成5件を追加した。既存のmigration inventoryへ0031の68 statementsを登録し、全31 migrationを従来の購入gate drillへ通す。

独立レビューで、ブラウザのnullable attachment/userHandle形式と既存verifierの不一致、および画像decode待ちの期限処理を修正した。verifierの合格条件は変えず、実際のブラウザserializerを署名integrationでも検証する。画像body/decodeを待つ前からタイマーを開始する。

実ブラウザで合成認証と実Node暗号の1×1 JPEGを用い、描画→判断/未送信表示、権限拒否、source不一致を確認。5秒のdecode遅延に対して1.890秒で画像source・判断欄を消去し、遅延完了から再表示しないことを直接観測した。これは本人の実認証器や実写真の一連成功ではない。

初回HTTP検証のAI補助行残存は製品側のpurgeを修正。DB fixtureのSQL列/同一reporter制約、strict optional型、queueへ追加したkey版の期待値は試験側を修正した。既存の遠隔migration互換性検査で0031の括弧なしCASE式が拒否されたため、25式へ同値の括弧を追加し、従来の68 statementsと厳格な互換性検査20件の成功を確認した。失敗・修正・実測は上記証拠フォルダーに保持し、合格に読み替えない。

## 次の接続

実認証器のdiscoverable credentialと既存の登録承認、信頼できるローカルhostへの鍵・暗号文輸送は未検証。現状は既に正規登録されたoperatorを前提とするlocal実装で、これだけで本人登録や運用開始ができるわけではない。対象限定の非表示・制限とその復旧、送達先を保った返信の実送信、AIへ渡す前の最小化/事前screen、運営の本番接続は残る。

今回のCIは凍結した製品入力に対する別control登録を先行し、同一SHAのowning pushでiOS planと既存Sharing4job・Preservation1jobを確認する。Mac/Widget/全アプリ画面/Apple配布の成功とは区別する。run・候補SHA・main merge・総時間は外部の完了記録に追記する。
