# 別方式：YOLOX-Nanoの初回機構比較

2026-09-10。追加縮小/分割の改善が確認できないため、別方式として一般物体検出器を1つだけ比較した。本アプリと独立iPhoneアプリへの組み込みはまだない。

## 選定理由と出典

- 第一候補YOLOX-Nano：公式ONNX配布、416×416入力、0.91Mパラメータ。[公式ONNX手順](https://github.com/Megvii-BaseDetection/YOLOX/blob/main/demo/ONNXRuntime/README.md)。既存ORT1.24.2を利用できるので、別の推論runtimeや新しいサーバーを導入しない検討ができる。
- 公式モデルを取得した実サイズ3,659,407 bytes（約3.49MiB）。[配布元](https://github.com/Megvii-BaseDetection/YOLOX/releases/download/0.1.1rc0/yolox_nano.onnx)。今回取得したファイルのSHA256 `c789161ed43c8269fcd4e67c67eeeb4e80c622da2eb296a20bc6007bd18a0b7d`。これは取得内容の固定で、上流が署名付きチェックサムを示したとの意味ではない。
- YOLOXのリポジトリは[Apache-2.0](https://github.com/Megvii-BaseDetection/YOLOX/blob/main/LICENSE)。原文は隣の`YOLOX-LICENSE.txt`に保持する。商用製品への採用時は配布重み・学習データの由来・必要表示を改めて確認し、法的条件まで解決済みとはしない。
- 比較候補YOLO11nは[公式ライセンス案内](https://www.ultralytics.com/license)上、非公開製品/R&DとEnterprise契約の確認が増えるので今回は取得・実行しなかった。精度が低いという判断ではない。

## 実行前に固定した条件

`yolox-fixed-fixtures.py`。生成単猫3枚、75%サイズ・四隅配置12枚、2匹横/縦配置6枚。個人写真のパスを引数で受けず、固定したリポジトリ内の3生成画像のみを読む。

公式例に合わせて、BGR・0〜255・左上配置/余白114・416角、stride8/16/32の出力復号、クラス横断NMS0.45、事前score>0.1、最終score>=0.3、COCOクラス15(cat)。[公式推論例](https://github.com/Megvii-BaseDetection/YOLOX/blob/main/demo/ONNXRuntime/onnx_inference.py)、[前処理](https://github.com/Megvii-BaseDetection/YOLOX/blob/main/yolox/data/data_augment.py)、[復号/NMS](https://github.com/Megvii-BaseDetection/YOLOX/blob/main/yolox/utils/demo_utils.py)。モデル・スコア・NMS・配置を結果に合わせて探索していない。Visionの0.5とは異なる尺度であり同一の意味を持たない。

Windowsの隔離venv、ORT1.24.2 CPUで実行。アプリへの依存追加なし。Pillowの合成処理はUIKitと画素一致しないため、前のVision結果と厳密な同一入力・同一端末比較ではない。ここでの検出数は枠数であり、その位置や実頭数がすべて正しいことの保証ではない。

## 初回結果

| 固定画像 | 結果 |
| --- | --- |
| 単猫15画像 | 14画像でCat枠1、白黒猫・右下配置1画像で枠0。枠2以上は0画像。 |
| 茶色＋白黒・横 / 縦 | どちらもCat枠2 |
| 茶色＋灰色・横 / 縦 | 横は枠2、縦は枠1 |
| 白黒＋灰色・横 / 縦 | 横は枠2、縦は枠1 |

計21画像の処理1.163秒（ロード後・前処理等を含む）。PC測定であり、iPhoneの速度・RAM・発熱の結果ではない。未検出1枚と2匹見落とし2枚を省かない。実写真精度95%達成や既存21枚での改善はまだ主張できない。

元結果はローカル`artifacts/detector-alternative-20260910/fixed-fixtures.json`。ファイルに写真・PhotoKit ID・個体識別特徴量は含まない。モデルとvenvはartifacts内だけに保持し、gitへ含めない。

独立レビューで前処理/復号/NMSの公式例との整合を確認した。枠数だけでは同じ猫の重複検出を除外できないとの指摘を受け、条件不変で生成画像の枠座標と6組の重ね描きだけを追加出力した。主担当の目視では、2枠になった4組はいずれも別々の猫を囲み、残りの縦2組は下側の灰色猫を見落としていた。厳密なIoU正解データや個体識別の成功とはしない。再出力の件数・スコアは初回と一致し、新規の独立標本には加算しない。

追記証拠：`artifacts/detector-alternative-20260910/fixed-fixtures-geometry.json`、`pair-detections.png`。座標はこの固定生成画像だけの診断であり、本人写真の座標を新たに共有する仕様ではない。

## 判断と次の実装境界

**追加の検出方式として、iPhone上で比較する候補にはなる。全置換/本番採用にはまだ不足。**

次は配布済みBuild21を基点に、単独候補の写真だけへの比較に限定する。失敗した分割検出を重ねて組み込まない。
元の猫crop・A/Bの見本/個体識別/距離閾値・保存済み21枚/判断は維持。追加検出が複数枠なら単独候補を控えるだけで、A+Bや所属は自動確定しない。追加検出0/失敗を「1匹と確認済み」と扱わない。
iOS用前処理/復号/座標/NMSと重み・ライセンスを固定し、同じ生成画像でPCとの差を確かめてから既存本人用TestFlightへ進める。本人には保存済み21枚の再比較だけを依頼し、新たな選択/判断の再入力は求めない。
候補の正しさ・有用率・2匹見落としを保存済み判断と照合する。数字が改善しなければ採用せず、同じ検証セットへ閾値を合わせない。独立した採用試験と確認時間の目標は別途残る。
