# 内部Sandbox購入の配布準備（未配布・実購入未確認）

## 完了と扱わないもの

現在の内部TestFlight235は購入OFFである。アップロード成功、会員案内のUI、合成の権利検証、Appleキーを使った存在しない取引への404は、実商品の申込・取消・復元・失効の通し確認ではない。

2026-10-01 18:58 JST頃のApp Store Connect読取で、正しいIssuerの既存IAPキー425C27496Jがactive、有料アプリ契約は「ユーザ情報を保留中」、U.S. Form W-8BENとCertificateは税務情報不足、銀行口座は処理中だった。税務住所の訂正依頼・フォーム・契約を変更していない。Apple TN3186のSandbox要件には有効な有料アプリ契約が含まれる。実商品の購入成功は未確認のままとする。

## この候補で準備したこと

- 通常配布と保管だけの内部pilotでは、従来どおり全Plus設定OFFを維持。既定のInfo.plist・Config.xcconfigは変更しない。
- 別の明示`billing_sandbox=true`に、`preservation_pilot=true`、media-staging、既存pilot承認、protected `BILLING_SANDBOX_ENABLED=YES`/`BILLING_SANDBOX_SCOPE=internal`が揃ったときだけ有効。
- 月額`jp.nekowidget.plus.monthly`と既存staging購入APIを固定。年額は空。Storefront・サーバー購入確認・復元を接続する。新しいキー・サーバー契約・実課金開始をしない。
- 内部archiveの入力でだけ、app/Widgetの`MembershipAccessEnforced`をbool trueにする。通常sourceのfalseを確認してから変更し、署名済みarchiveで両方のbool・商品・送信先・privacyを照合する。購入画面だけON、会員制御はOFFという不十分な通し確認にしない。
- internal限定exportを維持する。通常releaseは購入要求なしなら従来の設定へ戻る。
- 新しい読取専用runtime profileは必要なbilling 7 gateのON、history recoveryのOFF、notification limiterのREADY、generationの正規整数を要求する。通常のlimited-external-beta profileは不変。これはgate readinessであり、Apple/verifier疎通の成功証拠ではない。

## 証拠と未確認

- 配布設定11件、配布CLI37件、既存署名/evidence順序3件、runtime checker19件、通常beta報告境界4件がローカルで成功。最初の追加テストはWindowsの既定cp932によるUTF-8 workflow読取エラーだった。テストにencoding指定を追加し、製品の振る舞いはその失敗を理由に変えていない。
- 独立レビューは配布5パスと追加runtime条件を確認し、確定P1/P2なし。既存署名・内部限定export・通常beta不変・固定商品/送信先・実境界の条件を保持する。
- Xcodeが処理したInfo.plist、署名済みarchive、Appleアップロード、protected設定の実環境、実StoreKit商品/無料体験/取消/復元/期限切れ/通信断は未確認。ローカルの辞書/fixtureをそれらの代用にしない。
- この記録時点では候補はローカルのみ。push/CI/main反映/新TestFlightをまだ行っていない。

## 次の実行順序

1. 本線担当のContainer/Node＋caller候補を先に統合し、既存非公開サーバーで短時間の接続・署名・nonce・停止を確認する。担当は既存チャット「ねこのまど本線開発を開始」。呼出側の修正は0c16bcbf0e25ce8212ca42282a47e178aa976c62を渡してある。新規ホストは不要。
2. 本候補をその最新mainへ追従させる。配布helper/runtime入力の変更に必要なCIを別候補で固定し、未知分類だから全Widget/UIを走らせる方法は採らない。native成功の入力不変を証明できない場合は未確認として必要な経路を選ぶ。既存成功を無条件に流用しない。
3. サーバーreadinessとApple有料契約が揃った後、protected設定と固定SHA/未使用build/必要CIを照合し、CLIの`--preservation-pilot --billing-sandbox`でdry-run→内部版1回の配布。
4. 実機のApple Sandboxで、980円/初回対象者7日が実商品の条件と一致すること、購入シート取消で権利が増えないこと、購入/無料体験で会員操作が開くこと、復元、更新停止後の期限切れ、通信失敗時の確認不能と保存済み記録の保護を確認する。購入・返金/取消・終了の意味を区別し、合成JWSや手作りDB権利を実購入の証拠にしない。

18:20:35 JSTからの調査と18:30:22 JSTの最初のcaller候補を含め、このターンの経過を後続成功runだけでリセットしない。新しいiOS CI/配布の時間はまだ未計測。契約待ちの完了時刻は予測しない。
