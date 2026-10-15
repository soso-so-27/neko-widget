# ツール保管候補の正式Photos検査を独立実行する経路

対象製品は `fb5a1dce3696703e3942c77c34287c9319886eb1`、tree `6720274ee20b7d7649c86c62687f425455f1d28f` のまま。価格980円。保存写真の再利用・厳密な参照保全・件数表示・中断再開の22製品入力と署名対象は変更しない。

元の正式検査 `38667725132` attempt1 は、Build全39step、両OS runtime、ツールUI全9操作、planに合格し、Photos `116203650168` だけが初回写真アクセス後のAX snapshot timeoutで失敗した。元の全7job、失敗raw、UI9のstarted/passed各1回と同一SHAのPreservation owning push `38667725016` 全8stepを保持する。別の1操作診断 `38669865915` は成功したが、原因確定・正式Photos全体・配布成功の証拠ではない。

公式job単位の再実行要求は02:37:02Zに201で受理されたが、03:02:50Zにも新jobは0で、最新run行だけqueued/attempt1、immutable `/attempts/1` は元のfailureのままだった。一度のcancelは409「まだqueueに入っていない再実行は取消不可」。取消成功とはしない。以前のc033候補の同じ停滞と失敗も消さず、再送・別branchでの全4検査反復を行わない。

新workflowはmainの手動実行だけを扱う。Linuxでexact source/tree/parents/元全7履歴を先に照合し、Macで直前に再照合後、既存 `bash ci/run-simulator-smoke.sh` を無変更で完走する。Xcode26.3/iOS18.6、既存の写真許可操作・許可済みライブラリの2 XCTest、TCC・fixture・scan/Widget・終端markerの成功が必要。権限はcontents/read・actions/read、公開・配備・Apple upload・利用者写真への書込は含まない。

controllerの実head/eventとビルドしたfb5製品のsourceは別々に記録する。mainへ先に非活性のcontroller/専用shared判定を登録し、実run/job/raw/観測の全成功を得てから、観測済みの値だけを別のmain承認で有効化する。元sourceに新attempt/jobが現れた場合や、別controller実行・不完全な履歴・未知の入力がある場合は停止する。診断や元の失敗を成功に置換しない。署名済みrelease CLI本文は変えず、mainとreleaseの正式経路は同じshared proofで判定する。

初回候補は `2026-10-14T12:59:13Z` のまま。新経路準備時の累計は約838分で、旧900分枠を満たしたとは報告しない。実装・レビュー・正式Photosは追加60〜115分＋queue、クラウド更新・uploadの参考15〜30分で再計画し、累計計画枠を1050分とした。新経路の成功時間は未計測。Macの40分上限・旧診断11分43秒/14分13秒・upload参考12分11秒を、新経路の完了保証にはしない。

非活性登録時点では、新Photos合格、製品main反映、0037/既存2Worker更新、内部256アップロードは未完了。正式合格後に順番に行う。既存本人の試用期限・grant/debt・記録・設定/secret参照・cron、公開・課金範囲は維持し、有料契約や新試用を追加しない。新v2の実認証付きcapability GETと実機保存/復元、Apple処理完了・端末での更新確認は別の未確認事項として残す。

## 検査準備の履歴取得設定を訂正

制御PR315をmain `d6b11049e128eb2d8f45434e7a5d61be52af8ba2` へ反映し、候補CI `38675960954` とmain CI `38676176712` がplanのみで成功した。最初のcontroller `38676316408` はLinux `116230623798` の事前照合で失敗し、Mac `116230680503` は空のskipで実行0だった。固定sourceのcheckoutが既定のdepth1だったため、`git show --format=%P HEAD` が親を返さない、準備設定の見落としである。

ローカルのbare cloneで同じsource/treeのdepth1→depth2を直接観測した。depth1では親が空、depth2では正しい0529/c033の2親が取得でき、HEAD・tree・元harnessのSHA256は不変。9.485秒、source変更・remote API・Mac起動なし。両jobのproduct checkoutだけをdepth2へ直す。

最初のcontrollerの失敗は全2jobの完全metadataとraw `e83d162e…` を保持し、成功には数えない。GitHubの実HTTP readerと保存したCLI rawはBOMを含めてbyte一致した。汎用raw正規化や検査本文を変更しない。以降はこの既知の事前失敗と、main承認した訂正controller1回だけのglobal2実行を照合し、未知・再attempt・追加実行を拒否する。5control通常Mの訂正登録と、実成功後の2control通常Mによる実測pin登録を分ける。未観測pinはNoneで、配布資格は引き続き無効。

初回候補・元Photos失敗・待機要求・今回の準備失敗・累積時間を保持する。新Mac検査の実描画と全2操作の完走、クラウド更新、256アップロードは訂正時点では未完了。
