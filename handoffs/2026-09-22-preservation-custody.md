# 個人保管：本人確認・暗号化保存・復元の本線接続

## 目的と今回の完了条件

利用者の「すすめて」を受け、main `22c9706` から独立worktree `C:/dev/neko-preservation-custody-20260922` を作成。主担当が実装と統合を引き受け、利用者に資料の転送を求めない。

旧候補 `1f476ae` の保管専用Apple認証・永続owner・D1/R2保存を本線へ移す。今回追加するのは、所有者/記録に結び付けた版付き暗号化の実装、外部応答/本文の受信上限、再ログイン後の復元を一連で確認する試験。アプリ・課金・CloudKit・共有のデータと鍵は変更しない。

成功条件は、型検査、必要な保管サービス試験、独立レビュー、専用Linux CIと本線反映。実Appleアカウント・実KMS・実2台の成功とは別。一般公開、課金開始、契約、remote migration、deploy、TestFlightを行わない。既定OFF。

## 判断

- Sign in with AppleのsubjectとStoreKitの購入所有者は別。課金復旧はactive/graceが必要なため、保管の本人復元へ流用しない。解約後も本人の既存記録を取り出せる条件を維持する。
- 写真/本文はデータごとのAES-256-GCM鍵で暗号化し、データ鍵だけを別の管理鍵で包む。所有者・用途・記録をAADに結び付け、包んだ鍵の版を保存する。管理鍵の実サービス接続は必須で、固定テスト鍵や平文へのfallbackはない。
- 管理鍵サービスの提供元や契約は今回確定しない。外部KMSアダプター、運用上の鍵保全/復旧、容量・保持・削除条件は未完として残す。コード上の暗号処理を鍵の運用保証と混同しない。
- 既存のiOS署名設定にSign in with Apple capabilityは未追加。実サービス設定と実機確認のバッチで扱い、今回勝手に有効化しない。

## 検証と費用の計画

旧候補の関連試験はApple8件約2.4秒、永続認証12件約5.8秒、保存14件約4.6秒。新しい通し確認と暗号処理の時間は未計測。新依存は加えず既存lockfileを使う。専用Linux CIを準備し、前回のJPEG部品の観測19〜23秒は参考のみで、今回の所要時間保証にはしない。5分job上限、初回測定は1回。無関係なMac全件を起動せず、選択器の変更は独立レビューする。

## 根拠

- [Web Crypto AES-GCM仕様](https://w3c.github.io/webcrypto/#aes-gcm)：標準暗号とAADを使う。
- [AWS KMSのencryption context](https://docs.aws.amazon.com/kms/latest/developerguide/encrypt_context.html)：管理鍵側にもcontextを結び付ける考え方。AWS採用の決定ではない。
- [Envelope encryption](https://docs.aws.amazon.com/encryption-sdk/latest/developer-guide/concepts.html)：データごとの鍵と管理鍵を分離する。SDK形式互換を主張しない。

## 結果

### ローカルの実装・確認

- 移植前の20ファイルは旧候補のblob hashと一致を確認。そのうちlockfileは初回の取得出力が切れておりnpm ciが失敗したため、全文を取り直し一致を確認した。利用者ファイルや旧候補は編集していない。
- 旧lockfileの開発依存にaudit指摘6件（moderate2/high4）。実際のaudit経路を読み、vitest 4.1.11とsharp 0.35.4の限定overrideで修正。依存更新2秒、audit0。強制的な一括upgrade/downgradeはしていない。runtime依存joseは変更なし。
- 独立レビューで、暗号処理がrecord UUIDをv4へ狭めていた不整合を修正。内部ownerはv4、recordは既存HTTP契約と同じ一般UUIDに分離。UUIDv7の通過試験も追加。
- 初回暗号試験は20MiB配列にテスト側のdeep-equalityを使い、Workers heapを使い切った（32.72秒＋終了待ち）。製品の暗号化失敗ではなく、比較方法をbyte数＋SHA256へ変更した。再実行で暗号7件・受信3件成功、2.82秒。過去の失敗を隠して成功時間だけを全体時間としない。
- 永続認証12件は2.68秒で成功。新しい復元fixtureは型注釈でsignIn補助メソッドを隠す誤りを修正し型検査成功。復元3件・Apple8件・保存14件・受信4件は8.30秒で成功。受信の1件は本物の5秒期限を確認しており、mock時計だけの試験ではない。
- 合計48件の成功を入力/依存単位で保持。既定OFF、本線への統合CIはこれから。実KMS・実Apple・実2台・本番保存先での成功は未確認。
- 製品候補 `560fd2d`。変更した開発手順の11組は81.6秒ですべて成功。固定digest設定後は影響する新backend選択1件と既存JPEG2件だけを0.036秒で再確認した。専用CIの5分はjob上限であり、全体の作業時間や実行時間の保証ではない。
