# 長期保存のアプリ組込み

## 2026-10-19 保存後に残る赤い警告を修正・TestFlight264アップロード完了

- 配布後、利用者が「264で保存済み・赤い表示なし」と回答。通常写真メモの編集→再確認なしの保存表示を実機で確認済み。08:44:54 JSTにhead revision6→7、live photo27→28、45,498,391B/予約0/参照欠落0、inventory世代111の読取中一致を確認した。メモ・写真内容の取得と資源への書込は0。今回の赤い警告は実機まで解消確認。証拠は外部`intake-window/arrival-20261018T234454395039Z/summary.json`。以下の264端末表示未確認はアップロード時点の履歴。
- 263で通常写真メモを編集し、再確認ボタンなしで「保存済み」。クラウドhead revision4→6・写真26→27・参照欠落0を読取確認した。赤い「記録が更新されています」は設定を一度出て戻ると消えたとの利用者報告。実際に失敗した要求は未採取だが、設定用coordinatorが不要な保管一覧を読み、保存成功と独立した409を残す経路を修正した。
- 設定は本人確認・会員情報だけを取得するaccount用途へ分離。旧保管一覧のgeneration照合、owner/session/epoch、削除状態、復元時の原本と未保存メモの保護を維持する。クラウド追加反映0、月980円、新規契約/一般公開/課金開始/定期作成・再実行0。先行容量反映の50GiB/200,000 live records等は変更しない。
- 診断39173406929/b77cbc1はUI2件・runtime42項目成功。保存済み/会員情報/赤い警告なし、通常ツールの復元と添付写真、編集中メモ保護を実シミュレータ画面で確認。診断を配布証拠に代用しない。独立レビュー済みcontrol PR378をmainへ先行統合後、製品候補0bb6bebbの通常push39174673944でBuild/privacy/migration・Photos bootstrap・両OS runtime・関連UI3件の全4必須jobが初回成功（21分48秒、合計runner70.483分。請求額の意味ではない）。ローカル15検査はb77の419.1秒とb485の429.0秒を不変入力へ帰属して保持し、統合候補で実scopeと診断継続の交差部分を直接確認した。15検査を0bbで再実行済みとはしない。
- PR379をmain6f824705へmergeし、parents/全tree一致とmain39176417739の証拠再照合成功を確認。正規CLIから264を一度だけdispatch。run39176548675/job117820301076は08:39:46 JSTにApple upload成功。署名・privacy・IPAの必須stepと生altool VERIFY/UPLOAD SUCCEEDEDを照合した。実job11.68分。Appleの処理完了・264の実機表示・別iPhoneでの新形式復元は未確認。原本削除や再インストールを確認手順にしない。
- 警告修正の初候補は19日07:35:39 JST。診断・制御・通常検査・待機・配布を含め配布job完了まで64.23分（60〜90分計画内）。以前の容量候補18日09:18:58UTCからの失敗・経過も下記に保持し、この修正だけの時間へ置換しない。証拠は`C:/dev/neko-evidence/partitioned-release-continuation-20261019/settings-list-race`。

現在の残件:

- 264の通常写真メモ保存と赤い警告なしは実機確認済み。別iPhoneでの新形式復元、実iPhoneの大量データ時のメモリ/描画性能は未確認。自動検査の復元成功と区別する。
- 本人限定の保存テスト受付は19日09:21:40 JSTまで。今回の警告修正では延長・枠補充なし。07:21の残56PUT等は開始時の値で、263の実機保存後の残数ではない。期限後に新規変更を送れないことを今回の表示修正失敗と混同しない。
- 50GiBは無制限ではない。長期の全providerを含む1人総原価、実写真を含む大容量の災害復旧、稀なcursor喪失時の復旧速度は引き続き残る。写真原本・動画は現在の保存対象へ含めない。

## 2026-10-19 長期容量のクラウド反映・配布結果

- 19日07:26 JST、263で通常の写真メモを編集して「保存済み」になったとの報告。再確認操作なしでcloud head revision4→6、live photo26→27、44,707,333B/予約0/参照欠落0を読取確認した。赤い「記録が更新されています」は設定を一度出て戻ると消えた。実際に409となった要求は未採取だが、保存状態と独立した設定用coordinatorの旧保管一覧GETが競合を表示する経路を特定。設定だけaccount/membership経路へ分ける修正と、一覧409の対照・owner/token交換・停止後応答・401・削除状態、実画面保存/復元の検査を準備中。旧一覧のgeneration fenceは維持。別実機でのv4復元の成功には読み替えない。
- この警告修正の準備時点でGitHub公開repo・当月Actions/成果物の請求0USD・Actions予算0USDで有料利用停止を読み取り確認。月額980円、クラウド料金プラン、有限受付の期限/残予算は変更しない。診断は既存2UI操作で約20分の参考、製品配布の確認範囲は依存関係に基づき別途確定する。容量対応の初回候補時刻と失敗履歴は保持する。

- 19日07:16 JST、利用者が「263に更新できた。今から確認できる」と回答。独立レビュー済み固定adapterが新しい同owner/epoch/link/会員資格・worker閉包・削除intentなし/全旧26列を再読取し、07:21:40に受付日時2列だけを単発CASで更新、1行/完全読戻しを確認した。期限は同日09:21:40 JST、残56 PUT/88,591,059B、53 mutation/86,993,619Bの補充なし。新契約/予算増額/新規owner/定期変更は0。既存SQLite12件を保持、adapter局所3境界成功。証拠は外部`intake-window/activation-20261018T221616Z/{approval,plan,review,completion}.json`。07:22の読取は旧head revision4、保存43,756,122B/予約0/参照欠落0、読み取り中のinventory一致。263の新v4送信・復元の成功とはしない。以下の「受付未延長」はこの再開前の履歴。
- 月額980円を維持。追加契約・料金プラン変更・一般公開・新規owner受付・定期タスクの作成/再実行は0。保存対象は写真メモ、ツール入力と添付写真、猫情報。写真ライブラリ全体、写真原本、動画のバックアップではない。
- 19日06:54頃JST、AWS CLI接続は失効していたが、同account164892691568の既存ログイン済みブラウザでcreditsを明示再読込し、推定119.24USD/確定119.81USD、当月0.57USD、FREE planを確認した。推定値は約24時間更新の遅延があり、瞬時の全原価とはしない。CLI再ログインや料金変更は不要だった。根拠は外部`aws-browser-cost-observation.json`。
- クラウドは既存73recordを保全し、0042〜0046、削除reader→archive writerの順で反映。live code hash、ACK、独立usage集計が一致。owner 50GiB/200,000 live records、global100GiBの3設定を変更した。証拠: `C:/dev/neko-evidence/automatic-test-20261018/partitioned-cloud-20261018T211114Z/execution/completion.json`。旧「未配備/1GiB/200record」の記載は以下の過去時点の記録として保持する。
- アプリは大容量JSON/転送確認の分割、v4再帰index、変更のない写真・部品の再利用、冷状態からの復元再開を組込み。全tree/写真/hash/manifest検証後だけ新datasetを有効化し、元データと未保存メモを保護する。旧v3から移行できるが、新v4 headを旧262で復元できるとはしない。
- 元候補4d63f372の通常native39129913547は初回5成功/solo1失敗を保持し、同SHAのsolo1だけ1回再実行。28caseと全6必須job成功。backendはPR367の39129917449の実checkout/tree、8stepを照合した。PRの結果をpushと呼ばず、skipped/mirror jobも実検査として数えない。main ba3704aへ統合済み。
- 配布時刻までにreadinessが失効したため、既存2authorityで現時計の署名を更新した。payloadはissued/expiresのみ更新、29codePathsと古い合成drillの帰属は不変。PR374の2controlを先にmain3db0f81へ統合し、候補b4d43d32522dcbdd8d04020ff23f2ad6c7be737cはその上にreadiness1ファイルだけを変更。full tracked treeと原native/backend/current signatureを再照合し、成功検査を再実行しない。
- 新control39168237349はLinuxのindex-only chmod後のcheckoutでfixture1件失敗。mode検査を最後へ移動し同じassertを維持、3focused成功、39168388988で全development checks成功。以前にも同種fixture failureがあり、以後のmode probeは独立repoまたは最後に置き、後続checkoutを前提にしない。失敗raw/初候補時刻を保持。新release候補39168620417のplan3必須stepも成功。
- TestFlight263は19日07:01:36 JSTにAppleへアップロード成功。run39169522658/attempt1/job117799489487、requested source b4d43d32522dcbdd8d04020ff23f2ad6c7be737c、workflow main90ecdf1。署名/プライバシー/IPA検査と実altoolのVERIFY/UPLOAD SUCCEEDEDを生ログで照合した。実job11分32秒、最初のdispatch1回のみ。raw SHA256 `a651e189cdf3ac23bbbfc02e360dff18d36d78b47a25ca3da05e8c0b8f305908`、外部`testflight263-upload-completion.json`。Apple側の処理完了、利用者端末の表示、新v4の実機復元はこの成功へ含めない。
- 最初の候補2026-10-18T09:18:58Zから計時し、試作・失敗・再検査と15:26→21:10UTCの観測間隔を含める。この間隔を全てactive作業と断定しない。旧readinessで263 dry-run成功後のdispatchは0。新継続の45〜60分計画は21:21UTCからの残作業見積もりであり、初候補から計時をリセットしない。配布job完了までの累計12時間42分45秒。21:21UTCからの継続工程は約41分で、45〜60分の残作業計画内。総経過を継続工程の時間へ置換しない。

残件と境界:

- 実機の新v4保存/復元、実iPhoneの大容量メモリ・描画性能は未確認。シミュレータではcold中断再開、実60秒429、破損nodeだけ再取得、写真/メモ一致を確認した。元データ削除・再インストールを確認手順にしない。
- 保存テスト受付は2026-10-19 03:09JSTで失効し延長なし。実機確認できる時間に合わせ、本人1人/新規0・残56 PUT/88,591,059B、53 mutation/86,993,619Bを補充せず、日時2列だけ2時間へ更新する提案とCAS草案を作成。現live schemaを使うSQLite境界12件成功、実API書込0。本番transport接続、時刻に合わせたfresh prepare/独立review/適用は未実施。Sandbox会員資格は別判定。外部`intake-window/proposal.json`へ現AWS/CF費用観測・遅延・残runtime読取不可も記録した。共有runtimeは既存fail-closed枠内の可用性未確認であり、残額の補充や追加費用の承認ではない。
- 無制限や全ての写真サイズで10年保証ではない。50GiBで36,500枚を保存するには、他データを除いても平均約1.47MB/枚未満が必要。既存50写真objectの実測平均約0.872MBは旧コピーも含む観測値で、将来の平均保証ではない。100,000file/8,192node等の保護上限も残る。
- 全履歴の稀なcursor喪失から100,001件を200件/回で再構築する試験は成功したが、15分周期では最低125時間15分を要する。通常保存の待ち時間ではない。S3版本数とrecord treeの大容量試験は別実行で、実写真全経路の災害復旧実証ではない。
- 長期の1人あたり総原価は未確定。写真二重保存の感度試算や128-photo合成cold経路の係数を、warm/36,500-photo全体の実測総原価にしない。CPU、DB/index、履歴、復旧/書出し/再試行、共通固定費の分担等は引き続き必要。無料枠を1人ごとに重複適用しない。


## 以下は候補検証中の履歴

- 21時台の追加修正: 新端末の一覧読込は子nodeごとの429待機・途中receiptがなかった。既存owner30request/分のまま、大量の一覧で初めから再読込する恐れを修正。owner/root ID/root SHAと親edgeに拘束した専用metadata cacheを1root分だけ保持し、破損はそのnodeだけ再取得。全tree/写真/manifest検証前に復元を公開しない。元データやpending/uploaded/restored receiptは消さない。
- 新差分は独立レビュー済み、Swift実行はこれから。既存実iOS fixtureへ、warm child GET=0、中断前の3node再利用、実60秒429待機、壊れたreceipt1件だけ再取得、写真・全メモ一致の復元を追加。既存modelへ3,839childと128KiB wire境界を追加。診断計画はrepo外`partitioned-cold-resume-plan.json`。初回候補09:18:58Zからの累計を維持し、診断約19分＋配布経路約77〜110分を見込む。前の91a144候補資格は無効化し、新入力で再固定する。
- 原価probeの整理: `v4-fullpath-cost-20261018T111249Z`は各scenarioで17node全部を読むcold経路。warmアプリは認証済みuploaded/restored receiptを残しており、全nodeを毎回読む原価ではない。memoのpreflightはhead1+node17、KMS18/D1読291/R2 GET78。これを全て除く値もwarm原価ではなく、実際のhead/root/usage分を再加算する必要がある。S3処理回数はこの分類で変わらない。既存raw測定を上書きしない。
- 実保存量は11:39Z時点の保全baselineから集計: 現在保持する写真object50件で43,611,748B、平均872,234.96B、中央値886,687B。旧コピーを含み、最新datasetの26写真や将来の平均とは区別する。全record課金対象43,756,122B。証拠`current-saved-photo-size-observation.json`。

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


## 22時台 JST 長期利用時の端末データと復元再開

- 初候補09:18:58Zからの計時を維持。最初の通常native CI39123642817/6d3c909は67.8分・runner226.583分で、BuildのDEBUG生error privacy検査だけ失敗、Photos・UI3組・runtimeの5必要jobは実成功。生error表示を確認コードだけへ修正済み。失敗を成功にせず、最終候補のnative6jobを別に要求する。backend39123642785の全8step成功は21入力閉包が完全一致する場合だけ保持する。
- cold復元39127924738/4f72bd7は成功、18分26秒、対象UI test91.092秒。fresh rootの毎回検証、429後の60秒待機、途中取消後の3取得済node再利用、壊れたcache1nodeだけ再取得、新端末fixtureでの全メモ/写真一致と旧dataset保持を確認。端末別cacheはowner/root/hash/parent edgeで拘束する。純モデル39127911535は135秒成功、36,501file/3,840nodeのうち3,836再利用、hydrated index25,600,522B。実iPhone性能/別実機復元の成功ではない。
- 完了uploadのpending/uploadedに全hydrated indexが各1部残る問題を確認。36,501file仮定では約51.2MB/編集となるため、古いremote rootが実404であることとsessionを確認した後、owner/rootが一致した作業用metadataだけ整理する。pending最初・uploaded最後、対象を全検証してから削除し、contents/restored.jsonや元写真・未完uploadを保持する。独立レビューにデータ損失blockerなし。通常成功時の整理であり、通信/ローカルIO例外時の残骸を別queueで再試行する処理や過去履歴の一括整理は含まない。新しい保存をこの任意整理のために止めない。
- metadataの直接確認は既存のFoundationモデル診断で実ファイルのv3/v4、owner/root不一致、壊れたreceipt、unknown/symlink、未完upload、部分整理の再開と原本保持を実行する。約135秒の先行モデルで判断し、この追加変更だけのために19分のUI診断を重複起動しない。最終6nativeで実アプリの整理integrationを確認する。
- AWS再ログイン後、既存164892691568のFREE plan、推定残credit119.25USD・確定残119.81USD・当月0.54USDをread-only確認。見込み値の更新遅延は残る。追加契約/料金プラン変更0。月980円、既存受付/期限/予算/公開範囲を維持する。
- 累計360分を計画枠とし、最終native約68分＋過去upload約12分＋準備を見込む。元の時間目標内で完了したとは扱わない。実クラウド反映、内部263、実iPhone v4復元はまだ未実施。

- metadata実ファイル診断39129473810/20c4634は169秒で成功。未ACK・owner/root不一致・破損・symlink/unknownの拒否、v3/v4完了metadataの削除、partial pruneのhelper再開、原本保持を確認。初候補時刻と失敗履歴は維持する。
