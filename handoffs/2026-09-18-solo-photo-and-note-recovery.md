# N29：一人の写真と言葉を取り戻すための進捗

2026-09-18。本アプリへのクラウド保存は未実装。設計と独立したローカル試作までを記録する。共同記録の試作と、一人で復旧できる契約を分ける。

## 今回決めた開発上の方向

一人で使う利用者の復旧を、家族や送信相手の承認に依存させない。同じApple AccountのCloudKit私有DBを第一候補にし、明示して保管した写真のコピーと言葉を、新しい端末の空の状態へ取り戻せる経路を次に検証する。

既存メモやお気に入りを自動でアップロードしない。写真アプリ内のID、記録のID、保管する画像を分ける。iCloud PhotosのCloud IDは、存在する原本との再接続を助けるものとして使い分け、画像保管の代用にしない。

この候補は利用者のiCloud容量を使う。アプリの有料容量として扱わず、再発見・記録を続けたいという利用価値と、保管の信頼性を別に検証する。課金開始や有料機能の制限は行っていない。

## ローカル試作の結果

[試作と限界の記録](C:/dev/neko-evidence/n29-solo-recovery-prototype-20260918/README.md)、[実装](C:/dev/neko-evidence/n29-solo-recovery-prototype-20260918/recovery.mjs)、[検証](C:/dev/neko-evidence/n29-solo-recovery-prototype-20260918/recovery.test.mjs)。架空のPNG実バイト列と本文を使うNode.jsの状態モデルであり、製品コードやCloudKit通信ではない。

7ケース成功、失敗0件。空の別clientへの画像と本文の復元、写真のみ／本文のみ、途中失敗と再試行、account切替と遅い応答の隔離、競合時の両方保持、削除後の古いclientによる再公開拒否、画像欠落／破損時の本文と他の健全な記録の取得を確認した。

レビューで、写真の欠落が全件取得を止める問題と、部分取得が端末に残る健全な写真を捨てる問題を修正した。同じaccount・記録・digestに一致する検証済みローカル画像は維持し、遠隔の写真が復旧したとは扱わない。

現在の保管先catalogが健全に残る前提。実認証、暗号化、ネットワーク、容量不足、実写真、原本復元、壊れたcatalogの救済、完全削除、同時実行の耐久性は未検証。試作の成功を長期保管サービスの完成と扱わない。

## 次の実接続バッチ

1. App本体のCloudKit container・entitlement・保存済み署名profileの整合を確認する。現在はCloudKit entitlementがなく、既存profileの対応も未照会。秘密情報は資料へ出さない。
2. 既存の端末内メモを維持し、本人が選んだ一写真と言葉だけを、独立した記録IDで私有DBへ保管する。写真コピーの範囲とiCloud容量の扱いを明示する。
3. PhotoKitのlocal IDを引き継がない空のアプリ状態へ同じApple Accountで復元し、実画像・本文・記録IDが一致することを確認する。
4. 保存途中の失敗を完了扱いせず、写真を取り戻せない場合も本文と既存のローカル画像を維持する。別accountには表示・送信しない。

表示先は設定内の保管状況を候補とし、通常の写真画面に同期用語を増やさない。保持期間・完全削除・退出時の持ち出し条件は販売準備前に確定する。これらを未決のまま「一生保管」や原本バックアップを約束しない。

詳細は[設計案](C:/dev/neko-evidence/n29-solo-recovery-design-20260918.md)と[既存コード・署名前提の確認](C:/dev/neko-evidence/n29-solo-recovery-integration-notes-20260918.md)。この実接続を次のN29とし、関連アルバムの入口修正とは別バッチで進める。

[Apple側の実接続準備](C:/dev/neko-evidence/n29-cloudkit-connection-preflight-20260918.md)も確認。capability変更後は保存済み手動profileの再生成・更新が必要。TestFlightはCloudKitのProductionを使うため、Development試験と区別する。Web/API/Mac CI/実機の役割と、未確認の管理権限・containerを記録した。Apple側の設定変更や秘密情報の取得はまだ行っていない。
