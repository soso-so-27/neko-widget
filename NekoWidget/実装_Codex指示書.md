# 猫ウィジェット v1 実装指示書（Codex向け・改訂版）

発行：2026-08-15
改訂：2026-08-16（Build 6のWidget肉球操作と計測方針を反映）

## 0. これは何か

検証用のv1。課金・共有・サーバーは実装しない。

検証する中心仮説は「カメラロールから猫が主役の写真だけを自動選別して日常に表示すると嬉しいか、そして『これ好き』を押す行動が起きるか」。想定利用者は開発者本人と家族。

Webではなく、Swift / SwiftUIによるiOSネイティブアプリとして実装する。

## 1. 着工前に確定した設計判断

### 1-1. 実機スパイクの結果

Apple標準「写真シャッフル」に指定したアルバムへ後から写真を追加しても、その写真は壁紙候補へ反映されなかった。写真シャッフルは設定時のアルバム内容をスナップショットとして保持する挙動である。

この結果は `docs/ADR-001-写真シャッフルのアルバム追従.md` に記録する。

### 1-2. 設計への反映

- アルバム生成機能は残す。初回の選別済みセットを簡単に写真シャッフルへ設定するために使う。
- アルバム更新後の内容を壁紙へ反映するには、ユーザーが写真シャッフル側でアルバムを設定し直す必要がある。その旨を案内画面に明示する。
- ウィジェットをP0へ上げ、継続的に切り替わる主要表示先とする。
- アプリの中核は、スキャン、猫検出、選別、好きの蓄積。表示先が壁紙かウィジェットかは中核データを利用する末端機能として分離する。

### 1-3. 合意済みの5点の補正

1. 最低対応OSは **iOS 17.1**。
2. 猫中心のクロップは **アプリ内表示のみ**。Widgetはサイズ別canvasへ元写真全体をaspect-fitし、同じ写真のぼかし背景で余白を埋める。PhotoKitアルバムには元のPHAsset参照を入れ、壁紙のクロップはOSに任せる。
3. バックグラウンド処理は **best effort**。v1はアプリ起動時・フォアグラウンド時の同期を確実に行えばよい。
4. 初回表示は **速報値と確定値を分離**。最新500枚の処理中から速報を表示し、全件完了後に総数と最古日を確定する。
5. 写真シャッフルのアルバム追従はしないことが実機で確認済み。自動追従を受け入れ条件に含めない。

### 1-4. Build 5のWidget表示品質

- 眺める体験はAppleの壁紙、タップして「これ好き」へ進む体験はWidgetが担う。
- AppleとSubject Liftingや構図理解で競わず、v1ではサイズ別専用画像と背景ぼかしだけを追加する。
- Smallは400×400px、Mediumは800×374px、Largeは400×420px。各JPEGは50KiB以下。
- 鮮明な前景には元写真全体をaspect-fitし、同じ写真をaspect-fillしてぼかした背景で余白を埋める。
- Subject Lifting、saliency、猫boxによるWidget内の再構図は、この結果を実機で確認してから再検討する。
- 判断記録は `docs/ADR-003-Widget表示品質のBuild5範囲.md` に残す。

### 1-5. WidgetKitの制約

サードパーティウィジェットはロック解除ごとの更新を保証できない。1回のタイムライン生成で15〜20件の未来エントリをまとめて返し、10〜30分間隔で切り替える。表示時刻はOS裁量でありbest effort。

### 1-6. Build 6の「これ好き」計測

- Build 5は表示品質と配布の技術検証専用とし、1週間計測には含めない。
- 1週間計測はBuild 6を実機へ入れ、3サイズの肉球操作を確認した後、アプリの開始操作で明示的に開始する。
- Widget右下の肉球から、アプリを開かずに好き／解除を記録する。
- Build 5以前のlikesは開始時枚数として分離し、Build 6開始後のイベントだけを行動計測へ使う。
- 診断ログとは別に、App Groupへ30日・最大1,000件の操作履歴と、上限等で落とした件数を保持する。
- 判断記録は `docs/ADR-004-Widget肉球ボタンとBuild6計測.md` に残す。

## 2. 技術方針

- Swift / SwiftUI / Xcode
- Deployment Target: iOS 17.1
- オンデバイス処理のみ。ネットワーク通信、サーバー、外部ライブラリなし
- PhotoKit / Vision / WidgetKitを使用
- 本体とウィジェットはApp Groupでデータを共有
- 写真原本を複製しない。保存するのは `PHAsset.localIdentifier`、解析結果、好き・表示履歴と、App Group内の消去可能な低解像度派生キャッシュのみ
- `localIdentifier` は端末間で不変ではない。v1は単一端末のみ
- Widget設定には `AppIntentConfiguration` を使い、写真源の選択を `WidgetConfigurationIntent` で表す。Build 6で有効な写真源は自分の写真ライブラリの「うちの子」だけだが、providerとentryには写真源種別を渡す
- Widgetの肉球操作には、設定Intentとは別の非公開App Intentを使う。Siri / ショートカットへ公開する連携はv2以降
- Build 6では写真源の安定IDをentryまで渡す。将来ほかの写真源を実装する前にaction policyを追加し、表示側で写真源名から操作を推測しない。「他人の猫」は自分の本へ追加せず、専用policyを決めるまでは肉球を表示しない

## 3. 画面構成

### 3-1. 初回起動

1. 写真ライブラリの読み書き許可を求める。
2. `.limited` でも利用でき、「もっと写真を選ぶ」導線を出す。
3. 新しい順に最大500枚を第1段階として解析する。
4. 処理中から速報値を表示する。
5. 全件解析が終わった時点で確定値へ切り替える。

速報表示例：

```text
まず 37枚 見つかりました
最新 126 / 500枚を確認中
（これは速報値です）
```

確定表示例：

```text
あなたのカメラロールに
うちの子の写真は 2,847枚
ありました

一番古い1枚は
2021年4月3日
```

### 3-2. ホーム

- 今日の1枚を大きく表示（猫中心クロップ）
- 「これ好き」ボタン。1タップで切り替え、好きの総数を表示
- 画面上部に好きの総数を常時表示し、一覧では押した日時を表示
- 「うちの子」アルバムの作成・更新
- Apple標準写真シャッフルへの設定案内
- アルバム更新後は写真シャッフルの再設定が必要という注意
- スキャン進捗、再スキャン、総枚数、期間、最古日

### 3-3. 好きな写真

- 好きを押した写真を、押した日時が分かる一覧で表示
- 枚数を大きく表示
- タップで詳細、好きの解除

### 3-4. 設定

- 対象期間：全期間 / 直近1年
- 自動アルバム上限：既定300枚
- 猫検出confidence：既定0.7
- 猫領域の最小面積比：既定8%
- 再スキャン
- JSONエクスポート
- 全件確定後、detected母集団からSHA-256順位で最大100枚を抽出し、JSONと同じreviewNumber順で写真全体と撮影日時を確認する画面。目視ラベルを誘導しないようconfidence・area ratio・cat countは画面に出さず、JSONだけに保持する
- 診断ログの閲覧・更新・消去・コピー・共有

## 4. 自動アルバム

PhotoKitで「うちの子」アルバムを作成し、選別済みのPHAsset参照を追加・削除する。

- `PHAssetCollectionChangeRequest` を使用
- 写真を複製しない
- 作成したアルバムの `localIdentifier` を保存し、同名の別アルバムを誤更新しない
- 上限は既定300枚
- 上限を超えたら古い・優先度の低い候補から外す
- アプリ起動時とユーザー操作時に同期
- バックグラウンド同期はbest effortで、v1の成立条件にはしない

写真シャッフル案内：

```text
1. 設定 → 壁紙 → 新しい壁紙を追加
2. 「写真シャッフル」を選ぶ
3. 「アルバム」から「うちの子」を選ぶ
4. 切り替え頻度を「ロック時」にする

重要：写真シャッフルは設定時の内容を保持します。
「うちの子」アルバムを更新した後は、壁紙側でもアルバムを設定し直してください。
```

## 5. ウィジェット（P0・主要表示先）

### 5-1. サイズ

- `systemSmall`
- `systemMedium`
- `systemLarge`
- ロック画面アクセサリはv1対象外

### 5-2. タイムライン

- 写真源を選択できる拡張境界として `AppIntentConfiguration` / `AppIntentTimelineProvider` を使う
- 写真源は安定identifierを持つ`AppEntity`とし、Build 6の設定Intentで選べる値は「うちの子」だけにする。将来の写真源を未実装の選択肢として露出しない
- configurationからprovider、timeline entryまで写真源identifierを失わずに渡し、配置ごとのconfigurationをglobal状態へ保存しない
- Build 5の`StaticConfiguration`からの更新はTestFlightで既設Widgetを残して確認し、不調時は削除・再追加する。一般公開後に同じ構成方式変更を繰り返さない
- 将来別写真源を追加するときは、manifest/cache/leaseを写真源namespaceへ分け、action policyをentryへ追加してから有効化する
- Build 6の肉球ボタンは `Button(intent:)` と、設定Intentとは別の非公開App Intentを使う。Siri / ショートカット連携へは使わない
- 1回に15〜20枚分の未来エントリを返す
- 間隔は10〜30分、既定20分
- 最後のエントリ後に `.atEnd` で次のタイムラインを要求
- exactな更新時刻は保証せずbest effort

### 5-3. メモリ対策

- ウィジェット側でPhotoKit / Vision / クロップ処理を実行しない
- 本体アプリがSmall 400×400px、Medium 800×374px、Large 400×420pxの専用canvasを作り、各JPEGを50KiB以下へ圧縮
- 背景は元写真をaspect-fillしてぼかし、鮮明な前景は元写真全体をaspect-fitする
- App Groupにはmanifestと画像ファイル名を保存
- TimelineEntryにJPEG DataやUIImageを保持しない
- View表示時に現在の1枚だけ読み込み・デコード
- manifestとキャッシュは原子的に更新する
- データ更新後に `WidgetCenter.shared.reloadAllTimelines()`

### 5-4. タップ

写真右下の小さな肉球は、未押下で輪郭、押下済みで塗りつぶしとする。`Button(intent:)`でApp Groupの好き状態を原子的に切り替え、再タップで解除する。処理中の肉球へ`invalidatableContent()`を適用し、成功後にtimelineをreloadする。写真アプリの`isFavorite`は変更しない。

肉球以外の領域をタップすると、従来どおり `nekowidget://photo?id=<encoded localIdentifier>` でアプリを開き、対象写真の詳細を表示する。

Build 6では唯一の写真源「うちの子」に対して、自分の猫の好きストアを切り替える。将来「他人の猫」など別写真源を追加する前に写真源別action policyを実装し、同じ肉球をそのまま自分の本へ保存しない。専用の保存先・文言・Deep Link・計測定義が決まるまでは、その写真源で肉球を表示しない。

## 6. スキャンと猫検出

### 6-1. 段階スキャン

```text
第1段階：新しい順に最大500枚を解析しながら速報表示
第2段階：アプリがactiveな間に残りをバッチ解析し、進捗表示
第3段階：次回起動以降は未解析・新規写真を優先
```

- 全件完了前の数値には「速報」と表示
- 全件完了後だけ「確定」と表示
- バックグラウンド移行時は安全に中断し、次回起動時に再開
- バッチごとにメモリを解放する

### 6-2. 検出条件

- `VNRecognizeAnimalsRequest`
- labelがcatの観測だけを採用。犬は除外
- confidence 0.7以上（設定変更可）
- 長辺約1024pxの縮小画像で解析
- 猫のbounding box合計領域が画像の8%以上（設定変更可）
- `.photoScreenshot` を除外
- 動画を除外
- 同一 `burstIdentifier` から1枚だけ

### 6-3. iCloudと権限

- スキャン時は `PHImageRequestOptions.isNetworkAccessAllowed = false`
- ローカルに画像がないassetは未解析として記録し、後回し
- limited、denied、権限取消、asset削除でクラッシュしない
- limited時は `presentLimitedLibraryPicker` への導線を表示

## 7. アプリ内クロップとWidget合成

猫中心クロップはアプリ内表示だけに適用する。PhotoKitの元写真、写真シャッフル、Widgetの前景には適用しない。

1. 猫観測のbounding boxを取得
2. 複数匹の場合は全boxのunionを使う
3. unionの中心を出力中心に寄せる
4. 適切な余白を加える
5. 画像端を超えたら内側へ移動
6. アプリ内表示へ反映する

Widgetは各familyの専用canvasへ、同じ元写真から「ぼかしたaspect-fill背景＋鮮明なaspect-fit前景」を本体アプリで事前合成する。Widget Extensionは完成済みJPEGを現在の1枚だけデコードし、実行時にクロップやぼかしを行わない。

SaliencyはP2。

## 8. 選別

```text
候補 = 検出条件を通過した猫写真
     - 直近30日に表示した写真

重み：
アプリ内liked       3倍
PHAsset.isFavorite  2倍
burst代表           1.5倍
```

候補から重み付きランダムで選ぶ。候補が尽きた場合だけ30日制限を外す。v1では日付・場所・姿勢などの高度な軸は追加しない。

## 9. データ

App Group内のJSONを正本とする。最低限、次を保持する。

- `schemaVersion`
- assetの `localIdentifier`, `creationDate`, `isFavorite`, `isScreenshot`, `burstIdentifier`
- 検出状態（detected / rejected / unavailable / failed）
- confidence、全猫を含むunion boundingBox、catCount、areaRatio
- `liked`, `likedAt`, `lastShownAt`, `shownCount`
- スキャンの総数、処理数、猫数、最古日、速報/確定、最終スキャン時刻
- 作成したアルバムのlocalIdentifier
- App設定
- Widgetとアプリで共有する好きの最新状態、Build 6計測開始日時、開始時枚数、押下／解除イベント履歴

写真本体は保存しない。例外はApp Group内の消去可能なサイズ別ウィジェットキャッシュ（Small 400×400px、Medium 800×374px、Large 400×420px、各50KiB以下）のみ。

JSONエクスポートでは、App Groupの正本と同じ情報に加え、detected母集団から決定論的に抽出した最大100件の検出精度review queueを書き出す。設定画面のreview queueと単一のsamplerを共有し、`reviewNumber`、順序、metadataを一致させる。写真本体と人手ラベルはJSONへ含めない。

### 9-1. 診断ログ

- アプリ本体とWidget Extensionは、App Group内の同じログ領域へ書き込む
- 複数processの同時追記で壊れないようprocessごとにファイルを分け、画面表示時に時刻順へ統合する
- timestamp、level、category、process、messageと小さなmetadataをJSON Linesで保持する
- `localIdentifier`の全文や写真データは記録せず、必要な場合だけ不可逆な短いtokenにする
- スキャン進捗、Visionの集計、画像のpixel寸法・JPEG byte数、アルバム、Widget cache、timeline、Deep Link、errorを記録する
- ファイル数と容量に上限を設ける
- 設定画面から閲覧、更新、消去、クリップボードコピー、共有ができる

## 10. 優先度

### P0

- limitedを含む写真アクセス
- 段階スキャン、速報値と確定値
- Vision猫検出と主役条件
- 自動アルバム作成・更新
- 写真シャッフル設定・再設定案内
- 今日の1枚
- 「これ好き」と一覧・永続化
- 3サイズのWidget肉球ボタン、好き／解除、処理中表示、App Group共有、操作履歴
- アプリ内表示用の猫中心クロップ
- JSONエクスポート
- Small / Medium / Largeウィジェット
- 15〜20件の未来タイムライン
- 3サイズ専用canvas、元写真のぼかし背景、各50KiB以下のキャッシュとメモリ対策
- ウィジェットから写真詳細へのDeep Link
- App Group共有の診断ログとアプリ内ログ画面
- TestFlight確認用1024×1024プレースホルダーApp Icon / Asset Catalog
- GitHub Actionsによる無署名コンパイル確認と、手動実行のarchive・export・TestFlight upload

### P1

- PhotoKit change observerによる実行中の差分検知
- UIと統計の改善

### P2 / v2以降

- Saliencyクロップ
- 日付・場所・ポーズ軸
- Siri / ショートカットへ公開するApp Intent（Widget専用の非公開IntentはP0）
- 家族共有、同期、サーバー

## 11. 受け入れ条件

1. 起動後10秒以内に猫の速報値と解析進捗が見える
2. 全件完了後に確定値と最古日へ切り替わる
3. limitedでもクラッシュせず、「もっと選ぶ」が使える
4. 「うちの子」アルバムが作られ、選別済み写真が入る
5. 写真シャッフルの設定手順と、アルバム更新後に再設定が必要なことが表示される
6. screenshot、動画、面積比未満の猫、burst重複が候補に入らない
7. 好きが一覧へ蓄積し、再起動後も残る
8. JSONを書き出せる
9. 3サイズの専用画像が表示され、元写真全体と同じ写真のぼかし背景が見え、黒帯や二重クロップがない
10. 大きな原写真があってもウィジェットがクラッシュしない
11. タイムラインが15〜20件を先読みし、数十分単位でbest effortに切り替わる
12. ウィジェットタップで該当写真の詳細が開く
13. アプリとWidgetの主要イベントが同じログ画面で時刻順に読め、コピー・共有・消去できる
14. App Iconを含むarchiveを作成できる
15. GitHub Actionsで無署名buildを実行でき、署名Secretsを設定した手動workflowでTestFlightへ送信できる
16. 3サイズの肉球を押してもアプリが開かず、好き状態が輪郭／塗りつぶしで反映される
17. 肉球を再タップすると解除され、肉球以外をタップすると従来の写真詳細が開く
18. アプリを開くと好きの総数と押した日時が分かり、Build 6開始後の操作履歴を1週間分集計できる
19. 全件確定後に検出精度サンプル最大100枚を写真全体で確認でき、reviewNumberと撮影日時が検証JSONに一致し、機械判定値はレビュー画面に出ない

写真シャッフルがアルバム更新を自動追従することは、受け入れ条件に含めない。

## 12. やらないこと

- 課金・サブスク
- サーバー通信・家族共有・同期
- 写真原本の複製または変更
- フォトブック・物販
- 個体別クラスタリング
- Live Photo、動画、深度、OCR、音声
- 猫の健康判定
- ロック画面アクセサリウィジェット
- Siri / ショートカットへ公開するApp Intent（Widget専用の非公開Intentは除く）
- テストコード

## 13. ビルドと実機確認

コード生成環境がWindowsの場合、Xcodeビルド、署名、Simulator、PhotoKit、WidgetKit、写真シャッフルは検証できない。Mac上のXcodeで次を行う。

1. Apple Development Teamを本体とWidgetの両targetへ設定
2. Bundle Identifierを一意な値へ変更
3. App Group Identifierを一意な値へ変更し、両targetで同一Groupを有効化
4. 実機で写真アクセス（full / limited）を確認
5. アルバム作成、Widget 3サイズ、Deep Link、メモリ、数時間のtimelineを確認
6. アプリ内ログで本体とWidgetのイベントを確認し、ログを共有して障害解析できることを確認
7. GitHub Actionsの署名Secretsを設定し、手動TestFlight workflowを1回通す
