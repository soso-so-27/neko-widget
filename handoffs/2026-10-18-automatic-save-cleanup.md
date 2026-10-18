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
- `8165df4` の診断 [39086761952](https://github.com/soso-so-27/neko-widget/actions/runs/39086761952) はDEBUG fixtureのcompile失敗（ownerのlet代入、throwing initのtry不足）。job6分23秒・run6分34秒を履歴へ含める。製品条件を変えず `d594fbc` で訂正し、[39087301030](https://github.com/soso-so-27/neko-widget/actions/runs/39087301030) で再診断した。journal往復・改ざん拒否、ACK前/後の transport CancellationError、foreground loopの自動再開、cleanup中のmanifest変更を検証する。bindingのrootID不一致拒否と、実pointer切替の試験は区別する。実Task.cancel・実機の画面消失の原因までは実証していない。
- 上記 `39087301030` は **10:57 JSTまでに成功**。run17分19秒、runtime42件＋対象UI1件（内部で旧削除再開、journal往復/改ざん拒否、ACK/再開境界を実行）、失敗/skip0。検査完了PNGも確認。最終候補との差分は後続のrelease-test訂正とhandoffだけで、診断が読むnative/runtime/fixture/workflow入力は同一。診断成功を配布用CIへ代用しない。ローカルdevelopment-flowも15組すべて成功、441秒。
- 旧 `27fe784` から backend・workflow入力は不変で成功を保持する。アプリ入力が変わるため、最終候補の必須native検査と署名uploadは新しく必要。直近実績はfull 97分11秒＋upload11分06秒で、今回の終了保証ではない。
- 独立に確認した旧 `test-preservation-pilot-release.py` は11成功/1失敗。既存workflowの内部通報設定が増えたのに、テストが全体の文字列数を3回と仮定していた。workflowは変更せず、実際の準備/archive/exportの各工程でenvとpreservation CLIのbilling引数を確認する検査へ訂正し、12成功。訂正途中の存在しないサブコマンドを仮定したassert失敗も修正した。`internal-billing-release-prep-v1` 専用で、今回のfull native/配布の成功の代用にはしない。
- 月額980円を維持。既存GitHub無料対象構成を使用。新規契約・クラウド更新・受付/カウンター変更・定期タスク作成/再実行・一般公開・実課金開始は0。

## 必須CI・main反映・内部配布

- 固定候補は `d26aa4a6da49af9f50ba195e7c0378c9cad9666d`。通常push [39088451722](https://github.com/soso-so-27/neko-widget/actions/runs/39088451722) は `full-v1` の8必須native jobを実行した。最初のattemptは94分48秒、6成功・2失敗。展開されないmatrixのskipは成功へ数えない。
- solo-2は28件中1失敗。迷子チラシのPDF共有で、iOSのremote containerはあるが項目・閉じるボタンがない実AX階層を確認した。自動保存の追加回帰caseは成功。gallery-variantsは `app.launch()` のbackground assertion取得timeoutで、Widgetの製品assertに入る前に失敗した。元log・SHA256・job IDsをローカル証拠へ残した。
- 製品・fixture・合格条件を一切変えず、**12:37 JST** に失敗した2jobだけを一度再実行した。6成功は同じ入力の実履歴として保持。再実行は約58分で成功し、solo-2全28件と元のPDF共有case、元のWidget caseの実成功logも照合した。一時的な不調の再現なしを確認したのであり、PDF共有失敗の一般的な根本原因を修正したとは扱わない。
- 配布CLIと同じ判定で全8必須jobを資格確認した。privacy検査はローカル12成功/Swift1未実行とは別に、Mac Buildで13件すべて成功。通常CIの作成から成功まで155分09秒で、初回attempt・再検査前の待機・再検査を含む。初候補10:02:46 JSTからの計時は維持し、当初180分計画は超過した。再検査前に約50分の追加見込みを案内し、実再検査は約58分だった。
- [PR349](https://github.com/soso-so-27/neko-widget/pull/349) は13:36:27 JSTにmerge commit `f6cbc3533074a030bfd4ee90945c28ffc7d02e87` でmainへ統合。候補がmainのancestorであることを確認した。mainの [39097681356](https://github.com/soso-so-27/neko-widget/actions/runs/39097681356) もplan成功・native未再実行を確認。mainのskipを新しいnative成功へ数えない。
- 正規配布CLIのdry-runで前回260・未使用261、固定候補と成功CI、preservation-pilot/internal-reports、billing OFFを確認し、一度だけdispatch。[TestFlight 261 / 39097754027](https://github.com/soso-so-27/neko-widget/actions/runs/39097754027) の正しいtestflight環境だけを既存許可範囲で承認した。**13:50:07 JSTにAppleへのupload成功**。署名・App Group・書出しgateと実upload stepの成功、`UPLOAD SUCCEEDED with no errors` を確認した。Appleの処理完了・261の配布画面/実機表示は未確認。dispatch run作成からuploadまで12分19秒、初候補10:02:46 JSTから3時間47分21秒で、試作失敗・全CI・再検査・待機を含む。一般公開・外部招待・審査提出・実課金開始は行わない。

## 残件

- TestFlight 261の実機確認。更新が表示されたら「設定 → 保存・復元」を開き、再確認ボタンを押さず30秒待った保存状態・説明・確認コードを利用者へ依頼済み。Apple upload、必須検査、main統合は完了。
- 260で発生したjournal読み込み失敗の実機確認コードの取得と原因修正。新v3の通常画面への実機復元、一般利用量の容量・索引/復旧性能、動画クラウド保存、一般提供条件は引き続き別の残件。
- 元データ削除・再インストール・繰り返し再保存を利用者へ求めない。

ローカル証拠: `C:/dev/neko-evidence/automatic-test-20261018/` の `autosave-resume-investigation-plan.json`、`autosave-cleanup-fix-preflight.json`、`save-publication-v2-20261018T010026Z-summary.json`。
