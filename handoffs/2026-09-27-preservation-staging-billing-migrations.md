# 共有 staging D1 の課金・写真 migration 整合

2026-09-27。対象は `neko-window-sharing-staging` のみ。公開環境と保管専用 D1 は変更していない。

- 最新 main の共有DB migration 0019–0029を照合。遠隔には0018まで、0026、0027、旧名の`0028_family_record_moments.sql`が登録済みだった。新しい0029は旧0028と表・索引の定義が同じで、`IF NOT EXISTS`だけを加えたもの。遠隔の既存定義とも照合した。
- 専用の [CLI設定](../NekoWidget/SharingService/wrangler.staging.migrations.jsonc)を追加。この設定はmigration操作専用であり、Worker配備に使わない。
- 遠隔の変更前は`spaces=1`、`members=2`、`family_records=0`、`PRAGMA quick_check=ok`、`foreign_key_check`空。Time Travel bookmarkを取得してから、隔離ローカルDBで0001–0029を適用・成功。
- Wrangler標準の遠隔migration適用（自動バックアップ付き）で、未適用だった0019–0025、`0028_window_support_requests.sql`、0029の計9件を反映。終了コード0、適用待ち0件。
- 変更後も`spaces=1`、`members=2`、`family_records=0`、`billing_accounts=0`、`billing_window_support_requests=0`、`quick_check=ok`、`foreign_key_check`空。遠隔の保管受付・課金authorityは引き続き`NO`。

この結果はschema整合の証拠であり、購入・会員判定・保管・復元・請求の実環境通し試験ではない。旧bookmarkへ共有DBを丸ごと復元すると並行更新も巻き戻るため、必要時は事前に所有者・影響範囲を確認する。
