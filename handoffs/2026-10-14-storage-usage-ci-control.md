# 読み取り保存量集計のCI登録

この制御候補は `preservation-storage-usage-v1` を main に先行登録する。製品は owner の R2/S3 物理保存量と、渡された参照との一致を読み取りで集計する helper/test の追加だけ。非atomicなLISTの観測、参照外object、保存履歴を復元の完全性や削除許可と扱わない。

## 固定入力

- 制御base: `03fdd1996a3644e453343975cb0494af4f588823`。別branch `codex/storage-usage-ci-control-20261014` で control4本・開発手順1段落・このhandoffだけを変更する。
- 製品は commit `87adce6`、文書追加後 `ffc6b58`。両製品blobは不変。製品変更の独立レビューは主担当側で完了した。
- `NekoWidget/PreservationService/src/owner-storage-usage.ts`: absent → `60710beb3cdc9ed7c55f807a86f62b56b283267c`、A100644。
- `NekoWidget/PreservationService/test/owner-storage-usage.test.ts`: absent → `fba40f437cae1456b538d656f2dc68b9f175849c`、A100644。
- 製品2本、control4本、`handoffs/*.md`以外の全tracked閉包: 1185行、SHA256 `feb3c24a1f5af747466b105f2630c0ad08b1ee1f8e1b23384e1a98f4e32186b9`。実baseと実製品treeで一致を観測し、実base treeによる回帰testも置いた。release-candidate notes、workflow、依存、native、署名を閉包に含む。
- control4本は mainとのmerge-baseで承認済み登録を要求し、製品のbase/head双方がその全blob・modeと一致しなければscopeを選ばない。製品/controlの同時変更による自己承認を許可しない。

## 証拠と計測

製品の型検査・関連14testsは主担当側で6.31秒成功。保存証拠は主担当のローカル `storage-usage-20261014/local-validation.json`。この制御作業は製品検査やCIを重複実行していない。

ローカル制御は新selector/plan/budget10件と既存trialのselector/budget7件を対象とした。最初の17件では malformed blob fixtureを作るtest自身のunpackに1error、他16件成功。fixtureを直した1件は成功。main/PRの入口検査を追加した際、main fixtureに実pushのbeforeがなく1failureになった。beforeを補い同じ1件成功。製品・選択条件の修正は不要。最後に変更された新scope10件を0.161秒で全成功、入力不変の既存trial7件の成功を保持した。実tree閉包、欠落/重複登録、partially changed inputs、unsafe mode、control drift、未知blob、手動dispatch、main/PR/branch、release拒否、planの成功非claim、初回baseline/失敗/active保持を直接確認した。

初回製品候補は2026-10-14 11:50UTC。新scopeのCI所要時間は未計測。直前の別backend scopeの104秒は参考だけで、5分のjob timeoutもqueueや累計時間の保証ではない。初回からの時間・失敗・手戻りを主担当がCIの実測と合わせて残す。

## 統合順序と残る確認

主担当が制御の独立レビューと開発チェックを行い、制御だけをpushしてplan成功後mainへ反映する。そのmainへ製品をrebaseし、2追加blobと1185行の閉包・control4本の全文一致を再照合する。製品の同SHA owning Preservation pushで必要8stepすべてとiOS planの必要3stepの成功が必要。unknown、active、failed、skipped、stale、別SHAは成功証拠にできない。

backend planは必要jobを宣言し、backend成功を証明しない。新scopeはnative/releaseの必要job集合に登録しない。main統合後も実データの読取・復元・削除、cloud反映、一般公開・契約・課金や定期task変更をこの登録から許可しない。CI監視・push・PR・main反映は主担当だけが担当する。
