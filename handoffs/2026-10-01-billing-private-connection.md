# 購入確認の非公開接続（2026-10-01）

## 誤解の訂正と完了条件

購入確認サーバーの接続と、実商品の購入・無料体験・取消・復元・失効・通信失敗の通し確認は未完了。日常ツールの会員境界を実装し内部235をアップロードした結果とは別である。

2026-09-30の配備記録と2026-10-01のWrangler読取で、既存Cloudflareアカウントの非公開Verifier Worker/Container、IAP専用キーsecret、呼出側service bindingを確認した。Verifier version `607f1990-2cc6-4b3f-961f-0552556f7184` は購入runtime全部NO。`apple-server-api-auth-check.json` は認証付きApple APIから404/4040010を得た記録で、`purchaseVerified:false`。存在しない取引への応答を購入成功へ読み替えない。

旧Lightsail/Tunnel/Redis計画だけを見て新規ホスト必須と説明しない。Container側の回収・Node設定・実接続は本線チャット、caller側はこの候補が担当する。原典Container commit `f714d9c` は現在のmainから欠落していたため、既存配備imageとの照合が必要。相互に同じWorkerを上書きしない。

## この候補の変更

- SharingServiceの明示したprivate-bindingをlocal/stagingかつSandboxだけに接続。sentinel origin固定、binding欠落・Access混在・Production・未知値を送信前に拒否。公開fetchへのfallbackなし。
- 月額必須、年額は未設定なら許可しない。未登録の年額IDを推測しない。空・不正・月額と同じIDは拒否。
- 実workerdのRequest constructorが`redirect:error`を未実装として拒否することを直接確認。`manual`＋3xx拒否へ修正し、HMAC/Accessが転送先へ送られない境界を維持。
- 既存HMAC往復、nonce、応答サイズ上限、商品/bundle/環境の再照合、HTTPS+Access既定を維持。runtime gate、署名プロトコル、DB、iOS/Widget、価格は変更しない。

## 現在の証拠と残る不確実性

- 最初の製品候補は2026-10-01 18:30:22 JST（env.tsの記録）。調査開始18:20:35 JSTからの時間も総時間へ含める。
- typecheck成功。関連4ファイル・32 tests成功、11.51秒（購入client、Apple client、authority、account recovery）。最初の実runtime確認で追加3 testsが失敗し、単独constructor確認で原因を確定して修正した。旧失敗やskipを成功としない。
- 独立した別担当の4ファイル安全レビューはP1/P2なし。受け側のmonthly-only設定、private entrypoint、公開入口OFF、永続nonce、費用枠は別途の接続条件。
- 成功は実workerd内の合成入力と署名であり、実Apple購入、遠隔Container起動、価格表示、初回体験の成功ではない。
- CI前にアプリの入力不変を照合し、Container回収側とbackendのNode候補へまとめる。既存iOS selectorの未知path判定だけで無関係のWidget/native一式を起動しない。別候補の成功をこのSHAの検証へ流用しない。

## Apple待ちとその後

税務住所訂正は利用者がAppleへ依頼済みで、再提出しない。実商品のSandbox利用には有効なPaid Apps Agreementが必要（Apple公式TN3186）。契約が有効になった後、専用内部候補の実商品取得から購入→サーバー権威→会員状態を確認する。初回体験、購入画面での取消、復元、更新停止後の期限切れ、通信失敗を区別して記録する。画面fixture/未登録商品/合成JWSで代用しない。一般公開・実課金・追加固定費は開始しない。

秘密鍵・JWT・Apple JWSは資料やGitへ入れない。ローカル証拠は `C:/dev/neko-evidence/preservation-sandbox-20260930/`、今回の調査先は `C:/dev/neko-evidence/billing-private-connection-20261001/`。秘密情報を含む原資料をそのまま転記しない。
