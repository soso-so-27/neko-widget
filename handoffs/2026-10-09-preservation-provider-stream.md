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

CI制御を別候補で先行させ、製品3パスの正確なbefore/after・通常mode・両owning workflow不変を要求した。通常handoff A/Mだけを伴える。必要なCIはServiceとJPEG providerの既存2jobとiOSのplan。Mac/Widget/Gallery/追加TestFlightは対象外。

## main・内部配備完了

- 制御[PR191](https://github.com/soso-so-27/neko-widget/pull/191)は独立レビュー、必須development-flow14項目184.7秒、preflight、[control CI](https://github.com/soso-so-27/neko-widget/actions/runs/37858903260)成功後にmainへ先行反映。製品checkoutへ取り込んでも、検証したCI/workflow/native/fixture treeと製品treeがそれぞれ不変であることを記録して成功を保持した。
- 製品[PR192](https://github.com/soso-so-27/neko-widget/pull/192)の固定候補 `274f978dd8a03fdc0c124cc027d8fce88a5bd0f3`。同SHAの[Service CI](https://github.com/soso-so-27/neko-widget/actions/runs/37859139278)で410 Vitest＋27運用テスト・型検査・migration・private bundle成功。[JPEG CI](https://github.com/soso-so-27/neko-widget/actions/runs/37859139318)で34 unit＋7 actual adapter、private bundle、Docker build/probe成功。[plan](https://github.com/soso-so-27/neko-widget/actions/runs/37859139279)も成功。skipを成功へ合算していない。
- main merge `d3023778abe842ce3b9a9f6878bc30bf65f04187`。merge時に候補祖先・全tracked tree一致を確認した。自動PR/mainのbackend検査も成功。手動再実行0。
- 08:26:42 JST、既存非公開Workerをversion `1abecfa8-40cf-49c7-b0ca-400d288bc0f6`へ1回配備。bundle SHA256 `9c8b29db0d3c7712ee25b6437fb8e8a3ed2e3f77fcbe7cbed41c6ca48cf37333`。変更は実moduleのinvokeとboundPhotoValidatorだけで、残りの実行bytesは完全一致。配備後moduleも候補と全文一致。
- 配備前後の全設定・secret参照・D1/R2/service/rate binding・公開状態・schedule・schema135件・migration33件・本人1名/記録1件/quota3,358,122byte・pilot/intake期限を保持。pure guard78条件と独立helperレビューを保存。新しい料金/契約/権限・一般受付・本人データ操作なし。
- 所有するCIのrun時間はService91秒、JPEG54秒、plan40秒、先行control35秒。並行時間を足して全体時間と呼ばず、自動PR/main runは別の稼働として残す。最初の候補作業07:59:07から内部配備まで27分35秒。途中のselector単体検証・初期handoff分類修正と、戻り値を回収できなかったagentのruntime試験も含む。必須runnerではruntimeを含めすべて成功を改めて回収した。

## 通常月の編集費用を実操作で補完

合成1本人・1,000件の実暗号化metadataを用意し、既存約5MB写真のメモ編集を1回だけ実route/auth/archive/recovery経路で測定した。対象外999写真本文は生成せず、不足・対象外readを拒否するguardが0回のまま完走。200/revision2、元写真hash/key/ciphertext不変、他999件revision1、書込lease解放を確認した。準備＋実行9.442秒、調査開始から3分18秒。

編集1回はD1読出4,077行/書込28行、R2 GET11、鍵wrap4/unwrap13、S3 GET11/PUT3/HEAD3、S3読出20,740,172byte、履歴+372,312byte。写真PUTとJPEG provider呼出しは0。同条件300回という仮定なら、無料枠外D1行費約1.91円、S3処理/転送約131.94円、翌月履歴保存費+約0.51円（計画換算198円/USD）。300回を測った結果でも、本番CPU込み総額でもない。Local wall536msを課金CPUとして使わない。

実AWS/KMSは合成、他999写真の実体整合や本番外側gateは未観測。実CPU、背景処理、利用頻度、将来共有枠、実環境の大容量経路、実機ZIPは残る。次の最小調査は同じ20MiB fixtureで入口JSON・暗号化・R2読戻し・復旧を含む生存メモリを切り分けること。固定した今回の候補へ追加修正を積まず、設計を変える直接証拠を先に得る。

証拠は `C:/dev/neko-evidence/launch-readiness-20261008/` の `provider-stream-plan.json`、`provider-stream-contract-probe.json`、`provider-stream-checkpoint/result.json`、`provider-stream-local-validation.json`、`provider-stream-validation-reuse.json`、`provider-stream-qualified-ci.json`、`provider-stream-deployment/completion.json`、`note-edit-cost-probe/{result,assessment}.json`。通常月費用は[完成方針](2026-10-09-public-launch-proposal.md)に分離して記録。未計測費用を0円や予算超過へ読み替えない。
