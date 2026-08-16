# ADR-004：Widget肉球ボタンと行動計測境界

- 状態：承認済み
- 日付：2026-08-16
- 対象：TestFlight Build 6以降（1週間計測の開始buildはBuild 7）

## 背景

本製品は、アプリを頻繁に開かせず、日常に出ている猫写真から「これ好き」を蓄積することを検証する。アプリ内にしかボタンがない状態では、1週間で好きが0枚だったときに「写真に価値を感じなかった」のか「アプリを開かなかった」のかを区別できない。

Build 5は、3サイズ専用画像とぼかし背景を確認する技術検証用とする。Build 5で1週間の行動計測は開始しない。

## 判断

Build 6で肉球操作と保存境界を導入した。実機で常設ぼかしの没入感不足が分かったため、[ADR-005](ADR-005-Widget猫優先full-bleed.md)の表示修正を含むBuild 7を1週間計測の開始buildとする。Build 7をインストールし、Widget再配置、下記実機ゲート、ランダム100枚のPrecision確認を終えた後、アプリ内の「1週間計測を開始」を押した時点から行動計測を開始する。ゲート中の試し押しは計測へ含めない。

Deferred 2,586件は計測のcoverage gapとして開始時に固定記録するが、898枚の検出済み写真があるため計測開始を阻害しない。この状態で得るengagementは、古い写真が追加された将来状態に対して控えめな値になり得る。計測中は[ADR-006](ADR-006-iCloudローカル派生画像の検証.md)のBuild 8 probeを開発・CIまで進めてよいが、測定端末へインストールせずWidgetと写真露出集合を変えない。1週間の結果を回収した後にBuild 8を実行し、採用方針をBuild 9へ反映する。

- Small / Medium / Largeの右下へ、iOS 17の `Button(intent:)` による肉球ボタンを置く。
- 未押下は `pawprint`、押下済みは `pawprint.fill` とし、再タップで解除する。
- ボタンの処理中表示には `invalidatableContent()` を使う。
- 肉球以外の領域は従来どおり `widgetURL` で写真詳細を開く。
- Widget専用のApp Intentは `isDiscoverable = false` とし、Siriやショートカットへ公開しない。
- 写真アプリの `PHAsset.isFavorite` は読み取り専用の選別入力のままとし、肉球操作から変更しない。

### Widget設定と写真源の拡張境界

Build 6からWidgetの構成を `AppIntentConfiguration` / `AppIntentTimelineProvider` へ移し、Widget設定で写真源を選べる構造にする。現時点の有効な写真源は自分の写真ライブラリにある「うちの子」だけとし、設定Intentは将来の写真源追加に備えた境界として使う。肉球を実行する非公開の `ToggleWidgetLikeIntent` とは責務を分ける。

写真源は安定したidentifierを持つ `AppEntity` として表し、Build 6では `personal-library` だけをEntity Queryから返す。各Widget配置は設定Intentを個別に保持し、providerは受け取った写真源identifierをtimeline entryまで渡す。設定をプロセス全体のglobal値へ保存しない。同じWidgetを複数置いたときも、将来は各配置が別の写真源identifierを保持できる。

Build 5の `StaticConfiguration` から同じkindの `AppIntentConfiguration` へ変える際、既設Widgetがその場で安全に設定Intentへ移ることは保証しない。Build 6は一般公開前なので、TestFlight更新時に既設Widgetを残したまま表示・編集できるか確認し、不調なら一度削除して再追加する。この移行を一般公開後には繰り返さず、将来構成方式そのものを変える場合は旧kindとの併存を検討する。

将来「他人の猫」を写真源として追加しても、その写真の肉球を自分の本（自分の猫の「これ好き」）へ入れてはならない。新しい写真源を有効にする前に、写真源別action policyをtimeline entryへ追加し、表示側は写真源名から挙動を推測せず、そのpolicyに従って肉球の表示、保存先、Deep Linkを決める。`他人の猫`は既定で肉球を表示しない。別の保存先や意味を持つ操作を提供する場合は、保存namespace、表示文言、計測指標を別途決定してから有効にする。manifest、cache filename、timeline leaseも写真源ごとのnamespaceへ分離し、別配置・別写真源の保持ファイルをcleanupで消さない。Build 6ではこの将来policyを実装せず、1週間計測には自分の写真ライブラリに対する好き／解除だけを含める。

## 保存と計測境界

`LibrarySnapshot`とは別に、App Groupの小さなLikeストアを正本とする。アプリとWidget Extensionは、プロセス内ロックとプロセス間ロックを重ねた同じread-modify-write経路を使う。

Build 6の初回同期では、Build 5以前のlikesを移行してWidget操作を解禁する。実機ゲート完了後に「1週間計測を開始」を押した時点で、次を保存する。

- `measurementStartedAt`
- 計測開始時点で好きになっている全写真の開始時枚数
- 開始後の押下／解除イベント（時刻、写真identifier、結果、操作元）

開始操作ではゲート中のイベントを消去し、その時点のlikesをbaselineにする。操作イベントは30日かつ最大1,000件を保持し、削除した件数も記録する。SharedLogにも同じ操作を短い写真token付きで記録するが、診断ログはrotationするため、1週間集計の正本には永続イベント履歴を使う。開始時点の既存likesを新規獲得へ数えず、削除件数が0でない集計は完全な1週間データとして扱わない。

## Build 7で再確認する実機ゲート

1週間計測を始める前に、TestFlight Build 7上で次をすべて確認する。

- 3サイズすべてで肉球が右下に表示される。
- 輪郭から塗りつぶしへ変わり、再タップで輪郭へ戻る。
- 処理中にボタンのinvalidated表示が出る。
- アプリを終了した状態でも操作でき、アプリを勝手に開かない。
- 肉球以外をタップすると従来どおり写真詳細が開く。
- アプリを開くと総数と押した日時が一致する。
- 診断ログと検証JSONのイベント履歴が一致する。
- Build 7インストール後、既設Widgetを削除し、Small / Medium / Largeを再配置して新しいcacheと設定Intentを使う。
- 長押しして「ウィジェットを編集」を開くと、写真源が「うちの子（自分のカメラロール）」として解決される。
- 同じサイズまたは異なるサイズを複数配置しても、各配置が独立した設定Intentでtimelineを取得する。
- 全件スキャンを確定させ、検証JSONを書き出し、ランダム100枚を外部表へ分類する。
- 最後にアプリ内の「1週間計測を開始」を押し、開始日時とbaseline枚数を記録する。

Apple写真の「猫」検索との5分比較はアプリ状態を書き換えないため、このゲートより先に実施してよい。

Simulator CIはSwiftのコンパイルと通常のApp Group入出力を検証するが、ホーム画面へ配置したWidgetの肉球タップ自体は自動化しない。このゲートは実機で行う。

## 保留

- Siri／ショートカットへ公開するApp Intent
- 「他人の猫」など、自分の写真ライブラリ以外の写真源と、その写真源専用の肉球action policy
- ロック画面アクセサリWidget
- Subject Liftingと高度な構図理解
