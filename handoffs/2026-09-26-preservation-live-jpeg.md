# 非公開JPEGサーバー：実配備の結果

2026-09-26。個人保管の提供開始・実iPhone試験とは区別する。

## 配備と境界

- 利用者がWorkers Paidへ切替。Containers listが以前のPaid必須拒否から終了0へ変化。
- Dockerの2種の通信ファイル障害は、承認された一時フォルダだけを退避して修復。
  Engine 29.6.1の正常応答を確認。Factory reset、写真/コンテナデータ削除、PC再起動なし。
- 本線採用済みJPEG候補 `e5145bb19a1fd8937f7bd671be01406685fdb1f2` を配備。
  Cloudflare account `829a34ef925a39d81b0e9e08800d7c7f`、Worker
  `neko-preservation-jpeg-disabled`、named entrypoint `JPEGValidationService`。
- application `a03c5de3-1975-472b-bd61-86ea672652cc`、basic 0.25vCPU/1GiB/4GB、
  max_instances=1。公開URLなし。default entrypointは実service呼出で404。
- image digest `sha256:4e078bdfadb63c1dcdee48a39572c7610ba0785f21aab6f1bb1eb7fe82cb2364`。
  node base digest `sha256:43ac6c60b8f89723f746e8a92ce91abd5017e627ce1ddfe4238355d3a30b772c`。
- 初回OFF版 `4cd2e6b2-52ef-4ffb-9384-38fcb080c863`。
  検査用ON版 `369cd521-f846-4ad2-9e0f-7cc993151940`。
  終了時OFFへ戻した版 `601a2765-1fe5-4e42-bc57-87b2abaa8fe6`。
  secretは乱数を直接stdinで登録し、表示・repo保存していない。
- 検査の入口は127.0.0.1限定のWrangler local dev→remote private service binding。
  検査helperは配備していない。D1/R2の写真保存受付や本人allowlistを変更していない。

## 人工画像だけの実結果（時刻UTC）

| 条件 | 結果 |
| --- | --- |
| 初回起動込み 622B JPEG、03:03:10.288開始 | 200 valid:true、2,863ms |
| JPEG圧縮データ途中切れ | 200 valid:false、320ms |
| 最大寸法4096×4096 progressive、13,111,259B | 200 valid:true、5,051ms |
| 同時2呼出 | 片方200、片方503。待ち行列に積まない |
| 上記すべての応答 | Cache-Control:no-store |
| 20秒ごと継続呼出、最終03:05:09.399 | 200、630ms |
| 直後03:05:14–19のinstance再読取 | inactive、location/versionなし |
| 停止後03:05:42.756の再呼出 | 200 valid:true、1,702ms |
| OFFへ戻した後の同じ入口 | 503 DEPENDENCY_UNAVAILABLE |
| 2回目も03:07:46に停止、03:08再読取 | inactive。OFFへの版更新後も期限停止を確認 |

最終呼出から1分経っていないのに停止したため、単なるidle停止ではなく
最初の起動から約2分の期限停止を観測できた。alarmの秒単位遅延はある。
最大寸法の1例が1GiB構成で成功した証拠であり、全JPEGのピークメモリ測定ではない。
全画像の10秒以内処理、月境界の実時間試験、月300回枠の使い切り試験はしていない。
月境界/枠の計算は既存の局所試験証拠を再利用し、実クラウド証拠と混同しない。

初回配備候補12:00 JST→Cloudflare application作成12:01:38 JST。
Docker修復からの総時間や、前段のCI/実装時間をこの配備時間に置き換えない。
追加のiOS CI・TestFlightは実行していない。

OFFが本文を読まず503を返した2回に、Wrangler local remote-bridgeが
`Can't read from request stream after response has been sent` を記録した。
localhost helperだけを本文読取完了後の転送に変更し、同じOFF503を再確認したところ
bridgeエラーは消えた。製品側のOFF早期拒否を変更する理由にしていない。
local devは終了済み。検査失敗を隠さず、helperと製品を切り分けた。

## 残る完成条件

これは画像検証部品の配備成功。実Apple本人/会員連携、KMS/S3の継続運用資格情報、
本人の実保存→別端末復元→持ち出し、通知/期限消去/35日清掃、原価・容量決定は別ゲート。
公開保管サービスを完成した扱いにしない。予算通知と2分/月300回の稼働枠は
請求のハード上限ではなく、固定料金・他サービス・為替・プロバイダーの遅延を止めない。
