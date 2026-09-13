# 承認済みキューの追加・期限保守

このCLIはローカル候補を作るだけ。通信、配備、heartbeat登録、実配備bundleのpointer更新は行わない。

OfficialWindowServiceから実行する例：

    node tools/prepare_maintenance.mjs --previous C:/evidence/deployed/bundle --queue C:/evidence/supply/queue.json --output C:/evidence/candidates/new-edition

全パスはローカルの絶対パス。previousには実配備したbundleとそのupdate-record.jsonが必要。履歴欠落時のbootstrapはしない。outputの親は既存ディレクトリ、output自体は未存在とする。

## private queue

schemaVersionは1、itemsは最大256行。それぞれ次の値を持つ。

- id：photo.idと同一のslug。キュー内で重複させない。
- channels：既存channel IDの重複しない配列。新しいまどは作らない。
- scheduledAt / approvedUntil：秒単位のUTC日時。例 2026-09-15T00:00:00Z。承認期限は予定日時より後。
- approved：true必須。提供許可が実在することの確認は運営側で行う。
- imagePath：既存publisherが生成したJPEGの絶対パス。basenameもphoto.imageFilenameと一致させる。
- photo：publisherの公開metadataから id、catID、catName、credit、任意caption、imageFilename、sha256、width、heightをそのまま写す。publishedAt・expiresAtはここに入れない。

未来行・期限超過行・掲載済み行も、metadata、承認、画像hash、サイズ、通常ファイルを確認する。元画像、UIスクリーンショット、privateまどの画像をこの仕組みで掲載承認済みに変えることはない。JPEGのmetadata除去は先行するpublisherの責務。保守CLIのヘッダー検査は画像の取り違えを検出するguardで、APP1〜APP15・COM、thumbnail付き/非JFIFのAPP0、SOF寸法の不一致、segment長の破損を拒否する。完全デコード検査やmetadata除去は行わず、Python/Pillowの実行依存を増やさない。

到来済みかつ承認期間内で、そのchannelの掲載履歴にID/hashがない写真だけ選ぶ。休止channelは再開せず、撤回・停止後も履歴がある写真は再掲載しない。一方のchannelが休止中でも、他の稼働channelへの初掲載は可能。同じバッチで追加する写真のpublishedAtは今回時刻に揃え、expiresAtは今回時刻＋7日とapprovedUntilの早い方。既存写真の日時・期限は変更しない。

PC休止などで複数予定を過ぎても、1候補で追加する画像は全channelを通じて1 IDまで。scheduledAtが早い順、同値はid順に選ぶ。同じ1枚の複数channel掲載は可能で、未選択の到来済み行はdeferredとして次回へ残す。nextActionAtは次の候補を作れる最早時刻を示すだけで、自動で追加候補を連続作成しない。

## 結果と引き継ぎ

- no-change：出力を作らない。nextActionAtに次の予定追加・catalog保守・現掲載写真失効の最早時刻を返す。同秒のgeneratedAt競合も候補を作らず、deferredReason付きで1秒後を返す。
- candidate-prepared：候補はoutput/update/bundle。output/maintenance-report.jsonに選定理由と残数を保存。公開対象はbundle/assetsだけで、履歴・キュー・内部レポートは公開しない。

catalog期限残24時間以下、予定写真の選定、現掲載写真の失効のいずれかがある時だけ既存prepare_updateを呼ぶ。対象外channelも保持する。queue.remainingCountは未掲載かつ承認期間内の素材数、remainingAfterCandidateはこの候補の配備成功後に残る見込み数。channel別残数、nextScheduledAt、earliestApprovalExpiry、期限超過行・休止行も返す。候補作成だけで実配備済みとは扱わない。

nextActionAtは運用への情報であり、処理を予約しない。毎日9時・21時JSTのheartbeat設定と、候補検証→既存previewへの配備→pointer更新は主担当が別に行う。承認済みの未来キューが尽きたら補充が必要で、自動生成はしない。

途中失敗の出力は調査のため残し、自動削除・再利用・復旧をしない。入力と既存履歴は変更しない。掲載済み行をキューから整理する場合もupdate-record.jsonは保持する。

検証：node --test test/maintenance.test.js。20件。metadataなしの小さい実JPEGをテストに含み、hashを合わせたmetadata挿入・寸法不一致・ヘッダー破損も拒否する。未来時刻の結合テストはprepareUpdate内部のDate.nowも同じ時計に揃え、製品の期限検証を緩めていない。
