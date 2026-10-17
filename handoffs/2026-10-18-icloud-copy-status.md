# iCloudの保管コピーに、そのコピー自身の保存状態を表示する

## 原因と変更候補

- TestFlight 259で本人が編集した「メモ」の削除項目は「保管したコピーを削除」。これで `PersonalArchiveRecordView` のiCloudコピーだと確定した。ローカルメモとのbindingの有無までは実機報告から断定しない。
- release版の同画面の「保存状況」は全体の `AppRecordSettingsView` を開いていた。そこでの「保存済み」は、選択中のiCloudコピーの保存完了を保証しない。既存DEBUG検査は別のselected-copy fixtureへ進み、この相違を検出していなかった。
- コピーの詳細に保存先を表示し、メニューを「このメモの保存状況」へ変更。本人とrecord IDに束縛した読取専用画面で、iCloud保存済み・反映待ち・競合・削除待ち・読込未完了・確認エラーを区別する。古いstored状態よりpending/inFlightを優先する。
- 全件の写真を読まず既存の単一record readerを使う。アカウント変更・背景移行・画面消失時は表示結果を破棄し、読取の前後の本人とgenerationを照合する。移行、再送、削除、会員接続、自動保存の有効化は行わない。
- 同じrelease遷移を使う専用UI検査を追加。iCloud表示、無関係な会員・購入・自動保存操作の不在、閉じた後の元メモ表示維持を確認する。画面の不在確認だけを、保存設定の不変の証明とは扱わない。

## 直接証拠と残る確認

- 本人の画面画像とメニュー名、releaseソースの遷移、03:33 JSTのクラウド読取を対応付けた。新自動保存headはrevision1、必要32部品すべてlive、旧31記録は不変。本文の復号は行っていない。
- 初回自動保存は本人の「保存済み」報告とクラウド到着で確認済み。今回の編集はiCloudコピーなので、通常ローカルメモの編集が新自動保存へ届いた証拠にはしない。
- 独立レビューで本人境界を確認。「削除＋競合」の判定順序の指摘を修正し、再確認済み。
- ローカル `test-memo-row-navigation.py` 2件、署名入力の `test-media-staging-release-config.py` 28件が成功。後者の入力は本変更で不変。Swiftコンパイル・実描画・新CI・配布は未実施。
- 旧iCloudコピーを自動保存へ取り込む変更は含めない。259の旧ツール復元は新v3自動保存の復元と異なり、同一iPhoneでの新v3 preview導線もない。通常編集の自動送信、現在のv3の実機復元は未確認として残す。

## 検査・配布前の計画

- 調査開始は2026-10-18 03:33 JST頃、最初の実装候補は03:38 JST頃。正確な初commit時刻はGitとrepo外の証拠に記録する。待機・失敗・再作業を含む実装候補からの経過も保持する。
- 変更する製品入力は `PersonalArchiveView.swift` と既存UI検査ファイルの2本。既存selectorで `app-private-data-ui-v1`、必要nativeはBuild・Photos・runtime・Solo1・Solo2・otherの6job。Gallery対象外。最終clean候補のpreflightで再判定する。
- 最初に正規 `preflight-ci.py --feedback` から専用UI 1件を診断し、実描画を確認する。診断は配布証拠ではない。その後 `--measure-baseline --include-upload --target-minutes 180` で新scopeを初計測する。未計測scopeへ旧full基準を流用しない。
- 参考実績はfocused 21.9〜26.6分、通常graph約100分、259 upload 12分37秒。ローカル確認等を含め150〜180分を見込むが、新6jobの実績・queue・失敗は未確定。待機が増えた場合は実経過へ加算する。
- 新候補6jobの実成功→merge commitでmainへ統合→同候補SHAでTestFlight。既存preservation-pilot/internal-reports、billing OFFを維持し、配布CLIのdry-runで未使用buildと署名期限を確認する。UI修正だけなのでクラウド再配備は不要。
- 署名29入力は不変、署名期限は2026-10-18 15:57:36.812 UTC。期限内でも最終配布CLIの検証は省略しない。

## 費用・権限

- 月額980円維持。契約・一般公開・実課金・受付延長・counter reset・Codex定期変更は0。
- repoはpublic、標準runner使用を確認済み。GitHub請求APIは現資格では読めず本人に既存GitHubログインを依頼。本人のログイン後、soso-so-27の実請求画面でActions全額割引・請求対象0 USD、storageも実利用24,954.61 GB-hrに対して請求対象0 USDを確認した。同じpublic標準runner/既存artifact設定で進める。支払方法・プラン・資格scopeは変更しない。この保存実費は、過去の最大有料仮定の試算と区別する。
- 個人画像・メモ本文・クラウド識別子はこの公開handoffへ記載しない。詳細の読取証拠はrepo外 `C:/dev/neko-evidence/automatic-test-20261018/` に保持する。
