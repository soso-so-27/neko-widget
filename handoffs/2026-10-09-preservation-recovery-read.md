# 保管の復旧読戻しを改善・内部反映

2026-10-09。共有・保管を含めて完成させる方針を継続。S3の復旧用暗号文を読み戻す際、受信した全chunkと全量コピーを重ねて保持する処理を、検証済みの長さの専有bufferへ順次コピーする処理へ変更した。元chunkは変更・detachせず、32MiB上限、4096chunk、5秒、正しい保存version、SHA256、短い応答・余分な応答・EOFの確認を維持する。最初に領域を確保するため、遅い/不正な応答でもその間のメモリは先に確保される。コピーを読取期限内に行うので期限直前の受入れが以前と完全同一とは主張しない。

## 直接確認と限界

- 同じ20,971,805byte暗号文と321chunkで比較。通常観測では約42.24MBのbacking合計に改善が見えず、GCを止めた検査もtimeoutした。これらを成功扱いにせず、同じasync checkpointで同じ明示GCを用いて保持対象を比較した。
- 比較後の保持backingは42,237,618→21,260,677byte。差20,976,941byteは入力chunkのbacking全量に一致。余分な入力保持の解消を示すが、自然なGC時刻や本番の全体peak・resident memoryの削減は証明しない。
- 現候補の20MiB写真保存1回はlocal workerdでHTTP200・内容hash・保存version・復旧確定・最終owner ack・lease解放まで成功、3.554秒。合成のKMS/S3/JPEG/会員とlocal R2/D1、検証専用輸送を用いた証拠であり、実クラウドのCPU/輸送の測定ではない。
- Inspectorのused/embedder/backing参考合計は185.68MiBまで観測。本番resident peakの定義とは異なり、**全経路の本番128MiB適合は未証明**。実機の大量ZIPも未確認。

## 検証と反映

- 独立レビューP1/P2なし。typecheckと95件の関連テストが14.42秒で成功。新規10件は入力viewの不変、偽content-length、短い/壊れた応答、余分なbyte、cancel拒否、EOF未到達、4096/4097空chunk、source失敗、不正長・version拒否を扱う。
- [制御PR200](https://github.com/soso-so-27/neko-widget/pull/200)で固定2ファイルとworkflow blob/modeを扱う `preservation-recovery-read-v1` を先行登録。必須development-flow14項目232.5秒とpreflight、[control CI](https://github.com/soso-so-27/neko-widget/actions/runs/37866987396)37秒が成功。
- [製品PR201](https://github.com/soso-so-27/neko-widget/pull/201)の同候補 `7f54cc64fdfaedff2dcf7c66c891c644ca2cedc3` で[Service CI](https://github.com/soso-so-27/neko-widget/actions/runs/37867299776)が434 Vitest＋27運用検査・型検査・migration・bundle成功、94秒。[plan](https://github.com/soso-so-27/neko-widget/actions/runs/37867299750)40秒。ローカル成功とCI制御の入力同一を証明し、重複した一式検査は行っていない。
- 自動起動のPR Service37867303916も94秒成功。PR plan37867303951はskipで成功証拠に使わない。mainのService37867500524は95秒、plan37867500574は30秒で成功。手動再実行や追加native/Gallery/JPEG/TestFlightは0。
- main `aaf3eb60975b0f5c133ade16f46e29949a9023eb`へmerge commitで統合。10:00:40 JSTに既存private Worker `neko-preservation-staging-disabled` へ1回反映、version `bea8cb9f-b55e-4ffb-8dc9-5a45aeb8df08`。bundle SHA256 `676a122655952eba5630b6ce3e0c87f7d50d308b47a630c4010fc46df9746feb` の全文一致を確認。
- 全設定・secret参照・公開範囲・予定・schema135・migration33・pilot/intake期限・本人1名/記録1件/quota3,358,122byteを維持。配備前後のbundle差分はreader追加とその呼出しのみ。配備guard114境界と独立レビューを通した。JPEGは入力不変を照合して既存run37859139318の成功を保持。

開始09:35:12から内部反映まで25分29秒、最初の動作候補09:43:43から16分58秒。失敗した観測も含む。前のprovider候補07:59:07からは累計2時間1分34秒。並行CI時間を足して経過時間とは呼ばない。PR添付はこのチャットの100件上限で失敗したため、URLを本記録へ保存した。過去の添付や会話履歴は変更していない。

証拠rootは `C:/dev/neko-evidence/launch-readiness-20261009/`。`recovery-read/completion.json`、`s3-exact-read-probe/`、`s3-exact-read-gc-probe/`、`recovery-read-full-path/result.json`、`recovery-read-deployment/{bundle-review,completion}.json` に集約。

本人向けTestFlightは1.0(247)のまま。次は運営者登録の暗号学的確認を製品へ組み込み、caseに限った通報内容確認・判断/返答へつなげる。本番の保管memory/CPU、実機ZIP、提供条件とAWS無料期間後の継続、公開構成/ストア提出は残件。一般公開、費用、権限、本人データ操作、受付・期限の拡張はしていない。
