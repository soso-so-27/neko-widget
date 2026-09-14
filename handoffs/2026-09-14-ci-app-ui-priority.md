# アプリUIの開始待ちを抑えるCI候補

起点は製品 `fcd1d7c`、専用branch `codex/ci-app-ui-priority-20260914`。
製品コード・試験内容・配布workflowは変更していない。製品169は先にアップロード済み。このCI候補の検証を製品のTestFlight配布条件にしない。

## 変更

- 最長の `app-ui` を独立jobへ移し、残り4laneのmatrixを `max-parallel: 2` に制限する。build・smoke・app-uiの3本と合わせて、このworkflowが同時に使うMacは最大5台。配列の並び順に開始保証を依存させない。
- 全Mac jobは引き続き `needs: plan` のみ。別の製品検証の成功を開始条件にせず、matrixも `fail-fast: false` を維持する。失敗・skipを後続検証へ連鎖させず、失敗jobだけの再実行も維持する。
- planを含む必須8件の名前、全試験、scope、成果物のSHA/run/attempt、各Macの独立checkout・Simulator・生成画像、署名/privacyチェック、24時間の証拠再利用条件は維持する。
- 表示だけの既存限定scopeではruntimeのみがmatrixに残り、独立3本と合わせ最大4Mac。季節ムービー限定ではbuildのみ、mainの成功証拠再利用では重いjobを実行しない。

GitHubの [max-parallel](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#jobsjob_idstrategymax-parallel) による実行数制限を使う。他リポジトリの実行やGitHub全体のrunner不足による開始待ちまでは保証しない。

## 手元で確認した範囲

`python NekoWidget/ci/check-development-flow.py` の6群が27.8秒で成功。追加境界では、実workflowの全scopeを展開し、検証の欠落・重複、最大Mac数、app-ui独立、Mac job間の依存追加、試験コマンドや成果物識別子の変化を検査する。既存の失敗/skip/重複/SHA違いの証拠拒否と局所再実行の検証も成功。YAMLの読み取りと `git diff --check` も成功。

初回候補 `0f1b080` の実行では app-ui の開始待ちが9分48秒から21秒へ短縮した。ただし後述のsmoke時間切れがあり、候補全体は成功していない。手元のYAML読み取りはActions engineの実行成功の代用ではない。

## 初回試験で判明した30分枠の不足

[34836005974](https://github.com/soso-so-27/neko-widget/actions/runs/34836005974) のsmokeが30分上限で打ち切られた。UI 21件とPhotos権限bootstrapは成功したが、その後の写真投入・Widget最終検証が未完了。成果物だけを成功証拠にはしない。他の進行中ジョブは、この候補を修正するために停止した。

独立したログ・成果物比較では、[製品169の成功34830006233](https://github.com/soso-so-27/neko-widget/actions/runs/34830006233) に対し、script開始からUI開始まで9分00秒→12分42秒。UI自体は15分26秒→15分24秒でほぼ同じ。bootstrap成功時点で残り94秒だったが、成功側でも最終smoke成功まで1分56秒、cleanupまで2分26秒を要していた。addmediaの既存120秒制限より先にjobが切れ、結果JSONは未生成。Simulator固有の停止と断定した同SHA再実行はしない。

最小修正としてsmoke job上限のみ30分→40分へ変更する。試験、個々の待機上限、成果物、失敗判定は変更しない。正常時に40分まで待つ処理を追加したわけではない。新SHAで全必須項目と全体時間を確認する。

## 短縮できる上限と採用条件

過去の各job実行時間を固定し、残4laneを2枠へ全24順序で割り当てた机上計算。新構成の実測ではなく、runner待ちや負荷変動を含まない。

| 入力となる成功実測 | app-ui実行 | 2枠matrixの完了時間の範囲 |
|---|---:|---:|
| [167候補34808797099](https://github.com/soso-so-27/neko-widget/actions/runs/34808797099) | 42分55秒 | 38分12秒〜49分14秒 |
| [168初回34815744744](https://github.com/soso-so-27/neko-widget/actions/runs/34815744744) | 48分30秒 | 31分42秒〜33分47秒 |

167ではapp-uiの開始が最初のMacより11分39秒遅かった。この遅れの解消が今回の短縮上限であり、Galleryが最長になる割り当てでは効果が小さくなる。168はapp-uiが最初のMacの3秒後に始まっていたため、この変更による正常系の短縮余地はほぼない。smokeの再実行時間やアプリUI本体の約34分を縮める変更ではない。

実CIでは候補開始から全必須job完了まで、app-ui開始待ち、matrix最後の完了、Mac job合計時間を比較する。Galleryの後段が新しいクリティカルパスになって全体が遅くなる場合は採用しない。ジョブ内容・総数は増やしていないが、実測前にMac時間不変や短縮率を達成済みと扱わない。
