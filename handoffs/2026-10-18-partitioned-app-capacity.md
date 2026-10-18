# 長期保存のアプリ組込み

- 依頼: 月額980円を維持し、アプリ組込み、容量制限、復元を完了する。現在の写真原本・動画の対象外方針は拡張しない。追加の有料契約・枠増額は事前説明する。
- base: `2c4843801118f7dc0b27a9be5555d952765ff2bd`。前段のowner capture修正、617件backend等の成功は当時の入力へ帰属させて保持する。
- 最初の診断候補: `0974fa4`、2026-10-18T09:18:58Z。製品変更前に実PhotoMemoryNoteStoreで36,500件の21文字/500文字をread/edit/reopenし、欠落・他記録の書換え・経過時間・peak RSSを確認する。生成した架空データだけを使用する。独立レビューを受け、fixture生成とは別のprocessで各caseを計測する。診断workflowだけで`-O`と専用flagを使い、通常verifierの既存チェックには大容量計測を追加しない。
- 判断を変える未確認事項: 全体JSONを再結合する方式が実Swiftのメモリ/編集時間に適するか。macOS結果はiPhoneの描画/メモリ上限の確認とはしない。不適なら実storeの項目単位保存へ変更する。
- 検査経路: 既存Private memo model diagnostic、macos-15、上限10分。過去の同workflowは53秒（36678269348）だが大容量部分は初測定。通常iOS全件CIは最初の仮説検証には使用しない。配布証拠にはしない。
- 独立レビューで判明: 旧262は一覧の非表示処理前に新pathを拒否する。新形式を旧版へ返す境界を必ず保護する。chunk単体をJSON modelとしてdecodeしない。移行後の実store読取・欠落時の原本保全・原子的な公開を別途確認する。
- 未完了: 新形式の最終検査、容量設定、クラウド反映・配布・新形式の実機復元。実装済み部分と確認済み部分を分け、解消済みと報告しない。

## 実装契約 v4（候補、未配備）

既存 `ToolBackupPart` の7キー、kind/index.json/256KiB上限を保持する。node payloadは128KiB以下。
nodeは `{version:4,snapshotID,uploadSnapshotID,createdAt,prefix,files?,children?,previousIndexID?}`。filesとchildrenは排他、空配列は禁止。uploadSnapshotIDはそのnodeを初めて送信した転送rootに固定する。rootは自身のIDと一致し、再利用nodeは元のpayloadを維持する。root送信前の中断も所属を追跡し、参照中のnodeを消さず未公開の孤立nodeを整理するために使う。
leafはfiles<=128、直接record参照<=256。fileはv3と同じpath/bytes/sha256/records/sourceSnapshotID。v4に限り既存toolディレクトリ直下のUUID.json（raw byte chunk）も許可。旧indexのpath契約は変更しない。
branchはchildren<=16。childは `{prefix,snapshotID,sha256,fileCount,nodeCount,toolMask,manifestMask}`。prefixは親prefix+1桁の小文字hex、重複禁止。leaf各pathのSHA256はnode prefixで始まる。prefix最大64桁、rootは空文字。各nodeのsummaryは子/実fileから算出し、親の宣言値と照合する。fileCount最大100,000、nodeCount最大8192。toolMask/manifestMaskのビットはtool名の辞書順（CareHandoff, CatIdentity, CatPreparedness, EvacuationPreparation, LostCatDrafts, PhotoMemoryNotes, ShowcasePhotos, VeterinaryVisits）。root公開時はtoolMask==manifestMask。
branchの参照はchild index、leafの参照はfile records。いずれもowner/immutable revision1/実hash/削除claim/最終inventory CASを照合。変更していないleafのexact file tupleはpreviousIndexIDを実認証して再利用できる。前のv3も移行元として受理する。
headのkind/idはapp-records-v1のまま。v4の場合prefix空の完全rootだけ公開する。既存headがv4を参照する場合v3への上書きは拒否する。
通常listはUUID.json fragmentを返さない。cursorは入力raw rowsの末尾IDを使い、空itemsでも前進させる。v4 indexは旧part validatorが通り、旧visiblePageは非表示にする。直接ID読取りは新clientが行う。旧v1-3/index/写真/メモの一覧は維持する。
削除はroot→branch→leaf→partsの既存参照保護を使用し、参照が残る対象を削除しない。cleanup candidateはv4nodeも扱う。新node導入をpublic、課金、無期限テスト受付の許可としない。

## アプリ側の変更と直接証拠

- PhotoMemoryNotes / VeterinaryVisitsのstateを、旧raw JSONを読めるまま、8〜32KiBの内容依存chunk＋原子的なrootへ分割。論理上限128MiB、pointer8MiB、chunk最大16384。実行中の書込みを直列化し、欠落/改変chunkは空の保存先と誤認しない。新chunk確定→pointer確定→旧pointerが参照した不要chunkのみ整理。失敗した事前書込みの孤立chunk回収は未完。
- 写真メモはportable typed snapshotにし、archive bindingを送信しない。既存JPEGは認証済みindexのexact file tupleを再利用し、1メモ編集のために再圧縮/再送しない。必要なpartだけを順次読み、ACKはprefix別receiptへ書き込む。
- 復元はowner/rootに拘束したprivate stagingへ受信し、全chunk/写真/hash/manifest検査後に新datasetを有効化。未保存のメモ下書きと元データの保護を維持する。
- 100件だった診察記録の固定上限は36,500件へ、全件書き出しのtotal上限は1,000から200,000物理recordへ変更。1page50件・byte上限・lease/世代照合・ZIP64は維持。
- actual Swift modelで36,500メモの読み/1件編集/再読込と全ID/本文を確認。21文字ケース7.84MB、500文字ケース60.29MB。旧whole JSONのpeak RSSは約105/296MBだった。macOS実測でありiPhoneのメモリ/描画検証ではない。
- 新CDCは36,500メモの変更byte 8,767/172,235。別の12,000件の可変長日本語JSONは約2.39MB中9,567byte変更・150chunk中149再利用。
- 36,501fileの実treeで3840node中3836再利用、変更index12,250byte。これはuploadSnapshotID追加前の測定であり、最新wireのbyte数には流用しない。通常1件変更で大部分を再利用する構造の直接証拠として保持する。

## 失敗・修正・検査の帰属

| run / source | 結果と扱い |
| --- | --- |
| 39114937621 / 367c09f | 旧whole JSONの実store大容量probe成功。現製品全体の成功ではない |
| 39115886912 / 013a4ed | CDCのanchorが疎く、局所編集で大半のchunkが変わる製品失敗。maskを0xffへ変更 |
| 39116110319 / 404d5e5、39116489795 / 554e16a | golden pathでinvalid。後者のstage証拠から.jsonを4文字だけ除去する製品誤りを特定、5へ修正 |
| 39116830249 / 3b24ebd | note/chunk/tree/golden成功。その後vet verifierのローカル名added重複でcompile失敗。capacityAddedへ訂正、vet/archive/exportはこのrunでは未実行 |
| 39117051820 / 3b24ebd | iOS compile失敗。CryptoKit import不足、旧DEBUG tuple fixtureとlazy Draftの接続漏れを修正。XCTest未実行 |
| 39117493330 / 28d9cfe | iOS焦点3caseを実行中。診断であり配布証拠ではない。後続uploadSnapshotID変更は入力不一致として別に検査する |

既存iOS診断の成功例は17分19秒/19分30秒/19分47秒、今回のworkflow上限30分。前段backend128秒をnative完了予測へ転用しない。通常全件CIの過去経路は約104分以上、小さい4jobは25分34秒であり、新候補の必須範囲と所要時間は最終preflightで確定する。初候補09:18:58Zからの手戻り・待機を含めて計時する。

## クラウドの履歴と復旧

0042はowner別のlatest-record sequence/counterと認証済みrootのcursorを追加する。DB triggerで旧writerも追跡し、最初のbaselineは既存の全件検証を通す。その後は最大200件ずつのdeltaをtreeへ適用し、owner/inventory/sequence/countとS3 exact rootを最終ACK時に照合する。deleted IDを削除して容量を作らない。

treeのref/update総数は100万、全配列へmaterializeするcreate/entries/hashは10万に分けた。10万→100001の実D1/tree delta成功・ACK再読取2回/書込0、全hydrate拒否を直接確認。cursor欠落後の全baselineとD1-independent災害復旧はまだ10万で止まり、大容量災害復旧まで完成とはしない。

独立レビューは、owner version INSERT後に一時失敗すると旧cursorが資格を失って100001件以上で永続停止する問題、root未送信の中断treeが整理から漏れる問題、大量abandonの1record=1SQL問題を発見。修正と境界検査を最終候補に含める。

初回全backendは74file/649case中642成功・7失敗、Node32成功、187.58秒。222入力の前後hash一致 `87960f8073344713dd0d962a3cc6d38528819df9f4a7750f6369e8a97d2f0cce`。失敗は既存fixtureが新counter FKを残してownerを直deleteする経路。製品eraserは共通削除順で新テーブルを消し成功しており、fixtureの準備/片付けを訂正する。未実行/失敗は成功へ読み替えない。

## 実環境と費用の境界

2026-10-18T10:09:08Zのread-only settingsで、既存WorkerはGENERAL_STORAGE_MODE=YES、PILOT_MODE=NO、tool trialなし。owner recovery paged/compression=YES。通常新clientにv4、旧tool trialにはv3を広告する。旧262への一覧互換を保つが、v4へ移行した自動保存headを旧262で復元できるとはしない。

実環境の200物理record/1GiBと全体3GiBはまだ変更していない。既存本人1・新規受付0・追加100PUT/128MiB・19日03:09JSTまでの有限受付と月予算を維持する。新しい有料契約0。実データの43.76MB/予約0、現record ACK済み・未参照live部品0を10:00:58Zに確認した。検査用合成データを実保存先へ大量投入しない。

長期原価には写真のR2/S3二重保持、復旧tree全version、PUT/GET/HEAD、KMS、D1/Worker、検証containerを含める。無料枠を1人ごとに重複適用しない。旧月2の14.42円を10年後の原価へ代用しない。写真0.93MB/10枚日＋メモ編集1回日を仮定した10年は36,500写真、deltaだけでも履歴約277,400ID・mutation約558,000。これは仮定の外挿であり実運用計測や写真原本/動画の容量ではない。新上限や追加費用が必要な設定は、この計算と現残額を確かめてから説明する。

## 19:24 JST 時点の追加証拠

- モデル診断39118395672、99b73a5は全成功。36,500メモ・500文字の実storeは60,286,919B、read665ms/edit1799ms/reopen1117ms、RSS319,995,904B。36,501ファイルのtreeは3,840node中3,836を再利用し変更index12,478B。raw移行、破損拒否、uploadSnapshotID新旧帰属、101件目の診察記録、既存コピー、書き出しまで成功。Mac合成モデルであり実iPhoneのメモリ/画面や実クラウドの証拠ではない。
- backend最終凍結292入力hash `bce4e8db93656258ad677eb0b986e35a9f43fbae33672748e938b3d117b6e666`。Node32、Vitest74file/652case全成功（140.08秒）、typecheck、migration5本（8.22秒）、0043既存data保持の実SQLite成功。直接223入力の前後hashも一致。fixture FK訂正後の成功であり、先の失敗を消さない。
- 独立再レビューで旧cursor再試行、root未送信abandon、set単位claimの3指摘は修正確認。cursor欠損/全災害hydrateの100k制限とusage全件SQLは残る。
- iOS診断39117493330は18分26秒で2成功1失敗。未保存メモ保護と中断整理の検査は成功。新規復元テストは `enable()` の正常復元時のtitleが「復元しました」であるのに「保存済み」を期待して停止した。fixtureの期待値だけを訂正し、失敗時には実title/detailを表示する。内容一致の後続assertはこのrunでは未実行なので再診断が必要。
- CI inventory専用PR365/a7cccc0は既存配置を維持して新テストだけsoloへ登録。ローカル251.6秒・owning plan39118959720成功、main629f6baへmerge。diagnostic workflowの一時拡張は製品差分から外す。通常CIの必須範囲は削らない。
