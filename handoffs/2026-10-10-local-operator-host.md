# ローカル運営入口の接続

`SharingService/src/moderation-operator-host-local.ts` の `createLocalModerationOperatorHost` に、信頼済みのローカル設定を起動時に一度渡す。返る Request handler が既存の登録ページ、通報console、本人閲覧、判断ルートを同じDB・Access・origin・RP設定へ接続する。登録画面の「通報の確認へ」は `/operator/console` に進める。

RPはHTTPS originのhostnameと完全一致させる。登録だけは親ドメインのRPでも成功するが、既存の通報・本人閲覧側は完全一致を要求する。共通入口はこの食い違い、登録scopeのorigin/RP/Access issuer・audience不一致を起動時に拒否する。呼出側が起動後に設定やHMAC鍵配列を変更しても別設定へ切り替わらない。

DB、対象identity・state・role、二つのoffline authority公開鍵、Access設定と隔離した `reviewEvidence` adapterは信頼済みの運営側入力である。HTTP本文から選択・新設しない。登録成功の控えは過去の登録結果であり、現在のAccess認証やroleの代わりにはしない。各通報操作は既存handlerで再認証・現在のrole/credentialを照合し、署名付き操作と監査を維持する。本人閲覧のadapterやowner policyがなければ閲覧を開放しない。

直接検証では、実RS256 Access、ES256登録・所持確認、二つのEd25519承認で登録を成立させ、同じDB上の通報一覧、登録した鍵によるreview-start署名、監査・証拠finalizationまで進めた。fixtureの親RP既定値は変更せず、不一致を拒否する検証も保持する。

これはローカルhandlerの統合である。公開Workerとdisabled Worker、config、migration、実role・鍵は変更しない。実Accessセッション、実認証器・offline管理者、実HTTP/TLS listenerへの接続と本人閲覧の実運営権限は未確認。本番配備・実通報者への返信送信・iOS配布の証拠にはしない。
