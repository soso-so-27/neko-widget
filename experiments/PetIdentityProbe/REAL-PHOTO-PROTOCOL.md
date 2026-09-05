# 実写真で2匹を見分ける・事前固定protocol

ID: `pet-identity-onnx-heldout-v1`。2026-09-05、実写の結果を見る前に固定。
目的はCPUの固定モデルが実写評価の次段階へ進めるかを調べること。旧ADR-016のFeaturePrint/HSVのNo-Goは変更しない。本体へ自動識別を実装する合格判定ではない。

## 選ぶ標本

- 2匹を固定ラベルA/Bで扱い、各猫の見本5枚・未使用判定写真15枚、計40枚を別欄で明示選択する。名前の入力は不要。
- 1匹だけが写った写真。20枚は別場面で、時期・明るさ・姿勢を分散させる。旧実験で結果を見た写真や、連写・ほぼ同じ構図を使わない。
- 全体の同一asset重複を拒否。同猫内の同burstまたはexact cropの64bit dHashのHamming距離2以下も、結果計算前に拒否する。dHashは簡易判定で、誤検出・見逃しをゼロにはできない。誤検出と思われても結果前に別場面へ変更し、独立性を自己確認する。
- 撮影時刻の差30秒以下は注意の集計のみで、時刻だけでは重複と決めない。
- 成功結果を見た後は選択をロック。同じ画面内の再評価では使用済IDを拒否する。IDを永続保存しないため、画面を閉じた後や再起動後の再利用は検出できず、未使用かは自己申告となる。結果を見た標本で閾値調整・再合格判定しない。

## 固定した前処理とモデル

- PHPickerからはassetIdentifierのみを受け取り、itemProviderで写真を取得しない。PhotoKitの認可済み選択IDのみをfetchする（限定許可対応、ライブラリ全走査なし）。
- `PHImageRequestOptions.isNetworkAccessAllowed=false`、current版、highQualityFormat、aspectFit、1024pxの取得要求。取得後も長辺1024px以下・scale 1・向き正規化・不透明化する。PhotoKit内部デコードの瞬間的メモリまではこの上限で保証しない。
- [Apple Visionの動物検出](https://developer.apple.com/documentation/vision/vnrecognizeanimalsrequest)revision 2で、Cat confidence 0.5以上が1件だけある写真を使用。exact bboxを画像内へclipし、最小32×32pxを要求。複数検出・検出不能を無理に選ばない。検出器の見逃しもあり得るため、1匹のみという利用者の確認は必要。
- cropを224×224へresize（縦横はモデル入力に合わせる）、sRGB・RGB CHW・float32、mean `[0.485,0.456,0.406]`、std `[0.229,0.224,0.225]`。合成RGB fixtureで色順・上下方向を検査する。
- ORT 1.24.2、CPU intra-op 2 threads、既存の固定batch-1モデルSHA `32adffda4e65f790ae624d828b79db7a18f7fdb1facdce1cc91bb9951d948c0b`。モデルサイズ/ハッシュは合成ベンチと共通コードで検証する。
- 512次元・有限値・L2誤差0.005以内を確認。ONNX実行自体の異常は中止し、識別の「保留」に見せかけない。

## 分類と判定（結果を見る前に固定）

- 距離は再L2正規化したfloat64ベクトルの`1-clamp(dot,-1,1)`。
- 各猫のscoreは見本5枚への距離の小さい3つの中央値。
- 各猫の半径は見本1枚ずつを抜き、残り4枚への近い3距離の中央値を計5つ求め、その中央値。評価用写真や正解を半径に使わない。
- 最良scoreがその猫の半径×1.25以下、かつ最良/次点scoreが0.70以下の両方を満たす時だけ予測。tie、半径0、次点0、条件外はunknown。
- 見本の読込・検出失敗は計測中止。判定写真の読込・検出失敗はunknownとして固定の30枚に残し、都合よく除外・差し替えない。
- 全体と猫別correct/wrong/unknown、2×3混同行列を出す。探索候補の基準は`correct*100 >= assigned*95`かつ`assigned*100 >= 30*70`。assigned 0は不合格。丸めた百分率で合格にしない。
- `productValidated=false`を常に出す。少数写真の探索であり、合格でも別家庭・未使用標本による評価、最低対応機負荷、権利確認、手動より確認の手間が減るかが別途必要。ADR-016の一般提供前の独立trial基準は維持する。

## 保存・共有・中断

写真、ID、撮影日時、burst、crop、dHash、特徴量、個別予測は端末内メモリのみ。モデルsessionと特徴量は処理後に解放し、UIへは小さなサムネイルと個別予測のみ返す。画面離脱・background・取消で結果と選択を消去し、キャンセルした処理の完了が結果を復活させない。

共有JSONはA/Bの件数と混同行列、固定protocol/model/runtime/前処理、OS、時刻近接ペア件数、privacy flagsだけ。写真・ID・名前・日時・個別番号/予測・特徴量・距離/半径を含めない。原本、写真アプリへの書込、本体membership、Widget、共有サーバーは変更しない。

権限は専用appの`NSPhotoLibraryUsageDescription`だけを目的文言固定で許可。他のUsageDescriptionとApp Group/APNs/iCloud等の権限拒否は維持する。[PhotoKitの認可モデル](https://developer.apple.com/documentation/photos/phphotolibrary)に従い、許可前や拒否後は読み取りを始めない。
