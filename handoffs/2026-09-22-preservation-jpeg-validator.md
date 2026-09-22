# 写真保管：実JPEG検証の独立バッチ

## 目的と範囲

利用者の「すすめて」を受け、[進行の正本](2026-09-22-preservation-parallel-plan.md)にある次工程を実装する。

最新main `1eddd77` を確認し、`C:/dev/neko-preservation-jpeg-validator-20260922` / `codex/preservation-jpeg-validator-20260922` を分離。既存の個人保管アプリ接続・共有アルバム・CloudKit・課金・本線担当の途中作業を編集しない。

今回の完了条件は、実JPEGを最後まで読むprovider、破損/偽装/資源上限の対象試験、既存adapterとのローカル契約照合、独立レビュー、接続と配備の未確認条件の記録。保管サービス全体の本線取り込み・有効化、新しい有料契約、移行、TestFlight配布は行わない。

## 判断

アプリは `PersonalArchiveImage.maximumPixelSize=4096` / `maximumBytes=20MiB` の向き変換済み閲覧用コピーを生成する。providerもこの上限を守る。原本の全解像度・動画・Live Photosの保管を追加したと説明しない。

Node / sharp 0.35.4 による全画素デコードを独立させた。単に拡張子やmetadataを読む検査ではない。返答は既存provider契約どおりで、写真を書き換えずSHAを保持する。OFFが既定値。

Node native addon のため、Cloudflare Workersのservice bindingへそのまま配置できない。非公開のNode実行基盤/橋渡し、cgroup資源上限、秘密やownerを渡さない経路は本稼働前に別途確認する。基盤採用・契約を先決めしていない。

## 費用と確認方法

追加した部品だけの型検査・Nodeテスト・実adapter照合を優先。iOS/PBX/UI変更なしなので、無関係なMac一式を念のため起動しない。既存のCI選択を勝手に緩めず、push前にpreflightが全件を要求する場合は独立候補として保持し、後続の保管backend統合とまとめて扱う。

依存導入は初回4秒、11 packages・audit指摘0。初回型検査はNode型のIPC callbackとWindows非表示指定で2件失敗し、callback引数を明示・hidden spawnへ修正。最初の対象試験は19件成功、実行4.51秒（build込み約7.47秒）。未配備環境のcold start・運用原価や一般的な性能保証ではない。

## 結果

- 独立レビューで、ready streamの大量空chunkがbyte上限とタイマーを迂回する問題を再現（有限500万chunkで2秒設定を超え2.875秒）。全chunk数4,096上限・空chunk非保持・ループ内実時刻期限・64chunkごとのyieldへ修正。影響する受信境界4件が0.77秒で成功。
- もう1点、未知のnative例外を写真破損として返す分類を修正。既知libjpeg破損診断だけfalseへ、EIO・TypeError・不明/混在診断は503へ。追加分類と影響するdecoder13件が2.80秒で成功。修正差分の独立再レビューで残るブロッカーなし。
- 対象テストは合計21件。初回成功19件のうち入力・依存が変わらない確認は保持し、上記変更の対象だけ再実行した。すべてを一度の最終runで再実行したという意味ではない。
- 実 `PreservationService/src/providers.ts` との別実行の契約照合6件は初回成功。変換・清掃込み1.397秒。分類修正後の再確認も6件成功、runner1.301秒/変換清掃込み1.432秒。正常true、切断false、OFF/キャンセル/過負荷503、同一入力の復旧、元TS3ファイル非改変を確認。外部fetchなし、実D1/R2保存なし。
- 型検査成功、依存auditは対象packageで指摘0（2026-09-22）。誤ってrootから起動したauditはlockfile不在で失敗し、成功へ算入していない。NodeのMockTimers実験的警告はタイマーテスト由来。
- 新規部品の完了条件は達成。実Apple・KMS・実保存先・実2台復元、OS総メモリ上限、非公開ネットワーク配備は未確認。本番有効化・課金開始・TestFlight配布なし。

## 次の合流

製品候補は `128e2b2`、`NekoWidget/PreservationImageValidator/`。push前preflightは新規フォルダーを未対応として `full-v1` / 過去64.43〜97.92分、既定30分を超えるため `ready:false` と判定した。新規CIを起動せず、製品はこの独立ローカル候補に保持。Macの成功証拠やmain反映済みと扱わない。CI選択の変更や診断branchへの迂回pushもしていない。

繰り返し保留だけにしないため、backend統合時には非公開providerのNode/Linux対象CIとiOS入力分離を独立レビューして整える。既存iOS入力に影響しないことを確認したうえで対象試験を必須にし、unknownな変更のfail-closedは残す。今回はそのCI変更をJPEG部品へ混ぜない。

保管backendの旧候補 `863ad16` と合わせて、非公開実行基盤・本人/鍵/会員接続・容量/保持/削除の未完ゲートへ進める。アプリの既定OFFは維持。別担当へ転送する操作を利用者へ求めず、主担当が候補と結果を保持する。
