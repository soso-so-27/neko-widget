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

## 通常環境での引継ぎ検証（2026-10-05）

最新main e97ebe6とbundleのbase一致を確認。別worktree
`C:/dev/neko-ci-runtime-validation-20261005` で検証し、進行中PR168のbranch/runは変更しない。
製品PRと変更pathの重複はないが、Soloの明示一覧は製品側UI sourceへの依存がある。

必須ローカル検証でapp-onlyの期待値5job/旧Solo名が残っていることを再現し、
6job/新2shardへ修正した。全scopeへのbuild/smoke待機は狭い検証も遅らせるため、
3UI shardを使う場合だけに限定。通常scopeは従来どおりplan直後から並行する。
成果物のversion固定、必須job集合、失敗の扱い、製品・fixture・XCTest本文は維持。

計測wrapperは開始時にincompleteと区別できる記録を作り、SIGINT/SIGTERM後も
非ゼロ終了と所要時間を残す。起動できないcommandは127、timeoutは124、
SIGTERMは143。timeout後の子プロセス終了待ちは最大5秒を別途含む。
OSによる強制kill時は完了と偽らずrunning/exitCode nullが残る。
Windowsのsignal模擬とPOSIX実signalは区別して確認する。

最初の候補時刻は元4776220の11:22:59 JST、引継ぎ開始は11:39:38 JST。
CIだけの変更なので測定専用TestFlightは作らない。配布総時間は製品配布で
確認するまで未測定とする。元資料の成功221件を必須全件成功とは読み替えない。
事前計画と実測は `C:/dev/neko-evidence/ci-runtime-validation-20261005/` に保存する。

同環境でmandatory development-flowの14suiteが175.2秒で成功。
Windowsで実行できないPOSIX signalと既存Apple環境チェックのskipは残し、
native成功として数えない。修正前の期待値失敗と修正中のartifact固定値不一致も
手戻りに含める。成功したchecksは変更しない限り再実行せず、次はpreflightのみ。
