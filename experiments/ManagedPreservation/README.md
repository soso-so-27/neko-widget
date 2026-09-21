# 個人保管：本線に接続しない原価検討

基点 `184b4cd53597c28c4719490369f7d84bd099df28`。2026-09-22。

アプリ機能ではありません。ネットワーク、利用者の写真、認証情報、課金商品、R2/D1/CloudKit、既存のアプリコードにはアクセスしません。依存パッケージのインストールも不要です。

- [商品と接続境界の仕様案](../../handoffs/2026-09-22-managed-personal-preservation-design.md)
- Node.js 22以上。リポジトリルートから実行します。

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

テストは計算式・入力条件だけを確認します。アプリ、サーバー、写真の画質、暗号化、復元、請求実績は未検証です。CI設定には追加しません。
