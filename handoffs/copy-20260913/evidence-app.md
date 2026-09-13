# 原稿照合記録 — TestFlight案内・英語審査メモ

2026-09-13。作業基点main `f90beaf`、対象アプリ仕様は1.0 (161)。製品SHAは `9f15984fe7188b0f2fc3a0e21316239d94eaa862`。そのSHAから作業HEADまでの `NekoWidget/NekoWidget`・`Shared`・`NekoWidgetWidget` の差分がないことをgitで確認した。配信内容はアプリの新しいビルドなしで変わり得るため、原稿に画像枚数や定時到着の約束を固定していない。

## 原稿の状態

- 作成したもの：`testflight-ja.md`（共通紹介／What to Test）、`review-notes-en.md`（英語審査メモ）。いずれも掲載前原稿。内部管理文をASC本文へ貼らない。
- Build161はAppleへのアップロード成功まで記録済み。内部配布画面、利用者の161実機反映、外部審査・招待の完了証拠とは区別する。
- 外部対象build／専用group／指定先と提出・招待の最終承認は本バッチで決めていない。旧Build71の外部例外を161へ自動適用しない。安全対応担当・連絡先は回答済みで再質問しない。
- ASCの現在の掲載内容と公開サイトはroot担当。この担当ではASC・サイトの操作、外部送信・公開、ビルド・CIを行っていない。
- rootの実掲載確認では、ASCはログイン画面で現在の保存値は未確認。旧原稿に残る2026-09-10の共通説明保存証拠と今回の新原稿を区別する。既存privacy/support/communityはHTTP200でも「公開フィードなし」等の旧説明が残り、rootが別途差し替え原稿を作成する。英語メモのURLは既存の案内先を維持したもので、リンク先の文言整合や差し替え完了を意味しない。

## 少数の照合根拠

以下のコードパスはすべて `C:/dev/neko-copy-alignment-20260913/` を基準とする。記載した行を読み取った範囲での根拠であり、今回の実機試験ではない。

| 原稿の内容 | 根拠 |
|---|---|
| 161の範囲と未確認事項 | [公開まど運用記録](../2026-09-13-public-window-operations.md)の「確認した範囲」にSHA・全必要CI・Appleアップロード成功。 [現行台帳](../2026-09-13-current-task-board.md)の冒頭、N10、回答済み担当の記載。外部対象・審査・招待は完了扱いにしない。 |
| 公式2まど、任意の読み取り専用購読、AI credit | [OfficialWindowStore.swift:18](C:/dev/neko-copy-alignment-20260913/NekoWidget/Shared/Storage/OfficialWindowStore.swift:18)に`official-cats`と`nap-cats`。 [OfficialWindowView.swift:358](C:/dev/neko-copy-alignment-20260913/NekoWidget/NekoWidget/Views/OfficialWindowView.swift:358)に受信開始、同407–408行に運営選定・投稿不要・AI表示、同267行に停止確認。 [最新供給記録](../2026-09-13-official-supply-and-maintenance.md)にAI creditと公開中／予定素材の区別。 |
| 初回スキップ・自分の写真からの共有 | [OnboardingView.swift:77](C:/dev/neko-copy-alignment-20260913/NekoWidget/NekoWidget/Views/OnboardingView.swift:77)は写真アクセスを後回しにする経路。 [LikedPhotosView.swift:1936](C:/dev/neko-copy-alignment-20260913/NekoWidget/NekoWidget/Views/LikedPhotosView.swift:1936)に「まどへ届ける」、同2050行に選んだ写真の送信画面。 |
| 宛先確認・任意ひとこと・送信前の取消 | [MomentDeliveryComposer.swift:64](C:/dev/neko-copy-alignment-20260913/NekoWidget/NekoWidget/Views/MomentDeliveryComposer.swift:64)に届け先と変更、同97行に確定送信、123行に「やめる」、185行に任意入力。 [PairingView.swift:879](C:/dev/neko-copy-alignment-20260913/NekoWidget/NekoWidget/Views/PairingView.swift:879)に12語照合、同282行にOSのセンシティブな内容の警告。暗号化の説明は旧審査原稿の既存契約を維持し、公開HTTPS feedへ拡張しない。 |
| 私的Widgetハート・受信保存の副作用 | [NekoWidgetView.swift:65](C:/dev/neko-copy-alignment-20260913/NekoWidget/NekoWidgetWidget/NekoWidgetView.swift:65)は公開写真の表示を私的操作と分岐、同180行に私的Widgetハート。 [FamilyWindowView.swift:2243](C:/dev/neko-copy-alignment-20260913/NekoWidget/NekoWidget/Views/FamilyWindowView.swift:2243)に位置情報を除くPhotos保存・相手へ通知しないこと、同2246行にiCloud同期とコピー保持。 [MomentCanonicalPreviewBuilder.swift:128](C:/dev/neko-copy-alignment-20260913/NekoWidget/NekoWidget/Services/MomentCanonicalPreviewBuilder.swift:128)は送信JPEGのAPP/COMメタデータ除去。 |
| 通報OFF・ブロック解除 | [SharingAPIConfiguration.swift:129](C:/dev/neko-copy-alignment-20260913/NekoWidget/Shared/Sharing/SharingAPIConfiguration.swift:129)で暗号化通報は常にfalse。 [FamilyWindowView.swift:2232](C:/dev/neko-copy-alignment-20260913/NekoWidget/NekoWidget/Views/FamilyWindowView.swift:2232)にTestFlight連絡と添付禁止事項。 [BlockedSharingView.swift:62](C:/dev/neko-copy-alignment-20260913/NekoWidget/NekoWidget/Views/BlockedSharingView.swift:62)に解除しても共有・削除写真は復元しないこと、旧版・別端末の制限。 |
| 最低OS・販売を約束しない | [Config.xcconfig:11](C:/dev/neko-copy-alignment-20260913/NekoWidget/Config.xcconfig:11)はiOS17.1、同26–29行はStorefront/billing無効・商品ID空。 [PlusPurchaseStore.swift:39](C:/dev/neko-copy-alignment-20260913/NekoWidget/NekoWidget/Services/PlusPurchaseStore.swift:39)は有効設定と両商品IDを要求。新料金・購入・自動有料移行は原稿へ追加しない。 |

## 旧原稿からの主要な変更

照合元は [2026-09-10外部1名原稿](C:/dev/neko-widget-mainline-20260907/handoffs/2026-09-10-external-one-review-copy.md)。旧原稿自体は変更しない。

- 「公開フィードなし」「There is no public feed」を削除し、運営配信の2つの公開まどを案内。私的まどの写真を一般公開する機能とは区別した。
- 公開まどを受け取る操作から試せる構成へ。自分の写真・猫登録・共有相手は必須にしない。公開まどに未実装の投稿・ハートを案内しない。
- 個別写真の送信、任意ひとこと、私的Widgetハート、受信保存、ブロック解除の説明は現行操作へ整理。無料限定テスト、通報OFF、添付禁止、回答済みの48時間安全対応を維持した。
- 現行の外部例外文言は [testflight.yml:17](C:/dev/neko-copy-alignment-20260913/.github/workflows/testflight.yml:17)と [境界検査:38](C:/dev/neko-copy-alignment-20260913/NekoWidget/ci/test-limited-external-beta-reporting.py:38)でBuild71限定のまま。原稿更新によって161の審査提出・外部招待を承認済みにはしない。

## 確認の限界

既存コード・記録の限定照合と原稿の静的確認だけ。外部テスターの利用開始、ブロック→解除→新招待の実機完了、161の実機表示、初回の予定自動配信は確認していない。外部提出に進む際は既存N10の対象・安全操作・当該buildの運用条件を扱い、今回の原稿作成を代用しない。
