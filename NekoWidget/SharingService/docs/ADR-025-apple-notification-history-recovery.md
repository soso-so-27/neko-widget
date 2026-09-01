# ADR-025: Apple通知履歴による欠落回復

## 状態

実装済み、runtime既定OFF。専用staging訓練が終わるまで有効化しない。

## 背景

App Store Server Notifications V2は再照合のきっかけであり、単独ではPlus権限を変更しない。ただし、Appleから公開webhookへの配送が一時的に欠落すると、Subscription Statusの再照合開始が遅れる可能性がある。定期再照合は最終的な権限判定を保つが、直近の通知欠落を安全に補う限定的な回復経路が必要である。

## 決定

- Notification Historyは公開webhookへ追加せず、Cloudflare AccessとHMACで保護したprivate verifierから正規化済みの検証結果だけを取得する。
- WorkerとD1には生の`notificationHistoryResponse`、`signedPayload`、transaction JWS、renewal JWSを渡さない。
- 専用の上限環境変数とD1下限gateを用意し、どちらも既定OFFとする。
- 1回のcronで取得するのは最大1ページ、1ページ20件までとする。
- 回復開始時にenvironment、bundle ID、開始時刻、終了時刻を固定する。pagination、再試行、cursor resetで期間を広げたり縮めたりしない。
- 各通知は既存の不変event ledgerへ冪等に保存する。通知UUIDごとの不変なcauseを1件だけ作り、同じ通知の再配送で再照合generationを増やし続けない。
- ページに含まれる通知UUIDとpayload hashがevent ledgerへ永続化済みであることをD1で確認してから、fenced cursorを進める。途中停止したページは同じcursorから再実行する。
- cursor resetは同じ固定期間で3回までとし、4回目は`blocked`にする。設定不一致、検証済みresponseの矛盾、app identity変更も自動で解釈せず`blocked`にする。
- lease、D1 gate generation、回復generationをcursor commitまで固定し、停止後に遅れて返ったresponseやgate切替後のresponseをcommitさせない。
- 過去にunmatchedだった正規通知は、対応する課金accountが後から登録された場合に同じ通知の再処理でlinkできる。ただし通知event自体の受信時判定は書き換えない。

## 回復範囲

最初の回復区間は安定化待ち10分を除いた直近24時間とする。その後は、完了した終了時刻から次の安定化済み時刻までを最大24時間ずつ処理する。これは常設の全履歴importではなく、直近webhook欠落の修復である。より古い事故を回復する場合は、自動で期間を拡大せず、別のreview済み手順と固定manifestを用意する。

## 運用条件

有効化前に、隔離stagingで次を確認する。

1. migration `0025`とprivate verifierのactive deploymentを固定する。
2. Apple Server API credential、environment、bundle ID、保持期間を照合する。
3. 上限・下限gateがともにOFFで取得が0回であることを確認する。
4. 合成ページで途中停止、同一ページ再実行、重複通知、stale lease、gate世代変更、cursor resetを訓練する。
5. event/cause/page ledgerに生JWSが存在せず、Subscription Statusだけが実効権限を変えることを確認する。
6. `blocked`からの復旧は原因と固定期間をreviewして、新しいgenerationを明示的に開始する。

## 影響

通知欠落からの回復は速くなる一方、Apple History APIへの依存と運用対象が増える。負荷と事故範囲を抑えるため、自動取得量、期間、cursor resetを強く制限する。ステージング認証情報がないlocal/CIでは、署名protocol、D1 fencing、冪等再実行までを合成データで検証し、外部APIの成功を主張しない。
