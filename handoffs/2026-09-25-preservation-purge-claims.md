# 個人保管：期限消去claimの候補（未提供）

2026-09-25。`0017_purge_execution_claims.sql`は、期限fenceの後で「中止」と「消去」を同時に進めないためのD1作業台帳だけを追加する。S3で読戻したprepared eventのD1参照と無効化済みownerがないclaimは拒否。claim後は期限切れleaseの自動解除とpre-deletion手動解除を禁止する。terminal stateは対応する外部event参照を要求するが、D1参照だけではS3の全版・実物理消去を証明しない。

専用staging D1でowner/record/purge eventが各0件と確認し、0017前Time Travel bookmark `0000000f-00000000-000050f1-c1135282faa0e3e8bb2e3a36f8de8f8c` を取得。0017の遠隔適用は7文成功。適用後もowner/record/purge event/claimは各0件、claim triggerは4件。公開Worker、R2、AWS、実利用者データは変更していない。合成D1のclaim遷移とfence解除拒否テストは成功した。

残るのは、外部S3全版replayとclaimの接続、S3 intentを持ったpolicy ONのfence、物理削除と全保存先の再一覧、35日以内の識別子掃除、古いD1 bookmarkからの隔離復旧である。この移行をサービス開始やデータ削除の証拠としない。`PRESERVATION_ENABLED`、期限消去ともOFFのまま。

後続の合成部品`owner-purge-abort.ts`では、全版replayを中止claimの前後に行い、aborted eventがS3とD1で読めるまでownerをdisabledのまま維持する。S3成功・D1 claim未完の再試行、S3失敗、D1から見えないerasing eventを試験した。これは**中止の記録まで**であり、本人の利用再開・policy ONのfence・物理消去を有効化していない。

独立レビューで、D1 Time Travel後にS3のerasing eventだけが残る場合、旧スケジューラのD1-only期限切れfence解除が写真欠損ownerを再開し得ると判明した。候補v13ではスケジューラの自動解除と公開のD1-only解除メソッドを削除し、S3再生を行う専用の復帰経路ができるまでdisabledを維持する。古い期限通知でclaimしないよう、確認関数とD1 triggerの両方で10分leaseを要求する。0017はstaging適用済みのため改変せず、専用staging D1へ0018でtriggerを置換した。0018前bookmark `00000011-00000000-000050f1-d6f2f8603c8830ce3f411122dfc1238e`、適用後はowner/record/event/claim各0、lease guardのtrigger 1件。公開・実写真は変更なし。

さらに、S3 abort成功後にD1が巻き戻った場合は、元のS3 event時刻でprepared/aborted参照とclaimを再調停する。新しい時刻でimmutable S3 eventを上書きしない。合成D1試験で確認したが、実S3 Time Travel演習・利用再開は未実施。

### v12候補のCI投入前記録

- 最初の製品候補は2026-09-25 18:38:33 JSTの`3196965`。以後の調整も初回からの経過時間に含める。
- 変更挙動は、D1の排他的中止/消去claim、外部S3全版での段階確認、pre-deletion中止eventの安全な記録。owner再開・物理消去・公開APIには接続しない。
- 直接証拠は、空の専用staging D1への0017適用（owner/record/event/claim各0、claim trigger 4）、合成サービス216テストと型検査の成功、Cloudflare非公開staging R2のCLIおよびremote binding合成往復と0件への復帰。実S3/KMS、実JPEG、実Apple/購入/別端末、12か月持ち出しと35日後の削除は未検証。
- 保管専用Node job一つを候補CIで確認する。v12のjob timeoutは5分で、待ち時間と初回からの総所要時間の保証ではない。iPhone全件CIは今回の変更の初回検査にしない。並行するTestFlight配布から本線push停止の連絡があり、解除までmainは更新しない。
- v13で上記3件の安全修正を加えた。対象4ファイル20試験、サービス全216試験、型検査、migration検証はローカルで成功。v13のCI・本線結果はまだ記入しない。
- v13候補`b8c8a3c`の保管Node CI `36124194099` は55.0秒で成功、iOS plan `36124194115`も成功しMacは起動していない。独立レビューで前回3点の解消を確認。初回製品候補からの累計時間をこの55秒へ置き換えない。
- 実R2/S3/KMSの合成写真→隔離復元で、検査用IAMが`purge/v1/*`の読取を許さず初回失敗。写真削除・秘密漏出ではなく、復元前の外部消去台帳確認がfail-closedで止まった。試験専用IAM policyにこのprefixのList/Getだけを追加し、再試験2件成功。S3全版・R2・一時IAM利用者の残存0を確認。変更した試験policyを含むv14候補CIは未検証。
- v14候補`ae4e84b`の保管Node CI `36125337267`は49秒で成功、iOS plan `36125337231`も成功、Macは対象外。AWSは利用者判断によりFree planのまま検証する。
- 後続の独立した実AWS合成検査で、`S3VersionPurge`の版指定DELETEが204と版IDを返し、owner prefixの再一覧が0件になることを確認。初回は後片付け用PowerShellの空配列判定だけが誤ってexit1（AWS直接一覧は空、一時IAMは0件）。判定修正後に同検査を再実行しexit0。独立レビューの指摘で、一時IAMの権限を毎回生成する合成object 1件へ限定し、key/policy/user削除失敗が成功扱いにならないよう再試行・一覧確認を追加した。再試験はexit0、一時IAM各資源の削除後確認と`recovery/v1/`全版・delete marker 0件を確認した。公開Workerにはこの削除権限を付けていない。これは単一合成版の削除だけであり、期限後の全写真・R2・D1の物理消去、S3外部event、35日内tombstone処理や通知を証明しない。
- v15候補の投入前記録（19:59 JST）：変更挙動は上記の合成probeと後片付けのfail-closedのみで、製品の公開・削除動作は不変。直接証拠は実S3版のPUT/GET→版指定DELETE→再一覧0件、全`recovery/v1/`版0件、一時IAMの削除確認、独立レビューで新たなP1/P2なし、PowerShell parse・TypeScript typecheck・CI選択71件/事前判定30件成功。未確認は実ownerの期限判定、複数版/R2/D1消去、通知、実iPhone、12か月耐久性。初回製品候補は18:38:33 JSTで、ここまで約81分。候補の必須CIは保管Node 1 job、過去の同jobは49〜55秒だがqueueを含む今回の所要時間は未確定。iOS planは判定のみ、Mac/配布なし。実行後もmainは並行TestFlight作業からの解除待ちで保留する。
- v15候補`aecb6d9`の保管Node CI `36127015207`は57秒、iOS plan `36127015291`は成功、Mac jobは対象外。追加のv16候補では同一の生成合成キーに旧データ版、通常DELETEで生じるdelete marker、新データ版を作り、全3版を`S3VersionPurge`で版指定削除し、owner prefixの再一覧を空と確認した。短命IAMの追加`DeleteObject`もそのキー1件のみ。実AWS試験exit0、key/policy/user消去とsynthetic prefix空を確認、独立レビューで新たなP1/P2なし。
- v16候補投入前記録（20:05 JST）：変更挙動は合成probeの3版検証だけ。公開Worker・実owner削除の挙動は不変。直接証拠は上記実S3、PowerShell parse、TypeScript typecheck。前候補のCI選択71件と事前判定30件の成功は、今回変更したCI scope文字列の検査には流用しない。未確認はR2/D1物理削除と再一覧、期限・通知・本人・12か月の持ち出し、35日識別子処理。初回製品候補18:38:33 JSTから約87分経過。候補の必須は保管Node 1 jobで前2回49〜57秒、queueは未確定。Mac/配布は対象外。本線は並行TestFlight作業からの解除待ち。
