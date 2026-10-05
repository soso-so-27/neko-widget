# CIの分割と証拠回収

PR #169後に着手し、通常CodexのPR #170/#171を含むmain `e97ebe6d`を取り込んだ専用候補。製品、fixture、XCTestの内容は変更しない。PR #168への適用前に最新mainと候補の差分を確認する。

## 変更と受け入れ条件

- Soloの全46件を23件ずつの明示method選択へ分割。Swift宣言と一覧の完全一致を必須とし、追加、削除、重複、未対応宣言、別indentやextensionからの選択漏れを拒否する。
- UI3本を初期実行し、runtime/Galleryはbuildとsmokeの終了後に開始する。兄弟ジョブの成功は開始条件にせず、失敗・skipでも独立した証拠を収集する。全scopeで同時Mac runnerは最大5。
- mainの90分job上限を維持し、UI実行stepは80分に制限する。残りをuploadへ確保し、既に圧縮されたxcresult等への再圧縮を省く。artifact欠落はerror。
- 添付exportは180秒以内。timeoutは124で失敗とし、元のテスト失敗を成功へ変換しない。matrix全体、composerのbuild/test、添付exportの実終了status・UTC日時・単調時計による秒数をSHA/run/attemptとともにJSONへ保存する。
- 現fullはnative必須8job。旧7jobのpinned correctionを新分割の成功証拠へ転用しない。PR #169〜#171の元run・source・branch・完全before/after・期限等の固定条件は保持する。旧graphを必要とする既存候補は既存制御のまま、新graph候補は全件検証する。

## 実測と未確認

既存run `37245665341` のGitHub job/step metadataによる最初の失敗step終了はplanner開始から1377秒、全jobのterminal到達は4583秒。これは最初のXCTest assertionの時刻でも、成功した全件検証の時間でもない。soloはcancelled、全件成功や配布成功は記録しない。外部の `ci-runtime-baseline-37245665341.json` に根拠を保存した。

分割後の時間短縮は未実測。件数均等は時間均等を保証しない。独立runnerで検証済みfixtureを再生成する方針を保つため準備1job分は増える。注入済みcheckoutやSimulator製品を別jobへ流用せず、準備共有による短縮は達成済みとしない。

製品修正とまとめた候補CIだけで新artifactのstage時間とGitHub job/step metadataを比較する。最初の失敗step終了、全必須job成功までの経過、実TestFlight runの開始〜upload終了を別々に記録する。失敗・cancelled・配布未実行を成功時間へ換算せず、測定専用の重いCIを追加しない。

## 継続条件

最新main取り込み後、planner105件、lane18件、release-flow7件、release-testflight39件（1件skip）、preflight51件、recorded-command2件の6suiteは221件成功・1件skip。Bash構文確認とdiffチェックも成功。skipをnative成功とせず、必須チェック全件成功とは扱わない。

標準環境のPython検証と編集は可能。Bash fixtureテストはWindowsホーム親ディレクトリのmkdirでアクセス拒否となり、Xcode/Swiftは利用できない。GitHub shell接続の既知制限も残る。ACL、safe.directory、実行アカウント、ネットワーク設定は変更しない。

ローカル必須チェックを成功扱いにせず、この環境からpush/CI/main統合/TestFlightは実施しない。通常Codexの新規プロジェクトチャットで候補を取り込み、開発・リリース手順の必須チェック→製品候補CI→main統合→本人向けTestFlightを完了する。テスト基準は維持する。
