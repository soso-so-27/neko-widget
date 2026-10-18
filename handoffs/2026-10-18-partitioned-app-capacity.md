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

## 20時台 JST の追加確認と配布前計画

- iOS診断39119155074/174483eは17分53秒で成功。実テスト`testAutomaticPartitionedRecordsMigrationAndRestore`は41.402秒、started/passed各1回、failure0。旧v3の写真を残したまま400メモ/130写真を追加してv4へ移行、欠落したローカル写真を既存認証済みコピーから保持、1メモ編集で写真PUT増加0、新fixture端末で全メモID/本文と全写真byte一致、旧dataset不変を確認。証拠は`C:/dev/neko-evidence/automatic-test-20261018/native-partitioned-174483e-success.log`。実iPhone・実クラウド・配布の成功へ読み替えない。
- 0044 usage counterは277,400履歴で単一SQL・record scan0、製品呼出10〜14ms。fixture生成込み39.47秒。0045 cursor欠損は100,001件を200件ずつ501checkpointで再構築成功（初期tree生成込み89.29秒）。独立レビューでretentionによるheader世代更新が再構築を0へ戻し続ける条件を発見し、修正中。0046のD1-independent全履歴復旧は小分けのoffline専用journalを実装中。いずれも最終凍結後の全backend成功はまだない。
- 保存コピー一覧は、非表示の自動保存内部部品を全件復号してから隠す処理を避ける。nativeのvisiblePageだけ`view=visible`を送り、backendはowner/世代/keysetを維持して内部部品をSQLで除外する。旧一覧・書き出し・直接ID読取の既存契約を維持し、visible件数が内部部品数へ比例しないことを直接検査する。
- 今回の容量設定候補はowner50GiB、live200,000、global100GiB。既存有限受付のowner1/新規登録0/期限/PUT・byte枠/予算値は不変。3設定だけでは受付量が広がらないことを独立確認し、AWSログイン待ちとは独立して準備する。新契約0。最新AWS残額は未確認であり無料保証はしない。写真10枚/日・930,000B/枚・10年の写真本体だけはR2/S3合計約206円/月（10/14計画FX、10/18公式単価、無料枠控除なし）だが、履歴/DB/処理/復元/固定費を加えた全原価は未確定。未計測の20revisions等の感度値869円を実原価や980円成立の証拠にしない。
- repo外にprepare/package/deploy-partitioned-cloud.pyを準備。実行はまだ0。candidate/入力閉包/main/同SHA全CI、既存owner/records/ACK元表/受付/会員/本人/試用/参照/cron/秘密参照を保護する。各migration境界でschema/ledger/元行、全migration後にusageとACKを独立再計算、新job表空を照合。deletion reader→archive writerの順で一度ずつ反映し、3設定以外のauthority/runtime/公開範囲は維持する。独立レビュー2指摘（main後続製品変更、ACK派生値未照合）を修正。合成SQLiteで誤ACK/誤合計の検出を確認。実version upload後settingsが旧/新どちらになるかは未観測のため、activation前は設定全体が旧または正規3値差分の新のどちらかに限り、activation後は新と完全一致を要求する。
- 配布前の残不確定: 0046全復旧/故障時再開と0045世代更新の直接検査、最終backend全体と独立レビュー、全体iOS CI、実cloud反映、TestFlight263以降の未使用番号、実機の新形式利用。保持する成功は入力が一致するものだけ。初候補09:18:58Zから計時を継続する。0046の追加実装・直接検査は60〜90分の未実測見込み、その後のfull-v1＋uploadは過去76.6〜110.1分。利用者へ追加時間を説明済みであり、以前の1〜2時間以内の完了を保証しない。

## 20:05 JST の統合候補確認

- 0045のheader-only更新による再構築の停滞は修正済み。601件を200件ずつ進め、その間に3回header世代を更新しても200→400→600→601と進み、最新headerに拘束したACKだけを公開する検査が成功。100,001件の501checkpoint成功は別の大容量境界証拠として保持する。既存15分cronだけなら501回は最低125時間15分であり、これは稀なcursor喪失時の再構築経路であって通常保存の時間ではない。新cron/HTTP経路は作らない。
- 0046のoffline journalは、空の隔離先・source書込み停止・削除要求なしを各quantumで再確認し、最後までownerをdisabledに保つ。S3全versionの列挙と再列挙、全owner世代の単調性、record全revision/削除intent/写真、v4参照を検査する。小規模の中断再開と写真復旧は成功。追加100,001個のS3 versionを処理した試験と、実treeの100,001 recordを新expected spoolへ展開して末尾ID/総数を確認した試験は別々の証拠であり、前者を大量record復元と呼ばない。後者は546quantum、peak rows200/S3 GET12/D1 prepared57/batch52/bind85、最大199ms/quantum（wall time）。全量の実ユーザー写真復旧ではない。
- 0044は派生ACK行の喪失をaccounting_valid=0として検出し、容量や復旧成功を偽装しない。0046の完了確認とcloud migration後の独立照合でもaccounting_valid=1を要求する。保管一覧は内部部品1,500件を復号せず、表示対象3件だけを開く境界とcursorの連続性を直接検査済み。
- 主担当は0046のsource inventory/header/tree、履歴の連続性、削除済みrecordの復活拒否、写真のexact readback、disabled維持、参照再構築、owner erasure順を独立レビューした。final accounting_valid確認は修正済み。最終全backend結果は次の凍結証拠へ記録する。
- 開発手順の15既存suiteは238.7秒で成功。入力が不変の成功を保持し、push直前はpreflightのみ再評価する。全backendやnative候補の成功とは混同しない。
- 写真930,000byteは以前の計画上の仮定。現製品は最大4096px/JPEG品質0.92/最大20MiBで、0.93MBを保証しない。実在の43.76MB/26 live写真はmetadata込みなので、写真平均そのものとして使わない。費用確認は実処理数と、1/2/4MB等の明示的な写真サイズ仮定を分ける。

## 20:20 JST 統合実装の固定前検査

- 0044 triggerによるD1 meta.changesの増加を実D1で確認（SQLite changes()=1 / meta.changes=3）。復旧参照の成功判定をINSERT RETURNINGの1行へ修正し、直前CASのchanges()=1条件は維持した。最初の全体検査の13失敗・中断は保持。修正後はNode32・Vitest76file/669case・typecheck・migration5組成功。検査前後350fileのclosureは7386d556161e0efa617b90479e9d6a47eb122ad90042245468a2851ece6db4e9で一致。全体191.90秒。
- 実100,001件immutable treeの展開・先頭/末尾ID・履歴参照・破損停止・中断/競合からの再開、target disabledの維持を直接確認。10万超S3 versionsの別probeと混同しない。最大200行のbounded処理、546quantum、実測最大199ms wall（CPU時間ではない）。lifetime tree100万ID / offline1000万versionsの防御上限は残る。
- 本番ArchiveStore経路を外部通信0で直接計測。メモ1編集は写真PUT0、S3 PUT71/GET163/HEAD71・KMS346回、写真1追加は88/201/88・417回、写真10枚まとめ追加は285/643/285・1248回。実写真fixtureは4096B、930k/1/2/4MBは別の仮定感度。128写真程度の実測であり36,500写真時の係数、Worker/container/D1保存量/長期履歴原価は未測定。先行product回帰12.19秒、成功出力回収失敗88.97秒、最終回収89.35秒を全て保持（累積190.51秒）。
- 検査選択は全native入力の固定source/full-tree照合を条件に既存app-dataの6job（Build/privacy/migration・Photos scan・両OS runtime・app UI3組）を使う専用制御を先行mainへ提案する。Widget target/fixture/runtime入力は不変、独立レビュー済み。native合格とbackend合格は分け、同じ候補SHAのowning Preservation全8stepをクラウド/配布前に別途必須化する。制御検査501件成功78.228秒（source pin確定前、確定後の条件を別確認する）。
- 初候補09:18:58Zから継続計時。これまでの診断・失敗・修正・準備を含め約2時間。新経路は未計測、旧CI+upload実測76.6–110.1分を目安にし、短縮を実績扱いしない。新クラウド・main製品・TestFlightはこの時点で未実施。

## 20:32 JST 配布候補の検査開始準備

- source 1dca22ed4d6baa00572fede16266d9769d2e0606を固定。制御PR366/a71fbe7727ad05b3f95310d4dd03ebfdd85c0ba3をmain c299f9deへ先行統合。通常push39123373067のPython planは成功（58秒）。先行39123244115はLinuxでindex chmod後のworktree mode差によりfixtureのbranch switchが失敗（23秒）、一時test repoのcore.filemodeを明示しraw mode拒否試験を維持して修正。製品変更ではない。PR側skipは成功証拠に使用しない。
- 固定control導入はhistorical controllerの同2pathに衝突してfullと判定されたため、exact base tree＋通常Python2files＋proseだけの入口を追加。実preflightでci-orchestration-v1/planのみを確認。独立レビュー済み。502検査中1件のmock設定誤りを直し3対象test成功、他501の成功を保持。最終CIは全development checksが実行成功。
- クラウドは既存73recordのread-only基準と42～46の移行bundleを作成。新secret/新resource/cron/公開/新契約0、変更設定はowner50GiB・200k live records・global100GiBの3値だけ。まだremote mutation0。
- クラウドと配布の共通資格確認helperを外部に作り、全tracked product入力のsource/candidate/current main一致・native6job・同SHAの最新owning Preservation8step成功を必須化。署名済release CLIは変更せず、独立レビューと合成境界9件＋wrapper5件成功。rootはhelper・wrapper・cloud接続差分を読み確認。実CI資格確認は後続。
