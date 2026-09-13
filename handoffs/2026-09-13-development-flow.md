# 開発・検証・配布の進め方

対象mainの起点は `dab2448`。アプリの最新配布は160。今回の候補は `codex/development-flow-20260913`。アプリ機能・写真・配信先・テスターは変更しない。

## 参考資料を照合した結果

[参考レビュー](C:/dev/neko-evidence/testflight-flow-review-20260913.md) は、待ち時間の中心が署名アップロードではなく共有runtimeとUI/Galleryを結合したjobである点は現状と一致する。レビュー時のmainは1455930で、現在より前。

- mainで候補の成功結果を再利用する仕組み、独立したRelease/smoke/runtimeの同時開始、追加Galleryのbuildとbootの同時実行は既存。作り直さない。
- 毎回のApple画面ログインを完了条件から外す対応は既に済んでいる。処理状態APIや内部グループ操作を新設して今回の開発条件にはしない。
- 自動2workerだけでなく、その後の明示分担47f881eも不採用。UI短縮1分27秒より準備時間の増加が大きかった。同じMac内での並列数は増やさない。
- 既存の限定した表示差分scopeを維持する。Views全体やテストファイル全体を無条件に軽量化しない。署名、権限、共有、永続化、CIの不明な差分はfull。

## 実装した変更

1. **Macの前で失敗を見つける**：`python NekoWidget/ci/check-development-flow.py` を手元とUbuntuのplan jobで実行。scope・証拠再利用・分割の網羅・Simulator準備の失敗伝播・Widget契約・配布CLIを先に確認する。ここで失敗したらMac jobsを開始しない。
2. **検証単位の分離**：共有runtime両OS、アプリUI、通常Gallery、白背景/長文/大文字Gallery、字幕なしGalleryの5単位。それぞれ独立したMac・checkout・Simulator・ビルドを使用する。Galleryのproduction cache JPEGは各Macのruntimeで検証・生成し、代替画像や注入済み成果物を配布へ流用しない。
3. **必要な結果を揃えてから採用**：旧一括jobの成功では新構成の証拠にならない。全必須jobの名前・scope・SHA・成功を検査し、欠落・skip・取消・重複を拒否。既存の同repo/workflow、push候補、24時間、同一SHAまたは限定した同一入力の条件も維持する。
4. **配布の定型化**：`release-testflight.py` はdry-runが既定。対象main SHA、CI証拠、build番号と重複を確認する。内部用の配布モード・公式preview・アップロード・暗号化archive保持を固定する。`--dispatch` だけが起動する。対象SHAが起動直前に変わった場合も署名前に停止する。

GitHubは同じSHA/refで失敗jobだけ、または指定jobだけの再実行を提供する。[公式説明](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/re-run-workflows-and-jobs)。これは環境障害を原因確認後に局所再実行するために使い、製品の失敗を繰り返して隠さない。

## 次からの固定手順

| 段階 | 実施内容 | 終了条件 |
|---|---|---|
| 着手 | 最新mainから対象を絞り、差分と完了条件を決める | 1候補に機能変更と未検証CI試作を混ぜない |
| 手元 | 対象検証とdevelopment-flowを実行、必要な独立レビュー | 対象検証成功、指摘解消 |
| 候補 | pushでCIを1回起動し、担当1人が結果を監視 | 必須jobすべて成功。失敗時は原因と対象jobを特定 |
| main | 成功した候補を反映し、同じ成功証拠を再利用 | mainの証拠検証成功。重いCIを理由なく繰り返さない |
| 配布 | 関連修正をまとめ、CLI dry-run→dispatch | Appleアップロード成功。未配布・処理エラー時だけ追加確認 |
| 記録 | 実装済み、実行確認済み、実機未確認を分ける | 短い結果と残件を台帳へ反映 |

同じSHAの環境障害と確認できた場合は `gh run rerun RUN_ID --failed --repo soso-so-27/neko-widget`。コード修正が必要なら新SHAで必要範囲を実行する。全体を最初から再実行するコマンドを既定にしない。

## 採用判定・計測

比較元は160の成功候補34738333552：workflow全体56分18秒。署名アップロードは成功した34740960779で5分17秒。試作・切り戻し・起動ミスは正常系の速度と分ける。

今回の分割は各Macでの準備が増えるため、候補開始から全必須job成功までの時間と、Mac jobの合計時間を併記する。アプリUIやGalleryを省いて速くなったとは扱わない。新構成のMac実測は候補CI結果を後記する。

今回新しいTestFlightは作らない。製品160の再アップロード、Apple画面の再照合、追加写真の配信を開発基盤の確認に混ぜない。
