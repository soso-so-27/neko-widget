# 運営者の初回登録: 永続challengeと未承認の署名検証

## 今回の範囲

起点mainは `d9453cc2f94867b05ee5d77c3599368f08a15f4f`。ローカルの信頼されたhostだけが呼ぶ登録準備を追加した。公開route、実Access認証、実認証器、実authority鍵、権限付与、admission保存、クラウドmigration適用は行っていない。アプリ・TestFlight248の入力は不変。

- `createLocalModerationEnrollmentCeremony` はAccessの認証済みHMAC/session、scope、正確なorigin/RP、登録前に固定したauthority集合digestを束縛する。期限はDBの `MIN(unixepoch()+TTL, Access expiry-1)`、最大900秒。生のchallengeは一度返し、DBにはdigestだけを保存する。
- 登録と登録鍵の所有確認は別の一度限りattempt。暗号検証より前にattemptを独立してcommitする。署名不正、再準備、並列呼出し、途中失敗で同じphaseを再開しない。結果INSERTでもDB期限を再確認する。所有確認の期限は延長しない。
- 元のregistration counterは不変。成功した所有確認counterだけを既存共通viewへ追加する。元の4種類のcounter sourceを保持し、検証後のINSERTでも最新floorを再確認する。0→0を許す既存認証器互換条件以外、同値/低いcounterは拒否する。
- canonical moduleは実際のdurable成功readbackを信頼された入力とする。ブラウザからserialized receiptを受けて登録の成功と扱う入口ではない。SQL管理者は既存設計と同じ信頼境界の内側にある。
- 2つの実Ed25519署名を検証しても `enrollmentAdmissionAuthorized=false`、`needsFinalDBRecheck=true` を返す。none/packed-self＋所有確認は実在の人やhardwareの証明ではない。

## 固定byte契約

`C` は既存のuint16 BE UTF-8 byte長＋各fieldのbytes。JSON/表示文言/prehashを署名しない。`H` はSHA-256の64桁lower hex。Ed25519鍵32 bytes、署名64 bytesはcanonical unpadded base64url。未定義field/accessor/symbol、重複role、未知policy、型・digest・COSEの不一致を拒否する。全records/配列/COSE bytesは最初のawait前にcopyする。

scopeは `NW.MODERATION-ENROLLMENT.SCOPE.v1,1,accountID,databaseID,serviceIdentity,Access issuer,audience,exact HTTPS origin,RPID`。roleは `NW.MODERATION-ENROLLMENT.ROLES.v1,1,count,ASCII順role列`。既存5roleだけを許し、initialにはsecurity_adminを要求する。authority集合は `NW.MODERATION-ENROLLMENT.AUTHORITY-SET.v1,1,2` に続きASCII keyID順の `keyID,revision,H(raw public key),authorizedAt`。ceremony開始前に固定した集合digestと照合し、秒精度timestampだけで同秒のauthority追加・revision変更を許さない。

requestは以下の順で固定する。これは今回の新契約であり、0017の旧fixture値から意味を推測していない。

1. `NW.MODERATION-ENROLLMENT.REQUEST.v1`, `1`, scope SHA, request UUID, `initial_bootstrap`
2. operator UUID, Access HMAC key version, subject HMAC, role snapshot SHA
3. credential SHA, COSE SHA, exact COSE base64url, **元の**registration counter
4. registration evidence SHA, policy revision `1`, `es256-single-device-none-or-packed-self-v1`, AAGUID SHA
5. registration challenge UUID/digest, Access session SHA, Access issuedAt/expiresAt, ceremony expiresAt
6. 空文字2個（initialのsuperseded admission/credentialはなし）
7. ceremony UUID, possession challenge UUID/digest, verified assertion SHA, possession newCounter, authority-set SHA

request digestにDB assigned requestedAtは含めない。2つの署名は、commit済みrequestのactual requestedAtとexpiresAtをそれぞれ束縛する。approval transcriptは `NW.MODERATION-ENROLLMENT.OFFLINE-APPROVAL.v1,1,Ed25519,scope SHA,keyID,revision,key fingerprint,request UUID,request SHA,requestedAt,expiresAt,approve-initial-bootstrap`。package指定の鍵は使わずhostの固定2authorityを参照し、keyID/raw key/fingerprintの重複とrevision不一致を拒否する。signature SHAは検証成功後にだけ計算する。

## 検証と残件

rootのcanonical contractはworkerd23件（actual2署名、独立signer serialization、時刻/roles/scope/鍵/possession変更、authority同秒rotation、非canonical forms、await後mutation）を4.49秒で成功。既存wrapper51件は担当者のD1初版14件と合わせ65件18.32秒で成功した。型検査は成功。初回inventory検査の1件は期待migration数32→33の更新漏れで失敗し、製品挙動を変えず当該fixtureを訂正した。統合D1接続、既存counter route、最終統合検査、CIは別途証拠へ記録する。成功していない範囲をこの記載から推定しない。

一般提供の前には、実ブラウザ/認証器/Access/実offline鍵の互換性を直接観測し、信頼された登録hostと操作画面を接続する必要がある。admission writerはまだない。将来writerは2approval行を先にcommitしてactual approvedAtを読出し、provenanceを計算して最終transactionへ進む。全role snapshot、現在のidentity/credential/authority revision/set、pending Access/ceremony/request期限、既存admissionなしを再確認する。SQLのsecurity_adminだけの条件やcrypto出力だけで全role/権限の承認完了と扱わない。失敗・中断は未承認のまま保つ。

独立設計/codeレビュー・初回時刻・失敗・候補固定・実行結果は `C:/dev/neko-evidence/launch-readiness-20261010/operator-enrollment/` に集約する。実機確認の再依頼や期限の自動延長は今回の作業に含まない。
