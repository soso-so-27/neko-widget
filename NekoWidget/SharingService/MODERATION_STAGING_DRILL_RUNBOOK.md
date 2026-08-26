# staging通報鍵の合成復号・削除drill runbook

この手順は、本人所有2台だけのstaging用`moderation-v1`鍵pairが、Swift互換の合成通報を
暗号化・復号でき、human review後にplaintext、receipt、ciphertextをdescriptor-boundで削除できることを
確認するoffline drillである。Production鍵、第三者の写真、通常の家族共有写真には使用しない。

このdrillが完了してもProduction運用の承認にはならない。全手順中、次をexactに維持する。

- `MOMENT_RUNTIME_ENABLED=NO`
- `LEGACY_SHARING_RUNTIME_ENABLED=NO`
- clientの`SHARING_MEDIA_ENABLED=NO`
- TestFlight upload、Worker deploy、runtime切替、network送信を行わない

## 停止条件

次のいずれかなら開始しない。

- `C:`がfixed local NTFSではない、BitLockerが`FullyEncrypted`／Protection `On`／100%／Unlockedでない
- Windows PowerShellを「管理者として実行」していない
- 鍵directoryが鍵生成runbookの成功品でない、ACLを変更した、fileを移動した、または再インストール後である
- browser、mail、messenger、clipboard history、screen recording、OneDrive等のcloud同期を停止できない
- 新規drill directoryをrepository、worktree、TEMP、user profile、sync root外に作れない
- human operatorが復号画像をその場で一度確認し、直後に削除まで完了できない

鍵directoryとdrill directoryは別の新規directoryにする。既存directory、`C:\secure`のように
未確認ACLを持つparent、8.3 alias、junction、symlink、UNC、device path、ADSは使わない。
鍵fileを開く、Base64化する、copyする、chat／ticket／GitHub／Cloudflareへ貼ることは禁止する。

## 1. 公開鍵だけで合成bundleを作る

Networkを切断し、同期・browser・Codexを閉じる前に本手順を紙または承認済みoffline copyで用意する。
管理者Windows PowerShellでrepositoryの`NekoWidget\SharingService`へ移動し、次を一行で実行する。
`<...>`はoperatorが確認したabsolute pathへ置き換える。

```powershell
& .\scripts\moderation-staging-drill-windows.ps1 -KeyDirectory '<existing-restricted-staging-key-directory>' -OutputDirectory '<absolute-new-restricted-drill-directory>' -ConfirmLocalEncryptedNoSync
```

Wrapperは最初に次をfail-closedで検証する。

- 管理者、fixed local NTFS、BitLocker full／On／100%／Unlocked
- 鍵directory、公開鍵file、秘密鍵fileのfixed name／size／single-link／属性／exact protected ACL
- 全ancestorのowner／replacement rights、canonical実体path、repository／profile／TEMP／sync除外
- 新規かつ別のdrill directoryとexact restricted ACL

Windows検証は秘密鍵fileの**内容を読み取らず**、固定名、32-byte size、file identity、link count、属性、ACLだけを
確認する。Node generatorへ渡すのは固定の公開鍵file pathだけで、Node generatorが内容を開くのも
`moderation-v1.public.base64url`だけである。Private-key option、stdin、environment、network入力は存在しない。

Generatorは固定の合成1x1 RGB JPEG、固定opaque fixture ID、`privacy` reason、現在の7日windowだけを使う。
撮影写真、thumbnail、EXIF、GPS、comment、ICC等を入力できない。毎回fresh ephemeral X25519 keyと12-byte nonceを
作り、Swiftと同じlength-prefixed AAD、HKDF-SHA256、ChaChaPoly combined、binary plist envelopeを生成する。

成功時のdrill directoryは次の2fileだけである。値やpathはconsoleへ表示しない。

| file | 内容 |
|---|---|
| `synthetic-export.json` | fixed synthetic descriptor、current 7-day window、ciphertext size/hash |
| `synthetic-report.ciphertext` | Swift-compatible binary plist ciphertext envelope |

どちらも`O_EXCL`、fsync、readback/hash、file identity、single-link、exact ACLを確認する。既存fileを上書きせず、
partial failureを自動再開しない。

## 2. 明示的な秘密鍵使用境界で復号する

ここからはhuman operator自身が既存のoffline moderation toolを使う境界であり、秘密鍵fileが初めて読まれる。
Codex、remote support、screen share中の担当者に実行させず、鍵値、画像、console screenshotを共有しない。

同じoffline・管理者Windows PowerShellで次を一行で実行する。

```powershell
& .\scripts\moderation-staging-drill-review-windows.ps1 -Mode DecryptForHumanReview -KeyDirectory '<existing-restricted-staging-key-directory>' -DrillDirectory '<restricted-drill-directory>' -ConfirmLocalEncryptedNoSync -ConfirmSyntheticStagingOnly
```

Wrapperは鍵directoryと2-file bundleを再検証し、既存
Toolへ秘密鍵pathを渡す**前**に、manifestがfixed synthetic ID／`privacy`／`moderation-v1`／current windowであり、
ciphertext size/hashと一致することをsemantic検証する。Fixed name／size／ACLだけではsyntheticと判定しない。
その後に既存
`scripts/moderation-report-tool.mjs decrypt`へ固定pathだけを渡す。Toolはmanifest、hash、retention、binary plist、
X25519/HKDF/AAD/ChaCha authentication、inner identity、metadata-free JPEGを検証する。成功後に次を作り、
全fileをexact ACLへhardeningする。Humanへ成功を表示する前に、review JPEGがfixed synthetic fixtureとbyte-exact、
receiptがそのJPEGとdescriptorへbinding済み、auditがexact `decrypt_succeeded` 1件だけであることを再検証する。

- `synthetic-review.jpg`
- `synthetic-review.jpg.receipt`
- `synthetic-audit.jsonl`

このcommandはviewerを開かず、削除もしない。ここで一度停止する。

## 3. human view boundary

1. Networkと同期が切れたままか再確認する。
2. `synthetic-review.jpg`だけを更新済みのlocal viewerで一度開く。
3. 1x1の固定色合成画像として表示・decodeできることだけを確認する。
4. Screenshot、copy、thumbnail export、mail、chat添付を行わずviewerを閉じる。
5. 「合成fixtureを表示できた」ことだけを画像なしのdrill台帳へ記録する。

表示不能、別画像、warning、予期しないmetadata表示なら削除commandへ進まず、directoryをrestrictedのまま隔離し、
二人でprotocol／viewer incidentとして扱う。Private keyやJPEGを調査channelへ貼らない。

## 4. plaintext、receipt、ciphertextをdescriptor-boundで削除する

Human view完了後だけ、次を一行で実行する。

```powershell
& .\scripts\moderation-staging-drill-review-windows.ps1 -Mode DeleteAfterHumanReview -DrillDirectory '<restricted-drill-directory>' -ConfirmLocalEncryptedNoSync -ConfirmHumanReviewCompleteAndDelete
```

Wrapperは既存Toolの`delete`を二回使う。

1. Manifest、receipt、JPEG size/hashの一致を確認し、`local_plaintext_deletion_started`をfsyncしてから
   JPEGとreceiptを削除し、`local_plaintext_deleted`をfsyncする。
2. Manifest、ciphertext size/hashの一致を確認し、`local_ciphertext_deletion_started`をfsyncしてから
   ciphertextを削除し、`local_ciphertext_deleted`をfsyncする。

成功を表示するのは、directoryに`synthetic-export.json`と`synthetic-audit.jsonl`だけが残り、review JPEG、receipt、
ciphertextが存在せず、auditが次のexact順序・同一descriptor identityであることを再検証した後だけである。

1. `decrypt_succeeded`
2. `local_plaintext_deletion_started`
3. `local_plaintext_deleted`
4. `local_ciphertext_deletion_started`
5. `local_ciphertext_deleted`

残るmetadataとauditは画像や鍵を含まないdrill evidenceである。承認済みsecurity audit retentionに従い、
同じ暗号化local volume上で保持または二人承認で閉じる。汎用delete commandへ秘密鍵を渡さない。

## 中断・失敗時

Wrapperは既存outputの上書き、自動resume、推測削除を拒否する。電源断や削除途中の失敗では、restricted directoryを
そのまま隔離し、auditの`*_deletion_started`と実fileの存在を二人で照合する。新しい画像を作って証跡を合わせない。
同じdirectory名で最初からやり直さず、incident記録後に新しい未使用directoryで再実施する。

Node/Windowsはdirectory fsyncをPOSIXと同等には保証しない。Local NTFS、BitLocker、安定電源、同期／snapshotなしを
前提にし、異常終了後は必ずauditとfile存在を照合する。SSD unlinkはsecure eraseではないため、BitLocker volume境界を
維持する。

## このdrill後も残るblocker

- Production鍵の二人管理backup、rotation、廃棄
- 強いoperator認証、二人承認、rate limit、access audit付きremote export API
- decision、appeal、早期content deletion workflow
- 独立report-ingestionのflag／candidate／local dry-runは実装済み。残るのは事前固定versionとactive-version条件を使う実停止、production訓練
- hostile image用sandboxed decode→canonical re-encode gate

これらが未完了のため、このrunbookやdrill成功を根拠にProduction、写真runtime、TestFlight media uploadを有効にしない。
