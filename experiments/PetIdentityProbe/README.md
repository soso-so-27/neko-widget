# 猫個体識別・独立iPhone試作

開発用の合成入力テスト。本体のねこのまど、共有データ、プロフィール、写真ライブラリへはアクセスしない。自動個体識別の製品版ではない。

## 含むもの

- 別アプリ `local.nekomado.PetIdentityProbe`。写真権限、App Group、iCloud、通知、通信実装、解析SDKなし。
- CPU基準→Core ML優先の2操作。推論は専用actorで実行し、UIを処理スレッドにしない。
- 固定モデルのサイズ／SHA-256確認、合成RGB 3種類、18回のwarm処理、512次元出力の検査。
- Core ML結果とCPU基準のコサイン類似度を比較（合成入力間の最低値0.999以上）。GPU／ANE使用率を確認したことにはしない。
- 結果はメモリ内のみ。任意の共有は集計JSONのみで、入力と特徴量を含めない。再測定開始時に旧結果を無効化し、失敗後に古い成功値を共有しない。

## 実行環境の固定

- 最低iOS 17.1。Swift 5。
- ONNX Runtime公式SwiftPM 1.24.2、revision `b7fb7f7dea8a2469e6335d95a61b8f36d0dc83b2`。
- [公式manifest](https://github.com/microsoft/onnxruntime-swift-package-manager/blob/b7fb7f7dea8a2469e6335d95a61b8f36d0dc83b2/Package.swift)のバイナリSHA-256は`f7100a992d2a8135168c8afd831e6a58b465349101982aa58b3e11d36e600b54`。SwiftPMで照合する。
- [公開モデル](https://huggingface.co/open-noodle/pet-recognition-small/tree/9dd4c915be29a81b116b3e30eb996c59d0e7ede0)は89,227,604 bytes。SHA-256は`6a5e2373ab348bed588cef4072f3914ca9c8bacde3e8d0651019e8dad86b24ba`。
- アプリには入力を`1×3×224×224`へ固定した派生だけを同梱する。89,227,594 bytes、SHA-256は`32adffda4e65f790ae624d828b79db7a18f7fdb1facdce1cc91bb9951d948c0b`。元モデルと派生の両方をアプリへ入れない。

旧Windows確認はORT 1.22.1だった。今回のCPU／Core MLは同じ1.24.2で揃え、過去のPC時間をiPhoneの性能として比較しない。

## Macでの準備

Xcode、Python 3.11以上、XcodeGenが必要。

```sh
cd experiments/PetIdentityProbe
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
python3 prepare.py
python3 fix-model.py Resources/model.onnx Resources/model-fixed.onnx
xcodegen generate
open PetIdentityProbe.xcodeproj
```

`prepare.py`だけが公開モデルを固定URLから取得する。アプリ実行時は通信しない。既存ファイルの検証が失敗した時は上書きせず停止する。モデルと生成プロジェクトはgit対象外。

無署名の端末向けコンパイルとSimulator起動は`run-ci.sh`。既存の手動`ios-scale.yml`へ`pet_identity_probe=true`を渡すと、写真の大量投入テストを起動せず、この試作だけを確認する。既定値falseで既存のscale動作は変わらない。通常の本体CI、main更新、TestFlightアップロードにはつながない。

実機インストールにはMac側で、この独立bundleの開発署名と接続したiPhoneを選ぶ必要がある。プロジェクトの`CODE_SIGNING_ALLOWED=NO`は無署名確認用なので、実機実行時に明示的に開発署名を有効にする。既存アプリの署名設定・配布証明書を使い回して自動登録はしない。

## 読み違えてはいけない値

- `platform=simulator`はコンパイルと合成入出力の証拠だけ。iPhone実機の速度、電池、メモリ上限の証明ではない。
- `sessionLoadMS`は新しいORTセッションの準備時間。モデルのハッシュ検査やアプリの起動時間は含めない。OSのモデルキャッシュが空であることも保証しない。
- warmの中央値／P95は18件の参考値。連続大量処理の安定性や発熱試験ではない。
- メモリはプロセス全体のphysical footprintを20msごとに観測した最大値。既存runtimeやUIも含み、瞬間的な真のピークやモデル単体容量ではない。
- Core ML優先はCPUフォールバックを許容する。成功＝全演算がANEに載った、ではない。
- Core MLの失敗は`PROBE_COREML_UNVERIFIED`として残す。CPU smokeの成功と、Core MLの確認を分ける。`summary.json`は`coreml_ep_run_completed`（呼び出しの完了）、`coreml_compiler_error_lines`（検出したコンパイルエラー）、`coreml_acceleration_verified`（今回常にfalse）を別に記録する。CI greenは加速合格を意味しない。

## 初回CIから分かったこと

[33937590974](https://github.com/soso-so-27/neko-widget/actions/runs/33937590974)でiPhone向け無署名コンパイル、iOS 18.6 Simulator起動、CPU／Core ML EPの合成入力実行を確認した。CPU中央値93.92ms、Core ML優先208.46ms、出力のコサイン類似度はほぼ1だった。ただしCore ML内部ログには`unbounded dimension`と形状不一致エラーがあり、出力が返ったことを加速成功とは扱えない。

この具体的エラーに対し、[公式helper](https://onnxruntime.ai/docs/tutorials/mobile/helpers/make-dynamic-shape-fixed.html)でbatchを1へ固定する。`fix-model.py`は元／派生ハッシュ、固定形状、合成入力の出力一致を検査してから次へ進める。Windowsの3入力で最大絶対差`2.23e-7`（許容`1e-5`）を確認した。精度評価ではなく変換の整合性確認である。Core ML EPは静的形状のノードだけを対象にするが、それでも全ノードの委譲は保証しない。

## 次の実機判断

入力形状固定後の[CI 33938262561](https://github.com/soso-so-27/neko-widget/actions/runs/33938262561)も、iPhone向け無署名コンパイル・Simulator起動・合成出力検査に合格した。Core MLコンパイルエラーの検出は32行から0行になった。記録は[集計JSON](results/2026-09-05-simulator.json)に保持する。異なるホストでの2回のCIなので、厳密な速度改善率は計算しない。

| 固定モデル・同一Simulator実行内 | CPU | Core ML優先 |
| --- | ---: | ---: |
| セッション準備 | 約270 ms | 約22,586 ms |
| warm推論中央値 | 約97 ms | 約189 ms |
| プロセスメモリ観測最大値 | 約229 MiB | 約1,080 MiB |

出力のコサイン類似度はほぼ1。無署名Debugアプリは`du -sk`で118,988 KiB（約116 MiB）だった。これはIPAダウンロード容量や本体アプリの増分ではない。

**次の実機判断はCPUから始める。Core MLの本体組み込みは保留。** シミュレータ上とはいえ、Core MLの初回準備とメモリに懸念がある。実機で同じ数字になるとは断定せず、CPUの実用性を先に確認する。ユーザーの普段のアプリへモデルを入れて試すことはしない。Core MLボタンは開発試作に残るが、低メモリ端末で安易に反復実行する案内はしない。

実機では端末型番、OS、時間、メモリ、温度状態を記録する。最低対応機クラスの実用性が低ければ本体へ追加しない。このWindows環境とホスト型CIだけでは実機性能を確定できないため、Macに接続できるiPhone、または別途承認した実機配布経路が必要。

次に、使用を許可された実写真と固定protocolで精度を評価する。写真を外へ送らない。合成入力は猫の識別精度を評価できない。[ADR-016](../../NekoWidget/docs/ADR-016-猫個体5-shot分離実験.md)のunknown、独立episode、precision／coverageと未使用家庭の検証境界を維持する。

モデルの商用配布条件、必要な帰属表示、実写評価は未完了。[単体調査記録](../../NekoWidget/docs/猫個体識別-モデル単体確認.md)も参照。今回、GalleryのAGPLコードは取り込んでいない。
