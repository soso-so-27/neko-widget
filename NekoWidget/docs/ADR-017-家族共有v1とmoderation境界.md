# ADR-017：家族共有v1は追記型momentとfail-closedな投稿前確認にする

日付: 2026-08-22
状態: 採用・実装中
関連: [ADR-015](ADR-015-共有の配送設計.md)、[共有設計](共有設計.md)

## 結論

「いまの一枚」は、標準カメラまたは写真アプリのShare Extensionから、
招待済みの家族のまどへ一枚だけ明示的に届ける。Build 26までの画面は静的な
レビュー表示であり、実送信ではない。旧ADR-009の日次20枚generationも本機能として
有効化しない。

Build 27候補では画面、暗号化、追記型relay、受信、通報、blockのsource基盤までを
実装するが、実送信はまだ有効化しない。Share Extensionはhost appの通常containerに
あるinstallation markerを読めないため、App Groupと共有Keychainだけで古い資格を
信頼すると再install直後に旧spaceへ送れる。`SHARING_SHARE_EXTENSION_SEND_ENABLED`は
App/Extensionとも`NO`へ固定し、archive validatorも`YES`を無条件に拒否する。

家族共有の保存単位は、内容を後から置き換えない一つの`moment`とする。最初の製品UIは
「2人・1つのまど・各1台」だけを扱うが、Serverと端末内stateは次を別の概念として持つ。

- `space`: 家族のまど。現在の鍵世代とlineageを持つ
- `participant`: まどに参加する人
- `device`: participantが承認した端末
- `moment`: `live`、`memory`、`bootstrap`の一送信
- `delivery`: commit時点の受信participantごとの取得、ACK、失効状態
- `reaction`: momentを書き換えない別の追記event

この分離により、後から3人以上、1人の複数端末、複数の家族のまど、履歴期間を追加しても、
一枚の配送形式を作り直さない。団体から購読者への一方向配信は、E2E objectを人数分複製しない
別システムなので、このschemaとAPIへ入れない。

## 共有パターンの境界

| パターン | 写真の起点 | 相手・端末 | このv1との関係 |
|---|---|---|---|
| 自分のまど | 端末内の思い出 | 本人の端末だけ | Serverを使わない現行機能 |
| 家族の「今の一枚」 | 共有シートで毎回1枚を確認 | 2人・各1台 | 今回の実装対象 |
| 家族のmemory | 過去写真から1日1枚、既定OFF | 同じ家族のまど | `kind=memory`で後続追加 |
| 最初の思い出 | 最大20枚を一括確認 | 同じ家族のまど | `kind=bootstrap`で後続追加 |
| 家族3人以上 | 上記live/memory/bootstrap | participantが3人以上 | deliveryの宛先snapshotを流用し、UIと鍵更新を後続追加 |
| 1人の複数端末・機種変更 | 同じmoment | participant配下に複数device | device登録・鍵の再wrap・復旧UXを後続追加 |
| 複数の家族のまど | 同じ送信UIから明示選択 | spaceが複数 | 無料v1では1つ。追加時だけ届け先選択を出す |
| 施設・保護団体の配信 | 管理者から購読者へ一方向 | 多数、家族関係なし | 脅威モデル・配信費用・鍵配布が別なので別サービス |
| 公開投稿・検索・フォロー | 不特定多数 | 公開ネットワーク | 製品範囲外。家族のまどへ後付けしない |

`moment`は内容を後から置き換えず、reactionや削除通知も別の追記eventにする。
したがって人数・端末・履歴を増やしても、送信済み暗号文を書き換える設計には戻さない。

## v1の範囲

v1として実装するもの（候補buildでは実送信OFF）:

- 既存の招待を使った2人の家族のまど
- Share Extensionからの画像一枚の明示送信
- 長辺最大2,048px、暗号文1MiB以下、metadata除去済みcanonical preview
- 暗号化payload内の原本撮影日時または欠損状態
- `reserve → upload → commit → receive → ACK`
- App Group outbox、offline/中断後の同一request再試行
- アプリ内の最近届いた写真、送信待ちの再試行、永続的に送れない写真の明示破棄
- 受信写真の通報、相手のblock、共有解除
- ACK後7日／未受領30日、unlink／blockによる取得権失効
- 端末内履歴は90日、最大500枚、最大256MiBのいずれか早い上限

後続にするもの:

- 過去写真を一日一枚届ける`memory`（既定OFF）
- 初回20枚の一括確認と一回限りgrant
- 3人以上と複数端末の製品UI、peer-assisted復旧
- APNs、WidgetKit push、Widgetへの即時反映
- 複数の家族のまど、IAP、有料履歴
- 団体向け一方向配信、原本、無期限保持

## 投稿前filterの判断

AppleのApp Review Guideline 1.2は、UGCに投稿前filter、通報、block、公開連絡先と
適時対応を求める。家族だけの招待制でも省略しない。

v1は画像だけを扱い、caption、動画、匿名探索、公開投稿を扱わない。送信前に端末上で
`SensitiveContentAnalysis`を実行し、次をfail-closedにする。

1. `analysisPolicy == .disabled`、権限不足、分析error、取消では送信しない
2. sensitive判定では送信せず、別写真を選ぶよう案内する
3. 判定済みのcanonical previewと同じ視覚内容だけを暗号化して送る
4. 判定versionと通過事実だけをreserveへ含め、画像や判定詳細はServerへ送らない
5. 受信端末でも表示前に同じ分析を行い、sensitiveなら隠したまま通報・blockを選べる

このframeworkは利用者のSensitive Content Warning等がOFFだと無効になる。その場合に
「確認できなかったが送る」という迂回を作らない。設定を有効にできない端末では、
家族共有の送信を提供しない。

SensitiveContentAnalysisが扱うcategoryだけで全ての不適切内容を検出できるとは主張しない。
コミュニティ基準で禁止内容を明示し、招待制、送信枠、端末credential、通報、block、
失効、運用対応を併用する。公開support URL、community standards、対応担当、通報用公開鍵、
48時間以内の初回確認runbookが揃うまで、環境の`MOMENT_RUNTIME_ENABLED`を`NO`に保つ。
Workerはこの値がexact `YES`でない限り通常moment APIをfail-closedで拒否し、通報・block・cleanupだけを維持する。

## 暗号化と配送

- 写真ごとにmedia keyを生成し、canonical previewとmanifestを認証付き暗号化する
- media keyはspaceの現在の鍵世代でwrapする
- AADはprotocol、space、client moment、kind、鍵世代、sender participantへ
  length-prefixで結び付ける。device IDは将来の端末交換を妨げないため含めず、
  reserveのclient request IDはServer側のidempotency recordで暗号文size/hashへ結び付ける
- Serverは暗号文、wrapped key、size、hash、kind、server時刻、期限だけを扱う
- 撮影日時、ファイル名、PhotoKit ID、EXIF、GPS、participant表示名を平文で出さない
- commitはその時点のactive recipient集合を固定し、recipientごとにdeliveryを作る
- retryは同じidempotency key、payload hash、暗号文を使い、送信枠を二重消費しない。
  upload leaseが失効した場合も同じ論理IDで再予約し、初回を含む3予約で停止する
- member削除またはblock後のcommitは、次の鍵世代が確定するまで拒否する

v1のblockは2人用のhard stopとする。相手の通常credentialを失効し、双方向deliveryを
revokedへ進める一方、被block側には既存受信の通報だけを24時間許可する。通常の
changes/download/sendと旧v1 APIはこの期間も拒否する。通報済み暗号文はspace削除と
切り離して7日保持し、report-only期限と通報content TTLより前にcleanupしない。

一人で使うローカルのまどはこのServerを呼ばない。Share Extensionは原画像を恒久保存せず、
保護・backup除外済みApp Group outboxへ必要最小限の一時copyを置く。成功、取消、期限切れ、
共有解除では回収する。commit中は取消不可とし、応答喪失時は同じidempotency keyで配信状態が確定するまで保持する。
通報outboxは10件・10MiB、未commit 24時間を上限とし、commit曖昧状態は自動同期で収束させる。
一時ファイルのmetadata確認はApp Group container内に限定し、Privacy manifestにFileTimestamp `C617.1`を申告する。

Host app内の同期、通報、blockは、通信前に必ず`PairingInstallationGuard.bootstrap`を通し、
通常container markerとApp Group stateとKeychain credentialを同じinstallationとして検証する。
Share Extensionからの直接通信を解除する条件は、次のどちらかを実装し再install実機試験を通すこととする。

1. Extensionは保護・backup除外・短期保持の入力だけを置き、host appが起動してinstallationを
   検証した後に初めて暗号化・送信するhandoff
2. App Attest等を使い、再install後には再利用できないinstall-bound capabilityをServerも検証する方式

App Groupや共有Keychainだけのmarker、短TTLだけのtokenは、再installとの境界を証明しないため解除条件にしない。

## release境界

コードと隔離stagingは、運用フラグOFFのまま実装・検証できる。次が揃うまでproduction、
一般向けTestFlight、App Store buildで写真送信をONにしない。

- App、Share ExtensionのSensitiveContentAnalysis/App Group/Keychain entitlementと署名検証
- 公開privacy policy、support URL、community standards、通報対応runbook
- moderation公開鍵と担当者だけが扱う秘密鍵
- Photos or Videos、User ID、Device ID、Product InteractionのPrivacy申告
- App Store Connect回答、Review Notes、二端末review手順
- 専用staging/productionのD1、R2、rate limit、cleanup監視、kill switch
- reserve、1MiB cap、quota、ACK別TTL、block、削除収束の自動試験
- 10,000 space同時revoke時、追跡object queueは日次上限内、orphan用prefix sweepは
  17時間以内に空確認まで収束することのstaging負荷試験
- 2台の実機でoffline、Extension終了、再起動、retry、鍵喪失を確認
- app削除・再install後、host appの初回bootstrap前にExtension/foreground syncが旧資格を使えないこと
- 上記install-bound handoffの採用と実装。完了までShare Extension direct send archive flagは常時`NO`

Build 27の候補CI成功は、上記のproduction運用準備が完了したことを意味しない。
