# ADR-014：FeaturePrintは個体を確定せず、確認回数を減らすために使う

日付: 2026-08-20
状態: 採用

## 背景

多頭プロフィールは写真と猫を多対多で保存できるが、約900枚を1枚ずつ確認する操作は現実的ではない。一方、VisionのFeaturePrintは見た目の近さを比較できても、同じ猫であることを保証する個体識別APIではない。背景、姿勢、成長、似た柄の別猫にも影響されるため、距離だけで所属を確定すると誤分類を永続化する。

目的は自動個体識別ではなく、未確認の猫instanceを約20グループへ整理し、利用者の確認回数を減らすことである。

## 決定

1. 保存済みの個体別cat bounding boxごとにFeaturePrint Revision 2を生成する。多頭写真は写真単位ではなく、猫instance単位で別候補にする。
2. cropは保存済みboxの各辺を10%拡張し、unit rectへclampする。この方針を`cropPolicyRevision = 1`として固定する。
3. 端末内で取得できる画像だけを使い、PhotoKitのnetwork accessは許可しない。iCloud等で取得できないinstanceは未確認のまま残す。
4. 同じassetは一度だけ画像を取得する。FeaturePrint距離から決定的なk-medoidsで最大20グループを作る。
5. グループは提案にすぎない。「全部むぎ」「全部あめ」等を利用者が押した時だけ、その正確な`asset ID + subject bounding box`を1回のidentity CASで保存する。
6. 「混ざってる」は選択中のグループだけを2分割する。分割、後回し、キャンセルはmembershipを変更しない。
7. 1つの確認済みsubjectは最大1つの検出boxと対応させる。重なった複数boxを同時に確認済みとは扱わない。
8. 別プロフィールの所属、世帯全体の除外、明示的な参照写真をグループ確認で変更しない。グループ由来の写真を新しい学習anchorへ昇格させない。
9. 確認画面を開いた後に別画面で所属が変わった場合、保存直前の最新identity stateで未確認かを再検証し、古い提案は拒否する。

## 保存とプライバシー

FeaturePrint observation、距離行列、提案グループ、session IDはメモリ内だけに置き、画面を閉じたら破棄する。`Codable`にせず、App Group、backup、検証JSON、診断ログ、共有protocol、Workerへ出さない。ログに残せるのは処理件数と利用者が明示確定したinstance件数だけで、asset ID、profile名、box、距離、vectorは記録しない。

永続化されるのは、既存の`CatHouseholdIdentityState`へ利用者が明示確定したmembershipだけである。

## 製品上の表現

「同じ猫を自動識別」や確率とは表示しない。「似た写真をまとめて確認」と表現する。精度が不十分なグループは何度でも分割でき、判断できない場合は後回しにできる。確認前の写真は従来どおり「みんな」に残る。

## 検証条件

- 同一入力とpolicy revisionから同じグループを作る
- 約900件に対する既定targetが20グループである
- 1グループを分割しても他グループを変更しない
- 生成、分割、後回し、キャンセルではmembershipが0件も変わらない
- 明示確定だけが、正確なinstance boxを選択プロフィールへ保存する
- 多頭写真で1匹を確認しても、別のboxは未確認に残る
- CAS retry時も最新stateで未確認かを再検証する
- FeaturePrint関連データがJSON、共有、Worker、ログへ入らない
- local image取得でnetwork accessを許可しない
