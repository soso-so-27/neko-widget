# 次の担当への引き継ぎ（2026-09-22 10:42 JST）

> この引き継ぎは設計側主担当が受領して作業を継続した。以降の進行は [写真保管・まどのアルバム](2026-09-22-preservation-parallel-plan.md) を参照。下記は受領時点の履歴であり、未commit・担当分担・未レビューの記載は更新後の状態を示さない。

## 最初に読むこと

利用者から「引き継ぎお願い」。新しいCI・配布は起動していない。以下の途中差分を引き継ぐ。長い旧会話や全台帳の再読は不要。このcheckoutの `AGENTS.md` と、CI前に `handoffs/development-release-workflow.md` を読む。

- 作業場所：`C:/dev/neko-managed-preservation-app-20260922`
- branch：`codex/managed-preservation-app-20260922`
- HEAD / 開始時main：`33c54b52bcbe49f99d08606a25b9acc24364c0ac`
- **製品変更・CI変更・資料は未commit。push・本体build・今回のCI・配布も未実施。** 作業ツリーをresetしない。
- 最新の配布済み製品はBuild202、SHA `32e3f201da42e4de8646137b6b9eb91ddaa51269`。今回の個人保管接続は含まない。

## 依頼と範囲

別の設計担当から引き継いだ個人保管候補を、アプリへ**既定OFFで接続**する。設定、選択した写真からの明示的な保管入口、既存ZIP書き出しとの接続が対象。CloudKitの置き換え/自動移行、既存共有E2EE、料金やβの有効化、基盤契約、実サービス有効化、共有アルバム実装、**新しい配布**は対象外。

正本候補：`C:/dev/neko-managed-preservation-integration-20260922`、実装 `863ad16`、資料 `1f476ae`。同checkoutの `handoffs/2026-09-22-managed-preservation-goal.md` がAPI等の根拠。古いexperiments・診断workflow・branch全体を一括mergeしない。

設計側の引き継ぎ：`C:/dev/neko-window-album-design-20260922/handoffs/2026-09-22-preservation-integration-transfer.md`。担当thread `01a02d6e-dcbb-7351-ae58-721f4f972536`。受領連絡は済んでおり、繰り返さない。設計担当はアプリ/サービスを並行編集しない。

## 作った差分

1. 新規Swift4本をapp targetへ登録。`ManagedPreservationClient.swift` と `ManagedPreservationSessionStore.swift` は候補のまま。Coordinatorには共通export adapter、Viewにはhost接続と選択写真準備を追加。
2. Settings/PhotoBrowserの「…」に入口を追加。`ManagedPreservationConfiguration.current.isEnabled` がfalseなら表示しない。Info.plistに有効化キーやoriginを加えていない。
3. 写真1枚を固定してJPEGコピーとメモを準備。取得前後で写真へのアクセスとメモ一致を確認。失敗時は送信せず、写真なしへ自動変更もしない。同じ画面の再試行は同じUUID/内容。
4. `ManagedPreservationExport.prepare` → **既存** `RecordExportController.prepare(build:verify:)` → `PhotoMemoryNoteExporter.createArchive`。本人/記録の検証closureを作成前後に渡す。未知の日付はnull、元写真/メモは変更しない。
5. 準備/共有中は他の記録操作を禁止。背景移行は準備をcancel、共有先が使う完成ZIPは共有完了まで保持。本人確認解除時はinvalidate。
6. runtimeの `managed-preservation-export-boundary` を追加。実ZIP作成とcleanup、作成後の本人変更拒否、背景cancelによる未公開ZIP除去。validatorとそのテストの必須IDにも追加。
7. `SoloMemoriesUITests.testManagedPreservationDisabledHidesEntries` を追加。既存fixtureで設定/写真メニューを開き、OFF入口非表示と既存入口維持を確認・撮影。今回新しいfixture経路や全件UIテストは追加していない。

製品差分の説明：`handoffs/2026-09-22-managed-preservation-app-integration.md`。

## レビューと検証の現在地

- `git diff --check` 成功。
- `python NekoWidget/ci/test-validate-sharing-runtime-self-test.py`：6件成功。
- CI担当報告：新scope境界2件＋既存lane照合1件成功。全11群はまだ実行していない。
- 独立レビューで、Apple認証UIからinactive→activeへ戻る時の無条件startが認証結果を捨て得る点を指摘。`needsResume` を背景移行時だけ立てて再開する修正を適用済み。**この最後の修正の再レビュー/実コンパイルは未実施。** レビュー担当は他のexport操作ロック・検証closure・署名解除invalidate・固定draft・メモ前後一致を整合すると報告したが、最終レビュー完了とは扱わない。
- **本体build、追加runtime、追加UIは未実行。** Live Apple認証、実Keychain操作、サービス、別端末復元の成功証拠はない。
- 候補側のwire12/typecheck/サービス34成功は元候補の証拠。変更したView/Coordinatorや今回の統合build成功の代用にしない。

## 次に行うこと（この順）

**最新の調整依頼が優先（引き継ぎ作成直後に受信）：** 設計担当threadが別worktreeで既存FamilyRecordViewと専用UIテストを担当する。こちらは同ファイルを編集しない。差分が固まったらcommit/残点/CI計画を返し、両差分を1候補にまとめられるか調整する。**調整前に候補CI・main反映・配布を起動しない。** 下記の個人保管限定profileは単独案であり、FamilyRecord差分をそのまま許容するものではない。高価なCIを担当ごとに重複起動しない。

1. 作業ツリーの状態を確認し、最後のscenePhase修正と実コンパイル上の懸念だけ最終確認する。元候補の全サービス監査や過去ZIP監査を再開しない。
2. CI profileをfreezeする。`ios_ci_scope.py` に追加済みの `reviewed-managed-preservation-app-v1` は**まだhashが空**：`MANAGED_PRESERVATION_DIGESTS = {}` / `MANAGED_PRESERVATION_COMPANION_DIGESTS = {}`。`reviewed-app-ui.json` もまだ旧portabilityの内容。全before/afterとmanifest、companion canonical hashを今回の差分に固定する。現状のままpushするとfullへ戻る。
3. 固定対象は製品/検証11本（新Swift4＋PBX/Settings/LikedPhotos/runtime/UITest/validator/validator test）、CI companion4本＋manifest。未知差分・mode変更・Widget/config変更は従来full。docsは製品成功の代用にしない。
4. 必須はRelease本体/拡張build、Photos bootstrap、両OS runtime、OFF UI1ケースの**4ジョブ**。workflow・matrix・成功再利用判定は変更していない。候補commit後の安価なdevelopment-flowチェックとpreflightを行い、scope/費用/重複runを確認して通常CIを1回。新scopeは未計測なので必要なら正規の初回baseline計測扱い。近いprofileの実績15〜20分を今回の実測と誤記しない。今回はupload加算なし。
5. 実行するならwatcherは1本のみ。失敗は最初の具体的原因を修正。UI失敗時は手順所定の同じ失敗操作の診断を行い、通常CIを無根拠に繰り返さない。
6. 成功後だけ結果と差分を台帳へ統合し、必要なmain反映を行う。**このバッチではTestFlightを新たに配布しない。** 実装接続とlive利用開始を区別して報告する。

CI担当 `/root/preservation_contract` がselector/plan/test/manifestを担当した。最終hash固定待ちで止まっている。利用可能なら関連idle担当を再利用し、新規子担当/履歴複製を増やさない。

## 今回以外の残件

- 個人保管を実サービスとして動かす：KMS、会員本人照合、画像デコードprovider、実Apple認証/capability、容量・保持・削除・復旧運用、別端末確認。専用PreservationServiceは候補checkoutにあり、本線移植/稼働は未実施。
- 過去のiCloud保管を今後どう扱うか。自動移行は未承認/未実装。
- 有料共有の実2端末/引き継ぎ条件、共有記録の持ち出し。
- LP・購入条件・サポート/β導線を実際に提供できる条件と揃える。
- 継続利用/課金価値/原価の検証。窓ごとの共有アルバム案は未採用。公式写真補充は利用者が保留指定。

## 利用者の期待

無関係な調査・全件テスト・同じCI確認・毎回のAppleログイン・長い報告を増やさない。検証はリスクに合わせ、未知を成功としない。修正の手間を理由に良い設計を避けない。なおBuild202のZIPは利用者が「ZIPのなかにそれぞれはいってました」と確認済みで、破損問題ではなかった。JPEG画質/他端末復元まで確認済みとは言わない。
