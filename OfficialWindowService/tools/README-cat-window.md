# 初回の猫まどを準備する

固定対象は `cat-tabby-nap`／`generated-tabby-nap`／「キジ白のまど」。運営が確認した既存公開画像を参照する初回専用ツールで、任意のまど・URL・原本・投稿を受け付けない。

```powershell
node tools/prepare_cat_window.mjs --previous <現在の実配備bundleの絶対パス> --window cat-tabby-nap --output <存在しないローカル出力先の絶対パス>
```

- 親ディレクトリは事前に作り、出力先自体は作らない。最終候補は返された`bundle`、確認記録は`creation-record.json`。
- 現在有効な`official-cats`からexact catIDだけを参照する。同じ毛柄の`generated-tabby-v3`は別の猫として除外。source catalogの期限切れ・休止、該当写真なし、既存ID衝突、履歴不足は拒否する。
- 原photo ID、初回掲載日、hash、JPEG、credit、caption、写真期限を保持。新しい写真として`added`へ数えず、`referenced`へ記録する。新窓の公開catalogは既存schemaのまま、`catID`制約は非公開の`update-record.json`へ保存する。
- 既存の全まど・履歴・休止状態を`prepareUpdate`で維持し、期限切れ写真の除去とcatalog更新を行う。以後の同ツールは猫まどの`catID`を保持し、別猫の履歴・現catalog・追加、固定窓の制約欠落を拒否する。停止した猫まどを初回作成で復活させない。
- Workerと配備先設定が既存bundleと違う場合は停止。画像はhash・寸法・metadataを再確認してコピーし、再生成しない。失敗した途中出力を削除・上書きしない。

これは未配備のローカル準備。配備担当は[既存保守手順](../MAINTENANCE.md)のpending排他・version再照合・dry-run・配備後検証を守る。`verify_preview.mjs --previous <旧bundle>`は、この固定猫まどの初回だけ旧URLがないことを許容し、新catalogとJPEGは通常どおり照合する。既存まどの旧catalog欠落は許容しない。

固定保守checkout・runtime pointer・許可されたまど一覧の更新は配備担当が別途行う。古い保守ツールのまま新bundleを指すと猫ID制約を引き継げないため、このバッチの`prepare_update.mjs`を含む検証済み版へ揃える必要がある。本ツールはそのcheckoutやpointerを変更しない。
