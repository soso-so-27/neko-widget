# staging通報鍵のオフライン生成runbook

このrunbookは、本人所有2台だけの`media-staging`で使うX25519通報鍵を、同期対象外の
BitLockerで完全暗号化されたWindows local NTFS volumeへ一度だけ生成するためのものです。
実運用helperはWindows専用であり、Production鍵の生成手順ではありません。
この手順はCloudflare deploy、GitHub Environment変更、TestFlight署名／upload、runtime flag変更を
一切行いません。`MOMENT_RUNTIME_ENABLED`と`LEGACY_SHARING_RUNTIME_ENABLED`は`NO`のままです。

## 実行前の停止条件

次の全てを人が確認できない場合は実行しません。

- Node.js 22以上を使う。
- WindowsのBitLocker画面が「暗号化中」ではなく「BitLockerが有効です」になっている。
- 出力先は固定local NTFS volume上で、OneDrive、Dropbox、iCloud、Google Drive、Boxなどの
  同期、backup、snapshot、検索indexの対象外である。
- 出力先はrepository、worktree、現在の作業directory、`TEMP`、ユーザープロファイルの外にある。
- 出力directoryはまだ存在せず、親directoryだけが存在する。
- Screen sharing、録画、clipboard履歴、mail／messenger、cloud同期clientを閉じる。

Helperは標準的な同期provider名と環境変数を拒否しますが、任意に設定された同期、backup、
snapshotの全製品を検出できるとは主張しません。`--confirm-local-encrypted-nosync`または
`-ConfirmLocalEncryptedNoSync`は、自動判定の迂回optionではなく、担当者が出力先を確認したという
明示的なceremony記録です。確認できない場合に指定してはいけません。

## Windowsでの実行

BitLocker完了後、管理者PowerShellで`NekoWidget/SharingService`へ移動します。安全な親directoryは
先に作成して構いませんが、最後の鍵directoryは作りません。次は名前の例であり、実行日と台帳に
合わせた未使用のdirectory名を使います。

既存の`C:\secure`などが`Authenticated Users`のModifyまたは継承write ACEを持つ場合、wrapperは
正しく停止します。検査を弱めず、親directoryの作成・ACL安全化・再確認を別の承認済み作業として
完了してからceremonyへ進みます。

```powershell
node --version
& .\scripts\moderation-staging-keygen-windows.ps1 `
  -OutputDirectory 'C:\secure\neko-widget-moderation-staging-20260822' `
  -ConfirmLocalEncryptedNoSync
```

Windows wrapperは鍵生成前に次をfail closedで確認します。

- 絶対local drive pathであり、UNC、device、extended path、ADS、symlink、junction、reparse、
  offline pathではない。
- Current directory、repository、`TEMP`、profile、存在するprovider環境変数rootと出力親を
  `realpathSync.native`で解決してから比較し、8.3 short nameやjunction／symlink alias、解決不能な
  provider rootをfail closedにする。
- Volumeが`Fixed`かつ`NTFS`である。
- `Get-BitLockerVolume`が`FullyEncrypted`、Protection `On`、100%、`Unlocked`を返す。
- 既知cloud-sync rootではなく、担当者がcustom sync／backup／snapshot対象外と明示確認した。
- 新規directoryの継承を切り、現在のuser、`SYSTEM`、Builtin AdministratorsだけへFull Controlを許可し、
  ownerとACLをSIDで再読して一致を証明できる。
- 親だけでなくdrive rootまでの全ancestorでownerが現在user、`SYSTEM`、Builtin Administrators、
  TrustedInstallerのいずれかであり、未知principalがpath componentを`DELETE`、`WRITE_DAC`、
  `WRITE_OWNER`できず、その親で`DELETE_CHILD`できない。上位ancestorの作成専用ACEは許容するが、
  直近親では出力directoryの先取りを防ぐため`CreateDirectories`、`CreateFiles`、`Write`も拒否する。

Wrapperは静的PowerShell/.NET APIと引数配列だけを使い、command文字列を組み立てて
`Invoke-Expression`や`cmd /c`へ渡しません。BitLocker cmdletの不足、権限不足、読取不能、想定外の
状態は全て生成前に停止します。`--skip-bitlocker`や`--force`はありません。
Node helperも同じ静的security scriptを鍵生成直前に独立して再実行し、書込後は両fileの継承を切って
exact ACLを再検証してから成功にします。環境変数や追加CLI markerをpreflightの証明として信頼しません。

## 非Windowsでは実行しない

POSIX向けの実運用ceremonyはありません。Node helperを直接実行しても、directory準備や鍵生成より前に
fail closedします。Linux CIで動くlow-level file testは固定の合成鍵と使い捨てdirectoryだけを使う
unit testであり、POSIXで実鍵を生成できるという運用保証ではありません。

## 固定出力と検証境界

利用者がfilename、key ID、private valueを引数、環境変数、標準入力で指定する機能はありません。
出力は新規directory内の次の2fileだけです。

| File | 内容 |
|---|---|
| `moderation-v1.private.raw` | X25519 raw private key、exact 32 bytes |
| `moderation-v1.public.base64url` | X25519 raw public keyのcanonical base64url、exact 43 ASCII bytes、改行なし |

Windows wrapperから呼ばれたhelperはNode/OpenSSLの`generateKeyPairSync('x25519')`で生成し、PKCS8 prefix
`302e020100300506032b656e04220420`とSPKI prefix `302a300506032b656e032100`をexact検査します。
Raw privateからpublicを再導出し、生成public、file readbackの3者が一致するまで成功にしません。
両filenameを`O_EXCL`で空予約してから鍵を生成し、publicをfsyncした後、privateを最後に書いてfsyncします。
Private DER、raw private、private readbackのBufferは全経路でzero fillします。KeyObject内のnative memoryは
Node/OpenSSLが管理するため、process終了を追加の境界とします。

Success／error consoleへ鍵、公開鍵、出力pathを表示しません。鍵値をargv、environment、audit、logへ
渡しません。公開鍵をGitHub Environmentへ登録する作業も、このceremonyとは別の承認作業です。

## 中断・失敗時

既存directoryや既存fileを上書きせず、自動再開もしません。通常の失敗では、同じprocessが作成した
固定fileをfile identityとlink countで照合して削除し、空なら新規directoryも削除します。電源断などで
zero-length placeholder、public-only、またはpartial directoryが残った場合、そのdirectoryを成功品として
使わず隔離します。Private fileやpublic fileの内容をconsoleで調べません。

担当者2人で、対象が今回指定したexact新規directoryであること、repository／profile／sync root外であること、
他fileがないことを確認してから、台帳に「失敗・未採用」と記録して削除します。既存directoryを消して同じ
名前で自動再実行せず、新しい未使用directory名でceremonyを最初から行います。

## 成功後

1. Directoryと両fileのACLをwrapperの終了結果で確認する。秘密鍵を開いたりBase64化しない。
2. `moderation-v1.private.raw`は隔離端末だけに保持し、GitHub、Cloudflare、repository、chat、ticket、
   password managerの自由記述欄へ置かない。
3. 封印・暗号化backup、二人承認、復元訓練、rotation／廃棄台帳は別の承認済み作業で用意する。
4. Public fileの43文字だけを`SHARING_STAGING_MODERATION_PUBLIC_KEY`へ登録する作業は、対象Environmentと
   `main`保護ruleを再確認した別の明示承認で行う。
5. 合成通報の復号・削除drillが成功するまで写真runtimeやTestFlight uploadを有効にしない。

CIの`check:moderation-keygen`は固定の合成鍵と使い捨てtest directoryだけを使います。Random X25519 pairの
試験はmemory内の導出一致だけで、鍵fileを永続化しません。CIがgreenでも実鍵生成、BitLocker、backup、
operator体制、Production準備を証明しません。

## Productionに残るblocker

Production鍵は本helperで作りません。[暗号化された写真通報のオフライン確認runbook](MODERATION_RUNBOOK.md)に
列挙した二人管理backup、rotation／廃棄、強いoperator認証付きexport API、decision／appeal／早期削除、
独立report-ingestion kill switch、実運用drillが全て未完了のままです。
