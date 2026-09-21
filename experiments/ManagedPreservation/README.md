# 個人保管：本線に接続しない原価検討と復元試作

基点 `184b4cd53597c28c4719490369f7d84bd099df28`。2026-09-22。

アプリ機能ではありません。テスト・原価計算は外部通信なしで、利用者の写真、実認証情報、課金商品、R2/D1/CloudKit、既存アプリへアクセスしません。Apple接続adapterのコードもありますが既定OFF・未接続で、テストの通信はすべてmockです。原価計算は依存なし。復元試作のみ、固定した `jose` をこのディレクトリ内にインストールします。

- [商品と接続境界の仕様案](../../handoffs/2026-09-22-managed-personal-preservation-design.md)
- [実本人確認・鍵管理への接続判断と別プロセス復元](../../handoffs/2026-09-22-preservation-identity-and-key-custody.md)
- [並行の持ち出し実装との形式・会員境界の整合](../../handoffs/2026-09-22-preservation-portability-integration.md)
- Node.js 22.17.0以上。原価計算はリポジトリルートから実行します。

## 復元試作（D1のローカル検証部分）

**合成データで動く試作です。実Appleログイン・実iPhone間の復元・運営の災害復旧backupは未実装／未検証です。**

```powershell
cd experiments/ManagedPreservation
npm ci --ignore-scripts --no-audit --no-fund
npm run test:prototype
```

インストール時だけnpmレジストリへ接続します。テストは外部通信なしで、専用一時ディレクトリに合成データのSQLiteを作成し、終了時にそのテスト専用ファイルだけを片付けます。Node 22の `node:sqlite` はexperimentalの警告が出ます。本番実行基盤には採用していません。

### 今回成立させる流れ

2026-09-22の整合バッチで内部レコードはversion 2になりました。複数猫名・独立した撮影/記入/更新日・写真なしの記録を保持し、native単件JSON相当の`document`を出します。旧version 1の合成DBは明示エラーで停止し、書き換えません。実データ移行はしていません。JPEG上限は本線と同じ20MiBですが、画像デコードは未実装です。

1. 合成の本人確認で、端末・メールアドレス・契約状態と独立した保管所有者を決める。
2. サーバー側の合成権利と明示同意がそろった場合だけ、写真のバイト列・メモ・日付・猫名を暗号化してSQLiteへ確定する。
3. SQLiteを閉じ、旧セッションを捨て、契約切れの状態にする。
4. 新しい本人確認セッションから同じSQLiteを開き、写真・メモ・日付を照合して、無料で書き出す。既存メモの編集も可能。新規写真の追加は拒否する。

| ファイル | 役割 |
|---|---|
| `prototype/identity.mjs` | 信頼済みローカルJWKSによるRS256署名、issuer/audience/期限/nonce/subject検証。一回限りのchallengeと短期session |
| `prototype/synthetic-identity.mjs` | テストだけの架空issuer・RSA鍵・トークン発行。Appleの鍵やアカウントではない |
| `prototype/archive.mjs` | 本人ごとのSQLite保管、JWE暗号化、同一内容の保存再確認、版を指定したメモ編集、削除tombstone、変更世代を監視する逐次export |
| `prototype/record-contract.mjs` | 本線の単件JSON項目・nullable日付・複数猫名・本文/写真サイズの契約。ZIP生成やJPEGデコードではない |
| `prototype/*.test.mjs` | 契約切れ＋旧セッションなしの読出し、他人拒否、署名・鍵・改ざん・競合・同意撤回・書込失敗の境界 |

追加の `key-bundle.mjs` と `recovery-process.fixture.mjs` は、標準JWEで保護した鍵束とSQLiteのコピーを別OSプロセスで読み出す**合成データ専用**実験です。写真用の平文鍵を最初のプロセス内だけで生成し、終了後は暗号化した鍵束から復元します。上位鍵は親ハーネスから注入するため、KMSの復旧や運営アカウント喪失への救済はまだ証明していません。新規分だけ実行する場合：

```powershell
node --test prototype/key-bundle.test.mjs prototype/recovery-process.test.mjs
```

### ここで決めていないこと

- **暗号方式の採用判断**：Apple本人確認と**サービス管理鍵**の方針は2026-09-22に利用者承認済み。試作は `jose` の標準JWE（`dir` / `A256GCM`）。運営側が復号できる構成で、E2EEではありません。現行利用者の同意・プライバシー説明の更新や、KMS業者の契約は別途必要です。
- **鍵の実際の復旧**：初期のarchiveテストは同じMapを再注入します。追加の別プロセステストでは暗号化した鍵束からデータ鍵を取り戻しますが、そのための上位鍵はテストハーネスが保持します。KMS/HSM・クラウド障害時の鍵取得・実運用の鍵backup・運営終了時の救済は未実装。鍵が失われれば写真は読めず、エラーで止まります。
- **実本人確認**：Sign in with Appleを採用方針に決定。固定Apple endpoint/JWKSを使うコード交換adapterを準備しましたが実通信は未検証。永続セッション、取消通知/失効、Appleアカウント喪失時、アプリ移管時のsubject移行、Web搬出導線は未実装。購入復元の安全条件は一切変えていません。
- **製品の保存品質**：画像は合成バイト列です。JPEGのデコード・閲覧画質・原本/動画/Live Photosの保管を証明しません。2MiB/メモ16KiBの入力制限は試作の安全上限であり、販売容量ではありません。
- **D2の保存基盤**：SQLite一取引に暗号文・台帳・本人ごとの変更世代を置いています。確定済みの同一ID・同一内容の再送は、契約切れでも元の成功を確認できます。ただしR2＋D1に分けた二段階受付、容量予約、通信再送キュー、復旧用副コピー、同意世代の永続管理、レート制限は未実装。export中に本人の記録が変わると未完了エラーにします。時点固定スナップショットや自動再開ではなく、途中まで出力した分の扱いを含む利用者向けUIは未実装です。
- **削除**：この試作のtombstoneは現行DB内で古い編集による復活を防ぐためのもの。削除前のbackupを戻した場合の復活防止、ごみ箱・取消期間・副コピーの最終消去・アカウント削除は未実装。SQLiteページ上の物理消去を保証しません。利用者データに対して実行しません。

### 根拠と接続条件

本人確認と購入権を分ける理由は[設計案](../../handoffs/2026-09-22-managed-personal-preservation-design.md)を参照。署名検証の参考は[Apple: Verifying a user](https://developer.apple.com/documentation/signinwithapple/verifying-a-user)、[Authenticating users with Sign in with Apple](https://developer.apple.com/documentation/signinwithapple/authenticating-users-with-sign-in-with-apple)。標準実装は[jose公式](https://github.com/panva/jose)。独自暗号/JWT検証は作りません。

本線接続前には、本人確認と鍵管理方式のプライバシー判断、実ID・実権利、失効、実2台、鍵と台帳を別々に失った場合の復旧証拠が必要です。この試作やテスト成功だけで「バックアップ完備」とLP・課金画面へ掲載しません。

## Apple接続adapter（未公開・既定OFF）

`prototype/apple-signin-adapter.mjs` は、native ID token検証→認可codeの交換→交換後tokenと本人の再照合を行うサーバー側部品です。`PreparedAppleSigninAdapter` は明示的な `enabled: true` と設定なしには動かず、本線アプリから呼び出されません。今回の実行は固定URLへの通信も含めすべてmockです。

```powershell
# このディレクトリ内で、新規adapterのテストだけを実行
node --test prototype/apple-signin-adapter.test.mjs
```

22項目が初回成功（runner約1.95秒）。独立レビューで重大な修正必須事項なし。既存44項目と原価計算は入力/依存が不変のため再実行していません。

**直接公開しないこと**：`takeChallenge` はproofを照合して一回限りに消費する永続storeの契約で、テストはMapです。返り値の `refreshToken` は内部資格情報でありクライアントに返すレスポンスではありません。秘密保存/本人ID対応付け/セッション/失効と取消通知を完成させてから接続します。交換後nonceの実互換性と、Sign in with Apple用client secretが実Appleで受理されることも未確認です。[接続契約と未完了条件](../../handoffs/2026-09-22-preservation-identity-and-key-custody.md#8-apple接続adapterの準備承認後バッチ)

## 原価計算（D0、前回の成功証拠を維持）

```powershell
node --test experiments/ManagedPreservation/cost-model.test.mjs
node experiments/ManagedPreservation/cost-model.mjs
```

1つのJSONオブジェクトを引数に渡すと、その条件だけ計算します。ファイルの自動探索・読込や外部API呼出しはありません。PowerShellではJSONを単一引用符で囲んでください。

```powershell
node experiments/ManagedPreservation/cost-model.mjs '{"payingAccounts":1000,"retainedNonPayingAccounts":1000,"photosPerAccount":10000,"averagePhotoMB":1,"copyMultiplier":2,"overheadRatio":0.15,"monthlyClassA":60000,"monthlyClassB":1860000,"applyAccountFreeTier":false}'
```

## 入力の意味

| 入力 | 単位・注意 |
|---|---|
| payingAccounts | 有料アカウント数。実人数・頭数・まど数とは別 |
| retainedNonPayingAccounts | 解約・無料体験終了など、非課金だが記録が残るアカウント数 |
| photosPerAccount | 全アカウント共通の仮の平均保管枚数。上限の決定ではない |
| averagePhotoMB | 閲覧用コピー1枚の平均MB。10進MB。未実測 |
| copyMultiplier | R2 Standard上の同容量コピーの倍率。2なら2組と仮置き。復元可能性や独立性の証明ではない |
| overheadRatio | サムネイル・暗号化・メタデータ等の仮の容量上乗せ。0.15なら15%。未実測 |
| monthlyClassA / monthlyClassB | アカウント全体の月間操作総数。副コピー、初回投入、再試行、復元、編集等を必要に応じて加える。コピー倍率から自動算出しない |
| applyAccountFreeTier | 原則false。trueはR2アカウントの無料枠をこの用途だけで使える場合のみ。利用者ごとの無料枠ではない |

30日間一定の在庫がある比較モデル。実際のR2請求は日次ピークの平均、請求単位切り上げ、アカウント全体の無料枠で決まります。単価は2026-09-22確認の[公式料金](https://developers.cloudflare.com/r2/pricing/)。

**出力はR2の一部費用のみで、総原価・利益・980円の妥当性ではありません。** Workers、D1、別のbackup基盤、認証・鍵復旧、監視、問い合わせ、決済手数料、獲得費、税等は含みません。別プロバイダーの副コピーはその単価で別計算が必要です。

初回一括投入や一斉復元は、日常利用とは別シナリオで操作総数を与えます。無料体験者の大量投入、解約者が蓄積する場合も、非課金保管数を変えて確認します。「解約したら費用がゼロ」にはしません。

原価計算テストは計算式・入力条件だけを確認します。復元試作の証拠とも分けます。アプリ、実サーバー、画質、実2台復元、請求実績は未検証です。どちらもCI設定には追加しません。
