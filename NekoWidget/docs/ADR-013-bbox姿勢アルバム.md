# ADR-013：姿勢アルバムは猫の検出枠の縦横比で作る

日付: 2026-08-20
状態: 採用

## 背景

関節点ベースの姿勢分類は、実機896枚のうち猫と骨格を対応付けられた730枚に対し、関節品質を通過したのが83枚、最終分類が1枚だった。閾値を一括で緩めると誤分類を増やすため、製品アルバムの判定には使わない。

一方、猫検出時の個体別bounding boxは既存写真896枚すべてで利用できた。保存済みboxの正規化座標における `width / height` は、次の分布を再スキャンなしで作れる。

- `2.0以上`: ねむってる
- `0.9以上1.1以下`: まるまり
- `0.9未満`: おすわり
- `1.1より大きく2.0未満`: 分類しない

## 決定

1. 関節点を姿勢アルバムの判定に使わない。
2. `VNDetectAnimalBodyPoseRequest` と再試行導線を廃止する。
3. 新規スキャンでは `VNRecognizeAnimalsRequest` が返した個体別bounding boxを保存する。
4. 既存データは、保存済み `postureInstances[].boundingBox` を個体別boxへローカル移行する。単頭写真だけはunion boxをfallbackにできる。多頭写真のunion boxは使わない。
5. アルバム所属は表示時に保存済みboxから導出し、移行のためにPhotoKitやVisionを再実行しない。
6. 「みんな」では、写真内の各猫を個別に分類する。同じ写真の猫が異なるbucketなら複数アルバムへの所属を許す。
7. 個体プロフィールでは、membershipのsubject boxと対応した猫だけを分類する。多頭写真で対象を特定できない場合は推測しない。

## 比率の意味

この版は実測時と同じ、Vision正規化座標の `width / height` を `vision-normalized-width-height-v1` として固定する。画像のピクセル縦横比は補正しない。ピクセル比を後から混ぜると確認済み分布と閾値の意味が変わるため、変更する場合は別versionとして再計測する。

## 互換性

旧 `CatPostureTag`、姿勢診断、pose instanceのCodable fieldは過去snapshotを復号するため残すが、現行のアルバム生成には使わない。旧 `postureRepair` は読込時に解除し、新たなscan purposeとして起動しない。

## 検証条件

- 境界値 `0.9 / 1.1 / 2.0` が上記仕様どおりである
- 個体別boxがある場合はそれを最優先する
- 多頭unionを個体boxとして使わない
- profileのsubject box不一致時に推測しない
- 旧snapshotがローカル移行だけでcurrentになる
- body-pose requestがscannerへ再導入されていない
- bboxアルバムがsecondary analysisの完了状態に依存せず表示される
