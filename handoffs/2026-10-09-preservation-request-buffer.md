# 保管の受信buffer解放と大容量保存の確認

2026-10-09。共有・保管を含めて完成させる方針を継続する。既存本人向けの内部運用の範囲で、写真を含むJSON受信の一時メモリを減らす。一般受付、容量、料金、期限、権限、暗号化、保存・復旧の合格条件は変更しない。

## 変更と直接確認

`readBoundedBody` が作る専有の連続bufferを、fatal UTF-8 decodeが終わった直後に `ArrayBuffer.transfer(0)` で解放し、その後に従来と同じ `JSON.parse` を実行する。入力streamのchunkや共有viewはdetachしない。元のbody処理を `request-json.ts` へ移し、routeの6呼出し位置と上限、content-type/object制限、読取の5秒・4096chunk・byte上限、abortとエラー順序を維持する。

実装前に同じcompatibility date/flagのlocal実workerdで20MiB人工JPEGを含む27,962,301byte JSONを比較した。元処理/採用候補の結果digestは同じ、266/257ms。parse直後のbacking観測は58,391,173→29,646,536byte。専有bufferの約27MiB解放を支持する局所証拠であり、本番resident memoryや全経路peakの測定ではない。先に試したstream UTF-8案は文字列flattenの重複で悪化し、不採用。Resizable ArrayBuffer案も有効な削減を示さず採用していない。試作の費用・時間を最終候補だけへ切り詰めない。

独立レビューはP1/P2なし。indexはimport差替とbody抽出以外不変、新関数は名前と上記decode/解放/parse以外が旧bodyと一致。typecheckとrequest-json/bounded-body/storage/recoveryの61件を9.59秒で確認した。新規13件は日本語/emoji/BOM/多byte分割/非ゼロoffsetの入力不変、通常JSON semantics、不正UTF-8/JSON/object拒否、413/4096chunk優先、transport errorとabortを扱う。readBoundedBody・JPEG adapter依存・nativeは変更しない。

## 保存・復旧全経路の確認範囲

直前main `cec77dca9aeee55c8261ed69571a09a8f0f53983` では、検証専用S3応答coalescerのbyte/hash/長さとcancel/abortを直接確認した後、20MiB PUTを1回実行し、HTTP200・record commit marker1・owner snapshot2・最終owner ackまで確認した。暗号化、R2/D1、実S3署名と復旧adapterを通るが、KMS/クラウド輸送/会員/JPEG providerは合成であり、本番のCPU・128MiB適合ではない。追加decoder/5GB export/クラウド操作は0。

今回の製品初候補 `fab42d8a920332233c6861d78dd7dcb4271aecc3` でも1 PUTの計装で専有buffer長0・最終owner ackまで観測した。ただしprobe作成側のWindowsパス置換ミスで出力先が前回dirのままとなり、最後のresult保存が既存ファイルへの上書きを拒否した。**今回の最終HTTP応答とDB集計は保存されておらず、この追加試験をHTTP200確認済みとは扱わない。** 再PUTはしていない。前回の正式resultはSHA256一致で保護されたが、途中partialと生成bundleは新観測で上書きされた旨を記録した。局所比較と61件の成功証拠は影響を受けていない。

新たに到達したS3写真読戻しでは大きな一時bufferが残る。Inspectorのused/embedder/backing参考合計は前回158.38MiB、今回の計装では180.64MiBまで観測したが、保持物/GC差を含むため本番peakや修正による全経路増減とは断定しない。専有request buffer解放は確認できたが、**本番128MiB内での全経路完走は依然未証明**。

## 計画・検証と内部反映

本バッチ開始08:59:49 JST、最初の試作09:06:06、採用案の直接試験09:08:36。計画35〜55分は前回control/local-check/Service CI/配備の実測に新しい設計調査を加えたもので、時間短縮の実績ではない。

製品3ファイルの完全before/after blob、通常mode、M/A/Aと既存Service workflowを固定する `preservation-request-buffer-v1` を、独立したcontrol候補で先に確認・main反映する。製品候補では同SHAのService全検査とplanを必要とする。製品と制御を混在してチェックを回避せず、既存JPEG/native入力不変の成功を保持する。配備は現在の非公開Workerと全設定・期限・schema/migration・本人データ集計を固定し、実module全体を確認する。

## 完了結果

- [制御PR197](https://github.com/soso-so-27/neko-widget/pull/197) は固定候補 `f91257e3ba07436e40377b2cba28b2e40b31a763`、development-flow必須14項目183.5秒とpreflight、[control CI 37864065913](https://github.com/soso-so-27/neko-widget/actions/runs/37864065913)41秒で成功。独立レビュー後、main `beaac64` へ先行反映した。
- [製品PR198](https://github.com/soso-so-27/neko-widget/pull/198) の最終候補 `f72979e8a47a55f9211a93bf844848bb358c0d98` へ反映済controlを取り込み、CI/workflow treeと製品Service treeが各ローカル成功時点と同一であることを確認。成功済み一式は再実行せず、preflightだけ再実行した。
- [Service CI 37864305833](https://github.com/soso-so-27/neko-widget/actions/runs/37864305833) は424 Vitest＋27運用テスト、型検査、全既存migration/private bundle成功、93秒。[同SHA plan 37864305837](https://github.com/soso-so-27/neko-widget/actions/runs/37864305837)42秒。既存workflowが自動起動したPR側Service37864312037も92秒成功、PR iOSはskip。skipを成功証拠にせず、手動再実行や追加JPEG/native/Gallery/TestFlightは0。
- main `3274698980ea0842fb71a6a13ba4e51aafbb6faf` へmerge commitで統合し、検証候補の祖先関係と全tracked tree一致を確認。
- 09:25:27 JST、既存private Workerへ1回反映。version `e46ce4dd-5734-4084-b9cc-3250e71a44de`、bundle SHA256 `14cf64923a9691f7c893e80663a06950ce8ea4d8ff29a3e7ca113acd51128147`。関数移動・コンパイラの変数名変更と専有buffer解放だけを実bundle全体で照合し、反映後全文一致。全設定/secret参照/公開範囲/予定/schema135/migration33/pilotとintake期限、本人1名・記録1件・quota3,358,122byteを維持した。追加契約・料金・権限・一般受付・本人データ操作なし。
- 開始08:59:49から内部反映まで25分38秒。採用案だけへ時間を切り詰めず、不採用2案、全経路probeの結果保存失敗、ローカル・制御・CI・配備を含む。前のprovider改善の最初の候補07:59:07からは累計1時間26分20秒。並行CIの秒数を合算して経過時間と呼ばない。

配備helperは106境界、独立した主担当の差分レビューと、準備/最終dry-run/実配備の全文一致を通した。`request-buffer-deployment/{helper-review,root-helper-review,bundle-review,completion}.json` に固定。PR197/198のチャット添付は既存100件上限により失敗したため実URLをこの記録へ保存し、過去の添付や会話履歴は変更しない。

本人向けTestFlightは1.0(247)のまま。今回のサーバー反映を、本番メモリ条件の合格、実機ZIP成功、一般公開の完了と混同しない。

## 証拠と残件

証拠root: `C:/dev/neko-evidence/launch-readiness-20261009/`。`request-json/{plan,probe-result,resize-probe-result,detach-probe-result,release-reader-review,implemented-review,control-review}.json`、`upload-full-path-completion/{assessment,result}.json`、`request-json-full-path/{partial,evidence-write-failure}.json`。前回正式resultのSHA256は `510f5eeab366dce42f9657b25c97a3dbde6b2f1549dbd047270a3e8eba347784`。

残件はS3復旧読戻し等を含む本番memory/CPU/輸送の確認、247実機の大量ZIP、通報に対する運営者の登録・内容確認・判断/返答、提供容量・受付ペース・費用停止とAWS無料期間後の継続条件、公開構成とストア提出。共有・保管を外さず完成させる。成功済みの購入・復元・解約・保存を理由なく繰り返さない。
