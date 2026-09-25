# 個人保管：期限消去claimの候補（未提供）

2026-09-25。`0017_purge_execution_claims.sql`は、期限fenceの後で「中止」と「消去」を同時に進めないためのD1作業台帳だけを追加する。S3で読戻したprepared eventのD1参照と無効化済みownerがないclaimは拒否。claim後は期限切れleaseの自動解除とpre-deletion手動解除を禁止する。terminal stateは対応する外部event参照を要求するが、D1参照だけではS3の全版・実物理消去を証明しない。

専用staging D1でowner/record/purge eventが各0件と確認し、0017前Time Travel bookmark `0000000f-00000000-000050f1-c1135282faa0e3e8bb2e3a36f8de8f8c` を取得。0017の遠隔適用は7文成功。適用後もowner/record/purge event/claimは各0件、claim triggerは4件。公開Worker、R2、AWS、実利用者データは変更していない。合成D1のclaim遷移とfence解除拒否テストは成功した。

残るのは、外部S3全版replayとclaimの接続、S3 intentを持ったpolicy ONのfence、物理削除と全保存先の再一覧、35日以内の識別子掃除、古いD1 bookmarkからの隔離復旧である。この移行をサービス開始やデータ削除の証拠としない。`PRESERVATION_ENABLED`、期限消去ともOFFのまま。

後続の合成部品`owner-purge-abort.ts`では、全版replayを中止claimの前後に行い、aborted eventがS3とD1で読めるまでownerをdisabledのまま維持する。S3成功・D1 claim未完の再試行、S3失敗、D1から見えないerasing eventを試験した。これは**中止の記録まで**であり、本人の利用再開・policy ONのfence・物理消去を有効化していない。

### v12候補のCI投入前記録

- 最初の製品候補は2026-09-25 18:38:33 JSTの`3196965`。以後の調整も初回からの経過時間に含める。
- 変更挙動は、D1の排他的中止/消去claim、外部S3全版での段階確認、pre-deletion中止eventの安全な記録。owner再開・物理消去・公開APIには接続しない。
- 直接証拠は、空の専用staging D1への0017適用（owner/record/event/claim各0、claim trigger 4）、合成サービス216テストと型検査の成功、Cloudflare非公開staging R2のCLIおよびremote binding合成往復と0件への復帰。実S3/KMS、実JPEG、実Apple/購入/別端末、12か月持ち出しと35日後の削除は未検証。
- 保管専用Node job一つを候補CIで確認する。v12のjob timeoutは5分で、待ち時間と初回からの総所要時間の保証ではない。iPhone全件CIは今回の変更の初回検査にしない。並行するTestFlight配布から本線push停止の連絡があり、解除までmainは更新しない。
