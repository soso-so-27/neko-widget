# ねこのまど v1 実装指示書（Codex向け・改訂版）

発行：2026-08-15
改訂：2026-08-17（Build 10の標準ページングと計測分離開発を反映）

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
2. 猫中心のクロップは **アプリ内表示とWidget派生cache** に適用する。Widgetはfamily別canvasを写真でfull-bleedにし、検出済みの全猫unionと余白を守る。PhotoKitアルバムには元のPHAsset参照を入れ、壁紙のクロップはOSに任せる。
3. バックグラウンド処理は **best effort**。v1はアプリ起動時・フォアグラウンド時の同期を確実に行えばよい。
4. 初回表示は **速報値と確定値を分離**。最新500枚の処理中から速報を表示し、全件完了後に総数と最古日を確定する。
5. 写真シャッフルのアルバム追従はしないことが実機で確認済み。自動追従を受け入れ条件に含めない。

### 1-4. Build 5のWidget表示品質

- 眺める体験はAppleの壁紙、タップして「これ好き」へ進む体験はWidgetが担う。
- AppleとSubject Liftingや構図理解で競わず、v1ではサイズ別専用画像と背景ぼかしだけを追加する。
- **履歴・Build 8で廃止：** Build 5当時はSmall 400×400px、Medium 800×374px、Large 400×420px、各JPEG 50KiB以下だった。現行値として実装へ参照しない。
- 鮮明な前景には元写真全体をaspect-fitし、同じ写真をaspect-fillしてぼかした背景で余白を埋める。
- Subject Lifting、saliency、猫boxによるWidget内の再構図は、この結果を実機で確認してから再検討する。
- 判断記録は `docs/ADR-003-Widget表示品質のBuild5範囲.md` に残す。

Build 5の実機確認後、常設のぼかし帯が没入感を損なうと判定した。現行の最終方針は1-7および `docs/ADR-005-Widget猫優先full-bleed.md` とし、本節はBuild 5の履歴として残す。

### 1-5. WidgetKitの制約

サードパーティウィジェットはロック解除ごとの更新を保証できない。manifestは最大20件を保持するが、高解像度化後は1回のタイムラインを現在＋次の最大2件に制限する。既定20分間隔で切り替え、次々境界を`.after(...)`で要求する。表示時刻はOS裁量でありbest effort。

### 1-6. Build 6の「これ好き」計測（撤回済み実験の履歴）

- Build 5は表示品質と配布の技術検証専用とし、1週間計測には含めない。
- Build 7ではWidget再配置、3サイズの表示・肉球操作とランダム100枚を確認した。`reviewNo 74`だけを製品候補から除外し、99 / 100を採用した。
- Build 7で始めた1週間計測は、WidgetのLikeがアプリ総数・一覧へ再スキャンまで反映されない不具合のため2026-08-17に中断した。中断値を製品判断へ使わない。
- 同じ2026-08-17に、結果が製品判断を変えないため再計測自体を撤回した。新しいbaselineから再開せず、計測を理由に端末へのbuild導入を制限しない。
- Widget右下の肉球から、アプリを開かずに好き／解除を記録する。
- 撤回前に保存した開始日時、開始時枚数、操作履歴は移行と検証JSONの互換性のため読み取り可能なまま残すが、新しい計測を開始せず、新しい操作を1週間計測eventへ追加しない。検証JSONは`experimentStatus=withdrawn`、`eligibleForProductDecision=false`、`historyIsComplete=false`を明示する。
- 判断記録は `docs/ADR-004-Widget肉球ボタンとBuild6計測.md` に残す。

### 1-7. Widget表示の最終方針

- 守るのは「写真を切らない」ことではなく「猫を切らない」こと。写真周辺はfamily比率へ合わせて切ってよい。
- Build 7の18%は履歴とし、Build 8ではbounding box unionへ各辺8%、最低でも画像各辺3%の余白を加える。Small / Largeは収容可能ならsharp full-bleedにする。
- Small / Largeで猫union＋余白を物理的に収容できない場合だけ、元写真全体＋同写真のぼかし背景へfallbackする。
- Mediumは収容不能でもbbox上側35%付近を焦点にfull-bleedを維持し、猫全体が切れることを許容する。
- Build 8ではsource 2048×2048からSmall 500×500／100KiB、Medium 1050×500／200KiB、Large 1050×1100／220KiBを作り、SF Symbolsではなく共有`CatPawMark`を使う。
- Subject Lifting、新しい背景ぼかし、Medium 2枚化、saliency、顔・目・姿勢・美的構図理解、新しい選別軸は実装しない。Build 9では画像構図を変えずTimeline負荷だけを直し、Build 10では写真ブラウザの標準ページングだけを直す。ローカルアルバムと招待制共有は[ADR-009](docs/ADR-009-ローカルアルバムと招待制共有.md)に従い、アルバムから順に進める。
- 判断記録は `docs/ADR-005-Widget猫優先full-bleed.md` に残す。

### 1-8. iCloud Deferredの検証順序

- 実機の`unavailableLocally` 2,586件は「1024px high-quality requestをnetworkなしで満たせない」であり、低解像度ローカル派生もないとは断定しない。
- Build 10にはiCloud downloadもscanner request変更も入れない。
- 1週間計測の待機条件と測定端末へのinstall制約はない。paired probeは専用Internal buildの準備後に同じ端末でも実行でき、採用時だけ後続のproduction buildへ反映する。
- Probe用の技術検証buildでは通常`AppViewModel`を生成せず本番snapshotを変更しない専用rootを使い、Screenshot／burst除外方針を固定した同じ対象へ`512×512 / aspectFit / fastFormat / resizeMode=fast / version=current / network=false`でpaired probeする。fastFormatでは非nilのdegraded画像も最終結果として受理する。
- 旧解析済み集合の陽性保持率、旧Deferredの回収／新規猫、bbox IoU／中心移動、実出力pixelを分けて報告する。総猫数だけで判定しない。
- Widgetは最大1050×1100を含むため512pxへ一律変更しない。scanner probe後に現行2048px high-qualityをbaselineとして、非同期fast／local-onlyの2048px要求、nil／inCloud時の1100px要求、degraded非nil受理を別評価する。
- 同意なしの一括downloadは行わない。ローカル派生でも残る件数に限り、通信量の概算方法と明示同意を設計する。
- 判断記録は `docs/ADR-006-iCloudローカル派生画像の検証.md` に残す。

### 1-9. Build 8の計測修復、Build 9のTimeline修復、Build 10の標準ページング

- 製品表示名とApp Store Connectのアプリ名はどちらも`ねこのまど`とする。App Store Connectの既存レコード名はコード変更とは別に手動確認する。
- Widget App IntentはApp GroupのLikeストアへ原子的に保存する。アプリは起動、フォアグラウンド復帰、Deep Link時にLikeストアを読み、更新済みsnapshot全体を再代入してSwiftUIへ通知する。再スキャンを表示同期の条件にしない。
- 実機ゲートは、Widget肉球ON→アプリを開く（手動スキャン操作なし）→総数+1／一覧／likedAt、Widgetへ戻りOFF→アプリで総数-1／一覧から消える、の順で行う。診断ログのLike同期がscan startより前であることも確認する。これは計測開始条件ではなく、Like同期の通常の機能ゲートである。
- Build 9はmanifest最大20件を維持し、providerが時刻anchor基準の最大2件だけを返す。Build 10は写真ブラウザをOS標準ページングへ直し、ページ集合の入れ替えによる操作感悪化を解消する。CIの1枚5MiB／family別2件10MiBは静的予算であり、Widget Extension全体の実peak 30MiB未満を保証しない。実機ではSmall→Medium→Largeを段階配置し、20分切り替え、次pair取得、肉球操作でplaceholder化・再読込ループ・クラッシュがないこと、写真ブラウザが898件でも初期表示で固まらないこと、TestFlight crash／iOS AnalyticsにJetsamがないことを確認する。
- Build 10の写真ブラウザが固まる場合は待機せず、`LazyHStack`と標準pagingを含む開発branchのbuildを同じ端末へ入れ、[ADR-010](docs/ADR-010-大規模写真ブラウザの遅延ページング.md)の実機ゲートを実行する。
- 判断記録は `docs/ADR-007-Build8計測修復と最終UX.md` と `docs/ADR-008-高解像度WidgetのTimeline負荷制限.md` に残す。

## 2. 技術方針

- Swift / SwiftUI / Xcode
- Deployment Target: iOS 17.1
- 独自サーバー、外部API、外部ライブラリなし。解析はオンデバイスで行う。本体UIの個別写真表示はPhotoKit経由でiCloudへアクセスし得るが、scannerとWidget cacheの一括処理はユーザー同意なしにnetwork downloadしない
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
- 全件確定で猫0件なら、猫写真を追加する／写真アクセスを確認する／再スキャンする、の次の行動を示し、故障や無限処理中に見せない

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
- manifestは最大20枚の候補を保持するが、1回のtimelineで返す未来エントリは最大2件に制限する
- 間隔は10〜30分、既定20分
- manifest先頭日時をanchorにした時刻moduloで現在と次の候補を選び、2件目の表示区間が終わる次の境界を`.after(...)`で要求する。reload遅延や肉球操作でcadenceを後ろへずらさない
- exactな更新時刻は保証せずbest effort

### 5-3. メモリ対策

- ウィジェット側でPhotoKit / Vision / クロップ処理を実行しない
- 本体アプリが2048×2048のlocal-only high-quality入力から、Small 500×500px／100KiB以下、Medium 1050×500px／200KiB以下、Large 1050×1100px／220KiB以下の専用canvasを作る
- 通常は検出済み猫union＋余白を基準に、鮮明な写真をfamily比率へfull-bleed cropする
- Small / Largeで猫union＋余白を収容不能な場合だけ、ぼかしaspect-fill背景＋元写真全体のaspect-fitへfallbackする
- Mediumは収容不能でもbbox上側を焦点としたsharp full-bleedを維持する
- App Groupにはmanifestと画像ファイル名を保存
- TimelineEntryにJPEG DataやUIImageを保持しない
- WidgetKitはtimeline受理時に未来entryをすべて評価し得るため、Viewのlazy評価を前提にしない
- 1枚の推定デコード量を5MiB以下にguardし、最大2件のfamily別合計を10MiB以下にする。Largeは実機row alignment込みで約4.41MiB／枚、約8.83MiB／2件
- cacheは最大8 generation／400ファイルとし、全件220KiBと置いた保守的なdisk上限を約85.9MiBに抑える
- manifestとキャッシュは原子的に更新する
- データ更新後に `WidgetCenter.shared.reloadAllTimelines()`

### 5-4. タップ

写真右下の小さな肉球は、未押下で輪郭、押下済みで塗りつぶしとする。Build 8ではSF Symbolsの`pawprint`ではなく、指球を小さく丸く寄せ、掌球を横長にした共有`CatPawMark`を約20pxで使う。`Button(intent:)`でApp Groupの好き状態を原子的に切り替え、再タップで解除する。処理中の肉球へ`invalidatableContent()`を適用し、成功後にtimelineをreloadする。写真アプリの`isFavorite`は変更しない。

肉球以外の領域をタップすると、`nekowidget://photo?id=<encoded localIdentifier>&shownAt=<encoded date>`でアプリを開く。詳細では写真を大きく表示し、左右スワイプ、肉球、撮影日、「この日の写真をすべて見る」、約20分ごとの切り替えと最後に変わった時刻を示す。任意に進める「次へ」ボタンは置かない。

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
- 現行の1024px high-quality local-only requestで取得不能なassetは未解析として記録し、後回しにする。低解像度ローカル派生も存在しないとはprobe前に断定しない
- limited、denied、権限取消、asset削除でクラッシュしない
- limited時は `presentLimitedLibraryPicker` への導線を表示

## 7. アプリ内クロップとWidget合成

猫中心クロップはアプリ内表示とWidgetの消去可能な派生cacheだけに適用する。PhotoKitの元写真と写真シャッフルは変更しない。

1. 猫観測のbounding boxを取得
2. 複数匹の場合は全boxのunionを使う
3. unionの中心を出力中心に寄せる
4. 適切な余白を加える
5. 画像端を超えたら内側へ移動
6. アプリ内表示へ反映する

Widgetは全猫union＋余白を基準にfamily比率のfull-bleedを本体アプリで事前合成する。Small / Largeの収容不能時だけ同じ写真のぼかし背景＋鮮明なaspect-fitへfallbackし、Mediumはbbox上側へ寄せてfull-bleedを維持する。Widget Extensionは完成済みJPEGだけをデコードし、実行時にクロップやぼかしを行わない。WidgetKitが未来entryを評価する前提で、1回のTimelineは最大2件に制限する。

Subject Lifting、saliency、顔・目・姿勢・美的構図理解は実装しない。

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
- assetの `localIdentifier`, `creationDate`, `sourceModificationDate`, `sourceModificationDateWasCaptured`, `isFavorite`, `isScreenshot`, `burstIdentifier`
- 検出状態（detected / rejected / unavailable / failed）
- confidence、全猫を含むunion boundingBox、catCount、areaRatio
- `liked`, `likedAt`, `lastShownAt`, `shownCount`
- スキャンの総数、処理数、猫数、最古日、速報/確定、最終スキャン時刻
- 作成したアルバムのlocalIdentifier
- App設定
- Widgetとアプリで共有する好きの最新状態。撤回前の計測開始日時、開始時枚数、押下／解除イベント履歴は保存互換のため読み取り専用で維持する

写真本体は保存しない。例外はApp Group内の消去可能なサイズ別ウィジェットキャッシュ（Small 500×500px／100KiB以下、Medium 1050×500px／200KiB以下、Large 1050×1100px／220KiB以下）のみ。

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
- 3サイズのWidget肉球ボタン、好き／解除、処理中表示、App Group共有、最新状態と`likedAt`（撤回済み計測eventは新規記録しない）
- アプリ内表示用の猫中心クロップ
- JSONエクスポート
- Small / Medium / Largeウィジェット
- 最大20件のmanifestと、時刻基準で最大2件だけを公開する未来タイムライン
- 3サイズ専用canvas、猫優先full-bleed、例外時だけの既存ぼかしfallback、100／200／220KiB以下のキャッシュとメモリ対策
- ウィジェットから写真詳細へのDeep Link
- App Group共有の診断ログとアプリ内ログ画面
- 「ねこのまど」C5 Softの1024×1024正式App Icon / Asset Catalog（紙色`#F2E8D5`、墨色`#2A2521`、不透明RGB。形状正本は`docs/design/AppIcon-P1-master.svg`）
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
9. 3サイズの専用画像が通常はsharp full-bleedとなり、Small / Largeは猫union＋余白を守り、Mediumの収容不能時はbbox上側を焦点にし、黒帯や空白がない
10. 大きな原写真があってもウィジェットがクラッシュしない
11. manifest最大20件からタイムラインが現在＋次の最大2件を返し、20分単位でbest effortに切り替わり、次のpairへ進む
12. ウィジェットタップで該当写真の詳細が開く
13. アプリとWidgetの主要イベントが同じログ画面で時刻順に読め、コピー・共有・消去できる
14. App Iconを含むarchiveを作成できる
15. GitHub Actionsで無署名buildを実行でき、署名Secretsを設定した手動workflowでTestFlightへ送信できる
16. 3サイズの肉球を押してもアプリが開かず、好き状態が輪郭／塗りつぶしで反映される
17. 肉球を再タップすると解除され、肉球以外をタップすると従来の写真詳細が開く
18. アプリを開くと好きの総数と押した日時が分かる。撤回済みの1週間計測を開始・リセットするUIは表示しない
19. 全件確定後に検出精度サンプル最大100枚を写真全体で確認でき、reviewNumberと撮影日時が検証JSONに一致し、機械判定値はレビュー画面に出ない
20. Widget肉球ON後に手動再スキャンなしで総数+1、一覧とlikedAtが現れ、OFF後に総数-1、一覧から消える。共有Like同期ログはscan startより前に記録される
21. WidgetはSmall→Medium→Largeの段階配置、切り替え、肉球操作で消失・再読込ループ・クラッシュがなく、各画像の推定デコード量が5MiB以下である。CIの静的予算だけを実peak 30MiB未満の保証とは扱わない

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
- Subject Lifting、新しい背景ぼかし、Mediumの2枚化、新しい選別軸、共有機能
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
