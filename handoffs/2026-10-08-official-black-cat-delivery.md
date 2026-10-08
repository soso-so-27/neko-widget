# 黒猫10枚の公式preview配信

2026-10-08 23:27 JST、既存の「どこかの猫」へ黒猫シリーズの配信を反映した。利用者の「設定してほしい」と元ZIPの提供に基づく既存内部TestFlight向け更新で、アプリのビルドや一般公開の変更ではない。

- 対象は既存 `neko-widget-official-cats-preview` / `official-cats`。Worker versionは `d2ef82ea-4b15-4892-8f93-ecb0d89b6b64`。
- 元ZIPは利用者がDownloadsへ保存した `black-cat-series-10 (5).zip`。6,358,780 bytes、SHA256 `29e62202cbaa589517f32f50e82f0326be508baf61ba87df60fe400a5b71a2ea` が既存の原本記録と一致した。
- 元のasset-listの01〜10順（家8枚、パリ、オーロラ）を保持。全画像1254正方形RGB JPEG、hash・サイズ・metadata・製品JPEG validator成功。10枚を目視確認し、既存publisherで掲載用に加工した。原本のdraft/未承認表記は書き換えず、今回の有限preview掲載判断を別の `publication-review.json` に記録した。creditは「ねこのまど・AI生成」。
- 開始Sは **10/8 23:23:15 JST**、実反映は23:27。次の1枚は **10/9 23:23:15 JST**。以後24時間間隔で10/17まで1枚ずつ追加し、全予定を **10/18 23:23:15 JST** に終了する。各画像の期限は掲載+7日または全体終了の早い方。過去の掲載も期限内は閲覧できる。
- 旧queue6行と全掲載履歴を維持し、新10行のみ追加。期限切れ旧写真は復活させない。「おひるね」「キジ白のまど」はenabled=true・写真0枚のcatalogになった。以前の期限終了503から空catalog200への変更であり、新写真の供給や新まど追加ではない。

既存OAuthで対象アカウントを確認し、記録版 `de1d9a35-ccef-4219-b5dd-8f5dde79d968` と全3窓503を正式に照合した。以前の読取コマンド失敗を成功扱いせず、元画像受領後の新しい検証で解消した。新しい資格情報・権限・契約・料金設定は作成/変更していない。

既存serviceテスト103件が成功（49.384秒、失敗/skipなし）。実候補では全10版、旧履歴、各日直前/切替、全期間終了後、未来/旧画像/内部URLについて製品Workerへの335回のローカル要求を確認した。固定Wrangler4.125.0のdry-run成功後、pendingを排他的に作り、直前の実version/current/queueと候補hashを再照合して**1回のみ配備**した。配備後の現在catalog・1枚目JPEGのhash、未掲載/内部URL拒否、旧履歴15URLの404を確認し、成功後にcurrentを原子的更新した。pendingは完了記録へ移動済み。

実機/Widgetへの反映は未確認。サーバー配信成功と区別する。新しいTestFlight・iOS CIは不要で、実行していない。最初の具体候補23:23:15から反映確認まで3分56.5秒。これは素材取得待ちを含む総日数ではない。10/5〜10/8の素材未取得・認証/実版照合待ちの履歴は旧taskの記録に保持した。今回のローカル候補確認スクリプトは初回に構文エラー1件があり、括弧修正後に上記335要求をすべて実行した。製品コード・検証条件は変更していない。

## 正本と引継ぎ

正本は引き続き `C:/dev/neko-official-supply-20260913/output/runtime/current.json`。固定checkoutの既存09:00/21:00読取監視は、このpointerを参照する。自動補充・期限延長はしない。

- currentBundle: `C:/dev/neko-evidence/official-black-cat-20261008/candidate/bundle`
- queue: `C:/dev/neko-evidence/official-black-cat-20261008/approved-queue.json`
- 元画像、加工画像、掲載判断、実候補検証: `C:/dev/neko-evidence/official-black-cat-20261008/`
- 配備ログ、前後照合、completed-pending: `C:/dev/neko-official-supply-20260913/output/runtime/runs/20261008T142641779Z-black-cat-rollout/`
- 完了記録: evidence rootの `completion.json`

これらのbundle・queue・参照JPEGは実運用入力なので削除しない。次の補充はこのcurrentを基点とし、旧予定の再配備・履歴の初期化・期限切れ画像の復活を行わない。
