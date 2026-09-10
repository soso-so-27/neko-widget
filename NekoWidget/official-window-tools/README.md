# 公式まどのローカルcatalog生成

承認済みのローカル画像から `official-cats` 配信の確認用ファイルを生成する Python CLI です。**アップロード、配信、公開、外部への通信は行いません。** 出力ができても公開されたことにはなりません。協力者、写真の公開同意、配信サーバーが既に用意されているとは仮定しません。

## 実行環境

- Python 3.11 以降、Pillow 12.3 系（色変換に Pillow の ImageCms を使用）
- `python -m pip install -r requirements.txt`
- 元写真、提供元JSON、生成物はリポジトリ外の作業領域へ置き、commitしないでください。このフォルダー内の `.private/`、`inputs/`、`outputs/` もgit対象から除外します。
- 画像dir、JSON、出力先はローカルのファイルシステムのみ。URL、UNC共有、Windowsのネットワークドライブは対象外です。

## 提供元JSON

UTF-8のJSONで、最上位は `photos` 配列だけです。入力は最大60件、`id` は配列全体で一意にします。未来・期限切れの行も承認・形式・期間・パスを検証するため、未承認の候補一覧をそのまま渡す用途ではありません。

以下は形式説明です。実行日時に合わせて公開期間を設定し、実在する承認済み画像を指定してください。サンプルの同意や写真は存在しません。

```json
{
  "photos": [
    {
      "id": "example-20260910-01",
      "catID": "example-cat",
      "catName": "猫の公開名",
      "credit": "提供者の公開クレジット",
      "caption": "任意の説明。改行は2個まで。",
      "photographedOn": "2026-09-01",
      "publishedAt": "2026-09-10T00:00:00Z",
      "expiresAt": "2026-09-17T00:00:00Z",
      "sourceFilename": "approved/photo.jpg",
      "publicationApproved": true,
      "internal": {
        "permissionRecord": "operatorが別途管理する承認記録の参照"
      }
    }
  ]
}
```

- `publicationApproved` はJSONの真偽値 `true` が必須。`false`、省略、文字列 `"true"`、数値 `1` はエラーです。CLIは同意の実在や範囲を検証しません。公開提供の確認はoperatorの別業務です。
- `sourceFilename` は `--images-dir` 内の相対パス。区切りは `/`。絶対パス、`..`、外へ出るsymlink、Windowsの代替データストリームは拒否します。
- `id`、`catID` は `[a-z0-9-]` の1〜64文字です。
- `catName` は1〜30文字、`credit` は1〜80文字。空白だけ、前後の空白、制御文字は拒否します。
- `caption` は省略可能で100文字以内、LF改行は2個以内（最大3行）。`photographedOn` は省略可能で、実在する日付 `YYYY-MM-DD` にします。文字数はPythonのUnicodeコードポイント数で数えます。
- `publishedAt`、`expiresAt` はUTC秒精度の `YYYY-MM-DDTHH:MM:SSZ`。小数秒やUTCオフセット表記は拒否します。`publishedAt < expiresAt`、差は14日以内です。
- `internal` は任意の内部記録です。公開catalogへは出力しません。その他の未知のキーは誤記として拒否します。公開される `credit` や `caption` に内部情報を書かないでください。

## 通常生成

このディレクトリを作業ディレクトリとして実行します。

```powershell
python .\build_catalog.py --input C:\official-window-private\source.json --images-dir C:\official-window-private\images --output C:\official-window-review\batch-001
```

`--output` の親ディレクトリはあらかじめ用意します。指定した出力ディレクトリ自体は**存在してはいけません**。空の既存ディレクトリ、ファイル、symlinkも上書きしません。再生成は新しい名前で行います。

- 生成時刻は実行時のUTC、catalogの有効期限は既定48時間後です。`--valid-for-hours 24` のように1〜48時間を指定できます。
- `publishedAt <= 生成時刻 < expiresAt` の写真だけを新しい公開日時順に収録します。同時刻はid順です。未来予約分はその日時以降に再生成しない限り配信物に入りません。期限切れ・未来だけ、または入力0件なら `enabled: true, photos: []` が生成されます。
- EXIFの向きを適用し、縦横比を保って長辺最大2048pxへ縮小します。拡大はしません。Pillowで読める単一フレーム画像が対象で、動画・アニメーション・複数ページ画像は拒否します。HEIC対応はこのツールに追加していません。
- 埋め込みICCがあればsRGBへ色変換してから除去します。透過部分は白に合成します。新しいRGB画素だけをJPEG（quality 88）へ書き、元のEXIF/GPS、ICC、XMP、コメント、PNGテキスト等は引き継ぎません。JPEGとして必要な新規の形式ヘッダーは含まれます。元画像は変更しません。
- ファイル名は生成JPEGのSHA-256小文字hex + `.jpg`。同じJPEGは同じ1ファイルへまとめます。公開schemaの `imageFilename`、`sha256`、`width`、`height` は生成結果から設定します。
- 出力は `catalog.json` と収録写真のJPEGだけ。権利確認記録、元ファイル名、元ディレクトリ、承認フラグはcatalogへ出しません。
- 入力検証・JPEG生成をすべて終えてから出力先を作り、catalogを最後に書きます。容量不足などのI/O障害では新規出力先が不完全なまま残る可能性があります。終了コード0以外の出力は利用・公開しないでください。既存の出力や写真を自動削除する処理はありません。

## 停止catalog

元画像やJSONがなくても生成できます。入力指定との併用は拒否します。

```powershell
python .\build_catalog.py --paused --output C:\official-window-review\paused-001
```

`enabled: false, photos: []` の `catalog.json` だけを生成します。有効期限は通常と同じです。**これは停止ファイルのローカル生成だけです。実際の公開先の切替や、既に配信されたJPEGの削除は行いません。**

## 検証

```powershell
python -m unittest discover -s . -p "test_*.py" -v
```

テストは一時ディレクトリ内の合成画像だけを使用します。向きと画素、寸法、metadata除去、hash、公開schema、承認、期間境界、未来非掲載、停止、入力上限、パス境界、既存出力保護を確認します。symlink作成権限がないWindowsでは当該1件だけskipします。

## 公開運用へ進む前に残ること

- 提供元の同意・公開範囲・credit・休止/取り下げ手順を確認し、画像と文章を人が確認すること。
- 審査済み出力を公開する仕組み、HTTPS配信先、catalogとJPEGの整合した更新、生成失敗時の扱い。CLIには配信機能を足していません。
- 定期再生成、48時間のcatalog失効、写真ごとの失効を踏まえた運用頻度。未来写真は自動で追加されません。
- 停止・取り下げ後の**旧JPEGの物理削除**、CDN/HTTP cache期限と無効化、端末内cacheの期限・削除、保持済みコピーの扱い。catalogから外すことは公開済みファイルを消すことではありません。
- Swift受信側との実ファイル相互運用、実写真の色・向き・表示品質、実際の公開権限・配信状態。このツールの合成テストだけでは確認済みにしません。
