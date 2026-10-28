# 内部TestFlight 310

- 所有者指示: 1028e。最初の候補確認は2026-10-28 14:09 JST。配布前の運営確認更新を含め、ここからの累計時間で記録する。
- 製品候補: main `ec4334f8d134e632dc85638896917ffdfa7e13bb`。最新mainを確認済み。配布には本書と新しい有限readinessを含む統合後SHAを固定する。
- 309との差分: 写真タブの旧押し出し方式・比較スイッチ削除（#567）、端末内の旅立った日と年齢表示（#568・#570）、家族手帳の窓口と脱退・除外・解散の分離（#569）、グループの通報・ブロック・返答の試作画面（#572）。#573の本物adapterも含むがDebug/Releaseとも設定NOで、310の画面は試作のまま。
- #466・#467は既にmainへ統合されている。#467の16ファイルはすべてSharingServiceで、Swift・Xcode・配布workflowに変更なし。この配布workflowはWorkerを配備しない。#468〜#470は未統合。通知の追加有効化は行わない。

## 直接確認と残る検査

- 製品候補の通常CI `40640912223` はBuild/unit/launchとPrivacy/saved-data/sharingの両必須job成功。#573のnative暗号相互運用・保存・中断再開・元端末への返答・OFFの対象検査も成功済み。コードとCIを実機描画の証明にはしない。
- 旧readinessは運営コード2本の変更により拒否され、その後14:41に失効した。既知の失敗のままrelease CIを開始せず、変更後コードで本人確認と合成写真の実表示から更新した。旧閲覧証拠の付け替えは行わない。
- 16:05〜16:07、現在コードの運営ホストでWindows本人認証、既知の新しい1ピクセル合成写真の実表示、再認証による「対応不要」の保存を直接確認。DB/R2への隔離seedによる運営確認であり、iPhoneからのHTTP通報受付全体の検証ではない。
- Windows鍵保護確認を同一本人・鍵・権限で再起動し実検査成功。本人限定Sandboxの受付は開始・終了だけ更新し、同一本人・鍵・Workerコード・その他設定の不変を確認。両期限は2026-10-29 15:41:23.956 JST以内。
- staging Worker `65757ee4-ab33-4823-a9d3-2b9b422026be`。group YES / group report NO / group moderation YES / group APNs NO。グループの合成資料では本人閲覧→写真停止→解除を実施し、署名付き返答と通常写真metadataの404→200を確認。普通の写真本体の取得と、実iPhoneから本物adapterを通す一周は未確認。
- 運営画面の既知事項: 解除後の選択中詳細は更新されるが、一覧行の「写真停止」は一覧再読込まで残る。本物の一般受付前に修正する。一般受付はOFFのまま。
- 16:10時点の残り検査: 新しい閲覧receipt・決定と現在コードを照合した2署名、既存verifier、現在runtime、候補CI、archive/exportの設定と署名、Apple upload、TestFlightの「テスト中」と内部グループ。
- 実機未確認: 旅立った日の入力・年齢、家族手帳の操作、通報・ブロック・返答の試作画面。310では本物の通報送信は確認しない。

## 配布設定と時間

- 309と同じ: `testflight.yml` / ref main / build_number=310 / release_mode=media-staging / preservation_pilot=true / internal_reports=true / billing_sandbox=true / group_windows=true / upload_to_testflight=true / retain_signed_artifacts=true / legacy_release_evidence=false。
- official_window_feed_url: `https://neko-widget-official-cats-preview.nakanishisoya.workers.dev/catalog.json`。
- 配布先は既存内部グループ「自分用」。App Store審査・一般公開・外部TestFlightは含まない。App Store版は手動リリースの選択を確認済み。
- 直近通常CIは約13〜17分、309のarchive/export/uploadは17分33秒、TestFlight表示まで約21分。readiness確定後から候補CI＋配布確認に約35〜45分。初回候補14:09からの本人操作待ち・環境更新・失敗の時間を除外しない。
- 16:10時点は未dispatch・未配布。Windows本人操作は完了し、Appleログインも確認済み。

## 16:14の配布候補確定

- 新しいNW2閲覧receiptとsource snapshot、本人・認証・no_action決定・返答の結合、現在31ファイルのコード、D1/R2の既知資料、staging/Sandboxの対象を照合し、2署名を作成。変更なしの正規verifierで成功した。
- `internal-purchase-sandbox-report-ui-continuation` の現在runtime検査成功。healthとbillingは200、認証必須操作は401、旧共有経路は503で無効。鍵・対象・権限・一般公開の承認を広げていない。
- 今回のcommit差分は既存の配布用readiness JSONとこのリリース記録だけ。製品コードは上記成功CIの候補から変更なし。新しい候補CIが自動起動した後は追加の手動全面再検査を行わない。候補成功後、統合treeが同じであればその成功を保持する。
- 次は候補CIと固定mainからのarchive/export/upload、Appleの内部配布表示。16:14時点でまだdispatchしていない。
