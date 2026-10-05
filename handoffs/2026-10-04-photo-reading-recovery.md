# 写真・メモの読込失敗復帰：次の候補

Branch `codex/photo-reading-recovery-20261004`、base main
`79f78bbbbb2c38a8556b16cf7ffec4ba2cee4472`。
Worktree は許可済み `<task-2>/neko-reading-recovery`。
PR #165 の通常 Codex 作業と追加候補 `3d0adf1` は編集しない。
このまとまりは次の改善候補であり、今の配布候補には追加していない。

## 受入条件と変更

- P1 メモ：写真ブラウザで読込中・読込成功/未作成・失敗を区別する。
  失敗を「メモを書く」と表示せず、保存内容を変更しない説明と読込だけの
  再試行を用意する。写真切替後に古い要求の結果/失敗を表示しない。
  エディタの既存上書き防止・競合・保存処理は維持する。
- P1 初回スキャン：途中写真・プレビュー・進む操作を保持しながら失敗理由と
  既存の再スキャン操作を表示する。失敗中に「確認中」の進捗を出し続けない。
  写真なしの既存エラー画面、アクセス権、スキップ等の境界を維持する。
- P2 保管単件参照：`linkedRecord` / `memoRecord` が対象JPEGだけを読む。
  一覧と同じ materialize 処理を使い、payload validation、hash、破損時の
  partial 表示/本文保持、削除状態、前後のアカウント照合を維持する。
  一覧の画像遅延読込まで広げない。

独立作業は UI/state と保管サービスに分け、主担当が差分をレビューする。
レビューで途中結果の「確認中」が残る点を指摘し、失敗状態と表示の整合を
取る。これは起動ストア障害からの復帰を実装したものではない。

## 検証と計測の意味

既存 `verify-photo-memory-notes.swift`、`verify-onboarding-presentation.swift`、
`verify-personal-archive.swift` の必須経路へ状態/保存/読込の回帰を追加する。
読込失敗と成功した空メモ、古い要求、取消、途中結果+失敗、既存進行状態、
単件画像読込数、対象外の欠落/破損、対象破損時の本文/revision 保持を扱う。
Swift / Xcode は現環境にないため、これらの native verifier と iOS UI は
未実行。コンパイル/実行が通ったという証拠にはしない。

`test-family-window-widget-boundaries.py`：63件中62件成功、既存Swift依存1件
未実行。差分空白チェックも行う。変更していない成功チェックは理由なく
繰り返さない。mandatory `check-development-flow.py` の成功の代用にはしない。

性能の必要性を調べた Python 合成バイナリ I/O + SHA256 モデル：
40件×524288 bytes、全件40 reads / 20971520 bytes / 0.037593秒、
単件1 read / 524288 bytes / 0.000777秒。
外部記録：`<task-2>/archive-read-model-20261004.json`。
これは JPEG decode、Swift、iPhone の実測ではなく、アプリの改善率を示さない。
新 Swift 回帰の合成12記録での list12 / linked1 / memo1 / absent0 は期待値であり、
native 実行まで測定済み結果とは扱わない。

## P2 起動ストア読込復帰：停止中

`AppViewModel.start` は `hasStarted` を立ててから curation / snapshot /
identity を読む。失敗は authority を failed にして候補・Widget を安全に止め、
スナップショットを空データで上書きしない。一方、通常の foreground / rescan
は ready 必須で、起動読込の再試行操作はない。

安全な最小修正を決めるには、次を正規 native 環境で合成ストアに対して確認する：

1. 初期化不能と一時読込失敗、型/内容破損を区別する。初期化失敗の `let` store
   を単なる `hasStarted=false` で復旧したと扱わない。
2. 一時読込失敗→元の合成データを正常に戻す→明示再試行で3ストアすべてを再照合。
   成功前は photo routes / Widget authority を閉じ、未検証 snapshot で保存しない。
3. 再試行の連打・scene activation・scan cancellation と競合して古い結果が復活しない。
   元ファイル/本文/所属のbytesとrevisionを比較し、失敗時に変わらないことを確認。
4. 起動再試行で共有・通知・外部送信の既存同期を新たに起動しない。

現環境では Swift の故障注入/検証を実行できず、このP2は実装していない。
安全ゲートの弱化、ファイル削除、ACL変更等で再現や復旧を代用しない。
次担当は正規 native 環境の通常 Codex。追加の費用・権限・認証変更は含まない。

## 統合依存と次の担当

先行 PR #165 / Gallery の通常担当の進行を優先する。main が確定したら新しい
統合ブランチを作り、`3d0adf1` と本候補を選択して取り込む。
主な近接箇所は `LikedPhotosView.swift` のメモ操作と既存再発見メニュー、
native verifier。既存移行/VO/猫アルバムの挙動を保持する。

正規通常 Codex で mandatory local checks と配布込み preflight → 固定候補の
必須 native/service CI → main CI → 本人 TestFlight の既存順序。
成功済み証拠はSHA/tree/対象ソース・有効期限の一致を確認して再利用する。
修正ごとの重いCI、測定だけのCI、PR165への無調整pushは行わない。

状態：P1二件とP2単件読込の実装候補・主担当による独立レビュー完了／native検証待ち。P2起動復帰は停止中。
実機未確認・統合未了・配布未了のため全体完了とはしない。
