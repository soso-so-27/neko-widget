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
- `CatProfile`の配列
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

### 3. global exclusionとprofile membershipを分ける

global exclusionは「この世帯の子が写っていない」という写真単位の判断であり、全profile、世帯アルバム、Widget、Photosの管理アルバムから外すための軸である。

profileの`excluded`は「むぎではない」のような個体単位の判断である。別profileのmembershipを変更しない。

global exclusionを戻した写真は、以前のprofileへ自動で戻さず`unknown`にする。既存global exclusionは類似検索のnegativeまたはpositive anchorへ変換しない。

### 4. life referenceはprofileごとに持つ

`CatProfile`は任意の`CatLifeReference`と、日付が推定かを示す`lifeReferenceIsApproximate`を持つ。referenceが未入力なら推定flagは必ずfalseに正規化する。

誕生日／迎えた日は、そのprofileへ所属する写真だけを子猫・年齢・成長へまとめるために使う。個体を見つける入力にはしない。

Build 13の単一`catLifeReference`は、migration時にprofileへ割り当てない。`legacyUnscoped.lifeReference`としてそのまま保持し、利用者がprofiled modeへ進むときに誰の日付かを明示的に決める。

### 5. manual subject rectを値で保持する

手動のpositive membershipは、任意の`subjectBoundingBox: NormalizedRect`を持てる。複数猫写真のどの猫を指したかを、Vision座標の矩形値で保持する。

Scannerが返す配列indexは再解析で変わり得るため永続参照にしない。姿勢側のinstanceと結合するときは、保存した矩形と`postureInstances[].boundingBox`の幾何的な重なりで照合する。raw関節点は保存しない。

矩形は有限、正の面積、unit rect内だけを許可する。`excluded`または`unknown`は矩形を持たない。

### 6. 類似検索の教師は明示したpositiveだけにする

`isSimilarityReference`は、利用者が基準写真として明示した`included` membershipだけがtrueになれる。`excluded`、`unknown`、既存global exclusion、将来のモデル提案ではfalseへ正規化する。

このflagは将来のFeaturePrint評価に備えた境界であり、本ADRではFeaturePrint生成、距離計算、自動提案を実装しない。モデル提案を自己学習へ自動投入しない。

### 7. 保存はcompare-and-swapと原子的置換にする

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

初回loadでidentityファイルがなければ、次の`legacyUnscoped`状態を作る。

- profileを0件にする
- membershipを0件にする
- 単一life referenceはlegacy metadataに保持する
- 既存`CatCandidateCurationState.excludedAssets`はglobal exclusionとして保持する
- 既存source albumとlast-known membershipは世帯全体のlegacy sourceとして保持する
- 既存curation、scan snapshot、like、Widget cache、Photos管理アルバムは変更しない

同じ入力でmigrationを繰り返しても、ファイルを書き換えずrevisionを進めない。`legacyUnscoped`中にBuild 13設定が更新された場合だけ、世帯全体のlegacy値を同期する。`profiled`へ入った後は、古い設定でprofileやmembershipを上書きしない。

2匹目を追加するときに、既存候補全件を1匹目へ割り当てない。既存life referenceを複製しない。profile固有の年齢・子猫・成長は、明示されたmembershipを使えるようになってから接続する。未確認写真は世帯全体の既存体験へ残せるが、個体別の年齢を断定しない。

## 各機能への接続

- 年齢／子猫／成長：profile membershipで先に絞り、profileのlife referenceを使う。複数猫写真でsubjectが未確定なら成長代表には使わない
- 寝顔／へそ天／香箱／どアップ：profileのsubject rectとv3のper-instance traitを照合する
- いっしょ／おでかけ：顔有無と外出判定は写真単位のまま、写真のprofile membershipを通して表示する
- Like：asset単位を維持し、profileごとに複製しない
- Widget：当面は世帯全体の「みんな」を維持し、profile指定はまだ公開しない
- Photosの「うちの子」：当面は世帯全体の1アルバムを維持する
- album利用ログ：猫の名前、profile UUID、life date、PhotoKit identifierを送らない

## 今回やらないこと

- FeaturePrint生成または個体自動推定
- Widget intent、deep link、cache manifestのprofile対応
- profile別Photosアルバム作成
- 共有機能、Worker、API、暗号化manifestの変更

## 今回接続したもの

- 設定の任意profile作成、profileごとの誕生日／迎えた日と自動保存
- 1写真を複数profileへ割り当てる大表示menu、長押し、一括編集
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
- 1profileのexcludedが他profileを消さない
- global exclusionと復元がmembershipを安全にunknownへ戻す
- referenceなしの推定flag、negative/unknownのcropとsimilarity flagを正規化する
- Codable round-tripで値を失わない
- stale revisionを拒否し、commitごとにrevisionを1だけ進める
- 実ファイルがbackup除外とData Protection要件を満たす
