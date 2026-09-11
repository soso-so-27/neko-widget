# 公式まど：Build 150の確認版

## 目的と状態

送る相手や自分の猫写真がなくても、公式まど「どこかの猫」を受け取れるようにする。初回の写真提供元は利用者自身の猫に決まっているが、原本と猫の公開名は未指定。技術作業を止めず、明示した合成テスト画像で配信先・アプリ・Widgetをつないだ。

2026-09-11 08:43 JST、Build 150のアップロード成功。その後App Store Connectで処理完了と、既存の内部グループ「自分用」1人への配布を確認した。公式まどの確認手順と配信期限をテスト説明へ反映し、「保存済み」を確認。

[Build 150](https://appstoreconnect.apple.com/teams/c0938ad3-2941-4079-8248-0769666c8fd8/apps/6801962436/testflight/ios/aee0c22b-e4bd-4492-9068-7e3e26fb5d84)。新しい外部テスターや個人テスターは追加していない。2026-09-11、利用者から「Bをウィジェットまで反映できました」と報告あり。確認用画像Bの受信から実機Widget表示までを利用者報告による確認済みとして記録する。タップ先、受け取り停止、設置済みWidgetでの次の配信への更新は、この報告だけでは確認済みにしない。

## 配布コードと検証

- 配布コード/main: `68fd1f40240f9074fa0151ddabca21283cdc7531`。mainの最新状態を再fetchしたうえでfast-forward反映。研究・旧本線のworktreeには変更なし。
- 候補CI: [34538665138](https://github.com/soso-so-27/neko-widget/actions/runs/34538665138)。build、smoke、iOS18.5/26.2 sharing、判定の全4jobs成功。
- main CI: [34542621486](https://github.com/soso-so-27/neko-widget/actions/runs/34542621486)。同じSHAの上記成功証拠を確認して再利用。
- TestFlight: [34542676736](https://github.com/soso-so-27/neko-widget/actions/runs/34542676736)。`media-staging`、Build150、署名artifact保持、アップロード成功。通常のApp Store用disabledは公式URL空を維持。
- release入力/関連25件、撮影境界12件成功。release入力は固定HTTPS URLだけをmedia-stagingに許可し、archive内のApp/Widget双方のURL一致を検証。実装と独立レビューを分けた。
- 署名artifactは既存方式で暗号化し14日保存。キーや原本写真は追加していない。

## 確認用配信

- `https://neko-widget-official-cats-preview.nakanishisoya.workers.dev/catalog.json`
- TestFlight試験用の専用Worker。アクセス可能なHTTPSエンドポイントだが、内容はコードで作った図形A/Bと「合成テスト画像」の表示のみ。過去の添付スクリーンショット、実写真、個人の入力記録は掲載していない。
- 同じURLのA→B更新、JPEG hash一致、入力ファイル404を確認。macOS Foundation URLSessionでもcatalog/画像の200とhash一致を確認。
- 現在の版は**2026-09-13 07:34 JSTで期限切れ**。定時配信・自動更新は未稼働。続ける場合は新しい生成時刻のcatalogへ更新する。
- 既存の非公開まどのAPI、キー、D1/R2には接続しない。一般向けの紹介・募集、実写真の公開、App Store審査提出、課金開始は行っていない。

## Widgetで実際に見た範囲

[撮影run34539931217](https://github.com/soso-so-27/neko-widget/actions/runs/34539931217)が成功。rootが小・中・大のGalleryと、ホーム画面に設置した小WidgetのPNG4枚を表示して確認した。画像を大きく使い、猫名は左下。文字やボタンのはみ出しなし。公式Widgetには非公開まどのハート/保存ボタンを出さず、既存の非公開まどのハートは維持。

- 画像: `C:/dev/neko-widget-official-window-evidence-20260910/34539931217/exported/`
- ホーム小: `7EB92777-DCB8-4C9D-91EB-E7B9C72226AE.png`
- 小: `3D074DCA-38D2-4CB6-B3A2-0233F8316EAD.png`
- 中: `3DC7AA64-0B96-47B2-A11A-E17D7447FE22.png`
- 大: `EC6704EC-B17D-4966-B293-933C94DFD319.png`

上記PNGは合成イラストを本番のNekoWidgetViewで描画した実WidgetKit/Simulatorの証拠。これとは別に、利用者報告で確認用画像Bの実iPhone Widget表示を確認した。実猫写真の画質、設置済みWidgetでの次の配信への更新、tap・停止は未確認。中サイズは中心cropで上下を切り取るため、正式写真の顔や耳が収まるかは差し替え時に確認する。

初回撮影run34538672901は、テストが日本語のページ順序と「ウィジェット, 小」を読めず失敗した。失敗画像には正常なWidgetが表示されていた。撮影テスト1ファイルだけを`codex/official-widget-capture-20260911` / `1b0f7e6`で修正し、専用manual撮影を成功させた。全production source/設定/workflowは配布コード68fd1f4と同一。確認branchのpush CIを省いているため、それをrelease CIの成功証拠には用いない。日本語の撮影テスト修正は確認branchに保存し、次のテスト整備バッチで本線へ取り込める。

## 次の確認

確認用画像Bの受信〜実機Widget表示は利用者報告で確認済み。同じ確認を繰り返すためのビルド・配布は不要。

1. Widgetをタップし、アプリで同じ画像Bが開くことは利用者報告で確認済み。ただし「どこかの猫」を経由して詳細が開く二段階遷移を指摘された。修正は[直接表示の作業記録](2026-09-11-official-widget-direct-photo.md)へ分離し、Build150自体の動作と区別する。
2. 公式まどで受け取り停止を行い、Widgetへの反映を見る。iOSの判断によるWidget更新の遅れはあり得る。
3. 次に配信内容を差し替える際、設置済みWidgetが新しい写真へ更新されることを見る。

実際の猫写真へ差し替える残件は、原本2枚と猫の公開名の指定。提供者の初期表示名は「ねこのまど」。写真が届けば既存publisherでA/B版を作り、同じ配信先を更新する。継続供給量、配信頻度、楽しさ、有料価値は今回の技術確認で成立したとはしない。

詳細なローカル作業証拠は`C:/dev/neko-widget-official-local-proof-20260910/20260911-release-progress.md`。
