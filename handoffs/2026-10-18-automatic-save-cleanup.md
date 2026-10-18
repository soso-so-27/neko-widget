# 2026-10-18 自動保存後の整理失敗と表示

## 実機から得た事実

- 利用者が TestFlight 260 で通常の写真メモを編集後、5分以上「未送信の変更があります」、説明なしと報告。ホームへ戻って再表示すると、途中の削除記録の読み込み失敗と ToolBackupError.invalid の説明が表示された。
- 10:00 JST の読み取りでは、既存本人の自動保存 head が revision 2→3、必要34部品すべて live、転送予約0。以前の31記録は revision・保存量とも不変。内部部品数を利用者の写真枚数とは扱わず、写真・メモ本文の復号は行っていない。
- 09:34 JST の端末鍵による access 更新成功、会員有効・受付期限内、容量・試行回数の残りも確認済み。利用者の端末に更新応答が保存されたことや、5分間の全ライフサイクルをサーバー情報だけから断定しない。

## 原因と修正範囲

- 確認できた不具合: head の送信成功と端末 ACK の永続化後、以前の snapshot 整理で失敗・中断すると、外側の catch が保存済みを未送信に戻す。CancellationError では説明も空になる。
- 修正候補は、fresh remote head と端末 ACK の一致を確認した証拠を保持する。エラー時には通信を追加せず、既存 Keychain fence → dataset lock の順で本人・origin・revision・snapshot・fingerprint・pending・dataset ID を再照合し、一致するときだけ「保存済み」と整理の再試行説明を表示する。
- 整理成功中に新しい編集が入った場合も、開始時点の古い fingerprint だけで保存済みにしない。取消・変更待ちに必ず説明を付け、必要な再試行を残す。
- journal の読み取り・decode・index・identity 判定を J1〜J4 で区別する。住所・ファイル名・本人ID・生のエラーは表示しない。URL/内容 hash の一致、未知ファイル拒否、index先行削除、共有部品保護は変更しない。
- **実機の journal がどの判定で失敗したかは未確定。** iOS Simulator の正常 journal roundtrip は成功しており、URL同一性が原因とは断定できない。新しい確認コードで切り分ける。壊れた記録を無視・削除・再生成して通過させない。

## 検証と費用

- 初候補時刻: 2026-10-18 10:02:46 JST。調査開始09:58:08 JST。途中の試作・待機も累計へ含める。
- `cdf47fb` の診断 [39085074508](https://github.com/soso-so-27/neko-widget/actions/runs/39085074508) は **10:21 JST** に成功、job 17分39秒。通常CI・配布の証拠にはしない。
- 境界の独立レビューで、cleanup成功時の古い fingerprint と changed catch の空説明の2件を修正。後続レビューで fixture の生エラーを固定stageへ変更した。
- 診断ログprivacy検査: 12成功、ローカルSwiftコンパイラ不在の1件は未実行。CI lane inventory検査26成功。既存の削除再開UI caseへ probe helperを追加し、既存assertを保持した。
- `8165df4` の診断 [39086761952](https://github.com/soso-so-27/neko-widget/actions/runs/39086761952) はDEBUG fixtureのcompile失敗（ownerのlet代入、throwing initのtry不足）。job6分23秒・run6分34秒を履歴へ含める。製品条件を変えず `d594fbc` で訂正し、[39087301030](https://github.com/soso-so-27/neko-widget/actions/runs/39087301030) で診断中。journal往復・改ざん拒否、ACK前/後の transport CancellationError、foreground loopの自動再開、cleanup中のmanifest変更を検証する。bindingのrootID不一致拒否と、実pointer切替の試験は区別する。実Task.cancel・実機の画面消失の原因までは実証していない。
- 旧 `27fe784` から backend・CI・workflow入力は不変で成功を保持する。アプリ入力が変わるため、最終候補の必須native検査と署名uploadは新しく必要。直近実績はfull 97分11秒＋upload11分06秒で、今回の終了保証ではない。
- 独立に確認した旧 `test-preservation-pilot-release.py` は11成功/1失敗。既存workflowの内部通報設定が増えたのに、テストが全体の文字列数を3回と仮定していた。workflowは変更せず、実際の準備/archive/exportの各工程でenvとpreservation CLIのbilling引数を確認する検査へ訂正し、12成功。訂正途中の存在しないサブコマンドを仮定したassert失敗も修正した。`internal-billing-release-prep-v1` 専用で、今回のfull native/配布の成功の代用にはしない。
- 月額980円を維持。既存GitHub無料対象構成を使用。新規契約・クラウド更新・受付/カウンター変更・定期タスク作成/再実行・一般公開・実課金開始は0。

## 残件

- 修正候補のnative診断→必須CI→main統合→内部TestFlight配布。
- 260で発生したjournal読み込み失敗の実機確認コードの取得と原因修正。新v3の通常画面への実機復元、一般利用量の容量・索引/復旧性能、動画クラウド保存、一般提供条件は引き続き別の残件。
- 元データ削除・再インストール・繰り返し再保存を利用者へ求めない。

ローカル証拠: `C:/dev/neko-evidence/automatic-test-20261018/` の `autosave-resume-investigation-plan.json`、`autosave-cleanup-fix-preflight.json`、`save-publication-v2-20261018T010026Z-summary.json`。
