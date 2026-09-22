# CI・配布の作業手順

CIの起動・修正・改善、候補のmain反映、TestFlight配布を扱うときに、該当する節だけ読む。

## CIを起動する前

- push、main更新、TestFlight配布はユーザーの依頼範囲に含まれる場合だけ行う。
- 開始時に現在のmain、対象差分、完了条件を一度決め、機能変更とCI試作を別の候補にする。検証待ちの間に同じ候補へ追加変更を積まない。
- 候補をcommitした後、push前に `python NekoWidget/ci/check-development-flow.py` を実行する。既存の安価な検証に加え、実CIと同じ選択器でbranch全差分・必要job・全件になる理由・過去の所要時間を表示する。配布予定なら `--include-upload`。作業中の単体確認だけなら `--checks-only` とし、push前確認の代用にはしない。
- `--decision` は記録用であり、時間超過・失敗を通過させない。preflightは同じ作業名の `codex/<task>` と `diagnostic/<task>` のCI履歴を取得し、初回CIからの累計経過時間＋次のCI（配布予定ならuploadも）の実測上限を表示する。稼働中CIがあれば重複起動を止める。既定30分を超える場合は方法を変えるか、実測に基づく計画へ明示的に組み直す。`--target-minutes` を変えた場合は当初目標内に収まったと報告しない。成功済みの単体検証は繰り返さず **preflight-ci.pyだけ** 再実行する。
- 未計測scopeの初回計測だけは `preflight-ci.py --measure-baseline`。同じ作業にCI履歴があれば再利用できない。計測後は失敗分も含めtiming baselineへ反映する。未計測を短時間の約束にしない。この計画変更は主担当の責任で行い、ユーザーへの確認を毎回増やさない。
- 必要なprivacy、署名、migration、fail-closed確認は省略しない。

## CIの対象選択・監視・失敗対応

- `preservation-service-v1` は専用保管backendだけ。既知26ファイル・通常mode・固定workflow、導入時4つのCI companion全文を照合する。別のJPEG backendとの混在も含め、未知/native/権限/署名差分はfullへ戻す。候補SHAの `preservation-service.yml` / `Validate preservation identity and storage` の成功とiOS plan成功を別々に確認する。ローカルD1/R2と合成Apple/KMSであり、実デプロイや実端末復元・TestFlight証拠ではない。依存導入にはlifecycle scriptを使わず、専用job上限5分を全体実績としない。

- `preservation-image-validator-v1` は独立したJPEG検証Node部品だけ。既知ファイル一覧・通常ファイルmode・固定した専用workflowを照合し、導入時のCI4ファイルも完全before/after固定とする。未知/native/他service/署名/検証基盤の未監査差分が混ざればfullへ戻す。iOS planはMacを要求しないが、別workflow `preservation-image-validator.yml` の `Validate preservation JPEG provider` が候補SHAで成功していることを主担当が確認する。Node成功とplan成功はiOS release/TestFlightの証拠にしない。未計測は初回だけ明示計測し、5分job timeoutを全体所要実績としない。

- `reviewed-managed-preservation-app-v1` は2026-09-22の既定OFF個人保管接続＋既存共同記録アルバム表示だけを対象とする。既採用の固定companion方式を用い、製品変更とCI選択変更を独立レビュー・別commitに分離した後、完全before/after・manifest・companion一致の統合候補を1回計測する。Build・Photos・両OS runtime・変更経路のUI2操作・成功証拠条件は維持。汎用CI高速化の例外とせず、未知差分はfullへ戻す。未計測を時間短縮実績と扱わない。

- 画面操作の原因切り分けは `diagnostic/<task>` に候補をpushし、`ios-ui-diagnostic.yml` をそのrefで手動起動する。入力は候補の完全SHA、既存 `MomentDeliveryComposerUITests` または `SoloMemoriesUITests` のclass、同じclass内の失敗したメソッド名1〜3個（カンマ区切り）。通常CIはこのbranchのpushで起動しない。例: `gh workflow run ios-ui-diagnostic.yml --ref diagnostic/<task> -f source_ref=<SHA> -f test_class=SoloMemoriesUITests -f test_method=<METHOD1,METHOD2>`。初回のビルドとfixture準備は必要で、跨runキャッシュや診断時間短縮の実測は別途確認する。
- 同じ作業のapp-uiで当該classの失敗があれば、preflightは失敗ログのメソッドと候補SHAに一致する診断成功を要求する。別操作・旧SHA・skip/0件を代用しない。ビルド・環境失敗に無関係なUI診断を要求しない。ログや履歴を取得できない場合は推測で通さない。
- 他classの実XCTest失敗は、準備・環境失敗として無視しない。現在の診断経路の対象外として明示的に止め、対応する切り分け経路を用意する。通常CIの繰り返しや理由文で代用しない。
- 診断後は同じSHAを `codex/<task>` にpushし、既存の必須CIを一度実行して配布へ進む。診断workflowは署名・配布を行わず、通常CI・main再利用・TestFlightの合格証拠には使えない。診断にも同じwatcherを1本だけ使う。branch変更で作業の累計をリセットしない。
- 診断のcaseごとの成功は、祖先関係と全tracked raw差分で、既存通常ファイルの `preflight-ci.py`・`test-preflight-ci.py`・`verify-app-icon.py` の3本だけの変更と確認できた場合に限り継承できる。最後の1本は別Release job専用でnative診断が読み込まないため。診断が依存する変更を加える場合は例外を再レビューして撤去する。診断workflow・準備helper・選択器・製品・UIテストの変更は対象外で、通常CI/main/配布の成功証拠を継承する条件とは別。

- 利用者が見た目を実機確認すると指定した写真/アルバムUIのバッチは、[内容を固定した確認範囲](2026-09-17-reviewed-ui-checks.md)を利用できる。reviewed-app-ui.jsonの全変更before/afterハッシュ一致が必要。代表4操作とBuild/権限/runtimeを残し、未知の変更は一式へ戻す。実機の見た目を自動確認済みとは扱わない。
- `reviewed-memory-read-ui-v3` はv2の全8操作に共同記録・アルバム関連遷移の2操作を加える。FamilyRecordViewは独立レビュー済み全文before/after、PairingViewは共有終了説明の完全一致置換に限定し、全差分manifest・既存build/権限/runtimeを維持する。v3未計測時だけ `preflight-ci.py --use-full-baseline` で全件経路の観測最大を計画参照にできる。v3の実績ではなく、累計時間・実行中・失敗診断の判定を通過させる例外でもない。
- [変更別の画面確認](2026-09-14-targeted-ui-checks.md)に従い、Widget専用処理は関連7件、既知の文字・余白だけならアプリ画面操作を省く。限定scopeのsmokeは実Photos権限1件と後段の実写真スキャンを残し、別OSでの無関係な20件を繰り返さない。製品と既存build/安全確認が不変のCI選択設定だけは、専用scopeで実行経路を確認する。必要な描画・runtime・保存/送信境界は省かない。
- 季節ムービー画面だけ（必要ならADR-023も）の変更は、ビルドと既存境界チェックを残し、無関係な写真スキャン・共有通信の実行チェックを省く。対象外のファイル、CI/署名/権限/永続化などの変更、判定不能時は従来一式。手動workflow_dispatchは常に一式実行し、再利用しない。
- 1つのCI runは1人だけが監視し、意味のある変化かterminal結果だけ共有する。
- CI待機は `python NekoWidget/ci/watch-ci-run.py RUN_ID --expected-sha FULL_SHA --output RESULT_JSON` を1本だけ起動する。失敗jobの終了を検出した時点で `failed_job`・exit 1・失敗一覧を保存して主担当へ戻り、兄弟jobの終了を待たず原因調査を始める。兄弟jobのcancelは行わない。原因確認後、残りの完了を待つ必要がある時だけ `--wait-for-completion`。job内部で実行中のXCTest失敗を先行検知する機能とは区別する。60〜180秒の間隔で、同じ状態・全ログをモデルへ繰り返し返さない。JSONのrunner分は課金額やCodexトークン数ではない。
- watcher・preflight・それらのテスト/計測資料だけを変更し、既存通常ファイルで製品・build・安全検証・配布判定が不変なら `development-tools-v1`。planのPython検証を実行し、Macの画面テストを追加しない。選択器・check runner・workflow・新規ファイル・削除・型変更が混ざれば対象外。この成功はiOS検証証拠ではなく、TestFlightの配布根拠には使えない。
- アイコン2画像のみ（必要なら名前固定の正本資料を伴う）の変更は `app-icon-v1`。既存の通常ファイル、完全なRGB PNG、全差分を確認した上で、既存build/安全検査とコンパイル済みアイコン・実起動・初回画面の撮影を1台のMacで行う。写真送信/メモ全51操作やWidgetの全表示パターンは走らせない。Contents.json・Swift・署名・未知ファイルが混ざる場合は適用しない。専用成功をfullの成功として再利用しない。
- `ci-selection-v1` のアイコン確認は元画像・コンパイル済みアセット・署名まで。変更していないアイコンのために別のSimulatorを起動しない。通常のアプリ起動と操作は既存の必須nativeジョブが確認する。`app-icon-v1` の実起動・画面撮影は維持し、compiled-onlyの結果を画面確認済みと報告しない。
- 最初の具体的なエラーへ絞って修正し、同一SHAでgreenの検証を理由なく繰り返さない。
- CIの失敗は製品の不具合・検証コードの不具合・実行環境の障害に分ける。環境障害と確認した同一SHAは失敗したjobだけ再実行する。原因が不明なまま成功するまで再試行しない。コードを直した場合は新SHAの必要範囲を検証する。

## 候補からmainへ反映するとき

- 配布時は候補SHA CI → main CI → TestFlightの順で確認する。
- main CIは、同一リポジトリ・同一workflowの候補ブランチで過去24時間以内に必要ジョブが実行成功している証拠を再利用できる。原則は同一SHA。
- 別SHAは、成功した候補がmainのancestorであり、独立した研究アプリ `experiments/PetIdentityProbe/` 以外の全trackedファイル（パス・内容・mode・type）が同一と確認できる場合に限る。本アプリ・CIが研究フォルダーを入力にする変更時は、この例外を除去する。
- 省略ジョブ・失敗・未検証の差分は成功の代用にせず、判定不能時は一式実行する。archive・署名・配布記録は実際の配布SHAで新規に作成する。
- mainで成功証拠を再利用する候補CIはpushで起動する。現行の証拠判定はworkflow_dispatchを再利用元にしないため、起動前にこの条件を確認する。

## TestFlightを配布するとき

- 軽微な修正ごとに配布せず、関連修正を一つのrelease candidateへまとめる。
- 内部TestFlightは `NekoWidget/ci/release-testflight.py` のdry-runで対象SHA・成功CI・build番号・重複を確認してから同じ引数に `--dispatch` を付ける。毎回workflowのフラグを手入力しない。アプリを変更していない開発基盤だけの修正は、検証のために新しいTestFlightを作らない。
- 配布runが `waiting` の場合は、そのrunの `pending_deployments` を確認する。既に承認された内部配布の対象SHA・buildに一致する場合に、そのrunの `testflight` 環境を承認する。環境の保護ルール自体は変更しない。対象や許可範囲が異なる操作へ流用しない。
- Appleへのアップロード成功とエラーの有無を基本の完了証拠とし、毎回のApp Store Connect画面確認・再ログインを次の開発の前提にしない。配布が見えない、処理エラーなどの問題がある場合にだけ画面を確認する。アップロード成功と内部配布画面の確認済みは区別して記録する（2026-09-13ユーザー指定）。

## CIを改善するとき

- CI高速化の試作は専用候補で検証する。製品側は検証済み構成を使うが、既知の時間超過を繰り返すことをこの分離規則で正当化しない。選択理由と所要時間を実行前に確認し、必要なら基盤側を先に改善する。
- CI改善は全必須チェック成功と候補全体の実測時間・runner分を確認して採用する。未計測の短縮予想を実績として扱わず、失敗部分だけ再実行できる効果も区別して記録する。
