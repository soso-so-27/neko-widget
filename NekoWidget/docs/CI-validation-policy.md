# iOS CIの対象選択と成功結果の再利用

小変更で無関係な実行チェックを繰り返さないため、`ios-build.yml` の最初に検証計画を作る。

## 対象選択

- `SeasonalMovieView.swift` だけ、または同ファイルとADR-023だけの変更は、既存の境界・選定チェックとiOSアプリ・拡張のビルドを実行する。ムービーの保存・共有を検証していない写真スキャンと共有通信のSimulatorジョブは実行しない。
- 明示したファイル以外が含まれる場合、または差分を確定できない場合は従来の全3ジョブを実行する。Views全体などの一括除外はしない。書き出しserviceや永続化、権限、署名、CI設定の変更も全件対象。
- 候補ブランチの差分はmainとの分岐点から計算する。直前pushだけを見て、同じブランチの先行変更を見落とさない。
- mainの差分はpush前のmainから計算する。mainの履歴が連続していなければ全件対象。

## mainへ反映するとき

main pushでは、次の条件をすべて満たす既存runがあれば重いジョブを再実行しない。

- 同一リポジトリ・同一workflow・同一コミットSHA。
- `codex/` ブランチへのpushで実行され、過去24時間以内に正常終了。
- 今回必要な各ジョブがそのrunで実際に成功している。skipped、失敗、欠落、不完全なジョブ一覧は証拠にしない。

再利用元のrunリンクと対象をGitHub Actionsのsummaryに残す。新しいrunの省略ジョブを、別のrunへの再利用証拠として連鎖させない。API取得・判定に失敗した場合は通常の検証を実行する。

全件の再検証が必要な場合はActionsから `iOS build check` を手動実行する。`workflow_dispatch` は対象選択・結果再利用による省略を行わない。

## 検証範囲の限界

この変更はiOS CIの重複を減らす。署名付きアプリの作成・アップロードとApple側の処理は別途必要。ムービーの実機操作・実際の共有先への到着は、このCIが成功しても確認済みとは扱わない。

APIの根拠：[workflow runs](https://docs.github.com/en/rest/actions/workflow-runs)、[workflow jobs](https://docs.github.com/en/rest/actions/workflow-jobs)。
