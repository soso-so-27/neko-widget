# 通報ごとのAI通信・失敗処理

2026-10-09。失効確認の予約とは独立して、公開準備の通報対応を進める。変更は未接続の送信部品と所有テストであり、Worker route、実API key、実通報の外部送信、運営権限は有効化しない。

## 変更と直接確認

`requestModerationAdvisory` が準備、発信、当該応答の読取り、最終判定までを一つの呼出しで所有する。外から別リクエストの応答本文を渡せない。合成A/Bの回答を逆順に完了させても、case・証拠版・request hash・判定が取り違わないことをworkerdで確認する。

送信前と応答後にtrusted repositoryでcaseの現在性を読む。更新・削除・終了・読み取り失敗は参考判定を採用せず本人確認へ戻す。事前screen未実施とchild-safety holdは通信0回。固定endpointへのPOST1回、redirect禁止、cookieなしとし、429や5xxも自動再送しない。ネットワーク・本文・DB読取を合計10秒に制限し、本文は16KiB・1024chunk・厳格UTF-8/JSONの範囲で読む。応答が止まる、巨大になる、キャンセルされる場合も成功へ読み替えない。例外・providerエラー本文・認証情報は結果へ複製しない。

実装前に実workerdのResponse/ReadableStreamで、未完了readのcancelと逆順の応答を2件直接観測。初回の新旧90件では89成功・1失敗。失敗はテスト用streamの自動先読みにより、送信前の応答に対してcancelを期待したfixture側の同期誤りだった。highWaterMarkを0にして実際のreadまで待ち、新規32件成功。独立レビューでは、サイズ違反が確定した応答をDB確認前に停止する修正を追加。DBを待たせ、cancelが完了しない場合も含む回帰を通し、新規33件成功。既存58件の成功は保持。型検査成功。独立レビュー・最終CI結果と最初の候補からの時間は `C:/dev/neko-evidence/launch-readiness-20261009/moderation-ai-transport/` へ記録する。

## 未完の接続条件

これは署名・閲覧許可・事前screen・最小化を代行しない。呼出し前の適法な送信範囲、証拠閲覧の短寿命lease、永続jobの一度限りのclaim、結果保存時の証拠版CASは次の接続側で必要。事前/事後readだけで全処理の原子性や取消との競合を保証したとは扱わない。providerの実精度、通信時間、アカウント制限、本人画面・本人の実鍵登録も未確認。

従来の別担当者承認・復旧条件は不変。AIはcase終了・非表示・削除・送信の権限を持たない。本人判断の永続記録、対象共有copy限定の制限と返答outboxは[本人運営の具体案](2026-10-09-owner-moderation-workflow.md)に従って続ける。一般公開や実データ送信の承認を、この局所確認で代用しない。

## 必須検証と計画

完全A/A blob・通常modeと既存Sharing/Preservation workflowを固定する専用選択を、別の制御候補で先に検証・統合する。最終製品SHAでplanと既存Sharing4job・Preservation1jobを確認する。既存workflow/job本文・成功条件は変更しない。アプリ入力不変のため新しいnative/Gallery/TestFlightは不要。今回のscopeは初回計測であり、旧scopeの時間を実績としない。作業記録開始17:38 JST、見込み30〜55分（独立レビュー・制御・CIを含む）。
