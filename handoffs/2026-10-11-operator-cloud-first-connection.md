# 内部通報の初回クラウド接続

本人の指示に基づき、既存運営者の認証・権限を保ち、対象を既存staging D1と通報専用private R2へ接続する。別の鍵を返していた初回登録を反復しない。

## 確認した動作

- 元の登録署名・provenance・current ownerを検証し、別target scopeを2つのoffline authorityで新規署名する。元の登録記録やcounterを改変・偽装しない。
- 運営用Nodeは通常権限で起動する。Windowsの固定pipe brokerは暗号化volume・ACL・native file identityを読み取り検証するだけであり、秘密鍵をIPCで返さない。写真ごとに前後2回のfresh proofを取得する。
- クラウドD1/R2にある無害な1px合成通報を既存本人認証で開き、実画面のJPEG decode/visibleを確認した。`no_action`の判断とアプリ用返答をD1へ保存し、read receipt/source hash/read phasesも照合した。実利用者の写真、返答の閲覧済みは未検証。
- migration0035のnew scope admissionと0036のatomic report-key boundaryを対象D1へ適用・readbackした。intakeはOFFのまま。旧keyでの新規INSERT、upload/commit、失効後のv2を拒否し、cleanupと未導入installationの旧挙動は保持する。
- v2 releaseの従来のhard blockは、有限な2署名のreadinessが成立する場合だけ通過する。正確な対象・owner adoption・public key・候補code・観測証拠のhashを照合する。期限、改変、別target、異なるkey、片方の署名、不正authorityを拒否する。アーカイブ内public keyの検証は維持する。

## 適用範囲と残件

これは内部TestFlight向けの初回接続であり、production readinessやv1 rotation/retirementの完了ではない。署名前に全v1 report/tombstoneが0、未知/孤立したreport R2 objectが0であることを確認する。現在0件から過去のintake状態を推定しない。v1 toolは保持する。鍵backup/restoreは未検証。readinessは2026-10-12 14:05:42 JSTまでで、brokerの期限を越えない。

公開鍵のみを既存TestFlight保護環境へ設定する。既存billing Sandbox/保管pilot/内部配布先は維持する。新buildの署名済みarchive/IPA・upload確認後に、既存media/APNsを変えず通報受付だけを接続する。iPhoneから実際の通報1件と運営画面の写真を照合するまで、実写真経路を確認済みと扱わない。

## 証拠・時間・失敗

外部証拠は`C:/dev/neko-operator-local/key-recovery-20261011/live-connection`に保存。`cloud-verification-observation.json`と2枚の画面、`report-key-apply-*.json`、署名proposal/review、`app-key-result.json`を参照する。秘密鍵はrepository/CI/cloudへ送らない。

初回candidateは2026-10-11 04:21:42.377 UTC。初回brokerのPS5 parser失敗、unsigned proposalのexpiry不備、review P2修正、直接D1 CLIの7403を保持する。D1 schema変更は既存許可済みremote binding経路で適用しreadbackした。失敗を成功へ読み替えない。関連D1/暗号/権限/stream cancellation/型/migration inventory/署名改変/発売設定のlocal検証を行い、必要CIとarchive validationを残す。native CI・uploadの時間はpreflightの実測値で計画し、30分の完了約束をしない。
