# 個人 Widget 関連写真入口の限定 CI 候補

## 状態と前提

- 作業: `codex/widget-entry-ci-20260918` / `C:/dev/neko-widget-entry-ci-20260918`。
- 起点: `origin/main c8659454c7304a266cc5c3909cda88d688f819f2`。製品・workflow・実行scriptは変更していない。
- 製品依存: `7826029491e5dff3e8809f21fa3b5496deb9e2d7` の `OfficialWindowUITests/testWidgetURLPersonalPhotoOpensRelatedAlbumAndReturnsToOriginal`。起点mainには未存在だったが、製品CI `35339247924` の8 job成功後、同SHAをmainへ反映。このCI候補も同SHA上へrebase済み。製品CIのscopeは変更していない。
- 主担当の差分レビュー後、候補をローカルcommit済み。push、CI起動・監視、main操作は未実施。`reviewed-app-ui.json` は更新しておらず、この候補自身は既存の `ci-selection-v1` になる。採用・実時間短縮の確認は次の独立検証に残す。

## 許可条件

既存 `reviewed-app-ui.json` の schemaVersion 1 に、固定profile `"scope": "reviewed-widget-entry-ui-v1"` を追加する。scope省略時の既存 `reviewed-app-ui-v1` は維持。任意path・任意test・任意laneを指定する仕組みは追加しない。

レビュー対象の許可集合は次の4ファイルだけ。**全4ファイルを変更する必要はない**。実際に変更した全ファイルのbefore/after hashとmanifestのfiles集合が完全一致する必要がある。

- `NekoWidget/NekoWidget/Views/MainTabView.swift`
- `NekoWidget/NekoWidget/App/AppStoreScreenshotFixture.swift`
- `NekoWidget/NekoWidget/Views/WidgetPhotoOpeningFixture.swift`
- `NekoWidget/NekoWidgetUITests/PhotoPermissionUITests.swift`

ハッシュは既存 `source_digest` と同じLF・末尾改行正規化。manifest自体も差分に必要。新profileでは未知field、重複JSON key、未知schema、空purpose、不正なvisualReview、余分・不足・古いhashを拒否する。AppRoot、Store、Widget extension/render/cache、project、CI等との混在はfull。通常のhandoff文書だけは従来どおり併記可能。

plannerの既存raw Git検査は維持し、実ファイルの新規・削除・rename・copy・非regular・mode変更、manual dispatch、比較base/HEAD不整合はfullへ戻す。4ファイルを一般的な軽量UI許可リストへは追加しない。

固定6件のテストがhead側の正しいXCTestCase内にそれぞれ1件存在することも必要。テストファイルが未変更なら、plannerは同じhead SHAの固定パスを読み込む。欠落、重複、読込失敗ではfull。古いcheckoutで新test selectorだけが走ったことにする事態を防ぐ。

宣言の計数前に行コメント・ネストしたブロックコメント・通常文字列（補間内の文字列も含む）を字句的に除外する。複数行/拡張literal、条件付き宣言、閉じていないコメント/文字列は判定不能としてfull。コメントや文字列にだけ残るtest/class名を実在と扱わない。

## 実行する操作・保持する検証

app-uiは次の6件。

1. `OfficialWindowUITests/testWidgetURLPersonalPhotoOpensRelatedAlbumAndReturnsToOriginal`
2. `OfficialWindowUITests/testWidgetURLsColdOpenPhotoBeforeSourceResolvesAndCloseOnce`
3. `OfficialWindowUITests/testWidgetURLsActiveAppReplacesPhotosAndRestoresPresentations`
4. `OfficialWindowUITests/testWidgetURLsMissingPhotoNeverSubstituteAvailableFixturePhoto`
5. `SoloMemoriesUITests/testWidgetPhotoOutsideCurrentScopeOffersAPathBack`
6. `SoloMemoriesUITests/testAlbumRelatedPhotoRoutesPreserveScopeAndReturnToOrigin`

必須jobはBuild、photo-bootstrap smoke、shared runtime、app-ui。Photosの実権限操作・後段実スキャン、privacy・署名・migrationの既存Build検査、iOS 18.5/26.2 shared runtimeの実行コードは不変。Widgetの描画・cacheを変えないレビュー済み入口UIに限定するため、gallery 3 lanesは選択しない。scope外の変更は従来のfullへ戻す。

証拠のscope名は分離する。fullの同等実行は限定scopeを満たせるが、限定scopeはfullや別限定scopeを満たせない。欠落・失敗・skip・重複・SHA不一致の拒否と既存freshness/reuse規則は変更しない（既存の独立研究のみ同一input例外も拡張していない）。

## ローカル確認と導入順

- `test-plan-ios-ci.py`: 29件成功。hash/集合/schema/unsafe path、必要test欠落・重複、単独ファイル変更でのhead側test読込、raw mode/status、manual dispatch、必須jobと証拠の非互換を含む。
- `test-widget-ci-scope.py`: 11件成功。
- `test-ci-lanes.py`: 8件成功。
- `test-ci-smoke-scope.py`: 4件成功。計52件。iOS実行時間短縮は未計測。
- 独立レビュー追補後、コメント/文字列だけに残った宣言・補間・不明構文の拒否を追加し、`test-plan-ios-ci.py -k widget_entry` の直接関連7件成功。製品 `7826029` の実テスト本文は字句除外後も固定6件が認識されることを確認。無関係な一式は再実行していない。
- `c865945 → 7826029` の実4ファイル内容からmanifestをメモリ内生成して再生し、新scopeと上記4必須jobが得られることを確認。起点mainでは依存testが未存在であることも確認した。製品diffや有効manifestをこの候補へ取り込んではいない。

次はCI基盤だけの別候補で既存 `ci-selection-v1` を検証する。その後の入口UIバッチでは、レビュー済みの実変更に対しmanifestを更新する。過去のbefore/afterを後日の修正へ流用しない。scope縮小を今回の製品CIへ後付けしたり、限定証拠をfull証拠として記録しない。
