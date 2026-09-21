# 個人保管：実本人確認と鍵管理への接続判断

2026-09-22。独立実験ブランチ `codex/preservation-design-20260922`。
アプリ側の最新参照は `origin/main=b6c1a9c`（08:27 JST確認）、実験の既存土台は `46bb4cd`。本線へのrebase/mergeや並行worktreeの編集は行っていない。

**状態：Apple本人確認＋サービス管理鍵の方針は利用者承認済み。Apple接続adapterを既定OFFで準備。実Apple認証・KMS・実機2台の接続は未実施。**

追記：[並行中の持ち出し機能との整合](2026-09-22-preservation-portability-integration.md)。保存試作の複数猫名・日付・写真なしの記録・単件JSONを本線の形式へ合わせた。既存保管記録への追記は現在のnative同様、契約終了後も可能。実保存先の変更や本線合流はまだ行っていない。

## 1. 利用者にとっての完成形

保管を始めるときだけ「Appleで続ける」から本人確認する。新しいiPhoneでも同じApple Accountで本人確認できれば、自分が保管した写真とメモを取り戻せる。受信や端末内アルバムを使う全員へ新ログインを強制する案ではない。

保管自体はねこのまどのサービス側で行い、本人のiCloud容量購入を必須にしない。ただし、保管前の原本をiCloud写真から取得する通信や、既存のiCloudコピーの容量まで不要になるという意味ではない。Apple Account自体を使えない場合の救済も別途必要で、「何が起きても復元できる」とは案内しない。

## 2. 方式の決定

| 方式 | 普段の使いやすさ | 必ず説明すること |
|---|---|---|
| **採用方針：Apple本人確認＋サービス管理鍵** | 同じ本人としてログインできれば、専用の復旧コードを探さず保管記録へ戻れる設計にしやすい | 運営の権限を持つ処理が復号できる。アクセス権・監査・委託先・利用目的の限定が必要。E2EEではない |
| 復旧可能なE2EE | 運営が読めないことを優先できる | Appleログインだけでは写真の鍵は復元しない。復旧コード、端末間移管、信頼できる同期/復旧経路等が別に必要。その経路も失った場合のデータ喪失を説明する |

推奨理由は「日々の猫写真を残す一般利用者に、独自の鍵管理を要求しない」ため。安全性が無条件に上であるという意味ではない。E2EEを選ぶ場合も既存の共有鍵やThisDeviceOnly鍵をそのまま個人保管へ転用しない。

「Appleで本人確認＋ねこのまど側で暗号化保管」「運営側が技術的には復号できる方式」を明示して確認し、利用者は2026-09-22に「はい」と承認した。方式の再質問は不要。ただしこの開発方針の承認を、既存利用者の移行同意、課金業者の新契約、公開済みプライバシー説明の変更、一般公開への許可に拡張しない。実機試験にはApple側設定・専用環境の権限・使う本人/端末を確定する必要がある。

## 3. 現行との違いを隠さない

最新mainの `PersonalArchiveView.swift` は「自分のiCloudに保管」と表示する。共有ポリシー `docs/privacy/index.html` は通常の共有写真について、運営とCloudflareは復号鍵を持たないと説明している。

- 共有写真のE2EEは変更しない。個人保管を別節・別保存領域・別鍵・別権限で説明する。
- 現行iCloudへの保管同意を、新保存先や運営の復号可能性への同意として再利用しない。
- Appleログイン成功も、写真の一括アップロード・旧データ移行への同意にはしない。
- 対象は本人が選んだ閲覧用写真コピーとメモ等。原本、動画、位置情報、受信した相手の写真を自動で移さない。
- 過去分は移す対象/件数を確認し、コピー取得→新保存先での照合/再読込まで完了しても、旧コピーを自動削除しない。
- プライバシーポリシー、App Storeの申告、アプリ内案内を実際のデータ/委託先と照合する。現行privacy manifestだけで新方式の説明が済んだとは扱わない。

## 4. Apple本人確認の実装契約（まだ接続しない）

Appleの[公式フロー](https://developer.apple.com/documentation/signinwithapple/authenticating-users-with-sign-in-with-apple)は、サーバー側の認証セッションとnonceによる関連付け、認可コードの確認とトークン取得を説明している。今の合成トークン検証だけではこのフローを実装したことにならない。

1. 本線のアプリIDにSign in with Apple Capabilityを設定し、署名profile/entitlementsを一致させる。現在のmainには `com.apple.developer.applesignin` とAppleログイン実装がない。管理画面側の設定状態は未確認。
2. 保管用のサーバー認証セッションで期限付き・一回限りのchallengeを発行。nativeリクエストのnonceとサーバー照合を同じ契約にする。実端末で確認するまではnonceのハッシュ有無を憶測で接続しない。
3. Appleの公開鍵、issuer、アプリのaudience、nonce、期限、subjectを検証。認可コードをAppleへ交換し、交換結果も同じ本人と認証セッションに結び付ける。client secretは署名用の秘密情報で、アプリやリポジトリへ配布しない。
4. 所有者の本人照合は検証済みissuer/subjectを基点とする。メール、氏名、課金ID、まどの支援者、端末IDを所有者の代わりにしない。内部保管IDは不透明なIDへ対応付ける。本番のログ/KMS contextにApple subjectを直接出さない。
5. 認可取消・アカウント削除・トークン失効を処理し、短期セッションと再認証を管理。アプリ移管に伴うsubjectの引継ぎ、Apple Accountを失った場合、終了時のWeb搬出も要件に含める。
6. 解約は本人認証失効や記録削除と別。本人確認済みなら既存記録の閲覧・編集・搬出を購入復元で塞がない。新規保存権は、最新本線の課金側を別途参照する。

公開鍵更新/通信失敗/取消通知/コード再送を含むサーバーテスト後、実2台の同一本人・異なる本人で確認する。実IDトークン・refresh token・コード・鍵はログへ出さない。

## 5. 鍵の運用契約（KMS業者・実設定は未決定）

推奨候補は、写真暗号化用の鍵を専用の鍵管理サービスで保護する方式。鍵をアプリに埋め込んだり、リポジトリ内に保存したりしない。実験の全体Mapをそのまま本番の鍵台帳にしない。

- 本番では利用者または保管領域単位のデータ鍵を設計し、所有者・環境・用途を検証したうえで復号する。大量処理を一つの無制限な復号権へまとめない。
- データ鍵は上位の鍵で保護して台帳に保存する。AWS KMSの[envelope encryptionの説明](https://docs.aws.amazon.com/kms/latest/developerguide/kms-cryptography.html)を比較根拠にするが、AWS契約・リソース作成はしていない。
- 復号APIの権限と鍵削除・権限変更の管理権限を分離する。参照できる鍵IDを制限し、用途・環境を暗号化contextへ結び付ける。contextは秘密ではなく監査ログにも載り得るため、氏名/メール/Apple subject/メモを入れない。[AWS公式context仕様](https://docs.aws.amazon.com/kms/latest/developerguide/encrypt_context.html)
- 日常処理と緊急復旧の権限を分け、利用記録と異常な復号要求を監視する。問い合わせ担当へ通常の写真閲覧権を付けない。ただしこの運用制限を「運営は技術的に読めない」と表現しない。
- 鍵のローテーション後も旧記録を復号できるよう旧鍵との対応を保持する。利用者の解約で鍵を無効化・削除しない。
- 写真/メモの副コピー、台帳/削除履歴の復旧、上位鍵の可用性を別々に確認する。KMS鍵を削除すると読めなくなるため、キー削除権と運営アカウント終了にも備える。[AWS公式の削除リスク](https://docs.aws.amazon.com/kms/latest/developerguide/deleting-keys.html)
- 同じアカウント内の複製だけで、アカウント停止・管理者誤削除への救済まで成立したとは扱わない。別権限/別環境の復旧、保管期間、削除要求の最終消去を設計してから販売する。

R2には自動の保存時暗号化があるが、それだけで本人照合、誤削除からの復旧、独自のアクセス制御が完成するわけではない。[Cloudflare公式](https://developers.cloudflare.com/r2/reference/data-security/)。KMSを追加する場合の接続方式・権限・運用費は別見積もり。Cloudflare Secrets Storeも秘密情報の保管先候補だが、置くだけで鍵backup/緊急復旧が完成するとは扱わない。

## 6. 今回増えた実行証拠

`experiments/ManagedPreservation/prototype/` に追加した4ファイルだけで確認する。従来のアーカイブ・本人確認コードや既存37テストは変更しない。

1. seed用のOSプロセス内で合成データ鍵を生成。合成写真・メモを保存し、鍵束を標準JWEで暗号化して終了。親プロセスは平文データ鍵を受け取らない。
2. 閉じたSQLiteと暗号化鍵束のファイルを、別のテスト用ディレクトリへコピー。元の**合成ファイルのみ**除去する。
3. 別のOSプロセスを起動し、新しい合成本人確認セッション・期限切れ権利からコピーを読み出す。写真/メモのhash、日付等を照合する。
4. 上位鍵なし/違う上位鍵/違う本人は失敗する。鍵束の破損・環境取り違えも拒否する。

新規7テストが初回成功、runner約8.59秒（うち別プロセス試験約6.64秒）。実行はこの7件だけ。既存の成功済み37件と原価計算を再実行していない。独立レビューは今回の4ファイルを読み取り確認し、重大な問題なし。レビュー側のテスト重複実行もない。

**証拠の限界**：上位の鍵は親テストハーネスが持つ合成鍵をstdinで注入している。KMSやHSMの復旧ではない。ファイルコピーは同じPC内で、実クラウドの冗長性/災害復旧の証拠ではない。正常終了後のコピーでありクラッシュ整合性は未検証。画像は合成バイト列で画質未検証。認証も各子プロセスで作り直す合成issuer/署名者であり、実Appleログインや継続したプロバイダーの鍵更新の証拠ではない。元データをユーザーの写真で消す操作は一切していない。

## 7. 本線に接続する前に必要なもの

- 保管のプライバシー方式は承認済み。実際の保存先・委託先・保持条件に合った利用者向け同意と説明を整える。
- Apple側Capability/署名と実認証用設定、専用検証環境の用意。
- KMS/鍵管理の業者・権限・障害/終了時救済・費用の確定。
- 最新mainと並行作業の差分を照合し、保管部分の担当範囲を独立させる。
- 検証対象の本人、2台のiPhone、使用許可のある写真と確認シナリオを決める。

最新mainではCの受付境界と支援再開/交代の通常導線、Build 201 uploadまで進んでいるが、実サーバー配備/有料状態の実2台は残る。今回その作業や実サーバーを変更・起動しない。実2台へ行けない間に同じ合成試験を反復して、Dが完成したことにしない。

## 8. Apple接続adapterの準備（承認後バッチ）

追加：`experiments/ManagedPreservation/prototype/apple-signin-adapter.mjs` と専用テスト。既定は `enabled=false`。本線からimportせず、環境変数からの暗黙有効化もしない。実秘密鍵や実Appleアカウントは使用していない。

- nativeのID tokenを署名/issuer/audience/期限/nonceで検証した後、認可codeを固定のApple token endpointへform-urlencodedで交換する。HTTP redirectを拒否し、codeやclient secretを別hostへ転送しない。
- 交換後のID tokenも検証し、同じsubject/nonce/client IDであることを確認。`c_hash`があれば[OIDCのcode照合規則](https://openid.net/specs/openid-connect-core-1_0.html#CodeValidation)で照合する。Apple資料はc_hashをnative/交換後の両方で必須とは明記していないため、欠落だけでは失敗させない。
- challengeはサーバー側の `takeChallenge` でproof照合と一回限りの消費を原子的に行う契約。テストではMapで模擬。**この永続store・セッション発行・失効処理は未実装**なので、adapterだけを直接公開endpointにしない。
- Appleの公開鍵は固定originから取得し、joseの署名検証/キャッシュを使用。token内の任意jku/x5uを追跡しない。秘密や生のAppleエラーをログ/例外messageへ含めない。
- サーバー用client secretはES256、Team ID/Key ID/client IDを使う短命JWT。テストは合成のEC鍵だけ。共有の鍵やAppleへのアップロード鍵とは別管理。
- 成功結果のrefresh tokenは**サーバー内部の資格情報**。クライアントへ返すJSONではない。安全に永続化し、本人IDと対応付ける処理ができるまで利用者セッションを発行しない。
- `invalid_grant`、誤ったnonce/subject、失敗・期限切れ・再使用challengeは拒否。通信/Apple側障害と設定エラーを区別する。契約有無をここでは判定しない。

**実機で確かめる互換性**：nonceをAppleが自動hash化する／SHA-256が必須という公式要件は確認できなかった。nativeが実際に送る値をサーバーの期待値にする。交換後tokenにも同じnonceを要求するのはこのadapterの安全側の条件で、Appleが全経路で必ず返すことを実証したわけではない。欠落時に検証を省略して通すfallbackは設けない。対象OS/実フローで確認してから接続する。

公式の[Token validation](https://developer.apple.com/documentation/signinwithapplerestapi/generate-and-validate-tokens)では、native code交換に `client_id/client_secret/code/grant_type` を使い、初回に指定した場合だけ `redirect_uri` を添える。概要記事のnonce送信という表現より具体API項目を優先し、token POSTへnonceを独自追加しない。[native nonce](https://developer.apple.com/documentation/authenticationservices/asauthorizationopenidrequest/nonce)も参照した。

### 次の接続先と未完了条件

実client IDの候補は最新mainの `NekoWidget/Config.xcconfig` にある **`jp.nekowidget.app`**。APIへ渡すclient IDへTeam IDを連結しない。Apple管理画面のCapabilityとSign in with Apple用Key ID、署名profileの有無は未確認。秘密鍵をチャットへ貼らせず、サーバー側の秘密管理へ設定する。

まだ不足するのは、永続challenge/セッション、暗号化したrefresh資格情報の保存、[署名付き取消通知](https://developer.apple.com/documentation/signinwithapple/processing-changes-for-sign-in-with-apple-accounts)、適切な頻度のrefresh確認、[トークン取り消し](https://developer.apple.com/documentation/signinwithapplerestapi/revoke-tokens)、実native画面/Capability、専用環境、KMSの方式/権限、実2台の認証と保存往復。未実装事項を今回の22件のテストで確認済みとしない。

### 検証と今回の範囲

AppleのHTTP通信を注入mockへ差し替え、合成署名だけで22項目が初回成功（runner 1.946秒）。ES256 client secretの検証、既定OFF、native/交換後の本人一致、nonce/issuer/audience/期限/c_hash不正、未知鍵、challenge競合/再使用/失効、invalid_grant、設定エラー、rate limit、通信/公開鍵障害、不完全/過大responseを確認した。独立レビューで重大な修正必須事項なし。既存44テストと原価計算は不変なので重複実行しない。旧37件＋追加7件＋今回22件の総数を、同時に実行した一つの実機検証として表現しない。

作業開始08:27 JST。実Apple認証、App ID/Capability設定変更、鍵発行、サーバー資源作成、課金契約、既存iCloud操作、native build、CI、push、main/LP変更、TestFlight配布は行っていない。
