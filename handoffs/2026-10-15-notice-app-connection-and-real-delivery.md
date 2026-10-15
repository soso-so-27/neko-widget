# 通知のサーバー接続と実メール到達（2026-10-15）

**アプリが使う保管サーバーへ `notice@nekonomado.com` を接続し、試験メール1通の実配達と本人の受信トレイ到着を確認した。980円維持、新しい月額契約・購入なし。一般利用者への自動通知はまだ開始していない。** [ドメイン購入と接続準備](2026-10-15-notice-domain-connection.md)の後続。

## 完了した接続

- 稼働中の `neko-preservation-staging-disabled` に `NOTICE_EMAIL` bindingを追加。送信元は `notice@nekonomado.com` だけに制限し、account/zone/subscription/domain/sender/queueの6設定と、32byte乱数由来の `NOTICE_RECIPIENT_TAG_SECRET` を追加した。秘密値はクラウドへ直接渡し、資料・ログ・ディスクへ保存していない。
- Cloudflare account `829a34ef925a39d81b0e9e08800d7c7f`、zone `3561d4111d62ccb1f0e099f81810879c`、購読 `251f113543524fd1a9f81355ad182b06`、Queue `neko-retention-notice-events-nekonomado-v1` に固定。新しい失敗隔離先 `neko-retention-notice-dlq-nekonomado-v1` を作成した。旧ドメイン用Queue2件・旧購読は不変。
- 本体はsettingsだけを1回PATCHした。新しい稼働versionは **`d0adaee7-9e82-45e6-85fe-26d33354e6f4`**、100%単一配備。稼働version詳細のbindingも照合した。実行コードSHA256 **`2d9c74385a8783f38aee79d27a8397eed05d3bee5917b6e2c7216019ed918a9b`** は前後同一。既存DB/R2/S3/key/secret参照・保存受付・試用枠・期限・公開範囲を保持した。
- `RETENTION_TRACKING_ENABLED / NOTICE_SEND_ENABLED / NOTICE_EVENTS_ENABLED / CLEANUP_ENABLED` はすべて **NO** のまま。通知試験のためにcleanupをONにしていない。billingも変更していない。iOS入力やAPI接続先の変更がなく、新しいTestFlightは作成せず、既存256を維持した。

## 実メールの結果

利用者が「前回と同じ個人用Gmail」を選択。個人の宛先は公開資料へ転載しない。送信元・宛先を各1件に制限した試験専用binding、認証付き制御、30分の窓、永続的な最大1送信の制限を使った。実会員の期限を変えず、専用DBの合成ownerと、製品と同じ `NoticeDispatch / NoticeSubmissions / RetentionLedger / processDeliveredNoticeEvent` を使用した。

- **実送信1通**。件名に「テスト通知・実際の保管期限ではありません」を付け、本文にも試験であることを明記。実際の契約・保管期限が変わる通知ではない。写真・猫名・認証情報・持ち出しリンクを含めていない。
- 2026-10-15 **16:56:31.366 JST** の実 `message.delivered` を専用のprivate Queueから受信。providerのmessageId、eventId、account/zone/subscription/domain/sender、選択した宛先、合成ownerの送信記録を照合し、製品処理で **receipt evidence v2** へ進んだ。配達後30日以上の猶予も合成台帳で確認した。API受付だけを配達済みにはしていない。
- 利用者が **「受信トレイに届いた」** と回答。メールサーバーでの受付と、人が確認した受信トレイへの到着を区別して記録した。
- 終了後は試験を無効化し、実eventと送信台帳のprivate証拠を保全してから、今回の試験consumer・Worker・専用DBだけを撤去した。既存利用者のデータ変更・削除0。本体の31記録/22,378,689 quota bytes、owner1、contact1、retention0、submission0、migration inventoryは前後一致。

## 検証と途中停止の扱い

- 送信先/権限変更として独立レビューを行った。新しい閉じたfixtureで、全既存bindingのinheritと新設定/secret追加のPATCHを先に実測し、稼働version resourceと実行etagが一致することを確認してから本体へ適用した。
- 試験harnessのローカル境界10項目が成功。認証、activation/送信の1回制限、受付だけで配達にしない条件、異なるsource/非delivered拒否、receipt v2、30日猶予、削除禁止、無効化を確認した。連絡先変更/再加入の製品検査は、入力・依存が同一の既存成功を維持した。
- 最初の標準HTTP clientのhealth確認は403。識別用User-Agentで同じ閉fixtureを読取り確認し、製品やセキュリティ設定は変えず再配備もしなかった。その後、Queue APIの実応答が `script_name` でなく `script` だったため、**activation/dispatch前**の検査で停止。DBのowners/runs/submissionsが各0、送信要求未発行を確認し、応答fieldだけを修正して独立再レビューした。失敗を成功扱いにせず保存し、メールの再送はしていない。
- 最初の候補 **16:42:33.755 JST** から実配達照合・試験環境撤去 **16:56:45.690 JST** まで **14.2分**。準備見込15分＋配達観察上限8分を先に記録した。資料反映の時間はこの試験終了時刻に含めない。
- 製品/CI/依存の入力は `332f1545` の15ローカルsuite成功（432.8秒）から不変。NekoWidget/.githubの全tree、AGENTS、配布手順のGit entry一致で保存し、資料だけのための再検査・native CI・配布は追加しない。今回の差分/リンク/preflightは別に確認する。
- private証拠・実送信済みの再実行禁止helperは `C:/dev/neko-evidence/notice-app-connection-20261015/`。`verified-result.json` はサーバー側最終読取り、`inbox-confirmation.json` が後続の本人到達報告。`mail-once-execution-private.json` は未送信で停止した最初の記録、`mail-once-execution-identified-consumer-private.json` が実1通の結果。いずれも再実行しない。

## 残る運用条件と費用

1. 本体は一般通知の送受信gateを閉じているため、Queue consumerを本体へ付けたままretryを消費させない。試験後はconsumer **0**。将来の運用開始時に、現在の本人連絡先・会員終了日の根拠、配達照合/再試行/失敗隔離を実会員の経路へ接続する。今回の合成ownerの成功をApple連絡先由来や実会員終了の証明にはしない。Queueは4日、DLQは14日の有限保持であり、恒久保管ではない。
2. 自動通知の起動と、安全な保管整理の接続は未開始。現scheduledの通知処理はcleanupの後段なので、cleanupだけを勢いでONにしない。既存の保持条件・参照/復旧安全性・一般枠・停止条件・保持原資を満たしてから運用候補を確定する。今回cron/定期タスクの追加・変更・手動再実行0、既存本人退会削除cronは完全不変。
3. 今回は既存Workers Paid/Email Sending/Queuesの契約枠を利用し、新しい月額契約や購入はない。[Email Sendingの既存共通枠](https://developers.cloudflare.com/email-service/platform/pricing/)は月3,000通、[Queues](https://developers.cloudflare.com/queues/platform/pricing/)は月100万operations。将来の全原価の無料保証ではない。承認済みドメイン年額は前回資料のまま。AWS Paidへの変更・一般公開・課金開始・利用者への一斉送信・試用枠の追加/延長は行っていない。追加費用や新契約が必要な段階では、金額と用途を先に利用者へ伝える。

## 契約終了日の連携と自動通知の待機開始（後続・最新）

**Appleから試験契約の実終了日を取得でき、15分ごとの自動確認も実際に完走した。通知の送信設定を有効化したが、本人のiPhone署名による会員情報の接続はまだ0件で、現在の送信対象も0件。980円維持、新契約・購入0。** 上の「consumer0・全gate NO・cleanup後段」は16:56時点の履歴であり、以下が後続となる。

### 反映した動作と保護

- [制御PR323](https://github.com/soso-so-27/neko-widget/pull/323)を先行反映し、[製品PR324](https://github.com/soso-so-27/neko-widget/pull/324)をmain `7e6d052adeecdb46915a2f92b0d871d21a37a8cb`へmergeした。検証候補は `bbfe74b5eecb783a0553634af321ebf96fc35af8`。native入力・既存TestFlight256は不変で、再配布しない。
- 保管用の非公開照会だけが、登録済みSandbox契約をAppleで再確認する。購入受付が閉じた後も利用できるが、購入・新しいaccount/契約lineage・管理者による本人リンクは作らない。全登録lineageの新鮮な観測が揃わない場合、終了日はunknownとして保留する。新鮮24時間は再照会を省き、失敗時はlease/backoff、1回30秒の中断期限、呼出元の取消を守る。実サービス経由のprivate照会が2026-10-15 18:30 JSTにverified/expired/実終了日を返した。購入・メール0、終了後の一時previewも停止した。
- 実際の契約終了日から12暦月を計算する。古い/不明な根拠で期限を決めず、再契約は保持判定を更新し、既存期限を短くしない。本人連絡先・契約episode・配達元・送信記録を送信前と配達反映前に照合する。
- tracking/配達event/実行監視/送信をYES、**CLEANUP_ENABLED=NO**。通知を始めるために写真・セッションの自動整理を開けない。即時送信停止は `NOTICE_SEND_ENABLED=NO`。migration0038は実適用済みで、送信前にアプリ共通でUTC日50試行・UTC暦月1,500試行を原子的に予約する。失敗/結果不明でも予算を返さない。これは請求周期や他アプリを含むaccount全体の強制支払上限ではない。
- 新domain専用Queueに本体consumer1件、既存DLQを接続した。batch5/concurrency1/retry3/待機5秒/再試行3,600秒を実値で照合し、旧domain・全配達購読・既存退会削除cronは不変。保管本体には `*/15 * * * *` を1件だけ登録し、手動cron実行・Codex定期タスク作成/再実行は0。
- 15分（96回/日）は今回owner1の閉じた試験範囲。開始時に復旧用ownerコピーの未処理0を確認した。変更なしの空確認ではS3/KMSコピーをしない。データ更新/修復失敗があれば別途復旧処理が必要になり得る。Apple失敗時もbackoff後に複数回/日の再試行があり得るため、「1日1回だけ」「AWS全操作0」とはしない。

| 稼働サービス | 確認した100%単一version |
| --- | --- |
| `neko-billing-gateway-staging-private` | `daafe90f-f1f9-4591-8de9-7f79e736d26e` |
| `neko-preservation-billing-staging-disabled` | `c44712fa-dbd8-4944-afa1-f925af5fd87f` |
| `neko-preservation-staging-disabled` | `7549ce96-0886-4e86-a6c3-ff488cb8ab28` |

### 実行結果と検査

- 登録後の実自動実行は **2026-10-15 19:00:58 JST開始 → 2026-10-15 19:00:59 JST終了、errorなし**。その完走と対象0を確認してから送信設定だけをYESへ変更した。最後の読取りでも31記録/22,378,689 quota bytes、owner1、Apple確認連絡先1、本人リンク0、retention0、送信記録0、送信予算消費0。元データの削除0。
- Preservation全68file・526件とreadiness32件、関連57件、実workerdのprivate binding、generation7→8/lease/backoff/失敗時unknown/実30秒期限/取消を確認した。owning pushの[iOS plan 38710477280](https://github.com/soso-so-27/neko-widget/actions/runs/38710477280)、[private billing 38710477302](https://github.com/soso-so-27/neko-widget/actions/runs/38710477302)、[Preservation 38710477269](https://github.com/soso-so-27/neko-widget/actions/runs/38710477269)は同候補SHAの必須job実成功。main側3runも成功。成功済みのnativeや15開発flow suite（411.0秒）は入力不変を確認して保持し、資料のために再検査しない。
- 送信先/権限/保持境界と実運用controllerを独立レビューした。全binding・非binding設定・稼働codeとversion・consumer制限を照合。実code/settingsのGETは未配備uploadも示すことを直接観測し、配備状態はdeploymentsとversion resourceで別に判定した。最初のuploadは再送せず、その既存versionを検証して継続した。
- 途中のtimestamp精度/永続fixture行/Node早期拒否transport/abort timerの失敗、制御scopeがfullへ戻った最初のpreflight、remote preview403（認証付き照会前に停止）を保持した。原因別に局所修正し、未実行/skipを成功としない。初回候補2026-10-15 17:13:41 JSTから最終cloud確認まで **108.4分**。当初25〜40分見込を超えた。CI秒数だけを全作業時間として扱わない。資料反映の時間はこのcloud終了時刻に含めない。
- リポジトリのwrangler既定値は受付/通知OFFの安全な雛形として維持した。次回の実配備でも現行binding/秘密参照/単一cronを読取り照合してinheritし、雛形のdeployで通知を黙って閉じたり別resourceへ付け替えたりしない。
- private証拠は `C:/dev/neko-evidence/notice-automatic-20261015/`。`final-verified-private.json`、`contract-probe-result.json`、`notice-send-enabled.json`、各bundle/settings/migration/実行記録を保存した。`*-requested.json` のある実行helper・実送信済みの前回helperは再実行しない。

### 残る本人操作・一般運用・費用

1. 利用者は「会員情報を接続」が見当たらないと報告した。現在の内部テスト枠では接続ボタンを表示しない既存UI条件だった。**2026-10-15 20:17:01 JSTの試用期限後**に「保管枠を確認」で更新し、「会員情報を接続」→確認dialogの「確認して接続する」を使用する既存経路がある。購入・再保存・削除・再インストールは不要。期限後の実描画・本人署名リンク・実ownerの終了日/保持期限への反映はまだ未確認で、コードだけで確認済みとしない。管理者SQLで代用せず、試用を短縮/追加/延長しない。
2. 今回は署名リンク0の安全な待機開始であり、実owner宛の契約終了通知が実配達済みとはしない。前回の1通は試験到達の証拠として保持し、再送しない。一般公開/課金開始、一般枠と12か月保持原資、参照を守った世代整理、公開説明/審査の残条件は別に残る。
3. 既存Workers Paid等の枠を利用し、新規月額契約・購入0。認証済み請求画面で当周期の従量利用額0.00米ドル、メール1/3,000・billable0を確認した。固定契約料を含む全請求や今後の共通枠の無料保証ではない。AWS Freeの承認済み範囲を維持し、Paid化していない。**980円を維持し、新契約や未承認の追加支出が必要な段階では金額と用途を先に説明する。**
