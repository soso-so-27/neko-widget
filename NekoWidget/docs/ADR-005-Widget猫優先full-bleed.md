# ADR-005：Widgetは写真ではなく猫を切らない

- 状態：承認済み
- 日付：2026-08-16
- 対象：Build 7の猫優先full-bleedと、Build 8の最終解像度・余白修正

> **2026-08-17追記：** Build 7の表示判断は維持するが、1週間計測はLike表示不具合で中断した。Build 8で実ピクセル相当へ高解像度化したところ、20件Timelineの累積描画負荷でMedium / Largeがplaceholder相当になった。画像仕様は維持し、Build 9でTimelineを最大2件へ制限する。[ADR-008](ADR-008-高解像度WidgetのTimeline負荷制限.md)をresource設計の正本とする。

## 背景

Build 5では、写真全体を鮮明なまま残し、family比率で余る領域を同じ写真のぼかしで埋めた。実機のLarge Widgetでは、横写真の上下に常設のぼかし帯が生じ、「カードの中にもう一枚カードがある」ように見えて没入感が不足した。

守るべき価値は「写真を切らない」ことではなく「検出した猫を切らない」ことだった。写真の周辺にある家具、床、壁、人物などはfamily比率へ合わせて切ってよい。

本ADRは、Build 5の判断を記録した[ADR-003](ADR-003-Widget表示品質のBuild5範囲.md)を現行仕様として置き換える。ADR-003は履歴として残す。

## 判断

本体アプリが、既に保存している全猫bounding boxのunionを使ってfamily別JPEGを事前合成する。Widget Extensionは完成済みJPEGを1枚だけデコードし、PhotoKit、Vision、クロップ、ぼかしを実行しない。

Build 7で採用した共通仕様は次のとおりだった。

- Small：400×400px
- Medium：800×374px
- Large：400×420px
- 各JPEG：50KiB以下
- 通常表示：鮮明な写真でcanvas全面を埋めるfull-bleed
- 猫の余白：bounding boxの各辺18%。小さなboxでも画像寸法の各辺3%以上
- 複数猫：個別boxではなく、現在保存している全猫unionを使う
- cache algorithm：`cat-aware-full-bleed-v4`

これはBuild 7の履歴として残す。Build 8では構図アルゴリズムを増やさず、出力解像度、byte上限、余白、肉球だけを次の現行値へ更新する。

| family | 出力pixel | JPEG上限 |
| --- | ---: | ---: |
| Small | 500×500 | 100KiB |
| Medium | 1050×500 | 200KiB |
| Large | 1050×1100 | 220KiB |

- Widget cache入力：`2048×2048 / highQualityFormat / networkAccessAllowed=false`
- 猫の余白：bounding boxの各辺8%。小さなboxでも画像寸法の各辺3%以上
- cache algorithm：`cat-aware-full-bleed-v5`
- 肉球：SF Symbolsの`pawprint`ではなく、指球を小さく丸く寄せ、掌球を横長にした共有`CatPawMark`
- cache保持：最大8 generation、最大400ファイル。全ファイルを最大220KiBと置く保守的なdisk上限は約85.9MiB
- Widget側：1枚の推定デコード量が5MiBを超える画像は受理せず、providerは1回のTimelineを最大2件へ制限する

Build 8のCIでは、同じ生成候補に対して余白8%で実際に選んだ経路と、旧18%なら選ばれた経路を影計算する。artifactへ両方のfallback件数を残し、1つの数字の変更で例外ぼかしがどれだけ減ったかを比較する。これは新しいぼかし処理の追加ではない。

### Small / Large

猫unionと8%余白をfamily比率のcropへ収容できる場合は、その全体を残してfull-bleedにする。猫が画像端にいる場合はcrop窓を画像内で移動し、中央cropを優先して猫を切らない。

猫unionと8%余白を物理的に収容できない場合だけ、Build 5の「同じ写真のぼかしaspect-fill背景＋鮮明な元写真全体のaspect-fit」へfallbackする。没入感より全猫保持を優先する例外である。Build 8ではこの既存fallbackを維持するだけで、新しい背景ぼかしや境界処理は追加しない。

### Medium

猫unionと余白を収容できる場合はSmall / Largeと同様に全体を残す。1050:500の横長cropへ収まらない場合もぼかしへfallbackせず、bounding boxの上側35%付近を焦点としてfull-bleedにする。猫の胴体や複数猫の一部が切れることは許容する。これは多くの猫写真で顔がbox上部にあるという単純な幾何学的仮定であり、顔検出ではない。

## 写真編集後の無効化

PhotoKitの`modificationDate`と、その値を取得済みかを示すmarkerを解析recordへ保存する。回転、crop、調整後に日付が変わったassetは古いVision bounding boxを再利用しない。取得済みの正当な`nil`と旧snapshotの欠落を区別するため、`nil`から日付ありへ変わった場合も再解析する。cache identityにはbounding boxと変更日を含め、同じlocal identifierでも古いJPEGを再利用しない。

旧snapshotには変更日がないため、アップグレード直後だけ既存解析を信頼して現在値を記録する。これにより8,861枚を一斉再解析せず、以後の編集を検出できる。

## 今回行わないこと

- Subject Lifting
- saliency
- 猫の顔、目、姿勢の検出
- 写真的な三分割法や美的構図の評価
- Mediumで全猫を必ず救う高度な再構図
- Mediumの2枚表示
- 肉球ボタンが猫へ重ならないようにする被写体回避
- 新しい背景ぼかし方式
- 日付、場所、個体などの新しい選別軸
- 共有機能

Build 8で画像構図と写真詳細体験の改善を打ち止めとする。Build 9は高解像度Timelineのresource負荷だけを修復し、実機ゲート後に1週間の行動計測を新しいbaselineから始める。ローカル派生画像probeは1週間後のInternal Build 10へ送り、採用時のproduction反映はBuild 11以降とする。主観的にApple Photosより美しくないことだけを理由に再実装しない。

## 受け入れ条件

- 通常経路ではSmall / Medium / Largeの端まで鮮明な写真が入り、黒帯・空白・常設ぼかし帯がない
- Small / Largeは猫union＋8%余白を収容可能な限り切らない
- Small / Largeで収容不能な場合だけ、猫全体を残すぼかしfallbackになる
- Mediumは収容不能でもfull-bleedを維持し、bboxの上側を焦点にする
- Vision座標の上下反転、写真の回転・伸長・縦横比破壊がない
- 3 familyが500×500／1050×500／1050×1100で、JPEGが100／200／220KiB以下となり、最大20件のmanifest、App Group leaseと原子的publishを維持する
- source requestが2048×2048で、Widgetは1枚を5MiB以下、最大2件のTimeline合計をfamilyごとに10MiB以下でデコードする
- cacheが8 generation／400ファイル、保守的に約85.9MiB以下で上限管理される
- cache生成ログにalgorithmとfull-bleed／上寄り／fallbackの生成件数、8%と旧18%のfallback比較を残す
- `CatPawMark`が約20pxで猫の肉球として見え、未押下／押下済みを輪郭／塗りつぶしで区別できる
- CI artifactへ検出された全fixtureのSmall / Medium / Large JPEGと対応indexを保存し、weighted順序に依存せず目視できる
