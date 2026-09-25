# 個人保管 staging D1 migration 0013–0016

2026-09-25。対象は保管専用の **staging** D1 `neko-preservation-staging`
（ID `955a8530-9015-486c-8d0c-1b5a2c5b6d4f`）だけ。公開Worker・本番D1・共有DB・AWS・R2には変更なし。

適用前に `pa_owners`、`pa_records`、`pa_notice_contacts`、`pa_purge_fences` が各0件と確認した。
Time Travel bookmark は0013前が
`0000000c-00000000-000050f1-69e60a2715b9997b8ee8a919c5237ece`、
0014前が `0000000d-00000000-000050f1-84230c83e74bf8fa0edb573e444d0d39`、
0015・0016前が `0000000e-00000000-000050f1-94f1b0ebee442295440bb5909c85d186`。
これらは復元を実行した記録ではない。

初回は0013成功後、0014の複数行 `SELECT CASE ... END` を含むtriggerで遠隔D1 APIが
`incomplete input` を返し、0014は未適用のまま止まった。0014の同じ条件をtriggerの
`WHEN`に移し、ローカルのmigration一式と対象テストを確認したところ、再実行で0014が成功した。
同形の0015も同じエラーとなったため、0015と0016の条件を`WHEN`へ移した。次の実行で
0015・0016は成功し、未適用migrationは0件。失敗migrationの一部オブジェクトが残って
いないことは一覧で確認した。修正は安全条件を緩めるものではなく、Cloudflare遠隔SQL
実行で解釈できるようにしたもの。

適用後の読み取りでは、owner・record・purge eventは各0件、
`delete_intent_required=0`、`owner_snapshot_required=0`、purge event triggerは7件。
サービスの提供・写真保管・削除は依然として**OFF**。このmigration成功は実S3 intent、
実削除、復元、販売容量、12か月保持の完了証拠ではない。
