# 個人保管用 JPEG 検証 provider（未配備・既定 OFF）

写真の拡張子やヘッダーだけでなく、**最後まで画素をデコードできること**を確かめる独立した Node.js 部品。画像の保管・本人確認・課金判定は行いません。既存 iOS、CloudKit、まどの E2EE、保管データを変更しません。

## 契約

旧保管候補 `863ad16` の `PreservationService/src/providers.ts` が呼ぶ契約に合わせています。

```ts
import { createImageValidator } from './dist/provider.js';
const provider = createImageValidator(); // OFF: 503、本文も読まない
// 内部の実行環境だけで明示的に enabled: true にする。公開リクエストから指定しない。
```

`POST /images/validate-jpeg`、Content-Type `application/json`、本文 `{ "photoBase64": "..." }`。

| 結果 | HTTP と本文 | 保存サービス側の扱い |
| --- | --- | --- |
| 単枚 JPEG を全デコード成功 | 200 `{valid:true,mediaType:"image/jpeg",frames:1}` | 以降の認可済み保管処理へ進める |
| 不正な JPEG / 非対応の画像 | 200 `{valid:false}` | `INVALID_JPEG`。保存成功にしない |
| JSON / Base64 / 入力サイズ等の契約違反 | 400 `INVALID_REQUEST` | 既存 adapter は依存エラーとして閉じる |
| OFF / 混雑 / 中断 / 期限超過 / 子プロセス異常 | 503 `DEPENDENCY_UNAVAILABLE` | 写真破損と断定せず、再試行可能な依存エラー |

decoder例外のうち既知のlibjpeg破損診断だけを `valid:false` とし、不明な例外は503へ倒します。未分類の不正画像も503になる場合がありますが、例外を根拠なく写真破損と断定したり、成功扱いしたりしません。

応答は `no-store`。写真・EXIF・ファイルパス・native エラー内容を返さず、ログやディスクにも保存しません。URL取得、リダイレクト、利用者指定の接続先はありません。

## 入力と資源の制限

- 最大20 MiB・長辺4,096px・最大4,096²画素。アプリの `PersonalArchiveImage` と選択保存画面の閲覧用コピーに対応し、カメラ原本の完全バックアップを意味しません。
- 単枚の8bit baseline / extended sequential / progressive JPEG。grayscale / RGB / CMYK のフレームを許容し、sharp の厳格デコードが成功した場合だけ受理。
- 終端のない JPEG、終端後のデータ、連結 JPEG、MPF/MPO、複数 SOF、過剰な marker/scan は拒否。metadata 内の marker らしいバイトと画像の区切りは区別。
- `metadata()` だけでは合格にしない。sharp 0.35.4 / libvips で `failOn: warning`、JPEG loader のみ有効にし、全画素を raw へ展開して寸法・出力長を照合。
- 画像ごとに使い捨ての子プロセス。キャッシュ無効、native 並列数1。native処理4秒、起動と待ち時間を含む子プロセス6秒で打切り、**終了を待って**応答する。
- 本文受信2秒、最大4,096chunk（空も計数）、JSON/Base64サイズ上限。Content-Lengthを信用せずストリームの実サイズも測る。空chunkは保持せず、実時刻deadlineと定期的なevent-loop yieldでready-streamによるtimer飢餓も防ぐ。実HTTP橋渡しは極端に細かいchunkへ分割しない。
- provider インスタンスにつき受信から応答まで1件、待機キューなし。多重呼出しは即503。実運用はプロセス内で単一インスタンスを共有する。
- V8 heap 128 MiB は **native allocation やプロセス総メモリの上限ではありません**。実環境の cgroup / container memory・CPU制限と負荷試験は本稼働の必須条件です。

この部品は元の JPEG を再圧縮・回転・metadata除去しません。保存時のSHAとの不一致を作らないためです。EXIF/ICCを一律禁止するものではなく、位置情報除去は現在のiOSコピー生成側で行っています。検証成功はマルウェア検査やmetadata無害化の保証ではありません。

## ローカル確認

Node.js 22.17.0 以降、npm optional dependencies を有効にして実行します。

```sh
npm ci
npm test
```

テスト画像はローカル生成した人工画素のみ。実ユーザー写真・Apple認証・外部保存先を使いません。通常 `npm test` は型検査と実デコーダーの対象確認であり、iOSの一式CIを起動しません。タイマー制御のテストは Node の実験的 MockTimers を使用します。

既存の保管候補がある場合の別実行（source未指定をskip成功にしません）:

```sh
node test/test-adapter.mjs --source <PreservationService/src の絶対パス>
```

その候補の実 `contracts.ts` / `documents.ts` / `providers.ts` を型除去し、既知の相対importだけを一時 `.mjs` へ補完して実行。boundPhotoValidatorの中身を差し替えず、このproviderへローカル接続します。外部fetchを禁止し、元ファイル非改変と専用一時出力の清掃も確認します。D1/R2保存や実Worker間ネットワークの試験とは区別してください。

専用CI `.github/workflows/preservation-image-validator.yml` は Ubuntu / Node で `npm ci` と `npm test` を実行します。別候補を参照するadapterテストは含まず、実サービスへの配備も行いません。iOSの検証や配布の成功証拠とは別です。

## 配備前に残ること

非公開のContainer接続候補を `Dockerfile`、`src/http-server.ts`、`src/container-worker.mjs`、`wrangler.container.disabled.jsonc` に用意しました。既定 `JPEG_VALIDATOR_ENABLED=NO`、公開default routeは404、Workers URLもOFFです。HTTP bridgeは十分長い共有secretがないと起動・処理せず、許可された写真検証リクエストだけを既存の厳格デコーダーへ渡します。コンテナからの外部通信はOFFです。**まだCloudflareへ配備しておらず、実service binding・Container cold start・1 GiB環境の最大画像メモリを確認した証拠ではありません。** `fetch(Request)` の単体試験成功を実配備成功として扱いません。

専用CIはNodeでの全デコード試験、非配備のWorker bundle、Linux/amd64 Docker buildを行います。ローカルDockerが停止している場合はbundleのみ `npx wrangler deploy --dry-run --containers-rollout=none --config wrangler.container.disabled.jsonc` で確認できます。実配備にはWorkers Paid、Docker実行環境、Container権限、保管Workerからの名前付き `JPEGValidationService` service binding、環境ごとの共有secretが必要です。Workers PaidやContainerの費用契約をこのコードだけで開始しません。

1. Workers PaidとContainer権限を確認し、非公開named service bindingとsecretを実環境で接続する。Containerが利用できなければ別の厳格デコード実行環境を選ぶ。
2. basic 1 GiBでの総メモリ/CPU上限、同時実行、cold start込みの10秒呼出制限、依存更新と監視を実環境で確認する。現在のDocker baseは可変のNode 22タグなので、販売前に取得digest・更新/脆弱性監視・復旧を固定する。
3. 実iOSが生成する代表画像と境界を確認し、保存サービス全体の認可→画像検証→暗号化→保管・失敗再送を接続する。
4. KMS・Apple本人/会員owner・容量/保持/削除・別端末復元は別の未完ゲートのまま。画像検証が通っても、バックアップ提供開始としない。

## 採用根拠（2026-09-22確認）

- [sharp: 入力の厳格性と画素上限](https://sharp.pixelplumbing.com/api-constructor/)
- [sharp: metadataは画素をデコードしない](https://sharp.pixelplumbing.com/api-input/)
- [sharp: 処理タイムアウトにqueue待機は含まれない](https://sharp.pixelplumbing.com/api-output/#timeout)
- [sharp: loader制限・最新version・OS資源制限](https://sharp.pixelplumbing.com/security/)
- [Cloudflare: 非公開Service bindingの範囲](https://developers.cloudflare.com/workers/runtime-apis/bindings/service-bindings/)

Node実装を選んだのは既存の純粋JSヘッダー判定を置き換え、厳格なnative全デコードと強制停止をオフラインで実証できるため。配備方式まで確定したという意味ではありません。
