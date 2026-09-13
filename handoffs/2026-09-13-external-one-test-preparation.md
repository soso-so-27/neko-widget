# 指定1名への外部TestFlight準備 — 1.0 (163)基準

2026-09-13。準備資料であり、外部審査への提出、Apple承認、招待、相手端末での利用開始を示すものではない。指定1名への準備はN10の採用済み課題。一般募集・public link・2人目・課金・App Store一般公開は対象外。

## 対象と現在地

| 項目 | 現在の根拠／次に確定すること |
|---|---|
| 準備の基準 | 1.0 (163)、製品SHA `91a476c50dfd392cbb72fbe722921a2160fe0311`。9/13 22:16 JSTにAppleへのアップロード成功。163の実機確認、外部審査・配布は未確認 |
| 最終対象 | 163は照合基準。次版候補が出たら対象build・source・ASC build IDと差分の案内を差し替える。旧buildの承認や検証で新binaryを証明しない |
| 配布先 | 指定した既知の1名のみ。最終対象buildだけの専用external group、public link OFF。実連絡先・招待コード・確認フレーズはgit管理外に保持する |
| 提出・招待 | 最終候補への所有者承認と当該buildの限定条件を確認してから別途行う。本資料作成や内部アップロードの承認を代用しない |
| 担当と連絡 | 連絡先と安全対応担当は回答済み。安全上の連絡は48時間以内に初回確認し、必要時は停止を先行する。写真の更新頻度とは別の約束で、再質問しない |

本資料の照合基点はmain `b7f1fac`。163の製品SHAから、この基点のapp／Shared／Widget／Configに差分がないことを読み取りで確認した。以下の掲載用本文に、この内部管理表や個別の連絡先を貼り付けない。

## 共通紹介・日本語原稿

「ねこのまど」は、猫の一枚をホーム画面で眺めたり、iPhoneの猫写真を見返したりするアプリです。猫の登録や共有相手は必須ではなく、初回の写真確認を後回しにして始められます。

自分の写真がなくても、公開まどの「どこかの猫」「おひるね」「キジ白のまど」から、運営が選んだ画像を受け取れます。投稿は不要です。現在の掲載画像はAI生成で、提供元に「ねこのまど（AI生成）」と表示します。受け取るまどを選び、個別に受け取りを止められます。公開写真のうち対応する猫には「この猫のまど」への入口もあります。

自分の写真は、許可した範囲で端末内の猫写真を見つけ、写真・思い出・Widgetで楽しめます。対象の写真がそろうと月の便りや季節のムービーも見返せます。親しい相手との非公開まどでは、開いた写真から届け先を選び、任意のひとことを添えて送れます。写真とひとことはエンドツーエンド暗号化され、送信画像の位置情報は除去します。受信写真にはハートを返したり、確認して写真アプリへ取り込み、思い出に残したりできます。

公開まどは運営配信の公開コンテンツで、非公開まどとは別です。公開まどへの投稿・送信・ハートはありません。現在は購入手続きや自動の有料移行がない無料の限定TestFlightです。Widgetの更新時刻はiOSが調整するため、即時の切替は保証していません。

## What to Test・日本語原稿

試せる項目だけで構いません。投稿や毎日の操作は必要ありません。

1. **写真や相手がなくても始められるか**：「まど」→「＋」→「公開まどを探す」から、気になるまどを開いてください。写真を大きく見て戻り、「このまどを受け取る」で追加できます。見るだけでは受信は始まりません。対応するキジ白の写真に「この猫のまど」があれば、そこから追加し、元の写真へ戻る流れも試してください。
2. **Widgetで眺め、同じ写真を開けるか**：設置案内からWidgetを置き、表示するまどを選んでください。表示中の写真をタップしたときの写真と戻り先、写真が切り替わる様子を確認してください。更新には時間がかかる場合があります。受け取りをやめるときは、そのまどの「管理」メニューを使います。一つを止めても、ほかのまどの受信設定は維持されます。
3. **自分の写真を見返しやすいか**：写真アクセスを許可する場合は、開く・拡大する・思い出に残す・見返す流れを試してください。個人写真Widgetで似た写真が続きすぎないかも、普段の利用で気づいた範囲を教えてください。月の便りやムービーがまだなくても使えます。
4. **任意の非公開共有**：共有も試す場合は、開発者と確認したテスト用まどで、個人情報のない写真1枚を使います。招待後は両iPhoneの12語が一致することを確認してから承認してください。「まどへ届ける」で届け先と写真を確認し、必要ならひとことを添えます。「やめる」で送らず戻れること、確定後に同じ写真・ひとことが相手のアプリとWidgetへ届くことを確認してください。「送信しました」は相手の受信・閲覧を示しません。届いた詳細で全文、ハート、「思い出に残す」も試せます。写真アプリへの保存は確認と許可を伴い、取り込んだコピーは共有終了後も残ります。

迷った点は、Build番号と「どの画面で、何をしようとして、どうなったか」をTestFlightの「ベータ版フィードバックを送信」からお知らせください。この限定ベータではアプリ内の暗号化通報は停止中です。写真、招待コード、確認フレーズ、暗号鍵は添付しないでください。問題のある相手は受信写真の安全メニューでブロックできます。対応するブロックを設定から解除しても、以前の共有や削除した受信写真は戻りません。

## Beta App Review Notes — English draft

Neko no Mado requires iOS 17.1 or later. This is a free limited beta with no purchases or automatic paid conversion. The solo and public-window experience requires no app sign-in or review credentials. The proposed external test is restricted to one known, trusted tester in a dedicated group containing only the specifically approved build, with the public invitation link disabled.

Personal photos and another participant are optional. Skip the initial photo check, open まど (Windows), tap +, then 公開まどを探す (Explore public windows). Three operator-published windows are available: どこかの猫, おひるね, and キジ白のまど. Browse or enlarge an image, then choose このまどを受け取る (Receive this window) to subscribe. Browsing does not subscribe automatically. A supported cat photo also provides この猫のまど (This cat's window), from which the tester can subscribe and return to the original photo. Each window can be stopped separately from its management menu.

These are read-only public HTTPS feeds, separate from private encrypted sharing. Current images are AI-generated and credited ねこのまど（AI生成）; they are not presented as photographs submitted by a real owner. Public-window reception does not upload the user's photo library. There is no public posting, user directory, public heart, or reply feature. Images may expire or be withdrawn. The widget guide explains how to add a Home Screen widget and select its window. Tapping a displayed photo opens that photo if it is still available. Widget refresh timing is controlled by iOS and is not guaranteed to be immediate.

For personal photos, allow access to selected photos or the photo library. Cat-photo detection runs on device within that permission. Open a photo, enlarge it, keep it in 思い出 (Memories), and view it again. Cat registration is optional. Monthly photo letters and seasonal movies depend on available photos.

Optional private sharing requires two iPhones running the selected test build. Create a private window on one phone and join using its invitation on the other. Compare all 12 verification words on both phones and approve only when they match. Enable Settings > Privacy & Security > Sensitive Content Warning and complete the app's sharing consent when requested. Open a local photo, choose まどへ届ける, select the connected private window, and review the photo and destination. A caption is optional; やめる cancels before sending. Private photos and captions use end-to-end encryption. The app reduces image size and removes location metadata before sending. A sent confirmation indicates server acceptance, not receipt or viewing by the other phone.

Recipients can read the full caption and send a heart in the app; the private-window widget also offers a heart. 思い出に残す imports a received photo into Photos after confirmation and permission. The imported copy may sync according to iCloud Photos settings and remains after sharing ends or a participant is blocked. These private-sharing actions are not offered by public windows.

Encrypted in-app reporting is disabled in this beta. Use TestFlight feedback without photos, invitation codes, verification phrases, or keys. The designated operator has accepted initial safety-feedback review within 48 hours, including holidays, and stopping sharing when needed. A received photo's safety menu can block the participant. Supported blocks created on this iPhone can be removed in Settings > ブロックした共有, but this does not restore the old connection or deleted shared photos. Sharing again requires a new invitation and verification by both people. Separately imported Photos copies cannot be remotely recalled.

Privacy: https://soso-so-27.github.io/neko-widget/privacy/

Support: https://soso-so-27.github.io/neko-widget/support/

Community standards: https://soso-so-27.github.io/neko-widget/community/

## 外部開始前に残す最小の確認

1. **最終対象だけの承認と配布条件**：build／source／ASC build ID／専用groupを結び、提出とApple承認後の指定1名への招待を確認する。既存release文書・workflowの外部例外はBuild71限定のままなので、選定したbuildだけの例外と証拠を整合させる。人数1・public link OFF・report OFF・署名／privacy／runtimeの実検査を維持し、ほかのbuildへ広げない。本資料はそのgateを変更しない。
2. **一度の実機確認をまとめる**：テスト用まどで接続→同じ写真とひとことの実送受信→Widgetからその写真を開く→ハート到着／Photos保存を確認する。同じ写真で拡大画質も見る。その後ブロック→設定から解除→旧接続・削除した受信写真が戻らない→新招待と双方確認でのみ再開、までを1回記録する。取り込んだPhotosコピーが残ることは不具合扱いにしない。既存の同等実機証拠が得られた場合は再利用し、fixture合格を実サービスの到着証拠に置き換えない。
3. **公開まどの体験と提供期間**：公開まどの任意受信、猫のまどへの入口、Widgetの表示元・対象写真・独立した受信停止を実機で確認する。現在の予定は9/27 09:00 JSTまで。提出／招待時に、試す期間を覆う承認済み予定があることを正本で確認する。HTTP成功をWidget反映済みと扱わず、定時到着や永久供給も約束しない。
4. **案内と安全運用の照合**：旧「公開フィードなし」がPrivacy／Support／Community／ASC本文に残らないよう、現行原稿と実際の保存値を確認する。App Privacyは既存の公開済み状態を未実施へ戻さず、最終binaryとの必要差分を確認する。当該版のアップロード・処理状態と直近の共有監視／media・APNs ON／report OFFを結ぶ。連絡先と48時間担当は回答済みを使用する。旧71や146の結果を163の実績にしない。

Apple審査・指定1名への招待・インストールは、この準備の後の別段階。配布や処理に問題がある場合、または実際に外部提出へ進む時に必要なApple側の状態を確認し、毎回の再ログインを通常開発の条件にしない。

## 根拠と確認範囲

- [最新台帳のN08／N10](2026-09-13-current-task-board.md)、[163のアップロード記録](2026-09-13-widget-capture-spacing.md)、[運用窓口](2026-09-13-operating-desk.md)。連絡先・48時間担当は回答済み、163の実機と外部開始は未確認。
- [3まどの定義](../NekoWidget/Shared/Storage/OfficialWindowStore.swift)の18–35行、[公開まど一覧](../NekoWidget/NekoWidget/Views/MainTabView.swift)の1105–1128行、[受信・停止・出自説明・猫のまど入口](../NekoWidget/NekoWidget/Views/OfficialWindowView.swift)の365–423／805–823行を限定読取。猫別追加の既存検証は[162の記録](2026-09-13-cat-public-window.md)。
- [送信確認](../NekoWidget/NekoWidget/Views/MomentDeliveryComposer.swift)の64／123／147行、[12語照合](../NekoWidget/NekoWidget/Views/PairingView.swift)の879行、[受信保存・安全案内](../NekoWidget/NekoWidget/Views/FamilyWindowView.swift)の2233–2246行、[ブロック解除の制約](../NekoWidget/NekoWidget/Views/BlockedSharingView.swift)の62–63行。通報OFFは[SharingAPIConfiguration.swift](../NekoWidget/Shared/Sharing/SharingAPIConfiguration.swift)の129行、最低OS・購入OFFは[Config.xcconfig](../NekoWidget/Config.xcconfig)の11／26–29行。
- [有限予定配信の記録](2026-09-13-continuous-operations.md)を参照。今回scheduleの再監査・再試験はしていない。新規原本、配備、外部連絡、審査提出、ASC／サイト保存は行っていない。
- [旧外部1名原稿](C:/dev/neko-widget-mainline-20260907/handoffs/2026-09-10-external-one-review-copy.md)と[161の照合原稿](copy-20260913/evidence-app.md)を履歴として維持。旧「公開フィードなし」と2まど前提を本資料で更新した。外部例外の現状は[Media-Staging-TestFlight手順](../NekoWidget/docs/Media-Staging-TestFlight手順.md)の66行以降と[testflight.yml](../.github/workflows/testflight.yml)の17行で確認した。
