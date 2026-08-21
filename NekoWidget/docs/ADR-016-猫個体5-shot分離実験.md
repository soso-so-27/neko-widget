# ADR-016：猫個体UIより先に5-shot分離を測る

日付: 2026-08-21
状態: Experiment

## 背景

Build 18の「似た写真をまとめて確認」は、約900件を教師なしk-medoidsで最大20群へ強制的に分け、利用者が混在群を繰り返し二分する設計だった。実機では何十回も判断が必要になり、個体分類を完了できなかったためBuild 19で導線を非表示にした。

Build 18は画像全体を比較していたわけではない。保存済みの個体別bboxを各辺10%拡張し、`VNGenerateImageFeaturePrintRequest` Revision 2の`regionOfInterest`へ指定していた。したがって、同じ前処理と教師なし分割を作り直さない。

一方、各猫5枚を明示教師にした分類、1位と2位が近い写真を`unknown`へ退避する設計は未評価である。製品UIや自動所属を作る前に、この家庭の実写真で成立可能性だけを測る。

## 決定

初回実験は2プロフィール、各5枚、合計10枚に限定する。3匹以上では最大10タップという製品条件を超えるため、本実験の結果だけで一般化しない。

同じ10標本で次の3方式を比較する。

1. FeaturePrint Revision 2、個体bboxの各辺を10%拡張（Build 18と同じ前処理）
2. FeaturePrint Revision 2、余白を足さないexact bbox
3. exact bboxのHSV色ヒストグラムとHellinger距離

分類は、対象プロフィールの教師5枚との距離のうち近い3枚の中央値を使う。次の両方を満たさない場合は所属を決めず`unknown`にする。

- 最良プロフィールへの距離が、そのプロフィールの基準半径の1.25倍以内
- 最良距離 ÷ 次点距離が0.70以下

閾値はprotocol v1として計測前に固定する。今回の10枚が良く見えるよう、結果を見た後で値を変更しない。

## 標本

- 各プロフィール5枚は、利用者がすでに明示確認した写真だけを使う
- bboxと現在のdetector instanceが対応できない写真は使わない
- 多頭写真のunion bboxは使わない
- 同一asset、同一burst、30秒以内の撮影、ほぼ同一のcropは同じepisodeとして扱う
- 各プロフィール5つの独立episodeが揃わない場合は計測不能とする
- 同じepisodeを学習側と評価側へ分けないepisode単位leave-one-outを使う

## 出す数字

- methodとprotocol version
- 利用できたプロフィール数、標本数、episode数、取得失敗数
- top-1正解数
- assigned / unknown / wrong
- coverage、FAR、FRR、wrong-assignment rate
- confusion matrixの件数
- 同猫距離／別猫距離の分位点
- 色ヒストグラムの `最小別猫距離 ÷ 最大同猫距離`
- 全候補へ読み取り専用で適用した場合の割当数、unknown数、衝突数

未ラベルの全候補からprecisionやFARを算出してはならない。

## この家庭での次段階GO条件

次をすべて満たす方式だけを次段階へ進める。

- 2プロフィール × 5独立episode
- 個体別bboxが確定している
- 色ヒストグラムの最小別猫距離 ÷ 最大同猫距離が1.5以上
- 色ヒストグラムのleave-one-out top-1が10/10
- 採用方式のwrongが0/10
- coverageが8/10以上、各猫4/5以上
- 未確認候補のinstance coverageとepisode coverageがどちらも50%以上

この10枚では、時期・明るさ・姿勢が異なる写真を選ぶよう利用者へ依頼する。ただし、撮影日時や輝度subsetを集計JSONへ持たせず、この実験だけで「古い／新しい」「暗い／明るい」の網羅を証明したとは扱わない。`featurePrintExact`または`histogramOnly`というdecisionは製品実装のGOではなく、次のラベル付き検証へ進める方式を示すだけである。

個体推定の製品UIを実装する前に、採用候補方式を古い／新しい写真と暗い／明るい写真へ分けた追加標本で検証し、各subsetの誤所属が0件であることを別途確認する。

判断順は次のとおりとする。

1. exact bbox FeaturePrintが通る: 5-shot FeaturePrintを次段階で検討
2. FeaturePrintは落ちるが色が通る: 見た目が十分違う家庭だけ色方式を検討
3. 色のgateが落ちる: 個体推定の入口自体を表示しない
4. どちらも落ちる: 「この家の猫たち」の成長1本で止める

10件で誤り0でも安全な一般精度を証明したことにはならない。一般提供には、家庭を分離した検証集合と、少なくとも300件の独立した別猫trialでfalse accept 0件が別途必要である。

## 実装境界

- 実験は「設定＞詳細・診断」からだけ起動する
- プロフィール画面、猫別アルバム、オンボーディングには導線を出さない
- 実験はmembership、参照写真、除外、ライブラリsnapshotを変更しない
- 自動予測を教師へ戻さない
- 写真取得は`networkAccessAllowed = false`
- FeaturePrint、ヒストグラム、距離行列はメモリ内だけで、終了時に破棄する
- 写真、crop、PhotoKit identifier、プロフィール名／UUID、撮影日時、bbox、個別距離をログ・JSON・共有・Workerへ出さない
- 共有できるのは集計値とGO/NO-GO理由コードだけ

実機数値が出るまでは状態を`Experiment`のままにし、製品UIの実装へ進まない。
