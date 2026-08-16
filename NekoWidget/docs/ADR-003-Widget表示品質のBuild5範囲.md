# ADR-003：Widget表示品質のBuild 5範囲

- 状態：承認済み
- 日付：2026-08-16
- 対象：TestFlight Build 5

## 背景

実機のホーム画面で、Apple標準の写真表示は被写体の配置と背景処理がきれいで、Build 4のWidgetは全familyで同じ400×400px画像を使うため見劣りした。一方、この製品がWidgetで担う価値はAppleより美しく眺めることではなく、写真をタップしてアプリを開き「これ好き」を蓄積するループである。

## 判断

Build 5では、Widgetが消されない品質へ最短で到達するため、次の2点だけを実装する。

1. Small 400×400px、Medium 800×374px、Large 400×420pxのfamily別専用画像
2. 同じ元写真をaspect-fillしてぼかした背景と、元写真全体をaspect-fitした鮮明な前景の事前合成

各JPEGは50KiB以下とし、App Groupへ消去可能な派生cacheとして保存する。Widget ExtensionはPhotoKit、Vision、クロップ、ぼかしを実行せず、現在表示する1枚だけを最大800pxでデコードする。

## 今回行わないこと

- Subject Lifting
- saliency
- 猫の顔、目線、姿勢を使う構図理解
- Widget用の猫bounding box再クロップ
- ロック画面用accessory widget

これらは3サイズ専用画像とぼかし背景を実機で確認した後、必要性を判断する。

## 役割分担

- 眺める：Appleの壁紙／写真シャッフル
- 押して行動する：本アプリのWidgetから写真詳細と「これ好き」へDeep Link

WidgetはAppleと美しさで競わず、「消されない表示品質」と行動導線を受け持つ。

## 受け入れ条件

- Small、Medium、Largeがそれぞれ専用比率で表示される
- 鮮明な前景では元写真全体が見える
- 余白が同じ写真のぼかし背景で埋まり、黒帯にならない
- 意図しない二重クロップや、ぼかしだけの表示がない
- 各cacheが指定寸法のJPEGで50KiB以下
- TimelineEntryは参照だけを持ち、Extensionが表示中の1枚だけをデコードする
- Widgetタップから該当写真の詳細と「これ好き」を開ける

## 検証上の留意点

既存の1,000枚スケールテストで得た76.147MiBはスキャン処理の生涯ピークであり、Build 5の最終Widget cache合成後までsamplingした値ではない。無料のスケールテストは再実行せず、通常のSimulator smokeで3サイズの寸法、50KiB上限、最終scan後のcache生成順を確認する。実機では3サイズを同時に配置し、Extensionが現在の1枚だけをデコードしてクラッシュや継続的なメモリ増加がないことを観察する。
