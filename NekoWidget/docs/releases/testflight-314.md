# 内部TestFlight 314

- 所有者指示1029iと、運営確認の期限更新・必要な鍵操作・314内部配布の追加承認に基づく。
- 製品候補はmain d890c10150adebeb48fe361aaddf2a0999b9fb5c。最初の候補ブランチ確定は2026-10-29 20:27:46 JST。承認待ち・本人操作・運用ヘルパー調整を含め累計時間を計上する。
- 313後の変更はアルバムの本棚と作品のPlus境界、家族手帳停止案内、作成者名入力、対応サーバー限定のまど管理、支払う人の引き継ぎ、旅立った日の共有前確認と共有停止。保存枠の作業中変更は含めない。
- FAMILY_NOTEBOOK_PRODUCTION_ENABLED=NO、GROUP_REPORTING_PRODUCTION_ENABLED=NOなど313のNO設定を維持。家族手帳は試作画面で確認する。

## 配布前の直接確認

- d890c101の通常iOS CI 40858064048は必須2job成功。変更なしの製品検査結果は保持する。
- 実配備staging Workerのdeployment 9bbd533b-e737-4a05-8b34-2254ceadb66a / version 6c5f3f73-203e-4dd5-80f5-653df6fbcd11を読み取り取得。実bundleのdefault.fetchをローカルD1と合成本人で実行し、暗号化した作成者名入り作成201、保存暗号文の名前一致、同じoperationId再送200を確認した。余分な平文ownerDisplayName項目は400。現行Swiftはこの平文項目を追加せず、従来のencryptedMemberNamesを使う。ネイティブ形式と再送は既存成功CIにも含まれる。
- ローカル互換性試験は1件成功、10.67秒。初回のrate limiter不足とDB列名誤りは試験側を修正。実iPhoneから稼働中stagingへの作成試験ではない。
- #600はnameRevisionなしで管理操作を隠す。Workerコード更新・D1 schema適用・管理有効化はしない。
- 旧readinessは15:41:23.956 JSTに失効し、Info.plistのFamilyNotebookProductionEnabled追加でも記録更新が必要。配布CIを先に起動せず、追加承認後に運営確認を更新する。
- 同一本人・同じ鍵・同じscopeのWindows鍵確認を再開し、本人限定private billing gatewayの開始・終了時刻だけ更新。期限は2026-10-30 21:36:15.223 JST。gateway version 79d03c12-594a-4725-ae79-9304129e19cb。コード・その他設定・本人・鍵の不変を読戻し確認。一般group通報と自動メールはNO。
- 運用ヘルパーは現在の0053 counter view、既知合成資料の保存期限と前回の試験メール資料に合わせて照合。新しい隔離合成資料1件を保存。実利用者写真やHTTP通報受付の一周試験ではない。

## 設定と残る検査

- 313同様、testflight.yml / ref main / build_number=314 / release_mode=media-staging / preservation_pilot=true / internal_reports=true / billing_sandbox=true / group_windows=true / upload_to_testflight=true / retain_signed_artifacts=true / legacy_release_evidence=false。
- official_window_feed_url=https://neko-widget-official-cats-preview.nakanishisoya.workers.dev/catalog.json。
- 既存内部グループ「自分用」だけ。App Store設定変更・審査提出・一般公開・外部配布は含まない。
- 次は今回の合成写真の本人閲覧と対応不要保存、正規2署名、現在runtime、更新候補CI、archive/exportの設定・署名、Apple upload、内部グループの配布状態。実iPhoneの新画面描画と操作は未確認。
- 313の配布jobは15分52秒、dispatchから完了まで16分50秒。readiness候補確定後のCIと配布は35〜45分程度を見込み、本人操作とApple処理待ちは別。期限切れや未確認項目を成功扱いしない。

## 署名更新候補の確定

- 21:49〜21:50 JST、今回の合成画像の実表示と本人再認証による対応不要の保存を確認。現在の閲覧receipt・source snapshot・本人・認証器・決定・返答を照合した。
- 21:52:48 JST、現在31ファイルと今回の実証拠を結んだ正規2署名を作成。既存verifierで成功。バックアップや実写真・元端末閲覧など既存falseの境界は変更していない。
- runtime検査は最初healthが10秒でtimeout。同じhealth単独が200・0.28秒で応答し、再実行した対象runtime検査は全項目成功。製品やtimeout設定は変更していない。
- この候補はreadiness JSONと本リリース記録だけ。通常CIの対象外コードや運用スクリプトを含めない。候補CI成功後、同じ製品treeとreadinessから内部配布を行う。
