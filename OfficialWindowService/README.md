# 公式まどの配信準備

公式まど1つのcatalogとJPEGを、専用のCloudflare Workerで配信する。既存の非公開まど、R2、D1、アカウント、課金処理へのbindingは持たない。

写真の原本が未指定でも、合成画像A → B → 停止まで同じローカルURLで確認できる。合成画像は実在の猫や投稿者の写真として扱わない。ここまでのコマンドは公開・デプロイしない。

## 採用した構成

- Worker名: `neko-widget-official-cats-preview`。配備先アカウントは既存アプリと同じCloudflareアカウントに固定。
- 公開時のパス: `/catalog.json` と `/<sha256>.jpg` だけ。GET/HEADのみ。
- Workers Static Assetsを使い、Workerコードと画像を同じ配備で切り替える。`run_worker_first: true` にして、静的画像へ直接アクセスしても現在のcatalogによる判定を通す。[Cloudflare Static Assets](https://developers.cloudflare.com/workers/static-assets/)、[binding設定](https://developers.cloudflare.com/workers/static-assets/binding/)
- 有効なcatalogの掲載期間内にある画像だけを配信する。取り下げ・停止・期限切れは新規HTTP取得でも非表示。画像取得中に期限を跨いだ場合も、返答直前に再評価する。
- 応答は `Cache-Control: no-store`。ユーザーが既に保持した写真や、切替前に開始した通信まで即時回収できるという意味ではない。
- 写真と内部入力を同じ公開フォルダーへ入れない。`prepare_bundle.mjs` はcatalogと対応JPEG以外の余計なファイル、hash不一致、期限切れの版を拒否し、新しい出力先へだけコピーする。
- `preview_urls: false`。古い版の別URLを自動公開しない。Workerの古い版をロールバックすると、アプリの古いcatalog拒否に抵触するため、写真を戻したい場合も新しい生成時刻で版を作る。

## 実行環境

Node 22.17以降、Python 3.11以降、既存publisherのPillow。Wranglerはリポジトリ既存の `4.125.0` に固定。付属workerdが対応する `2026-08-27` をcompatibility dateに使う。

```powershell
# 作業ディレクトリ: OfficialWindowService
npm.cmd ci --no-audit --no-fund
npm.cmd test
python -B tools/test_prepare_fixture.py
```

## 原本なしでの表示・更新確認

以下の `C:/official-window-review` は事前に作成済みのローカル親ディレクトリ。各出力先 `pilot-001`、`http-001` は存在しない名前を指定する。生成物はgitへ入れない。

```powershell
python -B tools/prepare_fixture.py --output C:/official-window-review/pilot-001
node tools/run_local_drill.mjs --fixtures C:/official-window-review/pilot-001 --output C:/official-window-review/http-001
```

1. 初期版は合成画像Aだけを返す。
2. 同じURLを更新版へ切り替え、Bが新着となりJPEGのhashも一致することを確認。
3. 停止版へ切り替え、A/B双方の古い画像URLが404になることを確認。

実際のWorkersランタイムを `127.0.0.1:8795` で起動する。終了時はこのコマンドが起動したプロセスだけを終了する。他の開発サーバーを停止しない。別portが必要なら `--port` を指定できる。

結果は `result.json`、起動ログは `local-runtime.log`。これは配信HTTPの結合確認で、iPhone上のWidget表示確認ではない。

## 実写真へ差し替える

原本・猫名が決まったら、既存の [写真生成ツール](../NekoWidget/official-window-tools/README.md) で承認済みの写真から新しいcatalog/JPEGを作る。提供者の初期表示名は「ねこのまど」。元画像や許可記録はリポジトリ外で管理する。

```powershell
node tools/prepare_bundle.mjs --assets C:/official-window-review/photos-001 --output C:/official-window-review/deployment-001
```

出力の `assets/` が配信対象。Workerコードも `worker.js` として同じ版に保存するので、後でcheckoutのコードを編集しても、この配備パッケージの内容は変わらない。設定やコードを更新するときも、新しい出力先でbundleを作る。

```powershell
$env:WRANGLER_SEND_METRICS='false'
node node_modules/wrangler/bin/wrangler.js deploy --dry-run --config C:/official-window-review/deployment-001/wrangler.jsonc --outdir C:/official-window-review/dry-run-001
```

このdry-runはバンドル確認までで、アセットのアップロードと配備は行わない。公開を行う段階の実コマンドは同じ `deploy` から `--dry-run` と `--outdir` を外したもの。現在は実行していない。

実際に割り当てられたHTTPSの `/catalog.json` URLが確定したら、bundle生成に `--feed-url` を加えると `OfficialWindow.xcconfig` も生成する。アプリとWidgetへ同じ `OFFICIAL_WINDOW_FEED_URL` を設定するためのもので、URL未確定のいまアプリ設定を偽のURLへ変更しない。

## 更新・取り下げ・停止

- 更新: 元の入力を変えてpublisherで新しい版を生成し、bundle → dry-run → 配備の順で差し替える。未来の写真は、その公開時刻以降の再生成が必要。
- 取り下げ: 対象を入力から外して新しい版を作る。公開フォルダーにも旧JPEGを残さない。Workerも現在のcatalogにないJPEGを拒否する。
- 停止: publisherの `--paused` で新しい停止版を作り、同じWorkerへ配備する。アプリが停止catalogを取得すると端末内の写真を破棄する。
- catalogは最大48時間で失効する。今回は定時の写真供給や自動更新の稼働は約束していない。継続配信開始時に写真供給に合わせて運用頻度を定める。

## 2026-09-10の結果

- Node対象テスト14件成功。Python fixture生成テスト5件成功。
- 実WorkersランタイムのA → B → 停止が成功。`C:/dev/neko-widget-official-local-proof-20260910/http-drill-final/result.json` に記録。
- 配備dry-run成功。実アップロード・公開なし。
- Wranglerの既存Cloudflareログインと対象アカウントをread-onlyで確認。実配備の権限や公開URLはdry-runでは確認できていない。
- 元のiOSアプリコードとCI workflowには変更なし。アプリ・Widgetの実装検証は既存の成功した `81e3aff` の記録を保持する。
