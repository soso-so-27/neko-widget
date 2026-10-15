# ツール保存・復元の改善：本線・クラウド反映と内部256

**本線・クラウド反映と、内部TestFlight256のAppleアップロードが完了**。[内部256の実upload](https://github.com/soso-so-27/neko-widget/actions/runs/38682198116)は2026-10-15 04:47:14 UTC（13:47:14 JST）に成功。Apple側の処理・TestFlight一覧反映・実機導入は未確認として分ける。旧記録の「変更中」「0037未配備」「正式native未確認」は当時の状態で、この記録の確認済み事項が後続となる。

## 実装と確認済みの範囲

- 容量欄から内部part件数を外し、使用容量・空き容量・保存可否を維持した。保存・復元・削除は進行％を示し、最後の通信だけで100％完了とせず「結果を確認中」を挟む。コピー詳細と復元したツールには入力内容と添付写真ファイル数を表示する。写真枚数はカメラロールや内部JSON・目録の件数ではない。
- 操作中の画面自動ロックを抑え、操作近くにエラーを表示する。応答不明のPUTはreceiptを確認して成否を回収する。画面を離れた場合や手動ロック後のバックグラウンド完了は保証しない。途中状態からの再開を保ち、元データ削除や再インストールを要求しない。
- v2 indexは変更のない写真partを同本人・同path/hash等の検証で再利用し、immutableなsourceSnapshotIDへ束縛する。参照中の写真削除を拒否し、indexから先に削除する順序、削除claim、復旧時の参照閉包検証を加えた。v1との互換を保つ。通常利用での削減率・請求減・実機v2往復を実証したという意味ではない。

## 本線と正式な検証

- [製品PR314](https://github.com/soso-so-27/neko-widget/pull/314)をmain `a7975512e9359ca5f5a24cce2ca40eabda081942`へ反映。全treeは`ed20ecd162c50f17be3c5330f7e09a8279dc7f4d`、parentsは`63b1c3a971818806d740980f7844fcf18fc653a8`と製品source `fb5a1dce3696703e3942c77c34287c9319886eb1`。事前dry mergeの全treeと一致する。
- mainの[iOS CI38680737042](https://github.com/soso-so-27/neko-widget/actions/runs/38680737042)と[Preservation CI38680737037](https://github.com/soso-so-27/neko-widget/actions/runs/38680737037)は成功。planner451件、preflight、release CLIの所有検査も成功した。
- 元sourceのBuild39、両OS runtime、UI9操作、同SHA Preservation全8stepは入力不変の証拠を保持した。正式な別Photos実行[38678383169](https://github.com/soso-so-27/neko-widget/actions/runs/38678383169)は17分58秒で、変更していない全2XCTest・TCC/fixture検証・scan/Widget終端markerまで成功した。controller mainと実際にコンパイルしたsourceは区別したまま、最終mainのdefault共有graphで適格化した。premerge専用観測を配布資格へ読み替えていない。
- 初回UI診断のSwift型検査失敗、元sourceのPhotos AX timeoutとqueued rerun、最初のcontrollerのdepth1親取得失敗を保持する。診断の非再現成功を正式Photosの代わりにしていない。旧queued runを成功や消滅へ書き換えず、一般的なfailure-ignoreや再試行ループを加えていない。Photos AX timeoutの原因が解明・修正されたとは断定しない。履歴・生ログ・hashはcheckout外の`C:/dev/neko-evidence/storage-completion-20261014/fresh-validation-fallback/`に保存している。

## 実クラウドの反映

- 2026-10-15 04:29:12Zまでに、新規テーブルを空で追加する`0037_tool_snapshot_references.sql`と既存2Workerを反映した。既存schemaを保ち、追加2table・index1・trigger4を確認し、新しい参照/claim表は空。DDL全体がatomicとは主張せず、各phaseは一回限りのintentと読戻しで確認した。
- archive version `b796a7cc-4b45-4898-b09e-cc301266555b`、bundle SHA256 `2d9c74385a8783f38aee79d27a8397eed05d3bee5917b6e2c7216019ed918a9b`。deletion version `788aea6c-7c1c-4a69-b1e8-58be91102f35`、bundle SHA256 `0a76903f8708b56f8719fe2575027687acaee01466d4e9b3aca5811aef4dc030`。各1upload・1activationで、既存resources/runtime/bindings/handlersを維持した。
- 旧本人・記録、grant・repair・debt・slot・fingerprint・期限、settings・secret参照・公開範囲・cronを維持した。通常owner/record write・grant発行・cron write/手動実行は0。980円を維持し、新しい有料サービスの契約・AWS Paid移行・一般公開・課金開始は行っていない。
- 実completion SHA256は`c34af7d7ad564a7481d41ad19f8226168c569a6830879d49d7b08df8cb4b031e`、独立post-review SHA256は`60b35dcdacef1d494b5e360012aefa53aaa48f027cb80132e8a7c342fb9d6d7c`。後者は内部256への別途レビュー済み配布操作を許可するが、Apple uploadや実機v2成功の証拠ではない。

## 内部256：Appleアップロード完了

- 署名対象を変えない正規CLIのdry-runは、既存255・次256、`--preservation-pilot --internal-reports`、billing OFFで成功した。
- レビュー済みwrapper SHA256 `77ad795ae10aab1072c06ea5b30ce1ccc535d03222bf2d2a3bf77c75e03d2330`から正規CLIを1回だけ実行し、対象runの既存testflight環境を1回承認した。署名・privacy/export・App Group・IPA export・Apple validate/uploadの実stepはすべて成功。生ログにも `UPLOAD SUCCEEDED` を確認した。一般公開や課金開始は含まない。
- 実release run: [38682198116](https://github.com/soso-so-27/neko-widget/actions/runs/38682198116)、job `116249012452`、attempt1、source `a7975512`
- 実upload状態・完了時刻: 2026-10-15 04:47:14 UTC（13:47:14 JST）、Apple upload成功。run全体も04:47:21 UTCに成功終了
- Apple処理・端末反映: Apple処理完了・TestFlight一覧反映・256実機導入はいずれも未確認。upload成功と区別する
- broad初回候補は **2026-10-14T12:59:13Z**。件数UIの後続候補や成功run開始時刻へ時計をリセットしない。旧失敗・queue待ち・迂回制御・配布を含む最終累計: Apple upload完了まで **15時間48分1秒（948.02分）**。再計画1050分は当初目標の達成や完了保証ではなく、旧失敗を含めた累計。256のrunは12分39秒、実jobは11分8秒。CI単独の17分58秒を全所要時間としない。

## 利用者の確認済み事項と残件

- 利用者は255で保存完了と同じiPhoneへの復元成功を報告した。31→29を実際に見た画面は不明で、23枚すべての実表示まで証明していない。内部集計の説明と実機観察を混ぜない。
- 255の正しい導線は **「保管したコピー」→「ツールの保存」→「この端末に復元する」→「復元したツールを開く」**。「保管したコピー」は見出し。「ツールの記録」という古い案内は訂正する。元データはそのまま残し、削除・再インストールしない。
- 残る実機確認は256そのもの、同Apple Accountの別iPhoneへの復元、新v2写真再利用・参照保護を含む往復。既成功の255同phone復元や254のZIP確認等を再び前提として要求しない。
- 認証付きcapability GETは正規の既存bearerが手元に無く未確認。D1のtoken hashからtokenを作らず、確認のため新しいsessionや保存writeを発行しない。
- 本人限定の試用1snapshotは消費済み。元の新規保存期限 **2026-10-15 20:17 JST**を維持し、試用の追加・延長・再発行・counter resetを行わない。現枠で新しいsnapshot保存を促さず、新v2往復の残件を満たすためにこの境界を緩めない。既存コピーの読取/復元とは区別する。
- 通常1人の実測原価は未確定。一般提供のAWS有料継続と保持・通知・整理等の運用費は承認待ち。旧3人枠・予備費案・合成上限・試験データを販売設計、平均原価、承認済み予算へ復活させない。
