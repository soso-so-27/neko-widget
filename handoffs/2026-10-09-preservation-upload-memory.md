# 最大写真の変換メモリ修正と内部配備

2026-10-09 00:34 JST、`decodePhoto` が20MiB写真の変換で作っていた巨大な中間配列を除去し、mainと既存非公開保管Workerへ反映した。最終候補 `7e8c5f14f8af4252b517955f269f7846adf771bc`、main merge `001c6a62c4223d5a61ae90b285806462009fcccd`、Worker version `ffd37dd0-8a2c-47f6-bdcb-180ba15b6db5`。アプリの変更・新しいTestFlight配布はない。本人向けの更新可能版は引き続き247で、247の実機導入は未確認。

## 確認した原因と修正

前の20MiB検査は同期処理の14.517秒を計測できず、観測88.67MiBを上限とみなせなかった。変更後の方法ではローカルworkerdを確定した処理境界で一時停止し、同じ合成20MiB JPEGを観測した。旧`Uint8Array.from(binary, mapper)`直後のJavaScript used heapは約531MiB。8192文字ごとにbase64を変換して最終配列へ直接書く修正後は約87MiBだった。

上限20MiB、canonical base64、null、INVALID_RECORDは不変。全体の許容入力チェックとblockごとの再encode一致を保ち、最大サイズ+1byteが同じbase64文字数になる境界も拒否する。独立レビューでP1/P2なし。新規3テストは独立したBuffer encode、分割境界・padding、不正文字・非canonical bits、最大サイズ全bytesのdigest、超過拒否を確認する。

**経路全体の本番128MiB適合は未証明。** JSON parse、再encode、provider JSON stringifyの大きな割当は残る。候補のJSON stringify直後はJS約163MiB、used/embedder/backingを足す参考値約238MiB。これらはdebugger・GCの影響がある局所観測で、本番の最大値や常駐量ではない。実JPEG provider性能、S3/owner recovery、実KMSは含まない。ローカルnative ingress6827chunksが既存4096上限を超える問題は、検査側だけの64KiB集約（427chunks）で分離しており、製品制限は緩めていない。

## 検証・main・配備

- ローカルtypecheckと関連46テスト成功。制御の必須14suiteは204.5秒で成功。製品統合時は制御/fixtures/workflow不変、保管tree `e07ff3a7a3d4c422c4e9c0f5f1f764d2f497ccfb`の一致で成功を保持し、実Git候補の判定とpreflightだけ追加した。
- CI制御[PR189](https://github.com/soso-so-27/neko-widget/pull/189)を先行。旧v26の固定treeは変更せず、新`preservation-upload-memory-v1`が製品2ファイルのbefore/after blob、M/A、mode、workflowの完全一致を要求する。未知・部分・制御混在は拒否。iOS配布証拠には使えない。
- 製品[PR190](https://github.com/soso-so-27/neko-widget/pull/190)。同SHAの[Node CI](https://github.com/soso-so-27/neko-widget/actions/runs/37801196964)で59files/406vitest、27運用テスト、migration、private bundle成功。[plan](https://github.com/soso-so-27/neko-widget/actions/runs/37801197039)も成功、Mac/Widget/Galleryは実行していない。merge commit後、候補祖先と全tracked tree一致を確認した。
- fresh snapshotと配備前後の照合で、全user schema135件、migration33件、vars/bindings/secret参照/compatibility/公開範囲/schedule/受付/期限を保持。本人1名・記録1件・quota3,358,122bytes不変。レビューで見つかったschema/migration比較漏れは実配備前に修正し、7条件の純粋guardテストで確認した。
- 配備bundle SHA256 `7c28cd463c7765e7171bb4b6ee6db90938b76912692b5cf5ea0eff82a279bb4c`。旧bundleとの差はsource pathコメントを除けばdecodePhoto本文だけ。1回の配備後に実moduleとの全文一致を確認。DB migration・ownerデータ操作・pilot延長・一般受付ON・権限/契約/料金変更なし。

## 時間と残件

所有する候補Node CIは97秒、並行planは31秒。先行control CIは30秒。既存workflowによるPR/main自動検証も成功しており、97秒を全CI稼働合計とは呼ばない。手動再実行0。初回の記録された20MiB検査19:11:58から実配備00:34:20まで約5時間22分で、その間には247配布・公式まど・全件export・費用調査が含まれる。今回の計測方法変更00:01:41から実配備までは32分39秒。以前の検査失敗・計測抜け・今回の検査スクリプト修正も保存している。

新scopeの実測baselineはcheckout外 `C:/dev/neko-evidence/launch-readiness-20261008/upload-ci-timing-baseline.json`。後続preflightで必要なら既存の`--history`で指定できる。未計測を短縮実績としない。全量exportのローカル成功と条件付き費用は[前記録](2026-10-08-preservation-full-export-and-cost.md)を保持する。

公開には、最大写真の全経路メモリ/CPU・実iPhone ZIP、販売容量と受付ペースに整合する完全な費用予測、AWS継続契約、通報の実対応、実失効と最終ストア構成が残る。今回の修正だけでpublicReadyへ変更しない。20MiB対策の次の調査対象は、request JSONとJPEG providerへ送るJSONの完全コピー、復旧を含む経路、および本番ingressの粒度である。

証拠: `C:/dev/neko-evidence/launch-readiness-20261008/`の`upload-decoder-plan.json`、`upload-checkpoint-{probe,candidate}/result.json`、`upload-validation-reuse.json`、`upload-qualified-ci.json`、`upload-decoder-deployment/{bundle-review,independent-review,guard-validation,completion}.json`、`upload-memory-timing.json`。
