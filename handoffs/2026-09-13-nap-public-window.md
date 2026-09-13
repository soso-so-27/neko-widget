# お題まど「おひるね」

N07第3バッチ。`codex/nap-window-release-20260913`、製品SHA `e8154065a049205dc6828893a693dd428f5b7bc0`、基点main `eb50dd1`。2026-09-13「すすめてください」に基づく、既存の内部TestFlight・公式preview配信内の追加。一般公開や投稿受付の開始ではない。

## 今回の内容

- 「＋」→「公開まどを探す」に「おひるね」を追加する。名前と写真で内容を伝え、一覧の説明行・タブ・設定項目を増やさない。
- 受け取り前に写真を開ける。受け取りを始めたまどだけ一覧に追加され、Widgetの「表示する写真」から「おひるね · 公式まど」を選べる。
- IDは `nap-cats`、Widget IDは `public-window:nap-cats`。既存の検証済みfeedの親から `windows/nap-cats/catalog.json` を導出する。旧公式まどのID・保存場所・リンクは維持する。
- Widgetで選んだまどは、アプリで別のまどを開いても変わらない。写真をタップするとそのまど・その写真を開く。期限切れや受信停止では別の写真へ置換しない。
- Widgetの読み上げと、表示できない写真からの戻り先にも具体的なまど名を使う。配信先が無効なビルドでは新しいWidget選択肢を出さない。以前設定したIDの解決は残す。

## 写真と運用

最初のお題は固定の「おひるね」。既存承認済みの茶トラが眠るAI画像を1枚使う。原本を目視して内容とお題の一致を確認した。画像・ひとこと「となりで、すやすや。」・提供表示「ねこのまど（AI生成）」はそのまま。既存の「どこかの猫」の3枚と掲載日は変更しない。

全受信者に同じ掲載内容を配る。アプリを開いた時の確認と、OSが許可するWidget更新で反映する。新着頻度を約束したり、定期配信が動いているようには説明しない。この最初の1枚は表示・購読の確認用で、継続的に新しい猫が届く価値を満たした証拠ではない。

既存preview Workerの同一配置に追加channelを含むbundleを反映済み。有効期限は既存と同じ **2026-09-15 09:52:36 JST**。期限更新は新しい写真の追加とは区別する。写真を増やす際はお題との一致と掲載許可を確認し、取り下げはそのchannelのcatalogから外す。公開用ではない個人写真・非公開まどの写真を使わない。

## 完了条件と検証

1. 配信先の導出・無効設定・旧互換・まど別購読をSwift境界チェックで確認する。
2. 新規まどの発見→受け取り→Widget案内のまど名→一覧までを既存部品のUIテスト1件で確認する。既存の同じ写真IDの別まど分離・片方の停止も維持する。
3. bundleの既存3枚保持、新しいchannel、JPEG hash、Workerのchannel隔離を確認し、dry-run後に同じpreview Workerへ反映する。
4. 候補CI成功→mainの成功証拠→内部TestFlightへまとめてアップロードする。Apple画面の再ログインを次の開発条件にしない。

手元の配布設定11件とdiff checkは成功。独立レビューで、テストfixtureへの新規本番通信の混入防止・Widgetの無効な新規選択肢抑制・案内名の実表示待機を確認した。

## 結果

- [候補CI 34738333552](https://github.com/soso-so-27/neko-widget/actions/runs/34738333552) は全必要ジョブ成功。公式まど境界145件、iOS 18.6のUI14件、共有側アプリUI35件とGallery3条件が成功。新しい発見→受信→案内→一覧の1件と、既存の同じ写真ID・別まど停止の分離を含む。
- 実際に生成したSimulator画面で、公開まど2枚のカードの揃い、案内の「おひるね」、受信したまどだけが一覧に出ることを目視確認。テスト用イラストの画面と、配信する承認済みの実画像は区別した。
- mainへ同じSHAを反映。[main CI 34740635177](https://github.com/soso-so-27/neko-widget/actions/runs/34740635177) は上記push候補の成功証拠を再利用して成功し、一式の再検証は行っていない。
- 配信反映は2026-09-13 12:37 JSTまでに完了。Worker version `44921d99-5539-42ee-9caf-a7e60014ab13`。旧catalog・3枚のJPEGと新catalog・1枚のJPEGでHTTP 200とbundleのhash一致を確認。おひるねにない写真の経路は404。旧3枚と掲載日は保持した。
- 新しい配信先は [おひるねcatalog](https://neko-widget-official-cats-preview.nakanishisoya.workers.dev/windows/nap-cats/catalog.json)。[配置記録](C:/dev/neko-theme-window-20260913/output/theme-window/nap-cats-20260913T033158Z/DEPLOYMENT.md) と [実HTTPS結果](C:/dev/neko-theme-window-20260913/output/theme-window/nap-cats-20260913T033158Z/http-result.json) を保存。
- TestFlight **1.0 (160)** は [run34740960779](https://github.com/soso-so-27/neko-widget/actions/runs/34740960779) で署名・Appleへの検証・アップロード成功。2026-09-13 **14:47:35 JST**、実ログの `VERIFY SUCCEEDED with no errors` と `UPLOAD SUCCEEDED with no errors` を確認。Delivery UUIDは `3cddba02-1ffe-4c90-815f-10b10cf9a5ca`。製品SHAは上記e815406。IPA・archive・dSYMは既存の暗号化artifact保存を使用した。内部配布画面の追加照合は行わず、ユーザー指定に従ってアップロード成功を基本の完了証拠とする。
- 最初のrun34740677713は、実行時に必須の `retain_signed_artifacts=true` をfalseで指定したため、アーカイブ前に停止。入力だけを修正して同じ製品SHA・同じ160で再実行した。アプリ検証の再実行はしていない。

追加CI短縮の試作 `47f881e` は時間上限で中断し、不採用。製品は従来の成功構成を維持した。[試作結果と進め方の修正](2026-09-13-ci-parallel-trial-result.md) を参照。

## 残る確認と運用

利用者のiPhoneホーム画面に実際に置いた結果と更新タイミングは未確認。Simulatorの操作・描画成功をその代用にはしない。最初の固定1枚を配る段階であり、新しい写真の継続供給・投稿受付・自動更新運用は未開始。N08で扱う。
