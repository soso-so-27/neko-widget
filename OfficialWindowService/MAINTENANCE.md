# 公式まどの定期保守

## 予定配信方式への移行後

**最初に `output/runtime/current.json` の `mode` を確認する。`scheduled` なら、以下の旧配備手順は実行しない。** [予定配信の運用手順](SCHEDULED_OPERATIONS.md)が正本。写真の追加・期限更新は配備済みの有限予定がサーバー時刻で行い、heartbeatは読取専用で確認する。

- 固定checkout：`C:/dev/neko-official-supply-20260913`。同じruntimeにcurrent/pending/実行記録を保つ。
- `node output/runtime/check-schedule.mjs` を固定checkoutのルートで1回実行する。入口はgit管理の `OfficialWindowService/tools/monitor_schedule.mjs` を読み込む。現在版のWorker version・HTTPS・JPEG、内部URL/未掲載JPEGの拒否、queueと窓別在庫、予定終了を照合し、ローカル記録だけを作る。
- pendingがある、modeが違う、履歴や写真がない、versionが違う、通信・認証に失敗した場合は、新しい配備をせず原因を報告する。mode不明を旧方式へ自動で戻さない。
- 新しい掲載への切替、実際の失敗、新しく生じた補充不足・終了接近だけを通知する。同じ不足、健康な変更なしは繰り返し報告しない。写真の生成・queue追加・停止・復旧・再配備はheartbeatでは行わない。
- 予定の終了後は503で停止した状態を報告する。復旧は担当者が同一versionを確認し、明示的な期限切れ復元から新予定を作る。過去の予定bundleを再配備しない。
- アプリ変更、git pull、CI、TestFlight、外部公開、課金、サブエージェントは不要。写真がサーバーで切り替わったことと、実機Widgetで更新されたことを区別する。

## 旧方式の記録（modeがscheduledなら使用しない）

2026-09-13。既存の内部TestFlight向けpreviewを、このCodexタスクで毎日09:00・21:00（Asia/Tokyo）に保守する。初期の写真追加は公式・お題用に週3枚、キジ白のまど用に週2枚程度を予定する。実際の追加対象は承認済みqueueの日時とchannelを使い、頻度から新しい予定を作らない。catalogの有効性を保つ更新とは分ける。実際の端末・Widgetへの反映時刻はOS次第で、定時到着は約束しない。

## 実行場所と許可範囲

- 固定checkout：`C:/dev/neko-official-supply-20260913`。作業cwdはその中の`OfficialWindowService`。
- 私的な実行記録：`../output/runtime/current.json`。直前の実配備bundle、Worker version、照合日時、queueの絶対パスを持つ。このファイルと参照bundle・queue・画像を保守中に消さない。
- 予定は**current.jsonのqueueパス**を読む。初期queueの固定パスへ戻さない。9/13の猫別補充では `C:/dev/neko-cat-window-supply-20260913/output/cat-supply-20260913/queue.json` に既存3行を保ち、猫別3行（1枚を即時・2枚を後日）を追加した。原本・生成記録は同階層の`originals/PROMPTS.md`と、旧 `C:/dev/neko-official-supply-20260913/output/supply-week-20260913/originals/PROMPTS.md`。原本・提供元の確認を終え、既存publisherで加工した承認済み行だけが対象。`approved:true`は運営側の掲載判断で、利用者が各画像を個別確認したという意味ではない。
- 配備先は `neko-widget-official-cats-preview`、account `829a34ef925a39d81b0e9e08800d7c7f`。手動の猫まど追加反映後は「どこかの猫」「おひるね」「キジ白のまど」の既存3まどを保持する。`current.json` が示す実配備bundleを基点とし、heartbeat自体は新まどを作らない。固定Wrangler 4.125.0を使用する。
- 「キジ白のまど」は `cat-tabby-nap` / `generated-tabby-nap` だけ。制約は `update-record.json` に保存され、保守ツールも別猫を拒否する。未来行も含め、このchannelを持つ全queue行のcatID一致を確認する（未来行の在庫集計だけでは同猫と判定しない）。公式・お題用の別猫を、この猫窓にも自動で振り分けない。新しい同猫写真がなければ、掲載期限後は空のまどを維持する。
- アプリ変更、git pull、依存更新、CI、TestFlight、一般公開への拡張、新まど、投稿受付、画像の自動生成、無承認の写真期限延長を行わない。個人のまど・ユーザーの写真・スクリーンショットをキューへ入れない。サブエージェントを起動しない。

## 毎回の手順

1. `current.json`を読む。`output/runtime/pending.json`があれば新候補や新配備を開始せず、下記の中断処理を行う。記録や参照ファイルを紛失した場合も履歴を初期化して回避しない。自動処理と手動配備を同時にしない。
2. UTC秒から一意のrunディレクトリ（`output/runtime/runs/YYYYMMDD-HHMMSS`）を作る。次の読み取り専用照合を実行し、JSON結果をrun内に残す。versionはcurrent.jsonの値を渡す。失敗時は配備を行わない。

   ```powershell
   node tools/verify_preview.mjs --bundle <currentBundle> --version <workerVersion> --allow-expired
   ```

   この処理はWranglerの配備一覧を**日時降順**で選び、100%配備のversionが記録と一致すること、各公開catalogと有効JPEGのhashを確認する。検査前後でversionを照合する。catalogが失効した場合は、記録済みversionとの一致と想定503を確認して期限保守へ進める。任意の503を同じ版の証拠にしない。
3. `prepareMaintenance(currentBundle, queueObject, <run>/candidate)`を呼び、返るJSONをrun内の`plan.json`に保存する。APIは`tools/prepare_maintenance.mjs`がexportする。CLIを使う場合は[引数説明](tools/README-maintenance.md)を参照。候補出力先自体は事前作成しない。
4. `no-change`なら配備せず終了。照合日時を記録し、残数を扱う。`candidate-prepared`なら、追加が承認済みの予定到来分だけであること、全channel・休止・初回掲載日が維持され、写真の失効以外に予期しない削除がないことを`plan.json`と`bundle/update-record.json`で確認する。既存の同一写真の期限を勝手に延長しない。
5. 候補の`worker.js`と`wrangler.jsonc`がcurrentBundleと同一であることを確認する。違えば停止。固定Wranglerで候補をdry-runする。

   ```powershell
   $env:WRANGLER_SEND_METRICS='false'
   node node_modules/wrangler/bin/wrangler.js deploy --dry-run --config <candidateBundle>/wrangler.jsonc --outdir <run>/dry-run
   ```

6. `pending.json`を新規作成専用（既存なら失敗）で書いて排他を得る。runパス、準備時の旧current.json、新candidateBundle、開始日時を残す。以後、手動操作を含む他の配備はこのpendingがある間は始めない。**pendingを保持したまま**current.jsonを再読取し、準備時と同一であることを確認してから、手順2のversion・HTTP照合を再実行する。途中で他担当の更新があれば停止する。すべて成功した場合だけ、同じWranglerコマンドから`--dry-run`と`--outdir`を外して**1回**配備し、標準出力・エラーをrunに残す。成功時のWorker versionをpendingにも記録する。通信結果が曖昧なら、成功するまで配備を繰り返さない。
7. `verify_preview.mjs --bundle <candidateBundle> --version <newVersion> --previous <oldBundle>`で配信後を照合する。失効復旧フラグは付けない。取り下げ・失効した旧URLも取得不能であることを確認する。JSONをrunに保存し、成功した場合だけcurrent.jsonを一時ファイル＋renameで差し替える。新bundle・version・検証の実測checkedAtを記録し、queueパスを維持する。手動の承認済み補充でpendingに`candidateQueue`を記録した場合だけ、検証済みの新queueパスも同じpointer更新で引き継ぐ。pendingはrun内の`completed-pending.json`へ移して完了する。対象絶対パスがruntime内であることを先に確認する。履歴やrunを削除しない。

## 中断・不足

- pendingが残った場合は配備ログと実versionを確認する。新versionが記録され、候補との配信後照合が成功するなら、再配備せずpointer更新だけを完了してよい。pointer更新後・pending整理前の中断も同様。証拠のない成功扱いはしない。
- 新versionを特定できない、照合失敗、他の更新、認証失効、想定しないゼロ枚、履歴紛失は状態を残して通知する。自動rollback・履歴bootstrap・旧写真の復活・同じ内容の再配備を行わない。
- 承認済みキューが尽きても、catalogの期限保守と写真の失効処理は続ける。新しい写真を自動生成して補充しない。休止中まどを再開しない。
- `plan.queue.remainingAfterCandidate`は候補が配備成功したときの見込み残数。成功前に消化済みとは記録しない。全体の残数に加えて`plan.queue.channels`の窓別残数を読む。公式`official-cats`が3枚未満、猫別`cat-tabby-nap`が2枚未満になった最初の時点で、その窓の次の1週間分が必要と知らせる。全体在庫で猫別の不足を隠さない。`output/runtime/supply-notice.json`に窓IDごとの通知済み補充サイクルを記録し、各閾値まで補充されるまでは同じ不足を毎回報告しない。旧形式の通知記録は残し、猫別の通知済みとは読み替えない。ゼロ枚到達・期限超過で予定写真を掲載できなかったときは追加の意味ある変化として報告する。
- 健康な変更なし・期限だけの保守は逐次報告しない。新写真の掲載、実際の失敗、補充が必要になったときだけ短く伝える。配信成功とWidgetの実機反映は区別する。

## 実行条件と確認済みの範囲

この方式はサーバー常駐cronではない。PCが起動し、Codexアプリが動き、参照ファイルとCloudflare認証が使える必要がある。休止中の定刻実行を保証しない。48時間以上保守できずcatalogが失効したときは、次の実行で既知版だけを基点に復旧する。失効した写真そのものは戻さない。

登録済みかどうか、最初の自動実行・予定写真の配信が実際に成功したかは、[今回の記録](../handoffs/2026-09-13-official-supply-and-maintenance.md)で分けて管理する。
