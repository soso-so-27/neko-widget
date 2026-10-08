# 写真検査への送信メモリ削減

2026-10-09。共有・保管を含めて完成させる本線の一部。20MiB写真をJPEG検査providerへ送る際、写真全体のbase64文字列とJSON文字列を重ねて作る処理を、49,152byteずつ同じJSONへ変換して送る方式にした。公開容量・受付・料金・権限・期限・本人データを変更しない。

## 設計の直接確認と固定候補

- 変更前に、実workerd service bindingから実Node JPEG providerへ、Content-LengthなしのJSONストリームを送って受理されることを確認した。622byte人工JPEG、850byteのwire、200/valid=true。通信形式の確認であり最大サイズの証明ではない。
- 製品の変更は `PreservationService/src/providers.ts` のみ。固定private URL、redirect禁止、10秒timeout、4KiB応答上限、JPEG/frame判定を維持した。送信chunkは最大64KiB、先読みなし。元写真を変更せず、早期拒否・例外でも送信側参照を解放する。
- `photo-provider.test.ts` は0〜3byte、49,152byte境界、20MiBで独立したBuffer基準のwire全byte一致を確認。未読・reader保持中の503/throw、redirect、応答上限、JSON/画像結果の拒否も確認した。
- 既存実provider adapter試験は文字列専用観測をストリーム観測へ更新。失敗時は実際に消費したprefix、成功時は全byteを独立基準と比較し、再試行時の原写真digestも保持する。実デコーダーへの20MiB合法JPEG試験を追加した。合格条件を緩めていない。
- 独立レビューでP1/P2なし。reader保持中の早期応答を直接観測する不足を指摘され、4件目のunit試験を追加・成功した。

## 保存する検証結果

- Service型検査成功。provider/storage/membership-linksの58件成功7.87秒。その後追加したreader保持試験を含むprovider4件成功3.96秒。残る成功入力は不変。
- 実JPEG provider adapter7件成功2.886秒。最大20MiBは1.36秒。これはローカルNode接続での結果。
- 同じ20MiB人工JPEGを使う実route/body/ArchiveStore/暗号化/local R2/D1経路の1回保存は200、写真20,971,520byte、revision1。送信途中checkpointのJS heap最大観測は約89MiB（旧方式約163MiB）、比較用合算は約164MiB（旧約238MiB）。検査時のGC・nativeメモリは本番ピークと同じではない。
- **全経路の本番128MiB適合は未証明**。このcheckpointのJPEG応答は別isolateのstub、KMSも合成で、S3復旧経路は含まない。入口の64KiB集約はprobe側だけで、製品のchunk上限は変更していない。入口JSON、暗号化/復旧、実環境の断片化・CPUが次の未確認範囲。

## CIと時間の計画

最初の候補作業は2026-10-08 22:59:07 UTC（10/9 07:59:07 JST）。設計観測・ローカル試験・独立レビュー・厳密なCI選択追加・backend CIまで45〜75分を計画した。新scopeのCI時間は未計測、旧バッチの32分39秒を今回の短縮実績にしない。

CI制御を別候補で先行させ、製品3パスの正確なbefore/after・通常mode・両owning workflow不変を要求する。必要なCIはServiceとJPEG providerの既存2jobとiOSのplan。Mac/Widget/Gallery/追加TestFlightは対象外。この記録時点ではCI・main反映・内部配備は未完。

証拠は `C:/dev/neko-evidence/launch-readiness-20261008/provider-stream-plan.json`、`provider-stream-contract-probe.json`、`provider-stream-checkpoint/result.json`。通常月費用は[完成方針](2026-10-09-public-launch-proposal.md)に分離して記録。未計測費用を0円や予算超過へ読み替えない。
