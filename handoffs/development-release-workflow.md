# CI・配布の作業手順

CIの起動・修正・改善、候補のmain反映、TestFlight配布を扱うときに、該当する節だけ読む。

## CIを起動する前

- 実装途中の画面確認は `preflight-ci.py --feedback --test-class <既存class> --test-method <method1,method2>` で準備する。cleanな確定HEADと同一classの既存1〜3操作を検査し、`diagnostic/<task>` への固定SHA pushと既存診断workflowの起動コマンドをJSON配列で返す。コマンドは自動実行しない。同じ作業のCIが実行中ならコマンドを返さない。診断成功はrelease evidenceではなく、最終候補の必須jobを置き換えない。
- `codex/<task>` の途中pushは通常CIを起動するため、修正中は上記診断経路と関連ローカル検証を使い、関連修正を一つの統合候補へまとめる。preflightの `other_active_ios_runs` は他作業の通常iOS CIを表示し、runner競合を避ける計画に使う。他作業を自動取消せず、全作業を直列化しない。待ち時間と実行時間を分けて記録する。

- push、main更新、TestFlight配布はユーザーの依頼範囲に含まれる場合だけ行う。
- 開始時に現在のmain、対象差分、完了条件を一度決め、機能変更とCI試作を別の候補にする。検証待ちの間に同じ候補へ追加変更を積まない。
- 候補をcommitした後、push前に `python NekoWidget/ci/check-development-flow.py` を実行する。既存の安価な検証に加え、実CIと同じ選択器でbranch全差分・必要job・全件になる理由・過去の所要時間を表示する。配布予定なら `--include-upload`。作業中の単体確認だけなら `--checks-only` とし、push前確認の代用にはしない。
- `--decision` は記録用であり、時間超過・失敗を通過させない。preflightは同じ作業名の `codex/<task>` と `diagnostic/<task>` のCI履歴を取得し、初回CIからの累計経過時間＋次のCI（配布予定ならuploadも）の実測上限を表示する。稼働中CIがあれば重複起動を止める。既定30分を超える場合は方法を変えるか、実測に基づく計画へ明示的に組み直す。`--target-minutes` を変えた場合は当初目標内に収まったと報告しない。成功済みの単体検証は繰り返さず **preflight-ci.pyだけ** 再実行する。
- 時間計画の延長は、検証範囲の妥当性を確かめる代わりにならない。「未知ファイル／既存の分類に入らないため全件」は必要性の証拠ではない。依存先を安価に調べ、必要な確認と除外根拠を決め、選択処理へ反映してから起動する。既知の無関係な確認を、時間枠を広げただけで実行しない。安全への影響が未確認なら、チェックを手動で抜かず原因調査を先行する。
- 未計測scopeの初回計測だけは `preflight-ci.py --measure-baseline`。同じ作業に通常candidate CI履歴があれば再利用できない。focused diagnosticだけを先行した場合は、失敗・稼働中・累積時間の判定を維持して初回計測できる。計測後は失敗分も含めtiming baselineへ反映する。未計測を短時間の約束にしない。この計画変更は主担当の責任で行い、ユーザーへの確認を毎回増やさない。
- 必要なprivacy、署名、migration、fail-closed確認は省略しない。

## CIの対象選択・監視・失敗対応

- 同一SHAのrecovery refを作成できてもpush CIが起動しなかった場合、そのref・未起動記録を残す。`--recover-run <ID> --refresh-recovery` は、第一親が元候補、第二親がmain承認済みの実mergeだけを許可する。全raw差分はpreflight・対応テスト・本手順・固定recovery handoffの4パスに限定し、正常modeと第二親の完全一致を確認する。既存refが元SHAのまま・replacement履歴0件・元run全attempt job0を再確認し、元SHAをexpected値とするleaseで同じrefを一度だけFF更新する。空commit、別branch、未知結果の再送は行わない。元の履歴・累計を保持し、新SHAのowning pushと必須job成功を確認してから通常配布へ進む。制御変更以外の製品/選択器/workflow/署名・配布入力の差分は拒否する。

- GitHub内部障害で候補pushが60分以上queuedのまま、全attemptのjobが0、attempt 1、作成後の更新もない場合は、main承認済みのcleanなpreflightから `--checkout <候補checkout> --recover-run <元run ID>` で再開を計画できる。候補・元run・repo・workflow・branchの同一性と、候補が使用する選択器/manifest/workflowとツール側の完全一致を確認する。元runの成功は再利用しない。元のcandidate/diagnostic履歴・失敗・累積時間を保持し、そのrunのactive判定だけを除外する。他の稼働中/未解決失敗は止める。
- 再開は固定 `codex/recovery-<元run ID>` へ同一SHAを一度だけ登録する。`--dispatch-recovery --output <両checkout外の記録>` を明示した場合だけ、直前再確認→要求記録保存→空のexpected refを指定したGit push (`--force-with-lease=refs/heads/codex/recovery-<ID>:`) を行う。この指定はref不存在だけを許し、既存refを更新しない。既存ref/runがあれば停止する。応答不明時は同じrefとrunを調べ、別branchや再送で重複起動しない。ref作成とpush CI開始は別々に確認し、正しいSHA/branch/workflow/eventの実runを確認するまでCI開始済みと報告しない。
- 再開branchを後で調べる場合もmain承認済みpreflightの `--checkout` を使う。元run・exact-SHA ref・唯一のreplacement pushを再照合し、元履歴を必ず取り込む。元runが実行を始めた/情報が欠けた場合は再調査する。通常のworkflow・必須job・main統合・TestFlightの成功条件は変更しない。新scopeの実測と混同せず、必要なら既存のfull実測を計画上限の参照にする。元の時間目標を超えた事実を消さない。

- `billing-operation-tools-v1` はローカル購入gate CLIの明示3パスだけ。通常modeの変更と専用private entryの通常追加、handoffに限定し、Ubuntu planで既存mocked Node境界テストを実行する。Worker runtime・dependency・native・CIとの混在、未知/mode変更/重複/owning検査欠落は対象外。sharingのfull3jobはこのscopeと `ci-orchestration-v1` では起動しない。選択器導入は別control候補を先に確認し、sharing本文の差分は3つの既定jobの完全if行だけを許可する。実cloud操作・Mac・Widget画面・uploadは実行せず、成功をiOS配布の証拠に使えない。
- `public-policy-docs-v1` は既存の公開説明HTML7ページだけ。通常modeの変更とhand-offの追加・変更に限定し、Ubuntu plan内で既存 `test-public-policy-site.py` を実行する。未知ファイル・追加/削除/型変更・native/backend/CIとの混在はfullへ戻す。選択処理の導入は文書の変更と別候補にし、独立レビューと `ci-orchestration-v1` を先に通す。Mac・Simulator・Widget・uploadは起動せず、この成功をiOS配布の証拠に使えない。HTMLの見た目は必要な描画確認を別に行う。
- 制御用Python、対応する単体テスト、workflowの起動条件・配布SHA固定だけの変更は `ci-orchestration-v1`。Ubuntuのplan jobで検証し、Mac・Simulator・Widget画面検証は起動しない。native build/test/upload本体の変更や製品変更との混在はこの範囲に含めない。この成功はiOS製品・配布の検証証拠に使えない。
- 既存のアプリViews内だけの動作変更は `app-view-ui-v1`。アプリ操作・Photos・runtime・buildを確認し、Widget galleryは起動しない。共有モデル・Widget・project・fixtureの変更を含む場合は別途判定する。既存の文字・余白だけの限定判定は維持する。
- `app-private-data-ui-v1` は明示された写真メモ・個人保管・診察控えのapp専用保存／表示だけ。Widgetの実source ID→fileRef→pathを確認し、project差分は既知2ファイルのapp専用登録以外を全て拒否する。初回の保存検証追加は既存workflow不変＋1つの追加検証blockだけ。Build内の保存・migration・privacy確認、従来Photos／scan、両OS runtime、app UI両shardは維持し、Widget gallery3系統だけを除く。共有モデル・Widget描画／更新／cache・startup・画像fixture・未知ファイル・不明なmode／登録は対象外。選択処理だけの今回の修正は `ci-orchestration-v1` でPythonだけを検証し、Mac／Simulator／再配布を行わない。新scopeのnative所要時間は未計測で、除外した件数を実測の時間短縮や全件成功に読み替えない。
- `family-window-ui-v2` は既存FamilyWindowView・FamilyRecordView内の変更。共有写真の配置、選択中写真への操作、送受信一覧、共同記録の取り下げ・権限・書き出しの5テストとWidget URLから写真を開く3操作、build・Photos権限・実写真scan・両OS runtimeを実行する。Widget galleryは起動しない。UIテスト差分は選択された5メソッドの本文と、そこからのみ呼ぶ新規private helperに限定する。未選択テスト・既存helper・他class・importsは不変と確認し、未知・共有モデル・Widget実装・project・workflowの混在は対象外とする。v1のクラス全件所要時間をv2の実測値にしない。
- 同一リポジトリのPRはpush CIを使い、PR側ではMac jobを重複起動しない。fork PRは従来通り検証する。main pushは一致する候補の成功証拠を再利用し、一致する候補がない場合はplanで終了する。無条件に広い検証へ戻さず、配布済みでない固定候補を使うか、必要な統合候補を作る。

- `preservation-service-v3` はv2の既知33ファイルへ、予約のowner indexを追加する `migrations/0004_upload_owner_index.sql` だけを加えた34ファイル。専用workflow・必須Node job・通常mode・未知/native/Sharing混在時のfull fallbackを維持し、4 companionのbefore/afterを独立レビューして固定する。v3は初回計測し、v1/v2の時間をv3実績にしない。iOS planの成功と同SHA専用Node jobの成功を別々に確認し、Mac/配布の証拠として流用しない。

- `preservation-service-v2` は専用保管backendと独立private billing authorityだけ。既知33ファイル・通常mode・固定workflow、導入時4つのCI companion全文を照合する。Sharingの署名/権利判定は直接importするが、そのソースやmigrationを変更すればfullへ戻す（専用workflowも起動）。別のJPEG backendとの混在、未知/native/権限差分もfull。候補SHAの `preservation-service.yml` / `Validate preservation identity and storage` の成功とiOS plan成功を別々に確認する。実署名・ローカルD1/R2と合成Apple/KMSであり、private workerのbundleはdry-runのみ。実デプロイや実端末復元・TestFlight証拠ではない。依存導入にlifecycle scriptを使わず、専用job上限5分を全体実績としない。v1実績をv2の実測としない。

- `preservation-image-validator-v2` はv1の厳格JPEGデコーダーに、既定OFFの非公開Container gateway・HTTP bridge・Linux/amd64 Docker buildと人工画像でのコンテナ内検証を追加した既知23ファイルだけ。通常ファイルmode・固定専用workflow、CI4ファイルの完全before/afterを照合する。未知/native/他service/署名/検証基盤の未監査差分はfull。候補SHAで別workflow `preservation-image-validator.yml` の `Validate preservation JPEG provider` とiOS planの双方を確認する。Node/Docker/bundle成功は実Container配備・iOS release/TestFlightの証拠ではない。新scopeは初回計測し、10分job timeoutを実測時間としない。

- `preservation-provider-stream-v1` はproviderへのJPEG要求をstream化する既定3ファイルだけ。Serviceのproviderと新規境界テスト、ImageValidatorのadapterテストの完全before/after blob・M/A/M・通常modeを固定し、両backend workflowの内容とmodeもbase/headで不変と確認する。制御登録は `ci-orchestration-v1` で先にmainへ反映し、製品との混在・未知・部分一致にこのscopeを使わない。候補の同一SHAで `preservation-service.yml` の `Validate preservation identity and storage` と `preservation-image-validator.yml` の `Validate preservation JPEG provider` の実行成功を両方確認する。plan成功はbackend成功を証明せず、既存固定scopeや必須backendは変更しない。Mac・TestFlightは対象外。所要時間は新scopeとして初回計測し、両workflowの失敗・稼働中履歴と初回候補からの累計を残す。

- `preservation-r2-view-v1` はR2へ暗号文のviewを直接渡す `PreservationService/src/storage.ts` と既存storage境界テストの固定2ファイルだけ。完全before/after blob・M・100644、既存Preservation workflowのbase/head blob・100644を固定し、通常handoffのA/Mのみを併記できる。未知・部分一致・製品と制御の混在・mode変更・削除・重複は対象外。制御登録を `ci-orchestration-v1` で先にmainへ反映してから、製品候補の同一SHAでiOS planと既存 `preservation-service.yml` の `Validate preservation identity and storage` の実行成功を確認する。JPEG・native・Widget・配布の証拠には使わず、plan成功をbackend成功へ読み替えない。旧scopeの固定条件を維持し、初回計測・失敗・稼働中履歴・初回候補からの累計時間を残す。

- `preservation-request-buffer-v1` は専有request bufferをJSON解析前に解放する既定3ファイル（`PreservationService/src/index.ts` のM、`src/request-json.ts` と `test/request-json.test.ts` のA）だけ。完全before/after blob・M/A/A・100644、既存Preservation workflowのbase/head blob・100644を固定し、通常handoffのA/Mのみを併記できる。未知・部分一致・制御との混在・mode/type変更・削除・重複・欠落は対象外。制御登録を `ci-orchestration-v1` で先にmainへ反映してから、製品候補の同一SHAのowning pushでiOS planと既存 `preservation-service.yml` / `Validate preservation identity and storage` の実行成功を確認する。JPEG・native・UI・配布の証拠には使わず、plan成功はbackend成功を証明しない。旧scope固定条件、初回計測・失敗・稼働中履歴・初回候補からの累計時間を維持する。

- `preservation-recovery-read-v1` はS3復旧GETの専用readerを変更する既定2ファイル（`PreservationService/src/s3-recovery-copy.ts` のMと `test/s3-recovery-read.test.ts` のA）だけ。完全before/after blob・M/A・100644、既存Preservation workflowのbase/head blob・100644を固定し、通常handoffのA/Mのみを併記できる。未知・部分一致・制御との混在・mode/type変更・削除・重複・欠落は対象外。制御登録を `ci-orchestration-v1` で先にmainへ反映してから、製品候補の同一SHAのowning pushでiOS planと既存 `preservation-service.yml` / `Validate preservation identity and storage` の実行成功を確認する。JPEG・native・UI・配布の証拠には使わず、plan成功はbackend成功を証明しない。旧scope固定条件、初回計測・失敗・稼働中履歴・初回候補からの累計時間を維持する。

- `moderation-enrollment-verifier-v1` は通報運用者のWebAuthn登録verifierと所有テストの固定3ファイルだけ。完全before/after blob・M/A/M・100644、既存Sharing workflowのbase/head blob・100644を固定し、通常handoffのA/Mのみ併記できる。未知・欠落・重複・部分一致・mode/type変更・削除・製品と制御の混在はfullへ戻す。制御登録を `ci-orchestration-v1` で先にmainへ反映してから製品をpushする。同一SHAのowning pushでiOS planとSharingの `Select backend checks`、`Typecheck, test, and build Apple transaction verifier`、`Windows moderation key, drill, and report policy fixtures`、`Typecheck, test, and bundle Worker` の4job実行成功を確認し、workflowやjob本体は変更しない。plan成功・skip・旧SHA・別eventは4job成功の代用にならず、native・upload・実機登録・運用者承認・live公開の証拠には使えない。旧scopeの固定条件と初回未計測・failed/active履歴・初回候補からの累計時間を維持する。5/10/10/20分のjob timeoutは実測所要時間ではない。

- `reviewed-managed-preservation-app-v1` は2026-09-22の既定OFF個人保管接続＋既存共同記録アルバム表示だけを対象とする。既採用の固定companion方式を用い、製品変更とCI選択変更を独立レビュー・別commitに分離した後、完全before/after・manifest・companion一致の統合候補を1回計測する。Build・Photos・両OS runtime・変更経路のUI2操作・成功証拠条件は維持。汎用CI高速化の例外とせず、未知差分はfullへ戻す。未計測を時間短縮実績と扱わない。

- 画面操作の原因切り分けは `diagnostic/<task>` に候補をpushし、`ios-ui-diagnostic.yml` をそのrefで手動起動する。入力は候補の完全SHA、既存 `MomentDeliveryComposerUITests` または `SoloMemoriesUITests` のclass、同じclass内の失敗したメソッド名1〜3個（カンマ区切り）。通常CIはこのbranchのpushで起動しない。例: `gh workflow run ios-ui-diagnostic.yml --ref diagnostic/<task> -f source_ref=<SHA> -f test_class=SoloMemoriesUITests -f test_method=<METHOD1,METHOD2>`。初回のビルドとfixture準備は必要で、跨runキャッシュや診断時間短縮の実測は別途確認する。
- 同じ作業のapp-uiで当該classの失敗があれば、preflightは失敗ログのメソッドと候補SHAに一致する診断成功を要求する。別操作・旧SHA・skip/0件を代用しない。ビルド・環境失敗に無関係なUI診断を要求しない。ログや履歴を取得できない場合は推測で通さない。
- 既存の厳密なtest-correction機構が成功したBuild/Photos/runtimeの入力不変と、同一作業の既知UI本文だけの修正を証明できる場合は、重複する診断ビルドを挟まず通常のowning UI jobで再確認する。迷子・保管の既存範囲に加え、病院の保存済み猫選択は1本文だけ、他の制御は既反映main同一、未知失敗や後続失敗は対象外。新SHAの関連3UI全件成功は必須で、過去のUI失敗・skipを成功へ読み替えない。製品/fixture/共有モデル/権限/workflowの変更には使わない。
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

- 配布時は固定した候補SHAのCI成功 → そのSHAをmainへ反映 → 同じSHAでTestFlight。配布CLIの `--ci-run` は成功した候補push CIを直接受け付ける。main CIをもう一度待つ必要はない。既存の `--main-ci-run` も互換引数として利用できる。
- 配布候補のPRはmerge commitで統合する。squash/rebaseは検証済み候補SHAをmainのancestorに残さず、配布証拠がつながらない。統合直後に `git merge-base --is-ancestor <候補SHA> origin/main` を確認してから配布dry-runへ進む。
- main CIは、同一リポジトリ・同一workflowの候補ブランチで過去24時間以内に必要ジョブが実行成功している証拠を再利用できる。原則は同一SHA。
- 別SHAは、成功した候補がmainのancestorであり、独立した研究アプリ `experiments/PetIdentityProbe/` 以外の全trackedファイル（パス・内容・mode・type）が同一と確認できる場合に限る。本アプリ・CIが研究フォルダーを入力にする変更時は、この例外を除去する。
- 省略ジョブ・失敗・未検証の差分は成功の代用にしない。mainで証拠が一致しない場合はMac jobを自動再実行せず原因を示す。archive・署名・配布記録は実際の配布SHAで新規に作成する。
- mainで成功証拠を再利用する候補CIはpushで起動する。現行の証拠判定はworkflow_dispatchを再利用元にしないため、起動前にこの条件を確認する。

## TestFlightを配布するとき

- 軽微な修正ごとに配布せず、関連修正を一つのrelease candidateへまとめる。
- 内部TestFlightは `NekoWidget/ci/release-testflight.py` のdry-runで対象SHA・成功CI・build番号・重複を確認してから同じ引数に `--dispatch` を付ける。毎回workflowのフラグを手入力しない。アプリを変更していない開発基盤だけの修正は、検証のために新しいTestFlightを作らない。
- 対象SHAがmainに含まれていれば、mainの最新SHAと一致する必要はない。候補のcheckoutから `--sha <候補の完全SHA> --ci-run <その候補の成功run> --build-number <未使用番号>` を使う。配布workflowはそのSHAをcheckoutし、署名metadataも同じSHAへ結び付ける。候補以降にtestflight.yml自体が変わった場合は混在させず停止する。この経路の導入前SHAの再配布には使わない。
- 並行mainの制御更新で過去の検証済み候補を照合するときは、既にmainへ反映されたcleanな配布ツールから `--checkout <候補の絶対ディレクトリ>` を指定できる。ツール自身と候補のrepo・clean・main祖先関係を両方確認し、候補SHA/CI/重複/署名/内部設定の条件は維持する。Vetの制御承認は候補と現mainのmerge-baseへ完全一致しなければならず、未反映の制御差分は拒否する。可変main tipへの追従で検証済みnative入力を無効化せず、候補ソースや検証履歴を加工しない。
- 配布runが `waiting` の場合は、そのrunの `pending_deployments` を確認する。既に承認された内部配布の対象SHA・buildに一致する場合に、そのrunの `testflight` 環境を承認する。環境の保護ルール自体は変更しない。対象や許可範囲が異なる操作へ流用しない。
- Appleへのアップロード成功とエラーの有無を基本の完了証拠とし、毎回のApp Store Connect画面確認・再ログインを次の開発の前提にしない。配布が見えない、処理エラーなどの問題がある場合にだけ画面を確認する。アップロード成功と内部配布画面の確認済みは区別して記録する（2026-09-13ユーザー指定）。

## CIを改善するとき

- 写真読み込み・見返しの既知full-v1 run `37245665341` / `1c4c4b5` に限り、PersonalRediscoveryUITestsの共通openHistory helperの旧AX名称検索だけを修正する。XCTestファイル全文の完全before/after blobを固定し、ID検索・現ラベル一致・hittableを確認、元の2テスト本文と合格条件は維持する。このhelperを読むSMOKEとapp-ui-otherに加え、テスト成功後に成果物保存だけが失敗したapp-ui-soloを、新SHAで全件再実行する。既知2ケースだけがSMOKEとapp-ui-otherで失敗し、Build/runtime/Gallery2系統の旧4件が成功し、soloが固定ID・step結果・ログの全条件に一致してからのみ再利用する。同repo・branch・push・24h・attempt1・原plan full7・raw差分・既にmain承認済みの制御8本との一致を要求する。制御ファイルのうち`test-ci-lanes.py`と`test-release-flow.py`も、現mainと完全一致する場合だけ許可する。製品/fixture/未知の変更・追加失敗・skip・重複・欠落は対象外。未完了・取得不能では全件再起動せず停止。mainと配布でも旧4件＋新3件を再照合する。費用は失敗・診断と初回候補からの経過を残し、測定済みの実績だけを用いて報告する。未計測の短縮実績や完了保証にはしない。

- 猫アルバムの既知full-v1 run `37201863450` / `83c67ab` に限り、最大文字サイズのシート閉じ操作1本文の修正を、全UIテストファイルの完全before/after blobで固定する。製品・fixture・workflow・他のテストは不変、制御6本と本手順は独立レビュー・Ubuntu検証・main反映済みの一致が必要。同repo・同branch・24時間以内・同一必須graphの実行済み成功6ジョブを再利用し、新SHAでsoloの全46件を再実行する。原runのsolo失敗を成功へ読み替えず、未知の変更・追加失敗・重複・skip・未反映制御は対象外。配布CLIも原runと新UI結果を再照合する。一般的なfull-v1の失敗回避規則ではない。

- 病院・体重の保存済み猫選択は `reviewed-vet-saved-cat-ui-v1`。アプリ専用2View・既存DEBUG fixture・既存UIテストの完全4ファイルbefore/after一致だけを認める。関連3メソッド（体重編集、明示的な診察追加/除去と共通ID選択、写真なし/日付不明/大文字）とBuild・Photos bootstrap・両OS runtimeを維持し、全UI一式・Widget Galleryは起動しない。未知入力・mode/type変更・共有モデル・project・workflow・CI混在はこの登録を借りない。制御用登録はnative/配布成功ではなく、初回の所要時間は実測する。

- 迷子の保存済み情報入力（`d2f8418`）はstoreの完全before/afterを独立レビューして `lost-cat-photo-ui-v3` へ登録する。既存の迷子3操作へ候補入力・編集・再起動・禁止項目の非転記・同名別猫の場面を追加し、Build・Photos bootstrap・両OS runtimeは維持。全アプリUI・Widget Galleryは起動しない。未知store差分や他の入力はこの登録を借りず、既存selectorで判定する。制御用の登録だけではnative/配布成功と扱わない。

- CI高速化の試作は専用候補で検証する。製品側は検証済み構成を使うが、既知の時間超過を繰り返すことをこの分離規則で正当化しない。選択理由と所要時間を実行前に確認し、必要なら基盤側を先に改善する。
- CI改善は変更に対応する必須チェック成功と実測時間を確認して採用する。`ci-orchestration-v1` の必須はPythonを実行するplan jobのみであり、CI修正のために製品の全画面テストを追加しない。未計測の配布所要時間を短縮実績として扱わない。

- `billing-immediate-authority-v1` は明示取引の即時Apple authority再照会に関するSharingServiceの製品4ファイルの完全before/after一致だけ。制御4ファイルとの混在は既存の自己参照companion方式で全文一致を要求する。通常mode・削除/追加なし・main祖先・既存Sharing workflow全文不変を検証し、未知差分はfull。既存Ubuntu `Typecheck, test, and bundle Worker` の型検査・D1 integrationを含むnpm run check・bundle成功が必須。既存Sharingの他jobもworkflowどおり実行し、iOS native・再配布は不要。初回は未計測として記録し、20分job timeoutを所要時間と呼ばない。backend成功はiOS release証拠ではない。元taskのSharing runも費用/失敗/active履歴へ含める。
