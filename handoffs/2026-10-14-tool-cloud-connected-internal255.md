# ツール保存・復元のクラウド接続と内部255

2026-10-14 20:23 JST時点。月980円を維持し、既存本人だけの試用枠を実発行した。販売人数を3人に限定する設計や、旧予備費込み見積を通常の1人原価・承認済み費用として使わない。

## 使えるようにした範囲

- 内部版255をAppleへ実アップロードした。5つのツールの端末に保存済みの入力内容と添付JPEGをまとめて保管し、同じApple Accountで別のiPhoneへ復元する実装を含む。復元は元記録を上書きしないコピーで、通信を切った後にも開ける構成。実機での今回の往復は未確認。
- 既存クラウドの保管Workerをツールv3と有限試用に接続し、追加migration35の空台帳から、既存本人・epochだけの試用枠を一度発行した。最初の有効な部品のsnapshot IDへ自動で結ぶため、利用者がIDを手入力する必要はない。
- 既存の削除専用Workerも現在の承認済みsourceへ更新し、今回の試用台帳を正規の本人削除で消せるようにした。旧本人1名・記録1件の値、旧pilotとcounter、秘密参照、公開範囲、定期処理の登録と設定を保持した。通常の記録へのwriteは0。

## 今回の試用と使い方

**新しい保存を試せる期限は2026-10-15 20:17:01 JST。保存1回分、入力累計最大20MiB。** これは本人限定の動作確認で、一般販売の人数・容量条件ではない。失敗や再試行も有限枠を消費し、新しいコピーを何度も作る枠ではない。期限後も既存コピーの読取・復元を止めない設計で、物理削除や一般受付開始は行っていない。

1. TestFlightに255が表示されたら更新する。Appleへの送信成功を確認済みだが、Apple処理完了・端末への反映は確認していない。
2. 元のiPhoneで、必要なツールの内容と小さな確認用写真を用意する。設定 →「サービスに保管した記録」→ Appleによる本人確認 →「ツールの保存・復元」で説明に同意し、「ツールを保管する」を押す。
3. 別のiPhoneでも同じApple Accountで本人確認し、保管したコピーを開く。「この端末に復元する」→「復元したツールを開く」で5種類の内容と添付写真を確認する。
4. 元記録が残っていること、復元コピーを通信なしでも開けることを確認する。編集可能な復元ツールは少し編集し、アプリを開き直して残ることを確認する。「うちの子を見せる」の復元写真は見返す用途。

通信中断は「中断した保管を再開する」を使う。途中のコピーを取り消して別の保存を作り直すと、今回の有限枠では拒否される場合がある。元記録・元写真・アカウントを削除して確認しない。

## 実反映の証拠

- アプリ候補 `856194e2635e17821b539e3076563267ba6b1f8f`、[TestFlight run 38542522102](https://github.com/soso-so-27/neko-widget/actions/runs/38542522102)、job `115780527357` の実upload step成功。build255、内部保管と本人通報のみ、billing OFF。job11分16秒、run全体14分45秒。署名readinessが期限内のアップロードを保持し、backendだけの変更で再署名・重複配布しない。
- 制御[PR299](https://github.com/soso-so-27/neko-widget/pull/299)を先にmain反映し、製品[PR300](https://github.com/soso-so-27/neko-widget/pull/300)をmain `bac73b9`へ反映。検証source `afbee65b7e1153ba01f6f5c4bb2c0452203fd9a8`、service tree `a7ad12860657a8541f97cca659abdaacf1d6b03c` がmainと一致する。
- 同source owning pushの[Preservation 38549018837](https://github.com/soso-so-27/neko-widget/actions/runs/38549018837)で型検査・全test・synthetic migration・両private bundleの8必須stepを実行成功、job1分44秒。[iOS plan 38549018787](https://github.com/soso-so-27/neko-widget/actions/runs/38549018787)も成功。native入力は不変で、skipを新native成功に読み替えない。
- 保管Worker version `705195d9-63f9-4777-b86e-ae6c1704113a`、bundle SHA256 `4b757248e745f55dac9aaf035a3829b7bfda3ae41ccca9d4faeaa09c1f10f86b`。追加35だけ・凍結bundle全文一致・旧schema/記録/設定不変を実確認。
- 削除専用Worker version `f61cf178-a135-4a66-8efd-18df0bd656fc`、bundle SHA256 `6ca4e1c96101f70bc5afb685334ea30e38676a62a71515787fe03965d5c5e5a3`。固定multipartのversion POST一度と100% activation POST一度で更新し、cron同期・手動実行を行わず、全設定/秘密参照/公開範囲/既存queue metadataの不変を確認した。journal本文の完了段階・hashは読んでおらず、metadata一致から意味まで確認済みとはしない。
- 試用枠は20:23:13 JSTに一度のINSERTで発行。既存本人だけ・固定20MiB/400試行/200slot以下・1 snapshot・24時間以内・新counter0/unboundを実確認。原pilot期限/旧counterを延長・resetせず、一般受付は閉じたまま。

具体的owner識別子・費用画面の残額・秘密・SQL結果はpublic repoへ置かない。主担当のローカル証拠は `C:/dev/neko-evidence/tool-owner-trial-20261014/` の `deployment-v2/completion.json`、`deletion-executor-update/completion.json`、`grant/completion.json` とそれぞれの独立review。配布証拠は `C:/dev/neko-evidence/tool-cloud-preparation-20261014/release/255-upload-completion.json`。

## 費用と残作業

新しい有料契約・AWS Paidへの変更・課金開始は行っていない。利用者の既存AWS無料プランの画面と当月アカウント利用量を確認し、既存契約内で有限試用を発行した。AWSの再ログインや残額の手入力を条件にしない。

20MiBは、デコードしたJSON部品/目録/JPEGと各試行2KiB予約の入力累計。暗号文、S3履歴、読取、ログイン等を含む総請求上限ではない。当月アカウント利用額をそのまま1人原価にはしない。

残る作業は、255の実機保存→別iPhone復元の確認、その普通の利用量に基づく1人原価の計算、一般提供の保持・通知・整理運用、LPと審査資料の整合。全写真・動画の原本バックアップ、自動差分保存、ZIP読込みまで完成したとは説明しない。

費用承認が必要なのは、AWS無料期間終了後などの有料継続と、具体的な一般提供構成の継続費用。旧月10,000円/初月25,000円/保持150,000円等の案を承認済みとして実行しない。一般公開・外部招待・審査提出・課金開始も未実施。

既存のCodex定期タスク「ねこのまどの配信保守」の登録確認を引き継ぐ。重複作成・更新・移管・手動再実行は0。削除Workerの既存5分cronも登録・設定を変更せず、手動実行しない。

## 経過と修正

製品の初回候補09:24:48 UTCから試用発行11:23:13 UTCまで1時間58分25秒。CIの1分44秒を全作業時間とはしない。ローカルfixtureの型/IP/caller-secret/期待値とcoverage条件、CI closureの対象数と末尾NUL期待、migration既適用順とファイル名順の相違、executorのplacement空objectとmetadata期待の診断を保持し、成功済みの不変入力を再検査しない。

削除executorが旧sourceだったため、空35の保管反映後に実到達経路とversion schemaを調べ、grantを最後へ置いた。CLIの内部upload retry/settings同期を避けるため、公式local multipartと単発RESTの方法へ変更した。途中の失敗や旧freezeはローカルに保持し、実機往復・一般販売・1人原価を未確認のまま完了扱いしない。
