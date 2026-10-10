# 運営者の初回登録をローカルで確定する

通報確認を実運用へ接続するため、永続登録・同じ鍵の所有確認から、2つの承認署名、登録の確定、通信切断後の結果確認までをlocal専用のhandlerと画面へ接続した。アプリやproduction Workerの入口は変更していない。

## 登録の条件

- 既存のAccess署名を各API呼出しで検証し、Origin・対象operator・最新の主体alias・有効期限を確認する。GETの登録画面はデータを含まない。
- 対象のidentity、activated状態、全active roleと2つのoffline authorityは、事前の承認済み管理で用意する必要がある。handler/writerはidentity、activation、role、authorityを作成しない。
- 0033の成功したregistrationとpossessionをDBから読み、scope・2authority集合・全role集合・元counterへ束縛した申込を保存する。ブラウザから未検証の登録結果や権限を取り込まない。
- 最終試行を先に一度だけ記録し、実Ed25519の2署名を照合する。DBに確定した申込/承認時刻を読み、最終transactionで最新identity、全role、credential、authority revision、期限、他admission/sessionの不存在を再確認する。admissionとAccess sessionは原子的に作成する。
- 既存admission、未知legacy credential、有効な別申込は再開条件にしない。0033→0034に由来する未承認credentialの申込が期限切れ、または自身の試行に対する失敗終端を記録済みの場合だけ、新しいceremonyと新しいcredentialで明示再開できる。旧監査行は削除しない。失敗終端の書込まで不明なら自動再送せず、期限まで未解決として残す。

## 画面と不明な結果

登録画面は認証器の登録、同じ鍵の所有確認、承認署名の照合を分ける。秘密鍵やAccess JWTは表示・保存しない。raw JSONの重複/escaped重複フィールド、巨大body、非UTF-8、EOF前に停止したbodyを最終試行の前に拒否する。

通信切断後は同じceremony IDから読取専用で結果を確認する。申込や署名を自動で再送しない。期限後でも、既にcommitしたadmissionがあればその登録記録を返す。これは過去の確定記録であり、現在の通報閲覧権限とは異なる。通報画面へ移る際に本人認証と権限を改めて確認する。

## 検証と本線反映

実RS256 Access、ES256 registration/possession、Ed25519 2署名と合成D1を接続した検査を使用する。未知主体/role/credential/authority、期限、並行、再送、transaction rollback、応答喪失、失敗後の新ceremonyによる再開を確認する。合成ブラウザは製品HTMLの表示・操作・結果回収を確認する別の証拠であり、実認証器・実Access・実担当者の登録成功ではない。

最初のschema候補は2026-10-10 09:24:41 JST。独立レビューで、仮登録credentialによる再開停止、body timeoutがEOFへ化ける競合、期限後の登録記録回収を修正した。fixtureのstrict JWK違反と前提identity/activationを欠いた準備失敗を保持し、製品の認証条件を緩めていない。

別の制御候補で`moderation-initial-admission-v1`を先にmainへ登録する。製品10ファイルの完全before/after、依存入力と両backend workflowを固定し、同じ確定SHAのowning pushでiOS plan、Sharing4job、Preservation1jobの実成功を必要とする。新scopeは未計測の初回として扱い、旧scopeの時間やtimeoutを所要時間の保証に使わない。詳細結果、候補/PR/CI/経過時間は外部証拠 `C:/dev/neko-evidence/launch-readiness-20261010/operator-admission/` へ保存する。

## 次の接続条件

実Access・ブラウザ・本人の認証器・実offline authorityの互換性は未観測。localの運営者登録から、既存local triage/owner判断画面へ渡す実hostの起動・接続も必要である。実権限の付与、本番migration/配備、実通報写真の開示、AI送信、一般受付の開始とは区別する。

本人はTestFlight248で既存写真/メモの閲覧・書き出しを確認済み。同じ端末操作や購入操作をこのbackend候補の検査条件にせず、アプリ入力不変の成功を保持する。新しい料金、公開先、gate、期限、保管pilot、本人データは変更しない。
