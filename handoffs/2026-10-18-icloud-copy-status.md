# コピー自身の保存状態と、自動保存の本人接続を整える

## 06:43 JST時点の反映結果

- 製品候補は `27fe784f24695a4a118c7cab5c9b28ed97395323`。通常iOS [39064187042](https://github.com/soso-so-27/neko-widget/actions/runs/39064187042) の全8必須jobが2026-10-17 21:27:43 UTCに成功（97分11秒）。配布validatorで同じSHA・owning push・全必須jobを再照合した。未展開のskipped placeholderは成功へ数えない。Preservation owning push `39064187036` は全8必須step成功。
- [PR347](https://github.com/soso-so-27/neko-widget/pull/347) をmerge commit `6da78d725b3a64db7fde688d5e0426652c882b16` で本線へ統合。候補が祖先で全treeが同一と確認した。mainのiOS証拠再利用 `39071094166` とPreservation `39071094169` も成功し、nativeの実成功を再実行していない。
- 0041 migration、既存の削除処理側、保存処理側の順に反映し、21:31:20 UTCの完了証拠を保存した。前後の元記録・本人/会員情報・受付とcounter・secret参照・公開範囲・cronを照合して保持。元bundle候補 `35b1418` と資格候補 `27fe784` のservice・依存・設定・migrationなど21入力の閉包を確認し、同じbundleを使った。新しい契約・鍵サービス・一般受付・受付延長・定期操作は追加していない。
- 正規配布CLIのdry-runと1回のdispatchから、[TestFlight 260 / 39071374922](https://github.com/soso-so-27/neko-widget/actions/runs/39071374922) を実行。署名・App Group・privacy・IPA exportと「Validate and upload IPA to TestFlight」の実成功を確認し、**2026-10-17 21:43:28 UTC（18日06:43:28 JST）にApple upload成功**。アプリのsourceは上記候補、workflowのheadは製品統合main。preservation-pilot/internal-reports、billing OFFを維持。Apple側処理完了と実機で260が見えることは未確認。
- 途中の診断 `39061556299` / `35b1418` はruntime41/42成功・1失敗、UI未到達だった。追加fixtureの16byte/22文字nonceを、実serverと同じ32byte/43文字へ訂正した。productionの本人確認条件は緩めていない。訂正後のfocused診断 `39062699257` はruntime42件・専用UI1件成功、実PNGを確認した。診断成功は正式配布証拠の代用にはしていない。
- 初候補2026-10-17 18:38 UTC頃（初commit18:43:15 UTC）からApple uploadまで約3時間05分。失敗・再作業・準備・待機を含み、後続SHAで計時をリセットしていない。正式nativeは97分11秒、配布workflowは11分06秒。UIのみ150〜180分案を本人接続込み4〜6時間へ変更した履歴も保持する。月980円、追加の有料契約0。既存枠の利用・接続更新の費用部分とアプリ全体の一人原価を混同しない。

### 残る実機確認と一般提供の残件

- 通常写真メモの自動保存は、本人の「保存済み」とクラウド到着で確認済み。新しい端末鍵の実Apple登録・期限後の更新は未確認。260へ更新後、必要な初回確認を同じApple Accountで行う。保存受付と会員状態が有効な間に「保存済み」を確認し、アプリを離れる/ロックするなど普段どおり16分以上空け、通常写真メモを編集・保存する。追加のApple本人確認なしで「保存済み」になるかを見る。前面を維持したり自動ロックを変えたりする必要はなく、復帰時の更新でも条件を満たす。
- 会員待ち・受付停止・本人確認エラー・別端末競合が出たら文言を記録する。削除・再インストール・故意の競合は行わない。既存の同意と元データを保つ。
- 新v3の部品取得・整合検証・通常rootへの切替と、通常の写真メモ/JPEG・猫情報・各ツールの利用は実機未確認。「以前の保管記録」の手動復元や「復元したツール」は旧v1/v2の経路であり、その成功を新v3へ代用しない。安全な現行経路は別の空端末で同じApple本人に接続して自動保存へ同意する方法。これはソース上の確認で、実描画・実復元の成功ではない。復元の読取自体に新規購入や有効会員/PUT受付は不要だが、有効な同一本人認証と読取可用性は必要。復元後の編集送信には会員/受付が必要。
- 一般量の長期容量・索引/復旧性能、動画クラウド保存、一般提供・課金販売の条件は別途残る。「残りは実機だけ」「容量無制限/動画対応済み」とは案内しない。1台用v3 previewの追加は今回の必須作業に含めない。成功済み検査は入力が変わらない限り保持する。

以下は準備・検査中の履歴であり、上記を現在の結果とする。

## 03:49 JST以降の追加確認・計画変更

- 本人が通常の写真へメモを書いた後、「未送信の変更があります」「保管用の本人確認をやり直して」と表示された。同じApple Accountで本人確認し直すと「保存済み」へ変わった。03:49:42 JSTの読取で自動保存head revision2、写真25部品・JSON8部品、必要33部品すべてlive・転送予約0、旧31記録の不変を確認した。通常の写真メモから自動送信されることは実機報告とクラウド到着で確認済み。本文の復号や削除は行っていない。
- 残る原因は15分のaccess sessionの期限切れ。既存native fixtureは1時間のtokenであり、15分後の実運用を確認していなかった。access期限を長くするのではなく、Appleで確認した本人に束縛した端末専用P-256鍵で、短いaccess sessionを更新する候補を実装中。
- 初回Apple challengeへ公開鍵を束縛し、一度だけ使えるchallengeと署名proofで更新する。鍵は既存の会員購入用とは別にKeychainのThisDeviceOnlyへ保持する。30日未使用で失効、ログアウト・owner epoch変更・削除・Apple本人状態の失効を区別し、復旧データから端末権限を復活させない。遅れた応答で別のログインを消さないCASを維持する。
- 無変更の8秒pollごとに更新しない。実作業またはforeground準備の必要時だけ更新し、既存同意・未送信内容を保持する。Appleサーバーのrefresh確認は一日一度までとし、確定失効と一時的な通信失敗を区別する。一時失敗時も成功と見せず、鍵と元記録を保持して待機する。これは実装方針であり、native・サーバーの境界検証と実配備は未完了。
- 最初の実装候補03:38 JST頃、最初のcommit03:43:15 JST（`fa4ecd6649c3f270f4533d990212beaf456969c0`）を維持する。UIだけの150〜180分案を撤回し、本人接続・migration・データ保全の追加検証を含め4〜6時間へ再計画した。全経過・失敗・待機をこの初候補から集計する。
- コピーUI専用診断 `39059364856` は03:43:39 JSTに開始し04:00:57 JSTに成功。jobは17分08秒、専用UI1件は37.586秒、skip/失敗0。実PNGで「このメモの保存状況」「このコピーの保存先はiCloud」「iCloudに保存済み」と閉じる操作を確認した。準備時のiOS26.2 runtime42件も成功。これはfa4の実描画確認であり、追加する認証のnative確認や配布証拠の代用にしない。統合候補は既存selectorで必要scopeを再判定し、認証変更に必要なnativeとPreservation owning検査を新しく通す。旧6job案をそのまま使わない。
- 更新前の15分だけのログインには端末鍵がないため、新版で初めて端末鍵を登録するときは同じApple Accountでの本人確認が一度必要。自動保存の既存同意・未送信内容は保持する。通常利用中の15分ごとの確認をなくす変更であり、Appleの失効・長期未使用・一時障害でも無条件に保存成功とする変更ではない。
- migration0041とarchive/deletion/recoveryの互換性・全現存記録の不変を確認してからクラウドへ反映し、同じ検査済み候補をTestFlightへ配布する。新たな有料契約は不要。増える認証処理のrequest・D1行・KMS回数と既存残枠を確認してから反映する。料金980円、一般公開・課金、受付期限・counter、定期タスクは変更しない。

- 04:08 JST時点でバックエンド最終候補のtypecheck、node32件＋Vitest596件/70ファイル、既存migration5件が成功。別の0040→0041 SQLite検査で既存記録・本人情報・counter・recovery generationを保持し、旧session/challengeへ追加列NULL・端末権限の自動登録なし・FK整合を確認した。初回のD1 trigger込みchanges誤判定はRETURNING判定へ修正済み。失敗を最終成功で隠さない。
- native側は端末鍵の実署名、15分超過、同時更新1回、再起動、通信失敗、失効、ログアウト/新ログインとの競合を既存runtimeケースへ追加した。ローカルstatic検査23件成功。実Swift実行は統合候補のfocused診断で先行し、その後selector指定の通常検査を行う。
- 認証追加分の局所D1実測は通常更新read23/write13、日次Apple再確認read33/write13。月60回更新（うち日次30回）の仮定で、HTTP120・D1read1680/write780・KMS復号30・R2読取420。既存単価での既知部分の線形配賦は約0.17円/人月（計画換算158.345円/USD、税別）。CPU・DB容量・初回登録・token回転時の復旧コピーは別であり、これをアプリ全体の費用や請求額とは呼ばない。現アカウントの含有枠/丸めもある。実配備前に残枠と有限試験窓を再照合する。

- 統合候補 `35b1418` の診断 `39061556299` はコンパイル成功後、runtime42件中41成功・membership境界1失敗で停止しUI未到達。job10分09秒、run625秒を保持する。追加fixtureがBilling用16byte nonce（22文字）を再利用し、実serverの32byte nonce（43文字）を必要とするproduction proofが拒否していた。fixtureだけSecRandomCopyBytes32byteへ修正し、製品の認証条件を緩めない。32byte→43文字、実serverとの一致、runtime validator6件をローカルで確認。nativeは修正後再確認が必要。
- クラウドの読取で現在の全68記録・既存設定を保存。0041のschema-only互換と設定保持のローカルbundle生成、writerの読取事前確認が成功。cloud書込0。初回の取得API指定405、歴史的migration記帳順の検証誤り、WindowsのNode preloadパスは準備スクリプト側の問題として保持し修正した。完成bundleのPreservation service treeは固定し、native fixtureだけの後続修正では同treeの証拠を保持する。

以下は認証問題が判明する前のUI候補の証拠・計画であり、上の追加確認が現状となる。

## 原因と変更候補

- TestFlight 259で本人が編集した「メモ」の削除項目は「保管したコピーを削除」。これで `PersonalArchiveRecordView` のiCloudコピーだと確定した。ローカルメモとのbindingの有無までは実機報告から断定しない。
- release版の同画面の「保存状況」は全体の `AppRecordSettingsView` を開いていた。そこでの「保存済み」は、選択中のiCloudコピーの保存完了を保証しない。既存DEBUG検査は別のselected-copy fixtureへ進み、この相違を検出していなかった。
- コピーの詳細に保存先を表示し、メニューを「このメモの保存状況」へ変更。本人とrecord IDに束縛した読取専用画面で、iCloud保存済み・反映待ち・競合・削除待ち・読込未完了・確認エラーを区別する。古いstored状態よりpending/inFlightを優先する。
- 全件の写真を読まず既存の単一record readerを使う。アカウント変更・背景移行・画面消失時は表示結果を破棄し、読取の前後の本人とgenerationを照合する。移行、再送、削除、会員接続、自動保存の有効化は行わない。
- 同じrelease遷移を使う専用UI検査を追加。iCloud表示、無関係な会員・購入・自動保存操作の不在、閉じた後の元メモ表示維持を確認する。画面の不在確認だけを、保存設定の不変の証明とは扱わない。

## 直接証拠と残る確認

- 本人の画面画像とメニュー名、releaseソースの遷移、03:33 JSTのクラウド読取を対応付けた。新自動保存headはrevision1、必要32部品すべてlive、旧31記録は不変。本文の復号は行っていない。
- 初回自動保存は本人の「保存済み」報告とクラウド到着で確認済み。今回の編集はiCloudコピーなので、通常ローカルメモの編集が新自動保存へ届いた証拠にはしない。
- 独立レビューで本人境界を確認。「削除＋競合」の判定順序の指摘を修正し、再確認済み。
- ローカル `test-memo-row-navigation.py` 2件、署名入力の `test-media-staging-release-config.py` 28件が成功。後者の入力は本変更で不変。Swiftコンパイル・実描画・新CI・配布は未実施。
- 旧iCloudコピーを自動保存へ取り込む変更は含めない。259の旧ツール復元は新v3自動保存の復元と異なり、同一iPhoneでの新v3 preview導線もない。通常編集の自動送信、現在のv3の実機復元は未確認として残す。

## 検査・配布前の計画

- 調査開始は2026-10-18 03:33 JST頃、最初の実装候補は03:38 JST頃。正確な初commit時刻はGitとrepo外の証拠に記録する。待機・失敗・再作業を含む実装候補からの経過も保持する。
- 変更する製品入力は `PersonalArchiveView.swift` と既存UI検査ファイルの2本。既存selectorで `app-private-data-ui-v1`、必要nativeはBuild・Photos・runtime・Solo1・Solo2・otherの6job。Gallery対象外。最終clean候補のpreflightで再判定する。
- 最初に正規 `preflight-ci.py --feedback` から専用UI 1件を診断し、実描画を確認する。診断は配布証拠ではない。その後 `--measure-baseline --include-upload --target-minutes 180` で新scopeを初計測する。未計測scopeへ旧full基準を流用しない。
- 参考実績はfocused 21.9〜26.6分、通常graph約100分、259 upload 12分37秒。ローカル確認等を含め150〜180分を見込むが、新6jobの実績・queue・失敗は未確定。待機が増えた場合は実経過へ加算する。
- 新候補6jobの実成功→merge commitでmainへ統合→同候補SHAでTestFlight。既存preservation-pilot/internal-reports、billing OFFを維持し、配布CLIのdry-runで未使用buildと署名期限を確認する。UI修正だけなのでクラウド再配備は不要。
- 署名29入力は不変、署名期限は2026-10-18 15:57:36.812 UTC。期限内でも最終配布CLIの検証は省略しない。

## 費用・権限

- 月額980円維持。契約・一般公開・実課金・受付延長・counter reset・Codex定期変更は0。
- repoはpublic、標準runner使用を確認済み。GitHub請求APIは現資格では読めず本人に既存GitHubログインを依頼。本人のログイン後、soso-so-27の実請求画面でActions全額割引・請求対象0 USD、storageも実利用24,954.61 GB-hrに対して請求対象0 USDを確認した。同じpublic標準runner/既存artifact設定で進める。支払方法・プラン・資格scopeは変更しない。この保存実費は、過去の最大有料仮定の試算と区別する。
- 個人画像・メモ本文・クラウド識別子はこの公開handoffへ記載しない。詳細の読取証拠はrepo外 `C:/dev/neko-evidence/automatic-test-20261018/` に保持する。
