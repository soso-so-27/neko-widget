# TestFlight起動CLI

既存の内部確認向けmedia-staging配布が対象。アプリ、署名、Apple認証、テスター、審査の仕組みは変更しない。

## 使い方

Python 3と既存のGitHub CLIログインが必要。対象mainコミットをcheckoutし、tracked差分を解消して実行する。

    python NekoWidget/ci/release-testflight.py --sha <mainの40桁SHA> --build-number <承認した番号> --main-ci-run <成功したmainのiOS-CI-run-ID>

既定はdry-run。表示されたSHA、build、成功証拠、固定入力を確認し、起動するときだけ同じ引数へ --dispatch を追加する。CLI内からiOS CIの起動・再実行・main更新はしない。

固定入力は media-staging、既存の公式preview URL、upload_to_testflight=true、retain_signed_artifacts=true。番号は明示した正の整数のみで、自動採番しない。

## 実装した境界

- originは既存リポジトリに固定。HEAD、remote main、成功main CI、planのSHAを照合。tracked/index/submodule差分があれば停止。
- 成功したmain planの IOS_CI_PLAN_JSON を固定repository＋SHAで1件だけ採用。テストfixtureのplanを除外し、scopeと必須job名は現行plannerの required_jobs_from_scope で照合。fullだけでなく既存の軽量scope・movie-onlyに対応。
- mainが候補CIを再利用した場合は、参照先runのrepo/workflow/commit/24時間以内の成功と必要jobの実行成功を再確認。skipを実行成功とは扱わない。証拠が欠けても重いCIを勝手に再実行しない。
- 部分再実行のjob取得にはplannerの executed_jobs を共用。以前のattemptに残る成功兄弟を保持し、同じjobの最新結果がskip・失敗の場合は過去成功へ戻らない。
- 配布基準は確認済みbuild160、run 34740960779、SHA e8154065a049205dc6828893a693dd428f5b7bc0、作成日時 2026-09-13T05:42:24Z。基準runのAPI identity/successと実buildをログで1回照合し、基準以後のrunだけ重複確認する。古い全履歴は再取得しない。
- 新runはbuild＋SHA入りrun-nameで確認。基準以後の旧名成功runだけログへfallback。進行中runやupload状態が確認できない旧名失敗runは停止。番号は基準と予約済み番号のすべてより大きい必要がある。
- dispatch直前にmainと配布履歴を再確認。workflowへ expected_main_sha を送り、確認後にmainが動いてもcheckout直後・署名前に停止する。
- POSTは1回。応答不明時は自動再試行せずGitHubのrunを確認する。Apple管理画面へのログインはCLIの条件にしない。

## 基準の更新

次のアップロード成功をGitHubのログ（実build、VERIFY/UPLOAD成功、エラーなし）で確認した際、同じworkflow/repository/mainのrun ID・SHA・created_at・buildを release-testflight.py の BASELINE にまとめて更新できる。入力ミス回避のため4値を独立レビューし、次の変更バッチへ含める。成功を推測して自動更新しない。

## 検証と限界

python NekoWidget/ci/test-release-testflight.py は25件成功。GitHubをすべてmockにし、固定入力、dry-run/POST1回、SHA変更、scope/証拠、部分再実行、欠落・skip・失敗、重複build、基準、旧ログ、履歴欠落、ログ非表示を検証する。今回の実装から実GitHub操作や配布はしていない。

CLIの成功は「起動要求済み」まで。Appleアップロード成功、Apple処理完了、内部グループでの表示は区別する。アップロード後の画面未確認を理由に同buildを再送しない。

導入前のmain CIには機械可読planがないため、旧CIを推測で承認しない。基準のログが期限切れなどで取得不能なら、GitHubで確認できる新しい成功基準へ更新する。untrackedファイルは配布入力に含めず、tracked差分の検査対象外。

手動操作や別端末からの同時dispatchをGitHub側で原子的に予約する機能は追加していない。配布操作は既存どおり主担当1人が行う。mock検証は実サービスでの起動・アップロードの確認を代替しない。
