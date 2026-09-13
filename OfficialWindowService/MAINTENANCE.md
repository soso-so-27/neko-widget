# 公式まどの定期保守

2026-09-13。既存の内部TestFlight向けpreviewを、このCodexタスクで毎日09:00・21:00（Asia/Tokyo）に保守する。写真追加は週3枚の初期運用。catalogの有効性を保つ更新とは分ける。実際の端末・Widgetへの反映時刻はOS次第で、定時到着は約束しない。

## 実行場所と許可範囲

- 固定checkout：`C:/dev/neko-official-supply-20260913`。作業cwdはその中の`OfficialWindowService`。
- 私的な実行記録：`../output/runtime/current.json`。直前の実配備bundle、Worker version、照合日時、queueの絶対パスを持つ。このファイルと参照bundle・queue・画像を保守中に消さない。
- 予定と原本：`../output/supply-week-20260913/queue.json`、同階層の`originals/PROMPTS.md`。原本・提供元の確認を終え、既存publisherで加工した3枚だけが対象。`approved:true`は運営側の掲載判断で、利用者が各画像を個別確認したという意味ではない。
- 配備先は `neko-widget-official-cats-preview`、account `829a34ef925a39d81b0e9e08800d7c7f`。手動の猫まど追加反映後は「どこかの猫」「おひるね」「キジ白のまど」の既存3まどを保持する。`current.json` が示す実配備bundleを基点とし、heartbeat自体は新まどを作らない。固定Wrangler 4.125.0を使用する。
- 「キジ白のまど」は `cat-tabby-nap` / `generated-tabby-nap` だけ。制約は `update-record.json` に保存され、保守ツールも別猫を拒否する。現在の週3枚キューを、この猫窓にも自動で振り分けない。新しい同猫写真がなければ、掲載期限後は空のまどを維持する。
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
7. `verify_preview.mjs --bundle <candidateBundle> --version <newVersion> --previous <oldBundle>`で配信後を照合する。失効復旧フラグは付けない。取り下げ・失効した旧URLも取得不能であることを確認する。JSONをrunに保存し、成功した場合だけcurrent.jsonを一時ファイル＋renameで差し替える。新bundle・version・検証の実測checkedAtを記録し、queueパスを維持する。pendingはrun内の`completed-pending.json`へ移して完了する。対象絶対パスがruntime内であることを先に確認する。履歴やrunを削除しない。

## 中断・不足

- pendingが残った場合は配備ログと実versionを確認する。新versionが記録され、候補との配信後照合が成功するなら、再配備せずpointer更新だけを完了してよい。pointer更新後・pending整理前の中断も同様。証拠のない成功扱いはしない。
- 新versionを特定できない、照合失敗、他の更新、認証失効、想定しないゼロ枚、履歴紛失は状態を残して通知する。自動rollback・履歴bootstrap・旧写真の復活・同じ内容の再配備を行わない。
- 承認済みキューが尽きても、catalogの期限保守と写真の失効処理は続ける。新しい写真を自動生成して補充しない。休止中まどを再開しない。
- `plan.queue.remainingAfterCandidate`は候補が配備成功したときの見込み残数。成功前に消化済みとは記録しない。残り3枚未満になった最初の時点で、次の1週間分が必要と知らせる。`output/runtime/supply-notice.json`に通知済みの補充サイクルを記録し、3枚以上に補充されるまで同じ不足を毎回報告しない。ゼロ枚到達・期限超過で予定写真を掲載できなかったときは追加の意味ある変化として報告する。
- 健康な変更なし・期限だけの保守は逐次報告しない。新写真の掲載、実際の失敗、補充が必要になったときだけ短く伝える。配信成功とWidgetの実機反映は区別する。

## 実行条件と確認済みの範囲

この方式はサーバー常駐cronではない。PCが起動し、Codexアプリが動き、参照ファイルとCloudflare認証が使える必要がある。休止中の定刻実行を保証しない。48時間以上保守できずcatalogが失効したときは、次の実行で既知版だけを基点に復旧する。失効した写真そのものは戻さない。

登録済みかどうか、最初の自動実行・予定写真の配信が実際に成功したかは、[今回の記録](../handoffs/2026-09-13-official-supply-and-maintenance.md)で分けて管理する。
