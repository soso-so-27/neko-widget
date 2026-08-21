# ADR-012：多頭identity基盤と安全な移行

- 状態：採用・アプリUI／姿勢instanceへ接続済み、実機ゲート待ち
- 日付：2026-08-19
- 対象：猫プロフィール、写真と猫の所属、誕生日／迎えた日、手動訂正

## 背景

Build 13までのアプリは、Visionで「猫が写っている写真」を検出するが、どの猫かは保持しない。`AppSettings.catLifeReference`は1件だけで、候補の除外と入力元Photosアルバムも世帯全体で1組だけである。

この前提を多頭の写真へそのまま適用すると、次が起きる。

- 1匹目の誕生日で、2匹目の写真にも年齢を付ける
- 1匹目の基準日より前にある2匹目の正しい写真を、子猫・年齢・成長から外す
- 2匹が写る写真を「この子じゃない」で除外すると、正しいもう1匹も全画面から消す
- 写真単位にまとめられた姿勢や最大猫領域を、どの猫のものか区別できない
- unionの猫領域を、個体別の成長代表やWidget cropとして誤用する

Apple写真の「ピープルとペット」にある個体clusterは公開PhotoKit APIから取得できない。誕生日、姿勢、GPS、顔検出も個体識別の代わりにはならない。したがって、Scannerの機械的な証拠と利用者が所有する個体identityを分離する。

## 判断

### 1. identityをreplaceable scan snapshotから分離する

`CatHouseholdIdentityState`をApp Group内の独立ファイルへ保存する。Scannerの再実行、対象Photosアルバムの変更、checkpoint置換で、プロフィールや手動判断を上書きしない。

状態は次を持つ。

- `schemaVersion`
- storeが所有する単調増加`mutationRevision`
- `legacyUnscoped`または`profiled`のmode
- `CatProfile`の配列。schema v3では、任意のプロフィール別Photosアルバム連携と最後に正常取得できた所属assetもここに持つ
- 写真とprofileの多対多membership
- 世帯全体のglobal exclusion
- Build 13互換metadata

### 2. 写真とprofileは多対多にする

membershipのキーは`(PHAsset.localIdentifier, CatProfile.id)`とする。1枚に2匹が写る場合は、同じassetを2つのprofileへ`included`にできる。

decisionは次の3値である。

- `included`：このprofileの猫が写っていると利用者が確認した
- `excluded`：このprofileの猫ではない。他profileや世帯全体からは消さない
- `unknown`：未確認、または利用者が「わからない」とした

membershipが存在しない場合も`unknown`として扱う。モデルの低信頼結果を自動で`included`へ昇格しない。

### 3. 利用者が作った通常Photosアルバムを、profileの明示入力として連携できる

個体ページに出す写真は、利用者がアプリ内で手動確認した`included` membershipと、そのprofileへ明示的に連携した通常Photosアルバムのassetの和集合とする。これはAI個体識別、類似検索のanchor、推測されたmembershipではない。1つのassetを複数profileの連携アルバムへ含められるため、2匹が写る写真を両方の個体ページへ出せる。

所属の優先順位は、高い順に次とする。

1. 世帯全体のglobal exclusion
2. profileごとの手動`excluded`
3. profileごとの手動`included`
4. profileへ連携した通常Photosアルバム

この順序により、利用者はPhotosアルバムを編集しなくても「この子ではない」を指定できる。アルバム連携を解除しても、アプリ内の手動`included`／`excluded`は維持し、アルバム由来だけを個体ページから外す。

連携はread-onlyとし、PhotoKitでアルバムやassetを作成、削除、移動しない。profileの連携元は、世帯全体のスキャン対象アルバムとも、アプリが管理するPhotosの「うちの子」出力アルバムとも別の入力境界である。管理対象の「うちの子」をprofileの入力元にはしない。

`CatProfilePhotoAlbumLink`はアルバムの`localIdentifier`、最後に正常取得できたasset identifier、連携日時、更新日時を端末内だけに保存する。アルバム名の変更ではlinkを失わない。Limited Photos Accessや一時的な取得不能により現在の所属を確定できない場合は、空集合で上書きせずlast-known所属を保持し、UIで再許可または再連携が必要なことを示す。これらのidentifierを診断JSON、共有manifest、Workerへ出さない。

### 4. global exclusionとprofile membershipを分ける

global exclusionは「この世帯の子が写っていない」という写真単位の判断であり、全profile、世帯アルバム、Widget、Photosの管理アルバムから外すための軸である。

profileの`excluded`は「むぎではない」のような個体単位の判断である。別profileのmembershipを変更しない。

global exclusionを設定した時点で、その写真の手動profile membershipは削除する。復元しても削除した手動membershipは復活せず`unknown`のままである。ただし、まだ連携中の通常Photosアルバムにそのassetが含まれる場合は、その明示入力がprofile所属を再び成立させ得る。これはAIによる自動判定ではない。既存global exclusionは類似検索のnegativeまたはpositive anchorへ変換しない。

### 5. life referenceはprofileごとに持つ

`CatProfile`は任意の`CatLifeReference`と、日付が推定かを示す`lifeReferenceIsApproximate`を持つ。referenceが未入力なら推定flagは必ずfalseに正規化する。

誕生日／迎えた日は、そのprofileへ所属する写真だけを子猫・年齢・成長へまとめるために使う。個体を見つける入力にはしない。

Build 13の単一`catLifeReference`は、migration時にprofileへ割り当てない。`legacyUnscoped.lifeReference`としてそのまま保持し、利用者がprofiled modeへ進むときに誰の日付かを明示的に決める。

### 6. manual subject rectを値で保持する

手動のpositive membershipは、任意の`subjectBoundingBox: NormalizedRect`を持てる。複数猫写真のどの猫を指したかを、Vision座標の矩形値で保持する。

Scannerが返す配列indexは再解析で変わり得るため永続参照にしない。姿勢側のinstanceと結合するときは、保存した矩形と`postureInstances[].boundingBox`の幾何的な重なりで照合する。raw関節点は保存しない。

矩形は有限、正の面積、unit rect内だけを許可する。`excluded`または`unknown`は矩形を持たない。

### 7. 類似検索の教師は明示したpositiveだけにする

`isSimilarityReference`は、利用者が基準写真として明示した`included` membershipだけがtrueになれる。`excluded`、`unknown`、既存global exclusion、将来のモデル提案ではfalseへ正規化する。

このflagは将来のFeaturePrint評価に備えた境界であり、本ADRではFeaturePrint生成、距離計算、自動提案を実装しない。モデル提案を自己学習へ自動投入しない。

### 8. 保存はcompare-and-swapと原子的置換にする

`CatHouseholdIdentityStore`は次の順で保存する。

1. App Group内のstable lock inodeへ`flock`
2. diskの`mutationRevision`とcallerのexpected revisionを比較
3. staleなら拒否し、上書きしない
4. storeがrevisionを1だけ進める
5. private modeの一時inodeへencodeして`fsync`
6. Data Protectionとbackup除外を一時inodeで検証
7. 同じdirectory内の`rename`を唯一のcommit pointにする

保存先は`cat-household-identity.json`である。ファイルとlockはbackup対象外とし、iOS実機では`completeUntilFirstUserAuthentication`を要求する。名前、日付、PhotoKit identifier、矩形は端末内だけに置き、診断JSON、共有manifest、Workerへ出さない。

## Build 13からの移行

初回loadでidentityファイルがなければ、次の`legacyUnscoped`状態を作る。既存のschema v1／v2をschema v3へ読む場合も、存在しなかったprofile別Photosアルバム連携を推測して作らない。

- profileを0件にする
- membershipを0件にする
- 単一life referenceはlegacy metadataに保持する
- 既存`CatCandidateCurationState.excludedAssets`はglobal exclusionとして保持する
- 既存source albumとlast-known membershipは世帯全体のlegacy sourceとして保持する
- 既存curation、scan snapshot、like、Widget cache、Photos管理アルバムは変更しない

同じ入力でmigrationを繰り返しても、ファイルを書き換えずrevisionを進めない。`legacyUnscoped`中にBuild 13設定が更新された場合だけ、世帯全体のlegacy値を同期する。`profiled`へ入った後は、古い設定でprofileやmembershipを上書きしない。

2匹目を追加するときに、既存候補全件を1匹目へ割り当てない。既存life referenceを複製しない。profile固有の年齢・子猫・成長は、明示されたmembershipを使えるようになってから接続する。未確認写真は世帯全体の既存体験へ残せるが、個体別の年齢を断定しない。

## 各機能への接続

- 年齢／子猫／成長：手動確認とprofileへ明示連携した通常Photosアルバムの和集合で先に絞り、profileのlife referenceを使う。アルバム連携は利用者による個体指定なので日付ベースの成長へ使える。ただし、解析済みの複数猫写真は対象個体のboxが明示されていなければ成長代表から外す。未確認の機械判定や世帯全体の候補も個体別成長へ入れない
- 寝顔／へそ天／香箱／どアップ：profileのsubject rectとv3のper-instance traitを照合する
- いっしょ／おでかけ：顔有無と外出判定は写真単位のまま、写真のprofile membershipを通して表示する
- Like：asset単位を維持し、profileごとに複製しない
- Widget：当面は世帯全体の「みんな」を維持し、profile指定はまだ公開しない
- Photosの「うちの子」：当面は世帯全体の1アルバムを維持する
- album利用ログ：猫の名前、profile UUID、life date、PhotoKit identifierを送らない

## 今回やらないこと

- FeaturePrint生成または個体自動推定
- Widget intent、deep link、cache manifestのprofile対応
- profile別Photosアルバムの作成・書き換え（利用者が作った通常アルバムのread-only連携だけを行う）
- 共有機能、Worker、API、暗号化manifestの変更

## 今回接続したもの

- 設定の任意profile作成、profileごとの誕生日／迎えた日と自動保存
- 1写真を複数profileへ割り当てる大表示menu、長押し、一括編集
- profileごとに利用者が作った通常Photosアルバムをread-onlyで1つ連携し、手動確認との和集合を表示
- 連携解除時の手動判断維持、手動negativeの優先、取得不能時のlast-known所属維持
- profile固有の「○○ではない」と、世帯全体の「うちの子ではない」の分離
- 「みんな」を既定のまま維持し、profile固有の時間／姿勢／成長albumを選択可能にするUI
- 姿勢v3のper-instance結果と段階別count-only diagnostics
- Build 13の単一日付を、最初のprofile作成時だけ利用者が確認できる初期値として提示
- Xcode targetとCI verifierへのsource追加

## 検証

pure Swift verifierで次を固定する。

- migrationがprofileやmembershipを作らない
- 同じmigrationがidempotent
- 1写真を複数profileへincludedにできる
- 同じassetを複数profileの通常Photosアルバムから明示所属にできる
- global exclusion、手動negative、手動positive、連携アルバムの優先順位を守る
- アルバム連携を解除しても手動membershipを失わない
- 取得不能時にlast-known所属を空集合で破壊せず、schema v2からの移行でlinkを捏造しない
- 1profileのexcludedが他profileを消さない
- global exclusionと復元が手動membershipを安全にunknownへ戻し、まだ連携中の明示album sourceだけは所属を再適用し得る
- referenceなしの推定flag、negative/unknownのcropとsimilarity flagを正規化する
- Codable round-tripで値を失わない
- stale revisionを拒否し、commitごとにrevisionを1だけ進める
- 実ファイルがbackup除外とData Protection要件を満たす
