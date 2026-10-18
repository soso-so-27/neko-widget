# 長期保存のアプリ組込み

- 依頼: 月額980円を維持し、アプリ組込み、容量制限、復元を完了する。現在の写真原本・動画の対象外方針は拡張しない。追加の有料契約・枠増額は事前説明する。
- base: `2c4843801118f7dc0b27a9be5555d952765ff2bd`。前段のowner capture修正、617件backend等の成功は当時の入力へ帰属させて保持する。
- 最初の診断候補: `0974fa4`、2026-10-18T09:18:58Z。製品変更前に実PhotoMemoryNoteStoreで36,500件の21文字/500文字をread/edit/reopenし、欠落・他記録の書換え・経過時間・peak RSSを確認する。生成した架空データだけを使用する。独立レビューを受け、fixture生成とは別のprocessで各caseを計測する。診断workflowだけで`-O`と専用flagを使い、通常verifierの既存チェックには大容量計測を追加しない。
- 判断を変える未確認事項: 全体JSONを再結合する方式が実Swiftのメモリ/編集時間に適するか。macOS結果はiPhoneの描画/メモリ上限の確認とはしない。不適なら実storeの項目単位保存へ変更する。
- 検査経路: 既存Private memo model diagnostic、macos-15、上限10分。過去の同workflowは53秒（36678269348）だが大容量部分は初測定。通常iOS全件CIは最初の仮説検証には使用しない。配布証拠にはしない。
- 独立レビューで判明: 旧262は一覧の非表示処理前に新pathを拒否する。新形式を旧版へ返す境界を必ず保護する。chunk単体をJSON modelとしてdecodeしない。移行後の実store読取・欠落時の原本保全・原子的な公開を別途確認する。
- 未完了: app/サービスの新形式、端末内migration、復元、容量設定、配布。現時点で解消済みと報告しない。

## 実装契約 v4（候補、未配備）

既存 `ToolBackupPart` の7キー、kind/index.json/256KiB上限を保持する。node payloadは128KiB以下。
nodeは `{version:4,snapshotID,createdAt,prefix,files?,children?,previousIndexID?}`。filesとchildrenは排他、空配列は禁止。
leafはfiles<=128、直接record参照<=256。fileはv3と同じpath/bytes/sha256/records/sourceSnapshotID。v4に限り既存toolディレクトリ直下のUUID.json（raw byte chunk）も許可。旧indexのpath契約は変更しない。
branchはchildren<=16。childは `{prefix,snapshotID,sha256,fileCount,toolMask,manifestMask}`。prefixは親prefix+1桁の小文字hex、重複禁止。leaf各pathのSHA256はnode prefixで始まる。prefix最大64桁、rootは空文字。各nodeのsummaryは子/実fileから算出し、親の宣言値と照合する。fileCount最大100,000。toolMask/manifestMaskのビットはtool名の辞書順（CareHandoff, CatIdentity, CatPreparedness, EvacuationPreparation, LostCatDrafts, PhotoMemoryNotes, ShowcasePhotos, VeterinaryVisits）。root公開時はtoolMask==manifestMask。
branchの参照はchild index、leafの参照はfile records。いずれもowner/immutable revision1/実hash/削除claim/最終inventory CASを照合。変更していないleafのexact file tupleはpreviousIndexIDを実認証して再利用できる。前のv3も移行元として受理する。
headのkind/idはapp-records-v1のまま。v4の場合prefix空の完全rootだけ公開する。既存headがv4を参照する場合v3への上書きは拒否する。
通常listはUUID.json fragmentを返さない。cursorは入力raw rowsの末尾IDを使い、空itemsでも前進させる。v4 indexは旧part validatorが通り、旧visiblePageは非表示にする。直接ID読取りは新clientが行う。旧v1-3/index/写真/メモの一覧は維持する。
削除はroot→branch→leaf→partsの既存参照保護を使用し、参照が残る対象を削除しない。cleanup candidateはv4nodeも扱う。新node導入をpublic、課金、無期限テスト受付の許可としない。
