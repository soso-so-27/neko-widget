# 個人保管接続候補の完了目標

利用者依頼：目標を設定し、そこまで継続する。2026-09-22開始。

目標は本線に接続できる**既定OFFの実装候補**。実サービスの公開・課金開始・利用者データ移行は含めない。コードの準備と実Apple/KMS/実2台の成立を区別する。

## 完了条件

1. 専用PreservationService：永続challenge/session/opaque owner、暗号化保管、版付き更新・削除・ページ読み出し、既定OFF。
2. iOS：独立した本人確認・同意・保存/一覧/詳細/書き出し接続部。CloudKitや共有の保存先を暗黙に切り替えない。
3. 契約終了でも既存記録を取り出せる、別人拒否、競合や中断で偽の成功を返さないことを関連試験と独立レビューで確認。
4. 本線の単件JSON形式との対応、並行差分、外部環境の未確認条件をこの記録に統合。

## 固定するHTTP契約 v1（専用サービス・HTTPSのみ）

全応答 `Cache-Control: no-store`。失敗は `{error:{code:string}}`、生のproviderエラー・認可code・token・鍵を返さない。`PRESERVATION_ENABLED=YES`に加えて必要依存が揃ったときだけ受付。

- `POST /v1/auth/challenges` `{}` → `{challengeId,challengeProof,nonce,expiresAt}`（日時はUTC ISO8601）
- `POST /v1/auth/sessions` `{challengeId,challengeProof,identityToken,authorizationCode}` → `{token,ownerId,expiresAt}`。Apple subjectを返さない。
- `DELETE /v1/auth/session` bearer token →204。端末セッションだけを失効。保管記録は消さない。
- `GET /v1/records?after=<recordId>&limit=20` bearer → `{items:[{recordId,revision,document}],nextCursor:null|string,generation:number}`
- `GET /v1/records/<UUID>` bearer → `{recordId,revision,document,photoBase64:null|string,photoSHA256:null|string}`
- `PUT /v1/records/<UUID>` bearer → request `{expectedRevision:null|integer,consentVersion:'managed-preservation-v1',document,photoBase64:null|string}`、response `{recordId,revision}`。新規はnull。既存更新は現在のrevision。写真の差し替えは新規扱いではなく拒否し、新しいUUIDで明示保存する。
- `DELETE /v1/records/<UUID>` bearer, `If-Match: <revision>` → `{recordId,revision}`。tombstoneで再生を防ぐ。

documentは本線単件exportと同じ`{formatVersion:1,text,capturedAt,writtenAt,updatedAt,catNames,photoFile:null|'photo.jpg'}`。3日付はUTC ISO8601またはnull。owner/課金ID/位置情報なし。1枚20MiB、本文500書記素/65,536bytes、猫名100件/各200書記素/800bytes。写真なし本文ありを許す。実画像のデコード/許容codec確認は有効化条件。

新規保管はサーバーが確認したactive/grace権利と明示同意を必要とする。既存の写真コピーは保持し、本文編集・閲覧・削除・持ち出しに課金権を要求しない。本人セッション失効/別人/削除済みは拒否。

## 接続の境界

専用D1/R2を使う構成で、共有サーバーのDB・bucket・配送期限・E2EEを流用しない。鍵保護と会員権は非公開の信頼したサービス接続先に限定し、未構成ならfail-closed。実サービスや秘密を勝手に作らない。

Swift新規ファイルは独立して作成し、並行中のSettingsView/PersonalArchiveView/Exporterを編集しない。接続位置・PBX/ビルド確認は本線の確定版を基準に主担当がまとめる。

### 並行作業との合流手順

この候補の本線基準は `b6c1a9c`。2026-09-22再fetchでも同じ。並行する `codex/record-portability-20260922` の `4d1f50d` は読み取りだけ行った。そちらのExporter/View/PBX/CIを変更・mergeしていない。単件ZIPの `PhotoMemoryNoteExporter.createArchive` はまだ現在のmainにないため、同機能の別実装を増やさない。

合流時は、まず本線のportability確定版を取り込み、次の4ファイルをapp targetへ登録する。既存 `SettingsView` のiCloud入口は残し、別の `ManagedPreservationConfiguration.current.isEnabled` 条件内だけで `ManagedPreservationView` を開く。`Info.plist` のキーを未設定のままなら非表示・通信なし。`ManagedPreservationEnabled=true` と固定 `ManagedPreservationOrigin=https://...` の両方が必要。

- `Services/ManagedPreservationClient.swift`
- `Services/ManagedPreservationSessionStore.swift`
- `Services/ManagedPreservationCoordinator.swift`
- `Views/ManagedPreservationView.swift`

選択済み写真/メモの確認画面から `ManagedPreservationDraft(recordID: stableUUID, document: ..., jpegData: selectedCopy)` を渡す。全ライブラリ走査や自動移行を追加しない。成功不明の再送では同じUUID・内容を使う。

`onExport` には、再取得・本人/版確認済みの `ManagedPreservationExportSnapshot` が渡る。既存の書き出しcontrollerの `prepare(build:validate:)` に、以下の対応で接続する。写真をPhotosへ保存し直す処理や、元メモ上書きは不要。

| 単件ZIP引数 | 接続する値 |
|---|---|
| text | snapshot.document.text |
| capturedAt / writtenAt / updatedAt | snapshot.documentの同名日時（nullを維持） |
| catNames | snapshot.document.catNames |
| jpegData | snapshot.jpegData |

ZIP生成後・共有画面を出す直前にも本人と版を再確認する。背景移行/本人変更時のcancel、共有終了時の一時ファイル清掃は既存controllerを再利用する。今回のsnapshot callbackだけを、OS共有シートまで接続済みと報告しない。

**本候補は4ファイルを本線targetへ未登録、入口・ZIP共有シートも未接続。** 並行実装を無断で置き換えないための接続境界であり、アプリ内から利用可能という意味ではない。

### 有効化の残条件（今回の完了判定とは分ける）

Apple capability/実ログイン、private KMS/会員所有者照合/実JPEGデコーダー、専用DB/R2、容量・削除期限・監視・復旧、実2台、合流後のnative操作を確認する。provider実装がない現状を単なる設定待ちと表現しない。本番の利用者データ移行、課金、一般公開は別の判断。既存CloudKitの記録はそのまま。

## 検証計画と費用

ローカルの変更範囲を先に確認する。既存成功のApple adapter・暗号形式・原価計算を無条件に再試験しない。D1/R2 local runtimeの初回所要は未計測。native確認の過去候補は15〜20分だが未計測の新機能へその時間を約束しない。CI前に既存preflightで必須範囲・実測上限を取得し、並行CIとの重複を避ける。実AppleやKMS・実2台が不足した場合は未確認のまま合格としない。

## 実装レビューと検証記録

- 永続認証12件：成功、5.75秒。鍵封印失敗/待機中の本人無効化/再生成したサービスからの本人復元を含む。
- Apple adapter 8件：成功、初回2.42秒。Buffer型修正後2.44秒。Apple本番は呼んでいない。
- D1/R2保管：初回11件成功3.95秒。独立レビュー3指摘修正後14件成功4.57秒。別人拒否・契約終了・無料の最初のメモ・失敗再送・競合・上限予約・失効中断・削除後続・認証停止中の清掃を含む。
- TypeScript型検査：成功。変更後に対象serviceのみ実行。
- 初回npm installは依存解決器エラー。原因ログを読み、`--legacy-peer-deps`で成功（90 packages、11秒）。失敗を成功時間から除外しない。
- サーバー独立レビュー：予約を件数上限に含める、削除キューをdue時刻で巡回する、Apple/課金/KMSが止まっても清掃する、の3件を反映。
- native独立レビュー：認証切れで編集中メモ消失、サーバーエラーcode不一致、旧Clientによる新セッション削除、の3件を修正対象にした。コンパイル結果と修正完了は次の証拠欄に追記する。
- 本番CI全体は過去full-v1で64.43分失敗/97.92分再試行成功。未合流の候補のため全体実行せず、別diagnostic branchで新規4SwiftのiOS typecheckと純粋wire確認を上限8分で実行する。これは必須release CIを免除するものではなく、main/配布の成功証拠には使用しない。

### 最終証拠

native診断と候補commitは確認後に追記。未実行を合格にしない。
