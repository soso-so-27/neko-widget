# 画像検証Container：永続的な稼働枠

2026-09-26。`origin/main eaf57914655b605bf820379219e79632dbc512c8` から分離。
既存の保管サービス、並行アプリ、研究checkout、実写真を変更しない。

## 変更と確認範囲

- 2分の稼働枠を開始前にDurable Objectへ永続予約し、月300回・合計10時間分で新規起動を拒否。
- 起動失敗・早期終了でも返金しない。アクセスが続いても期限を延ばさない。
- UTC月末を越える枠は月末で切り、時計逆行・破損・未知の起動は受付を閉じる。
- 期限は永続scheduleからdestroyへつなぎ、起動中はabort。転送は自動再起動しない低レベルportを使う。
- 古い世代のtimerは新しい稼働を止めない。応答は4 KiBまで読み切り、未消費bodyを残さない。
- 公開入口404、private named entrypoint、既定OFF、固定DO名、max_instances=1は維持。

局所10件は純粋な状態遷移に加え、Cloudflare境界だけをmockした製品Workerクラスの
予約→schedule→起動順序、二重start拒否、startup中のabort/destroy、古いtimerを確認。
独立レビューで、旧healthy観測の直後にalarmがidleへ戻すと永続blockになるP2を発見。
physical観測と永続遷移を同じblockConcurrencyWhile内へ移し、競合再現試験を追加した。
実Cloudflareのalarm遅延・destroy反映時間・cold startを確認したものではない。
したがって「10時間分の起動許可枠」であり、実稼働時間や請求金額のハード上限とは呼ばない。

## 候補検証の計画

- 最初の実装ファイル作成は同日11:31 JSTごろ。CI開始前も含めて経過を数える。
- 変更挙動はContainerの稼働許可と期限停止。iOS、画像decode本体、保存先、暗号化、料金は不変。
- 独立レビューは製品4ファイルとCI4 companion。専用scopeをv3、既知pathを23→25とし、
  workflow digest・通常mode・未知/他製品混在時FULL・Node/Docker必須jobを維持する。
- 直近の同workflow成功は47〜51秒。ただしv3は未計測。10分job timeoutを予測時間としない。
- 必須は開発フロー検査、同SHAのiOS planとJPEG専用Node/Docker job。Mac/TestFlightは起動しない。
- 開発フロー12検査は85.3秒で成功。後続修正はJPEG製品/局所testと資料のみで、
  その12検査の入力に差分はない。成功を保持し、commit後のpreflightだけ再実行する。
- disabled gatewayのdry-run bundleは64.98 KiB。実配備はまだしていない。
- Docker Desktopはプロセス存在・context一覧取得可だが、desktop-linux/default両方のinfoが応答せず。
  利用者がDockerのみの再起動を許可。通常restartが90秒を超えて応答せず、CLIのforce stop成功後、
  Docker Desktopを非表示起動した。PC再起動・データ削除は行っていない。Engine応答は確認中。
  CIのDocker確認と実配備準備を分ける。

## 実設定と残るゲート

Cloudflare追加OAuthは成功し、対象accountとcontainers/cloudchamber権限を再照合済み。
Workers FreeのためContainers APIはPaid必要と明示拒否。料金プランは変更していない。
AWS月3 USDの予算と実績1.5/3 USD・予測3 USDの通知は実設定・再読取済み。
Cloudflare従量3 USDの警告への更新は利用者確認済みで、API再読取は未確認。
予算警告は停止制御や請求上限ではない。

受付はOFF、専用D1のowners/recordsは0を維持。
次はローカル停止制御確認→配備環境の復旧→Workers Paid→非公開の限定実稼働停止確認。
その成功後にのみ3人/7日の保存検証を開く。実環境確認前に利用者写真を受け付けない。
Paidが必要な実確認をPaid化の前提に置く循環した手順にはしない。
サービス完成には保存/復元/持ち出し、通知/期限消去、実端末、原価計測が別途必要。

## 根拠

- https://developers.cloudflare.com/containers/reference/container-class/
- https://developers.cloudflare.com/durable-objects/api/container/
- https://github.com/cloudflare/containers/issues/242
