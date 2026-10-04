# P2 起動ストア障害：テスト準備のみ

Branch `codex/startup-storage-fault-tests-20261004`、base `2e2ca9e`。
先行PR165、既存main、配布候補を変更しない。起動フラグ解除や
AppViewModel / store / Widget 本体の変更はない。

## 用意できた再現候補

既存 `CatHouseholdIdentityStore(stateURL:)` に毎回生成する temporary fixture
URL を渡す。実App Group、実写真、実メモ、実プロフィールを使わない。
既存 `ci/verify-cat-household-identity.swift` に追加し、既存native verifierの
コンパイル/実行経路を使うため新CIや配線変更は行わない。

1. 合成除外・日付を含む正常ledgerを既存storeで作り、state/bytesを保存。
2. 生成したJSONの前半だけをfixtureへ書く。loadの拒否とbytes維持を確認。
3. 同じ破損fixtureで `loadOrMigrate` を2回試す。emptyへの置換/上書きを拒否し、
   各回で同じbytesが残ることを確認。
4. テスト自身が元の合成bytesを戻し、同じactorの明示loadが元state/revisionを
   読めること、正常bytesを変更しないことを確認。自動修復の実装ではない。
5. future schemaを持つ合成JSONのmigrationを拒否し、bytesを維持する。

「途中読取」は切れたJSONを読ませるpayload再現であり、OSのread中断、
EACCES、Data Protectionや並行writeの瞬間を注入した実測ではない。
ACL/権限を変更して障害を作らない。ファイル生成/書換/cleanupは生成fixtureのみ。
load自身の既存file protectionの扱いは変更せず、テスト専用の保護緩和もない。

## コードレビューで確認した境界

- `CatHouseholdIdentityStore.loadOrMigrate` は `loadUnlocked` が失敗すると
  nil/emptyとしてmigrationへ進まない。future schemaの拒否も書込前。
- `AppViewModel.start` のcuration/snapshot/identity失敗はauthorityをfailedにし、
  候補表示・deep link・Widget出力を停止する。snapshot読み込み失敗を空成功にしない。
- `saveSnapshot` とscan/foreground処理はreadyを要求する。本体の再試行を導入する
  前に、未検証3ストアの状態を保存・公開しないことをruntimeで確認する必要がある。
- `LibraryStore(snapshotURL:)` / `CatCandidateCurationStore(stateURL:)` にも
  fixture URL注入はあるが、AppViewModelのproduction `init()` は3ストアを直接生成し、
  read closure/protocolやstore URLを外から渡せない。
- DEBUG UI fixture initializerは通常 `self.init()` を呼び、started/readyとして
  fixture stateへ置換する。実起動の失敗経路を検証する代用には使わない。

今回の追加テストは **個体所属ストア層** のread拒否/bytes保全/rereadの候補。
curation→snapshot→identityの途中成功、AppViewModelの再起動/再試行、Widget権威、
同時scan/scene変化、未検証snapshotの保存禁止を実行して証明したものではない。

## 本体復帰を進める前の受入条件

正規native環境の合成3ストアで、最小限のDI導入を別候補としてレビューし、次を確認：

- 初期化不能、一時read失敗、永続破損、future schemaを区別する。起動フラグだけを
  解除せず、初期化できなかったimmutable storeを成功扱いにしない。
- 1番目/2番目/3番目のloadをそれぞれ失敗させ、途中まで読めたstateを保存・公開しない。
  元の各データbytesとmutationRevision、除外・所属・本文を比較する。
- 明示再試行で3ストアすべての照合完了前は候補/deep link/Widgetを閉じる。
  再試行失敗は引き続き上書き禁止。成功時だけreadyへ遷移する。
- retry連打、foreground、scan中止、遅い古いloadの完了でstateを巻き戻さない。
- 読込失敗の再試行で共有/通知/外部送信を新たに起動しない。
- 外部権限/認証を増やさず、実データを削除せず、既存migration/保護を保持する。

## 検証状況・次担当

Swift / Xcode がないため追加testのコンパイル・実行は **未実行**。
Windows上で差分・本体非変更・既存配線を静的確認する。
独立コードレビューで要修正事項なし。読込拒否のcatchをDecodingErrorに絞り、
意図しない環境障害を「狙った破損の拒否」と数えないようにした。
`git diff --check` 成功。
成功したテスト結果、アプリ起動復帰、配布可能という証拠にはしない。
新CI/push/PR更新/配布なし。

次担当は正規native環境の通常Codex。先行PR165の実行中CIを優先し、
新たに重複CIを起動せず、既存verifierを次のまとまった候補で検証する。
本体の安全な再試行はその証拠と3ストアDI設計の後に判断する。
