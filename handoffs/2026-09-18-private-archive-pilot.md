# N29：写真と言葉のCloudKit保管・実接続バッチ

## 到達点

本人が明示して選んだ一写真と言葉を私有CloudKitへ保管し、同じApple Accountの空のアプリ状態へ取り戻す。既存のメモ・お気に入り・PhotoKit原本・共有まどは変更しない。原本バックアップ、全件自動同期、共同編集、販売開始は今回の範囲に含めない。

起点main `2ae677a`、worktree `C:/dev/neko-solo-cloud-recovery-20260918`、branch `codex/solo-cloud-recovery-20260918`。研究worktreeには触れない。

## 実装する流れ

- 設定内の「記録の保管」から、システムの写真選択で一枚と任意の言葉を選ぶ。写真のみ／言葉のみを許す。本人のiCloud容量、鑑賞用コピー、内部テスト中で編集・削除は未対応と有効化画面で明示する。
- 初版は追記・明示送信・明示取得。CKSyncEngineによる自動同期はこの縦断の後へ分ける。既存の全メモを移行・自動送信しない。
- 写真コピーは長辺4096px以下のJPEG。回転を適用し、GPS/元EXIFを転記しない。20MiB以下。原本ファイルやPhotoKit IDは変更・送信しない。画質は実写真の利用で確認する。
- 独立UUIDの記録と保護された画像をApp専用領域へ先に保存する。通信失敗でも保管待ちを維持する。作成画面の同じUUIDを再試行に使い、同じ内容だけ再送し、既存内容を上書きしない。
- 本人accountと変更世代を保管開始時から照合。各accountの保存領域を分離し、古い応答を画面・永続状態へ混ぜない。アカウント変更時は入力を捨てず送信を停止する。
- CloudKit私有zoneにgeneration markerを置く。既存端末は一致する保管先だけを利用し、削除・再作成されたzoneへ古い保管待ちを自動で送り直さない。本文等のpayloadはencryptedValues、画像はCKAssetを使用する。
- 遠隔画像が取得できなくても本文を保持し、同じ画像の検証済みローカルコピーを失わせない。旧端末のPhotoKit IDがなくても表示する。

## Apple側の接続条件

`PERSONAL_ARCHIVE_CONTAINER_IDENTIFIER` は新規登録した `iCloud.jp.nekowidget.app.personal`。値を空にしたビルドではclientを作らず、設定入口も表示しない。App本体だけにCloudKit entitlementを追加し、DebugはDevelopment、ReleaseはProductionを明示。Widget/Share Extension/研究アプリの権限は変更しない。

2026-09-18、Apple Developerへのログインを確認し、専用containerを登録、`jp.nekowidget.app`へ割当保存済み。既存のApp配布profileはcapability変更で無効になったため、同じ証明書のまま再生成中。新profileのCI登録と開発／配布schemaは配布前に完了させる。通常のTestFlight成功確認のための再ログインではない。

## 必要な検証

Swiftの保存境界検証（永続化・再試行・account・generation・部分取得）と、写真コピーの回転/位置情報除去/原本非変更をMac CIで確認する。製品View＋Storeを使うオフライン画面試験は、空一覧から取得→写真と言葉を開く→新しい言葉を明示保管する一操作に絞る。これは実CloudKit認証・通信・別端末復旧の証明ではない。

設定・接続・実機復元・提供可能という段階を混同しない。既存noteの成功済み確認やアプリ全体の利用者確認を改めて依頼しない。CIの必須条件は維持し、必要な失敗箇所だけ修正する。

実装・独立レビューを実施。レビューで見つけた、再試行失敗時の一覧消失、初回zone準備失敗後の再試行不能、同じdraftの重複、古いaccountの遅延応答を修正。ローカル開発フロー検証8項目は31.3秒で成功。CloudKit実接続、Swiftコンパイル、実画面描画、TestFlightはまだ未完了。
