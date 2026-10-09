# 運営者登録の検証部品を製品へ接続

2026-10-09。通報を運営者が安全に確認・判断・返答できる状態へ進めるため、既存の操作時WebAuthn検証に加えて、新しい鍵の登録応答を検証する処理を実装した。実際の運営者登録・権限付与・通報受付の有効化はまだ行わない。

## 確認できたこと

実装前に固定済み `@simplewebauthn/server 13.3.3` を使い、Nodeで37件、現在の互換日/flagのworkerdで30件を直接確認した。署名付きの合成登録を検証し、同じ公開鍵が既存の操作時署名検証でも使えることを確かめた。workerdの互換日ではNode互換が既定で有効になっているため、この結果をNode互換なしの証拠とはしない。ネットワーク呼出しは0、実機やブラウザ操作の結果ではない。

製品の唯一のWebAuthn wrapperへtyped prepare/verifyを追加。既存assertionとprivate helperの本文、依存package/lock、設定、既存assertionテストは機械照合で不変。既存の依存境界テストは同wrapper内の `verifyRegistrationResponse` だけ新たに許し、他ファイルからの利用・options生成APIを引き続き禁止する。

- 正確なHTTPS origin/RP、32byteのserver challenge digest、UP/UV/AT、ES256/P-256、rawIdとattested IDの一致、counter、COSE key、厳格なJSON/CBORを確認する。backup/reserved/extension flag、余分・重複・末尾データ、curve外の鍵を拒否する。
- 検証前に呼出元の値をコピーし、async処理中の差替えを防ぐ。opaqueな準備済みobjectを署名検証より先に消費し、同じobjectの並行/再利用と偽造を拒否する。失敗した署名にも再利用を許さない。
- 受け入れる形式は空のnoneかpacked selfのみ。noneにはattestation署名がなく、packed selfもメーカー/機器の信頼性や実在する人を証明しない。結果の型は未承認として、admission/hardware/humanをliteral falseにし、公開鍵を含むcredentialをネストして返す。生のcredential ID、client data、attestation、秘密鍵は返さない。
- 型検査成功。新登録と既存assertionのworkerdテスト51件は19.12秒、依存境界2件は208.8msで成功。登録から実署名の操作確認、counter増加/0互換、改ざん・不正形式・一度限りの消費・入力差替えを扱う。独立した主担当レビューでP1/P2なし。

## 合格に読み替えないこと

WeakMapによる消費は同isolate内のobjectだけ。同じ応答を再prepareすることは可能であり、永続challengeの期限/再送防止、Access identity、role、登録申請、承認人数、失効を原子的に扱う処理は別途必要。単なるDB行やこのreceiptだけで本人を承認しない。

実端末の `navigator.credentials.create`、画面、実際のorigin/RP/Access、対応する機器とattestation方針は未確認。同期・backup可能なpasskeyは既存方針で拒否されるため、手元の端末だけで登録可能とはまだ約束しない。HTTP route、options生成、DB登録・migration、live gate、権限・料金・利用者は変更していない。

## CIと時間の扱い

開始10:00:31 JST、最初の候補10:03:35、ローカル完了10:08:04（7分33秒）。計画30〜50分は固定CI登録・必須ローカル検査・既存Sharing CIを含む見込みで、短縮実績ではない。

製品3ファイルM/M/Aの完全blob、100644、既存Sharing workflowを固定する専用backend scopeを別制御候補で先にmainへ登録する。候補の同一SHAに対するowning pushでplanと既存Sharingの4job成功が必要。skipやplanだけをbackend成功と扱わず、既存workflowのApple verifier/Windows policy/Worker検査も維持する。iOSアプリ・Widget・TestFlightの入力は不変のため、追加native CIや配布はしない。

主担当の証拠rootは `C:/dev/neko-evidence/launch-readiness-20261009/`。直接試験は `moderation-enrollment-{prototype,workerd}/`、実装/独立レビューは `moderation-enrollment-integration/{plan,implementation-result,root-review}.json`、CI登録は `moderation-enrollment-ci-control/`。最終CI・main・時間は同rootの `moderation-enrollment-integration/completion.json` に集約する。

次の必要な接続は、期限付きchallengeと本人に結び付く登録申請・既存の承認、通報caseに限定した内容確認、永続的な判断/返答。現在の保護を保ち、一般公開や新権限の承認は具体的な構成と実機検証手順が揃ってから扱う。
