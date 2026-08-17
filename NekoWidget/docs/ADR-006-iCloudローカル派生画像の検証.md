# ADR-006：iCloudローカル派生画像を先に検証する

- 状態：実験待ち
- 日付：2026-08-16
- 対象：番号未割当のInternal TestFlight buildで行うdeferred対策の事前検証

> **2026-08-17日程変更：** Build 7で中断した1週間計測の再実施は、結果が製品判断を変えないため撤回した。paired probeに週待ちや測定端末へのinstall制約はなく、専用Internal buildの準備後に実行できる。採用時のproduction反映は後続buildとし、実験内容と事前に固定した判定線は変更しない。

## 背景

実機の確定snapshotは総数8,861、Screenshot除外736、`unavailableLocally` 2,586、解析済み5,539、猫898だった。解析済み写真内の猫率は16.2%である。Deferredにも同率で猫が含まれると仮定すると未発見猫は約419、潜在猫総数は約1,317、現在見えている割合は約68.2%となる。

ただし`unavailableLocally`は「写真にローカルデータが一切ない」という意味ではない。現行requestの`1024×1024 / highQualityFormat / networkAccessAllowed=false`をローカルだけでは満たせなかった状態である。iPhoneのストレージ最適化が保持する低解像度派生を、より小さく速いrequestなら取得できる可能性がある。

## 判断

ユーザー同意を伴うiCloud downloadはまだ実装しない。番号を割り当てたInternal TestFlight専用の技術検証buildを端末へ入れ、本番snapshotを変更しないpaired probeを1回実行する。1週間計測の終了を待つ必要はなく、Build 10を確認した端末へ同じInternal buildを入れてよい。probe結果を採用する場合も、通常scanner／Widgetへ反映するのは後続のproduction buildとし、実験コードをそのままproduction経路へ混ぜない。

probeのrequestは次とする。

- `targetSize = 512×512`
- `contentMode = aspectFit`
- `deliveryMode = fastFormat`
- `resizeMode = fast`
- `version = current`
- `networkAccessAllowed = false`
- 非同期request
- 非nil画像は`PHImageResultIsDegradedKey == true`でも成功として受理

現行wrapperはhigh-quality requestの中間画像を待つためdegraded callbackを捨てる。この処理を本番scannerの定数変更だけで流用してはいけない。fast probe専用のrequest policyで、1回だけ返るdegraded画像を最終結果として扱う。

## 非破壊の比較方法

Probe専用buildは専用root UIを使い、通常の`AppViewModel`と本番scannerを生成しない。開始時の`LibrarySnapshot`をbaselineとして固定し、probe結果を本番snapshot、アルバム、Widget cache、Likeストアへ書かない。対象は現snapshotの8,125件（8,861 − Screenshot 736。現在のburst重複は0）とし、静止画、Screenshot、burstの選別policyをbaselineと固定する。結果は`experiments/<runID>/checkpoint.json`と最終JSONだけへ保存する。本番snapshotファイルは実行前にbackupし、byte列のSHA-256を実行前後で照合し、不一致なら失敗としてbackupから復旧できる状態にする。

status比較のAは2026-08-16の固定snapshot、Bは同じassetに対する512 fast probeとする。一方、bbox差は時間差による編集やPhotoKit派生差を混ぜないため、旧detected 898件に限り現行`1024×1024 / highQualityFormat / resizeMode=fast / version=current / network=false`を同じprobe実行中に再要求する。JSON上の正本名は前者を`statusBaselineSnapshot`、後者を`bboxBaseline1024Current`として混同を防ぐ。A/Bで`localIdentifier`、`pixelWidth×pixelHeight`、`modificationDate`が一致するassetだけをbbox比較へ含め、probe中に削除・編集されて比較対象外になった件数も報告する。

probeはフォアグラウンド、給電中、機内モード＋Wi-Fi offで実行し、100件ごとにcheckpointを原子的に保存して中断後に再開できるようにする。現行実測約8枚／秒をそのまま当てはめると8,125件は約17分だが、PhotoKitの低品質派生、Vision、JSON保存、旧陽性898件の比較armを含むため、実行予算は20〜40分、打ち切り上限60分とする。

集計は少なくとも次を分離する。

1. 旧Deferred 2,586件のうち、512 fastで画像を取得できた件数、まだinCloudの件数、error、cancel、timeout
2. 回収できた旧Deferredの`detected / noCat`と新規猫件数
3. 旧解析済み5,539件について、`detected→detected`、`detected→noCat`、`noCat→detected`、`noCat→noCat`
4. 旧解析済み5,539件内の検出数、旧detected 898件の保持率、旧Deferredからの新規猫件数（総猫件数だけでは判定しない）
5. 両方でdetectedの同一assetについてbbox IoU、中心移動量、面積比、confidence差
6. 実際に返った画像のpixel寸法、degraded率、request所要時間
7. 旧Deferred、回収済み、残存Deferred、新規猫の撮影年・年月分布

総猫件数だけでは、新規回収と512pxによる検出低下が相殺されるため合格判定に使わない。bboxは1024版も正解データではないので、中央値・下位分位と差の大きい例を人手確認する。

## 暫定合格条件

- 旧Deferred 2,586件が95%以上減少する
- 旧detected 898件のうち、同一性を確認できたassetの95%以上をdetectedとして保持する
- Failedがprobe対象の0.5%以下に留まる
- 両方detectedのbboxはmedian IoU 0.80以上、p10 IoU 0.60以上、中心移動量p90が正規化画像対角の0.10以下である
- IoU最低30件とseed固定無作為20件を目視し、512版だけが猫を外す系統的なずれがない
- probeの全PhotoKit requestが`networkAccessAllowed=false`で、probeコードにdownload許可経路がない。端末全体の通信をゼロにして確認する場合は機内モードを有効にし、Wi-Fiも切って実行する

512 fastの総猫数は、旧Deferredから新規猫が増えるため898との単純一致を要求しない。旧解析済み集合の保持／遷移と、旧Deferredからの新規検出を分けて判断する。上記は実験前に固定する暫定線であり、結果を見て後付けで緩めない。不合格でも即downloadへ進まず、実画像の差と失敗分類を先に調べる。

## Widget cache

Build 8のWidget出力はSmall 500×500だけではなく、Medium 1050×500、Large 1050×1100もあり、現行入力は2048×2048 high-quality local-onlyである。入力を一律512pxへ下げるとMedium / Largeで拡大が必要になる。また現行`PhotoImageLoader`は同期requestであり、PhotoKitでは同期時に`fastFormat`指定が効かない。

したがってscanner probeとWidget取得変更を分ける。旧案の`900→512px`はBuild 8の最大1100px出力に足りないため採用しない。scannerの結果が良ければ、Widget側は現行の2048px high-quality local-onlyをbaselineとし、非同期`fastFormat / network=false`でまず2048×2048、画像がnilまたはinCloudなら1100×1100を同じlocal-only条件で要求する。いずれも非nilのdegraded画像を成功として受理する。live cacheを書き換える前に、実pixel寸法、500×500／1050×500／1050×1100のJPEG、100／200／220KiB上限、拡大の有無と見た目を専用probeで確認する。

## 通信量と同意

PhotoKitの画像download progressは割合であり、`requestImage`前に必要な転送byte数を正確に取得できる保証はない。targetSizeから通信量を算出することもできない。そのため、現時点で「約◯GB」を断定表示しない。

probe前に示せるのは感度表だけである。残り2,586件について、1件あたり実転送量を仮に0.5 / 1 / 2 / 4 / 8MBと置くと合計は約1.3 / 2.6 / 5.2 / 10.3 / 20.7GBになる。ただしPhotoKitが派生画像と原本のどちらを取得するかは公開契約から決まらないため、これは通信量予測ではない。512 fastで残った件数を確定し、必要な場合だけ少数assetの同意付きpilotで端末固有の実測レンジを作る。

ここで禁止する「同意なしの自動download」は、scannerやWidget cacheがDeferredを一括取得する処理である。現在の本体画面では、ホームの「今日の1枚」、詳細、一覧、精度レビューなどの個別画像表示が`networkAccessAllowed=true`でiCloudへアクセスし得る。この本体UIの個別表示と、数千枚を自動取得するbatch処理を分けて扱う。個別表示にも事前同意を要求する方針へ広げる場合は、別のコード変更とUX判断が必要である。probeは個別表示を行わず、全requestを`networkAccessAllowed=false`に固定する。

512 fastでもDeferredが大きく残った場合にだけ、次を設計する。

- 自動downloadは行わず、対象枚数、Wi-Fi・充電推奨、所要時間と容量が概算であることを明示して同意を取る
- まず少数assetの明示的なpilot downloadを行い、端末・ライブラリ固有の実測レンジを得る
- 本実行はDeferredだけを対象にし、停止・再開・cancelを提供する
- `progressHandler`と完了件数を表示し、ネットワークなし／Cellularでは開始しないことを既定にする
- download後に解析できた件数と猫件数を保存し、元の2,586件との差を報告する

正確なbyte見積りが得られない場合は、偽の精密値を出さず「2,586枚・通信量は写真形式により大きく変動」と表示する。

## 実験後の分岐

- Deferredがほぼゼロ：iCloud download同意UIは実装せず、ローカル派生を使うproduction requestを設計する
- Deferredは減るが残る：ローカル派生を先に使い、残数だけを任意download対象にする
- ほとんど減らない：通信量pilotと明示同意を設計する
