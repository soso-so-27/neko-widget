# 暗号化された写真通報のオフライン確認runbook

このrunbookは、利用者が明示的に送信した一枚の通報copyだけを、権限を持つ担当者が
隔離された端末で確認するための手順である。通常の家族共有写真を復号する手順ではない。
現在のrepositoryにはProduction秘密鍵を置かず、Cloudflareから通報を取り出すoperator APIも
まだない。識別子を含まない件数・滞留時間帯を確認するread-only statusはあるが、本文を閲覧する機能ではない。
したがって、本書とtoolだけを理由にProductionの写真共有を有効化してはならない。

## 責任者と対応時間

- Primary operatorとbackup operatorを各一人指名し、氏名ではなく社内roleを台帳に記録する。
- 通報queueは毎営業日一回以上、かつ休日を含め48時間を超えない間隔で確認する。
- 通報の`committed_at`から48時間以内を初回確認の内部SLAとする。期限の半分を過ぎた未着手件は
  backupへ通知し、期限4時間前にはincident扱いで責任者へ上げる。
- 差し迫った身体的危害、児童の安全、法的保存要請など通常手順を超える事案は、画像を転送せず、
  定められた安全・法務担当へ直ちにcase IDだけでescalateする。法的判断をoperator単独で行わない。
- Primary不在時にbackupが同じ手順を完遂できるか、合成fixtureだけで四半期ごとに訓練する。

### 内容を見ない日次確認

report-ingestion専用のignored ON configを作成・検証済みで、そのconfigが参照する隔離済みstaging D1を
確認するときだけ、次のread-only確認を使う。

```powershell
npm run moderation-staging:status
```

固定されたstaging D1へ、review済みの`SELECT`だけを実行する。引数、任意SQL、任意database、任意configを
受け付けず、表示するのはreport lifecycleの件数、committed reportの`24時間未満 / 24〜48時間 /
48時間超`という年齢帯、期限切れcleanupとreport object削除待ちの件数だけである。ID、氏名、端末、
object key、hash、暗号文、URL、秘密値、理由、写真本文は読み取りも表示もしない。

このコマンドが証明するのは、そのD1のschemaと識別子を含まない集計だけである。件数は少数でも抑制せず
exact表示するため、担当者が既知の出来事と照合すれば通報の発生や時刻帯を推測できる場合がある。出力を
公開channelや通常logへ転送せず、権限を持つ運用者だけが確認する。現在activeなWorkerのcode、binding、
runtime flag、Cron、または同じD1へ配備されていることは検証しない。一般配布前には、active deploymentと
review済みmanifestの一致を別のfail-closedな手順で証明する必要があり、未整備の間はrelease blockerとする。

`48時間超`は**reportの作成時刻帯であり、未確認やSLA違反を証明する値ではない**。現行Serverには
人手確認の完了receiptがないため、担当者の短期local台帳と突き合わせる。件数だけで個別caseを推測せず、
異常な滞留またはcleanup待ちを見つけたときは新規受付を独立停止してから運用incidentとして調べる。

## 鍵の準備と保管

Production鍵はこの変更では生成しない。導入時は次を別の承認済み作業として実施する。
本人所有2台のsource staging用に限る鍵生成helperと、BitLocker／ACLを含む停止条件は
[staging通報鍵のオフライン生成runbook](MODERATION_KEYGEN_RUNBOOK.md)を正本とする。
生成したstaging鍵pairの最初の実使用は
[staging通報鍵の合成復号・削除drill](MODERATION_STAGING_DRILL_RUNBOOK.md)に限定し、
そのdrillが完了するまで写真runtimeとTestFlight media uploadをOFFに保つ。
このhelperをProduction鍵へ転用しない。

1. Networkから切り離した暗号化端末または承認済みHSMでX25519鍵を生成する。
2. Appへ入れるのは32-byte raw public keyと`moderation-v1`だけにする。秘密鍵をCloudflare、CI、
   repository、ticket、chat、password managerの自由記述欄へ置かない。
3. Primary用copyと、封印・暗号化したbackup copyを別の物理保管場所に置く。取り出しは二人承認にする。
4. Raw private-key fileを使う場合は32 bytesちょうどとし、作業中だけ暗号化volumeへ展開する。
   POSIXでは`chmod 600`、Windowsでは専用local folderから継承を切り、Primary/backup以外を
   `icacls`で除外する。OneDrive、iCloud Drive、Dropbox、backup、indexingの対象へ置かない。
5. 鍵の作成、backup封印、復元訓練、廃棄を秘密値なしで鍵台帳へ記録する。

`test/moderation-report-tool.node-tests.mjs`の固定鍵は合成試験専用であり、Productionへ転用しない。

## 作業端末

- OS更新済み、full-disk encryption、screen lock、malware protectionを有効にした専用local accountを使う。
- Browser、mail、messenger、cloud同期、clipboard history、screen recordingを閉じる。
- 作業directoryとaudit logは暗号化されたlocal volume上に作り、共有folderやrepositoryの外に置く。
- 画面共有中、公共の場所、第三者が見える状態では復号しない。
- Commandには鍵の値を渡さず、鍵fileのpathだけを渡す。Shell historyやconsoleへ画像を出力しない。

## 受領bundleの契約

Operator exportは次の三点を別々のregular fileとして渡す必要がある。

1. private moderation R2から取得した暗号文（最大1 MiB）
2. D1の同一committed reportから作った、次のexact JSON manifest
3. `moderationKeyId`に対応する32-byte raw X25519 private key

Manifestはflat JSONで、未知field、欠落field、重複keyを許さない。

```json
{
  "schema": "jp.nekowidget.moderation-export.v1",
  "protocolVersion": 2,
  "envelopeDomain": "NW2.MODERATION-REPORT",
  "algorithm": "X25519-HKDF-SHA256-CHACHA20POLY1305",
  "reportId": "<opaque report id>",
  "momentId": "<opaque moment id>",
  "reporterParticipantId": "<opaque reporter participant id>",
  "reasonCode": "privacy",
  "moderationKeyId": "moderation-v1",
  "ciphertextSize": 12345,
  "ciphertextSHA256": "<base64url SHA-256, no padding>",
  "committedAt": 1787367600,
  "contentExpiresAt": 1787972400
}
```

`reasonCode`は`objectionable`、`harassment`、`privacy`、`other`のいずれかである。
Export側は、`reportId`、`momentId`、`reporterParticipantId`、`reasonCode`、
`moderationKeyId`、size、SHA-256が同じD1 snapshotの一行から来たこと、対象が`committed`で
content TTL内であることをtransactionally保証しなければならない。時刻はD1と同じUnix秒で、
`contentExpiresAt == committedAt + 604800`かつ`committedAt <= export時刻 < contentExpiresAt`を
remote export側とoffline Toolの両方で確認する。手作業で別のreportの値を
組み合わせない。

現時点では、このbundleを認証・認可付きで作成するremote export APIが存在しない。
R2 object keyの推測、public bucket化、Dashboardからのad-hoc copy、Worker logへのciphertext出力で
代替しない。監査済みexport経路が完成するまではProduction運用を開始しない。

## 復号と検証

Node.js 22以降を使い、最初に合成試験を実行する。

```sh
node --test test/moderation-report-tool.node-tests.mjs
```

作業directory内のpathだけを指定して復号する。既存outputへの上書きは拒否される。

```sh
node scripts/moderation-report-tool.mjs decrypt \
  --metadata /secure/case/export.json \
  --ciphertext /secure/case/report.ciphertext \
  --private-key /secure/key/moderation-v1.raw \
  --output /secure/case/review.jpg \
  --audit-log /secure/audit/moderation.jsonl
```

Download済み暗号文を成功直後に消す場合だけ、次を追加する。

```text
--delete-ciphertext-after-success
```

Toolは出力前に次をfail-closedで確認する。

- Manifestのexact schema、protocol/domain/algorithm/key ID、opaque ID、reason
- File sizeとmanifest size、base64url SHA-256
- binary plistのobject数、offset、reference、depth、型、exact envelope field
- 32-byte X25519 ephemeral public keyとprivate key
- Swiftと同じUInt32 big-endian length-prefix AAD
- AADのSHA-256をsaltにしたHKDF-SHA256、同じ`sharedInfo`
- CryptoKit `ChaChaPoly.combined`互換の12-byte nonce、ciphertext、16-byte tag
- 復号本文のprotocol、moment、reporter、reasonがmanifestと一致すること
- JPEGが上限内、長辺2,048px以下、8-bit三成分で、marker streamが完結し、APP0〜APP15とCOMが
  一切ないこと（EXIF、GPS、TIFF、IPTC、ICC、comment等のmetadata containerを拒否）

成功時には`review.jpg`と同時にowner-onlyの`review.jpg.receipt`を作る。Receiptはreport IDの
一方向hash、暗号文hash、JPEGのsize/hashを結び付ける短期local削除証明であり、画像や鍵を含まない。
別caseのreceiptを流用しない。Review JPEGを消すまで同じ隔離directoryに置き、その後一緒に消す。
ToolはreceiptをfsyncしてからJPEGを作る。異常終了でreceiptだけが残りJPEGがない状態は、JPEG作成前の
停止と、JPEG削除後・receipt削除前の停止を区別できない。Toolは自動再開とJPEG再生成を拒否する。
JPEGが存在しないこと、`local_plaintext_deletion_started`の有無、case判断を二人で照合してincidentへ
記録し、receiptは画像ではないcase metadataとして削除する。再度の復号が必要なら別の明示承認と新しい
作業directoryで開始し、既存receiptを上書き・流用しない。receiptだけをJPEGの存在証明にもしない。

Toolは鍵、復号plist、JPEG bytes、撮影日時、moment/reporter ID、output pathをconsoleまたはauditへ
出さない。Auditは時刻、event、key ID、ciphertext hash、report IDの一方向hashだけを記録する。
POSIX outputは新規file・mode `0600`で作られる。WindowsではNodeのmodeだけでACLを保証できないため、
事前に専用directoryのACLを確認する。

失敗時はoutputを開かず、再試行で迂回しない。次のいずれかとしてcaseへ記録する。

- `descriptor mismatch`: export bundleの取り違えまたは破損
- `authentication failed`: 誤鍵、AAD取り違え、改ざん
- `protocol/key unsupported`: client/server/key rotation不一致
- `privacy validation failed`: canonical化違反または破損JPEG

同じ失敗が別downloadでも再現する場合は鍵incidentまたはprotocol incidentへ上げる。

## 人手確認と判断

1. Review outputを専用local viewerで一度だけ開き、caseのreasonに必要な範囲だけ確認する。
2. `no_action`、`warning`、`block`、`account_removal`、`safety_or_legal_escalation`のいずれかを
   case managementへ記録する。画像、thumbnail、撮影日時、個人名をcaseへ添付しない。
3. 二人確認が必要な重大措置は、second reviewerへ画像を送らず、同じ隔離端末で確認してもらう。
4. Reporterへの返答はcase referenceと一般的な結果だけにし、相手のID、画像、内部判定ruleを返さない。
   Accused userへの連絡も必要最小限とし、reporterを特定できる情報を含めない。
5. 誤通報と判断しても報復を許さず、繰り返し濫用は別のabuse caseとして扱う。

現行Workerにはoperator decision/close/user-response APIがない。判断をServerへ反映してcontentを
早期削除する経路、appeal/status通知、operator access auditもProduction開始前のblockerである。

現行ToolのJPEG確認はbounded marker walkerであり、OS decoderでの実decodeや再encodeまでは行わない。
改造client由来のhostile decoder inputをviewerへ渡さないため、Production開始前に、更新済みの隔離
viewerとsandboxed decode→metadata-free canonical re-encode gateを実装し、undecodable/decoder攻撃fixtureを
通すこともblockerとする。それまでは本人所有2台のsource stagingで、正規Appが生成した合成写真だけを
対象にし、第三者から受けたreportを復号しない。

## Local evidenceの削除

判断記録が保存された直後にplaintext JPEGを消す。保持理由が承認されていない限りshiftをまたいで
local copyを残さない。

```sh
node scripts/moderation-report-tool.mjs delete \
  --metadata /secure/case/export.json \
  --file /secure/case/review.jpg \
  --kind plaintext \
  --receipt /secure/case/review.jpg.receipt \
  --audit-log /secure/audit/moderation.jsonl \
  --confirm-delete
```

Toolはplaintextをmanifest・receipt・JPEGの一致で、ciphertextをmanifestのsize・SHA-256で再照合し、
一致したartifactだけを削除する。Private keyや別caseのfileなど、上限内のregular fileであっても
descriptorが一致しなければ削除しない。必要なら同じcommandで`--kind ciphertext`としてdownload済み
暗号文も消す（ciphertextには`--receipt`を指定しない）。その後、manifestと
作業directoryを削除し、鍵の作業copyをapproved key procedureで閉じる。Private keyをToolの
汎用delete commandへ渡さない。鍵廃棄は鍵台帳と二人承認を伴う別手順にする。
7日のcontent windowを過ぎると新しい復号は拒否するが、既存local artifactの削除は期限後も同じ
manifest・receiptによる照合を保ったまま実行できる。

削除前に`local_*_deletion_started`をfsyncする。このauditを書けなければartifactは削除しない。
削除後のcompletion eventが書けない場合でも、started eventが「削除を試みた」回復境界として残る。
その場合はfileの存在を確認し、存在すれば同じcommandを再実行し、存在しなければaudit incidentとして
completionを復旧する。画像を再作成して証跡を合わせようとしない。
POSIXではToolが新規audit fileの親directoryと、unlink後のartifact親directoryもfsyncしてから次へ進む。
Node/Windowsには同等のdirectory fsync APIがないため、Windows運用はlocal NTFS、BitLocker、安定電源、
cloud同期・filesystem snapshotなしを必須とし、異常終了後はstarted eventと実fileの存在を突き合わせる。

この削除はfilesystemのunlinkであり、SSD、snapshot、cloud sync済みcopyのsecure eraseを保証しない。
そのため最初から暗号化・非同期・snapshotなしのvolumeを使用し、volume鍵の破棄を最終消去境界にする。
Audit JSONLは画像を含まないため、security audit retention policyに従って保持する。Toolは既存logの
各行と末尾改行を検証し、4 MiBを上限として追記する。上限へ近づく前にsizeを監視し、削除commandが
動いていないことを二人で確認してrotationする。現在logをfsync済みのowner-only archiveとして同じ
暗号化volumeへ閉じ、SHA-256・対象期間・保管期限をcase台帳へ記録した後、未作成の新しいlog pathを
次の作業に使う。実行中のlogをtruncate・差し替え・共有folderへ移動しない。

## Kill switchと障害対応

通常写真共有の安全性が疑わしい一方で安全窓口を維持できる場合は、media-only OFFで通常写真・ハート・
まど名・APNsを止め、report-ingestion、block、cleanupを残す候補を使う。先に
[`STAGING.md`の一般配布候補config手順](STAGING.md#一般配布候補の独立停止config生成検証のみ)を完了する。

```powershell
npm run staging:runtime:media-off
```

通報鍵、受付、復号、
削除、担当体制のいずれかが利用不能なら、通常共有とは独立した
`REPORT_INGESTION_RUNTIME_ENABLED=NO`へ戻す。このflagはexact `YES`のときだけ新しい通報の
reserve、暗号文upload、commitを許し、それ以外では、有効で現在も権限を持つ署名済み通報requestを
検証してnonceを消費した後に
`503 report_ingestion_runtime_disabled`で停止する。block、共有解除、TTL cleanup、既存暗号文の削除は
OFF中も継続する。不正署名は`401`、閉じたreport-only window等は既存契約どおりのerrorとなり、すべてが
503へ到達するわけではない。

まず外部変更を行わないdry-runを実行する。

```powershell
npm run staging:runtime:report-ingestion-off
```

`--confirm-media-only-off`と`--confirm-report-ingestion-only-off`は、local dry-run後に意図的に失敗し、
deployしない。通常のWrangler deployではactive versionへの原子的な条件を付けられず、選択したflag以外の
code／binding／Cronまで置き換え得るためである。review済みON/OFF version IDを事前固定し、条件付き切替を
検証する仕組みが完成するまで、実停止は一般公開のblockerである。広いOFFを含むrepository内の外部deploy
経路も廃止済みなので、本人2台のpersonal stagingでもdry-runを停止とみなさず、利用を中断して承認済み
incident responseへescalateする。鍵漏えい、紛失、backup不一致が疑われる場合は次を行う。

1. 通常写真共有を即時OFFにし、Primary/backupの鍵使用を停止する。
2. Audit/case IDだけを保存し、鍵や復号画像をincident channelへ貼らない。
3. 影響期間、使用者、export履歴、local artifact削除状態を確認する。
4. 新しいkey ID/public key、Server allow-list、client configを一体でrotateする。旧keyで暗号化された
   未処理reportをどう閉じるかをprivacy/legal責任者が決めるまで、推測で復号または再暗号化しない。
5. 原因とrotation後のacceptance windowをreviewし、別の承認済み変更で受付を再開する。

## Production開始前に残るblocker

- Production X25519鍵の承認済み生成、二人管理backup、rotation、廃棄（このrepositoryには置かない）
- Committed reportだけをprivate R2から取得し、同じD1 snapshotのexact manifestを返す、強いoperator認証・
  二人承認・rate limit・access audit付きremote export API
- Operator decision、user response、appeal、早期content deletionを記録するadmin workflow
- 事前固定したreview済みversion IDとactive version条件を使う原子的な選択的OFF、対象productionでの実停止訓練、鍵ID rotation中の明確なacceptance window
- Offline端末のWindows ACL/POSIX permission、encrypted volume、backup除外を確認する実運用drill
- Productionに近いSwift生成fixtureを使ったcross-platform compatibility試験。現在の自動試験は同じ
  field順、binary plist、X25519/HKDF/AAD/ChaCha combinedを再現する合成fixtureで、秘密鍵はtest内だけにある

これらが完了し、48時間SLAを実際の担当者で満たす訓練に合格するまで、写真共有のProduction flagを
有効化しない。
