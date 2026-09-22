# 写真保管と有料会員の本人リンク

## 今回の範囲と完了条件

開始点 main `6d9f3e8`。別worktree `C:/dev/neko-preservation-billing-link-20260922`。
写真保管のApple本人sessionと、既存billing鍵の署名を両方確認してから、保管ownerとbilling accountを一対一で固定する。解約後の閲覧・取り出しはこのリンクや有料会員を条件にしない。

完了条件は、本人混同・署名再利用・期限・並行リンク・解約後の読出しを対象テストで確認し、独立レビュー、本線統合まで。既存共有Workerや稼働DB、iOS、課金開始、TestFlightは変更しない。

対象はサーバーのみ。既存保管専用CI実績は35〜39秒、local型検査/対象テストは数秒〜十数秒。今回の署名/DB連携とCI経路追加は未計測なので、同時間完了とは約束しない。CI選択は別commit・独立確認し、未知差分はfullに戻す。実装の調査・修正時間はCI時間と分けて記録する。

## 構成

- 公開保管APIでsession付きchallenge発行 → billing鍵で目的・audience・owner・billing ID・期限を署名 → 同じsessionで確定。
- challengeは1sessionに1つ・5分・一回。外部検証失敗後も使い回さず新challenge。DB書込直前にsession/ownerの失効を再確認。
- owner/billing accountは両側unique・変更/削除不可。別人への自動再リンクなし。再購入やAppleアカウント変更は今後別の本人確認手順が必要。
- 独立private authorityは既存billing署名/nonce/権利判定を直接利用。default公開fetchは404。named entrypointをprivate bindingに限定し、専用設定はOFF・ダミーDB。
- 信頼境界：一対一は同一preservation DB内で保証。別サービスの署名検証と保管DBは分散transactionではない。請求鍵の所有確認時点と保管commit時点を区別する。
- 会員状態は保存ownerからサーバーの固定リンクを辿って確認。クライアント申告のbilling UUIDだけでは権利を付けない。

private bindingの公式仕様： https://developers.cloudflare.com/workers/runtime-apis/bindings/service-bindings/ 。URLの秘密ではなくbinding権限で接続する。実配備・環境ごとのaudience・binding許可先は別途確認する。

## 残る提供開始条件

ネイティブのリンク導線・同意・エラー回復、実Apple/KMS/JPEG橋渡し/保存先、期限と容量/保持/削除方針、低速回線と20MiBピークメモリ、実機復元は未完。公開や保存サービス完成の証拠ではない。

## 実装・検証記録

- 本人リンク11件、実billing authority8件（通し1件含む）。provider redirect変更で影響する鍵7件・復元3件も成功。型検査成功。
- 初回authority通し1件は失敗。Workersの実Requestは`redirect:'error'`を受け付けない製品不整合だった。`manual`へ修正し、3xx拒否・追従なしの1件を追加。8件再実行3.22秒、root影響21件3.33秒で成功。失敗を成功扱いにしない。
- private workerの実bundle dry-run成功（20.22KiB、配備なし）。確認コマンドに混在したworkflowハッシュ読出し1回はcwd誤りで失敗し、正しいルートで再計算した。bundle自体とは別。
- 開発フロー11群は79.5秒で成功。CIはv2とし、旧v1時間をv2の実測として流用しない。
- 製品とCIの独立読み取りレビューでブロッカーなし。既存SharingService/iOS変更なし。bindingと実環境は未確認。
