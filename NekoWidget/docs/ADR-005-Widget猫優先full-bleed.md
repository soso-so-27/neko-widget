# ADR-005：Widgetは写真ではなく猫を切らない

- 状態：承認済み
- 日付：2026-08-16
- 対象：1週間計測を始めるBuild 7の最終Widget表示修正

## 背景

Build 5では、写真全体を鮮明なまま残し、family比率で余る領域を同じ写真のぼかしで埋めた。実機のLarge Widgetでは、横写真の上下に常設のぼかし帯が生じ、「カードの中にもう一枚カードがある」ように見えて没入感が不足した。

守るべき価値は「写真を切らない」ことではなく「検出した猫を切らない」ことだった。写真の周辺にある家具、床、壁、人物などはfamily比率へ合わせて切ってよい。

本ADRは、Build 5の判断を記録した[ADR-003](ADR-003-Widget表示品質のBuild5範囲.md)を現行仕様として置き換える。ADR-003は履歴として残す。

## 判断

本体アプリが、既に保存している全猫bounding boxのunionを使ってfamily別JPEGを事前合成する。Widget Extensionは完成済みJPEGを1枚だけデコードし、PhotoKit、Vision、クロップ、ぼかしを実行しない。

共通仕様は次のとおり。

- Small：400×400px
- Medium：800×374px
- Large：400×420px
- 各JPEG：50KiB以下
- 通常表示：鮮明な写真でcanvas全面を埋めるfull-bleed
- 猫の余白：bounding boxの各辺18%。小さなboxでも画像寸法の各辺3%以上
- 複数猫：個別boxではなく、現在保存している全猫unionを使う
- cache algorithm：`cat-aware-full-bleed-v4`

### Small / Large

猫unionと余白をfamily比率のcropへ収容できる場合は、その全体を残してfull-bleedにする。猫が画像端にいる場合はcrop窓を画像内で移動し、中央cropを優先して猫を切らない。

猫unionと余白を物理的に収容できない場合だけ、Build 5の「同じ写真のぼかしaspect-fill背景＋鮮明な元写真全体のaspect-fit」へfallbackする。没入感より全猫保持を優先する例外である。

### Medium

猫unionと余白を収容できる場合はSmall / Largeと同様に全体を残す。800:374の横長cropへ収まらない場合もぼかしへfallbackせず、bounding boxの上側35%付近を焦点としてfull-bleedにする。猫の胴体や複数猫の一部が切れることは許容する。これは多くの猫写真で顔がbox上部にあるという単純な幾何学的仮定であり、顔検出ではない。

## 写真編集後の無効化

PhotoKitの`modificationDate`と、その値を取得済みかを示すmarkerを解析recordへ保存する。回転、crop、調整後に日付が変わったassetは古いVision bounding boxを再利用しない。取得済みの正当な`nil`と旧snapshotの欠落を区別するため、`nil`から日付ありへ変わった場合も再解析する。cache identityにはbounding boxと変更日を含め、同じlocal identifierでも古いJPEGを再利用しない。

旧snapshotには変更日がないため、アップグレード直後だけ既存解析を信頼して現在値を記録する。これにより8,861枚を一斉再解析せず、以後の編集を検出できる。

## 今回行わないこと

- Subject Lifting
- saliency
- 猫の顔、目、姿勢の検出
- 写真的な三分割法や美的構図の評価
- Mediumで全猫を必ず救う高度な再構図
- 肉球ボタンが猫へ重ならないようにする被写体回避

この修正の受け入れ後、Widget表示の改善は打ち止めとし、Build 7で1週間の行動計測を始める。Build 8のローカル派生画像probeは計測中に開発・CIまで進めるが測定端末へインストールせず、1週間後に実行する。主観的にApple Photosより美しくないことだけを理由に再実装しない。

## 受け入れ条件

- 通常経路ではSmall / Medium / Largeの端まで鮮明な写真が入り、黒帯・空白・常設ぼかし帯がない
- Small / Largeは猫union＋余白を収容可能な限り切らない
- Small / Largeで収容不能な場合だけ、猫全体を残すぼかしfallbackになる
- Mediumは収容不能でもfull-bleedを維持し、bboxの上側を焦点にする
- Vision座標の上下反転、写真の回転・伸長・縦横比破壊がない
- 3 familyの寸法、50KiB上限、15〜20件のtimeline、App Group leaseと原子的publishを維持する
- cache生成ログにalgorithmとfull-bleed／上寄り／fallbackの生成件数を残す
- CI artifactへ検出された全fixtureのSmall / Medium / Large JPEGと対応indexを保存し、weighted順序に依存せず目視できる
