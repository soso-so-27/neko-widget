# 猫個体識別・独立iPhone試作

開発用の独立検証アプリ。合成入力の速度測定、写真1枚の入力確認、少数枚からの個体判定の診断を分ける。本体のねこのまど、共有データ、プロフィールへはアクセスしない。自動個体識別の製品版ではない。

## 現在の判断と配布状態

2026-09-08 / Build 13アップロード済み・Apple内部配布状態はログイン待ち: [保留の距離差診断](WITHHELD-SEPARATION.md)を追加。保存済みの同じ12枚で、保留の「登録した猫に近い／別の猫に近い／同点／比較不能」と方向別の距離比集計を確認できる。判定・モデル・閾値・選択保存・本体は変更しない。集計だけでも各猫1枚ならその1枚の距離比が分かる点をUI/docsに明示。写真/ID/特徴量/個別行は共有しない。

SHA `987896e58913c0b10ce087c193b7e5419508a07f` の専用CI `34197918921` は79テスト成功、合成画面の目視と独立レビュー完了。同一SHAの専用配布 `34198506300` も成功（3分24秒）し、独立app record・署名・archive/IPA検査・Apple検証/アップロード成功を確認。ただしASCが`authResult=FAILED`のログイン画面へ戻ったため、Build 13のApple処理終了/本人用グループ「テスト中」はまだ確認していない。本人へ再ログインを依頼済み。新規配布runや再アップロードは不要で、復帰後は専用アプリ`6808865207`のBuild 13状態だけを確認する。

Build 13での本人操作は「保存した12枚で比較する」→「比較結果を共有」。新たな選択・交換・判定写真追加は不要。精度の改善が完了したわけではなく、本人の保留方向と距離差は次の実機結果待ち。

2026-09-08 / Build 12配布済み: [保存済み写真による比較](IDENTITY-RECOVERY-COMPARISON.md)に、候補方法でも使えない見本の端末内プレビューと「この1枚を入れ替える」を追加。Build 11本人結果はAの見本3/5→5/5、Bは4/5のままで両方法とも個体判定未評価。判定用はA/B各1枚あるため、追加要求せずBの失敗見本だけを交換できるようにした。その他の選択・順序・枚数、モデル、閾値、本体は変更しない。写真やIDを共有JSONへ追加しない。

SHA `65a9536cfd3a7fecf8c2458290374265332dbf4b` の専用CI `34194849021` は無署名device build・74テスト成功、独立レビューで阻害点なし。写真付き画面の目視確認と、同一アプリコードの画像なし表示証拠も確認（スクリーンショット取得方式の制約は比較文書に記録）。同一SHAの専用配布 `34195588334` も成功。ASCで0.1 (12)、UUID `ff7e0596-2737-4abd-85a7-ab43092aee79` の処理「終了」、内部「テスト中」、既存「自分用（猫識別検証）」・招待1人・アップロード15:42を確認。

本人操作: 専用アプリをBuild 12へ更新 →「保存した12枚で比較する」→「使えなかった見本」の「この1枚を入れ替える」で同じ猫の別写真を1枚選択 → 再比較 →「比較結果を共有」。ほか11枚の選び直しや判定写真の追加は不要。写真アプリの原本は削除・編集しない。交換後の入力回復と個体識別の正誤は未確認で、本体への自動振り分け採用は引き続き保留。

運用方針（2026-09-08本人指示）: テスト期間中、この独立検証アプリを既存本人用グループへ内部TestFlight配布する際、都度の許可確認は不要。必要なビルド・安全確認後に配布とApple側の状態確認まで進める。外部テスターの追加、本体アプリの公開、署名・承認ゲート設定の変更までを自動で許可されたものとは扱わない。

2026-09-08 / Build 10: Build 9の本人結果（100%/75%は0候補、50%＋余白は1候補）を受け、50%検出を再利用して元の取得画像へ枠を戻す端末内の切り抜き確認を追加。写真の再選択、追加の検出、保存、個体識別fallbackは行わない。統合SHA`6747a51`の専用CI `34185320490`で無署名device build・61テスト成功。先行候補の生成画像による表示確認と独立リリースレビューも完了。mainへ同じSHAを反映し、専用配布run `34185810791`で0.1 (10)の署名・Apple検証・アップロード成功。Apple処理「終了」、既存グループ「自分用（猫識別検証）」で内部Build 10「テスト中」、招待1人、アップロード表示13:11を確認し配布完了。本人写真での枠の正しさはまだ未確認で、個体識別成功を意味しない。詳細は[比較文書](DETECTOR-SCALE-COMPARISON.md#build-10-内部配布準備--2026-09-08)を参照。

2026-09-08 / Build 9: [保存済み1枚の縮小・余白比較](DETECTOR-SCALE-COMPARISON.md)を専用TestFlightへ配布済み。Apple処理「終了」、既存本人用グループで内部Build 9「テスト中」を確認。Build 8の本人実機結果は基準画像1/1/2候補でCIと一致、保存済み1枚はraw0件。既存の1ボタンへ、条件成立時だけ形式統一した100/75/50%の比較を追加。元結果の上書きや個体識別fallbackはしない。本人の写真はリポジトリ・CIへ含めない。統合SHA`5efc4ae`の無署名device build・57テスト、専用配布run`34178971279`に成功。本人の縮小比較結果は未確認で、原因特定・修正完了ではない。証拠と制約は比較文書を参照。

2026-09-08 / Build 8: [同じ実機での基準画像比較](DETECTOR-CONTROLS.md)を追加。生成済み猫画像3枚と保存した猫Aの先頭1枚をボタン1回で比較し、新たな写真選択やモデル実行は不要。元の検出条件は変更しない。実写真の候補0件はBuild 7の形式変換では改善せず、別途CIでは1匹の生成猫に大小2つの候補が出る現象を確認した。自動個体振り分けは引き続き保留。Build 8はApple処理完了・本人用グループで内部テスト中を確認済み。本人の実機比較結果は上記のとおり受領済み。以下の旧版の配布説明には当時の状態が含まれるため、最新状態はこの節を優先する。

2026-09-08追記: Build 6はApple処理完了と本人向け内部テスト中を確認済み。実写はVisionの候補そのものが0件で、本人による元写真の表示方向の確認も完了した。Build 7は[同じ1枚の画像形式比較](INPUT-FORMAT-COMPARISON.md)だけを追加し、47対象テスト・Appleアップロードが成功。Apple側の処理/配布状態は同文書に記録する。写真の再選択、識別基準の緩和、本体への組み込みはしない。

Build 3の実写結果は、A:正解0/誤り0/保留15、B:正解5/誤り0/保留10。判定率5/30=16.7%で事前基準70%を満たさない。判定済み5枚の正解率100%を一般精度と呼ばず、自動振り分けの本体採用は見送る。保留の原因は旧JSONから区別できない。

Build 4は内部TestFlightへ配布済み。診断内訳と写真選択の再利用に限定。選択途中も最大40枚の参照だけを端末内・バックアップ除外・Complete保護で保存し、再起動/更新後に同じ選択を使える。写真自体をコピーしない。欄ごとのpreselectionで変更でき、同じ40枚を再実行可。診断は合格判定と分離し、モデル・閾値は据え置く。[追補](REAL-PHOTO-PROTOCOL.md)参照。旧版が消去した選択は復元できない。確認記録は末尾。

Build 5では[少ない写真で始める診断](LOW-BURDEN-DIAGNOSIS.md)を実装。まず猫Aの見本1枚で入力工程を確認し、保存した選択を次の診断へ引き継ぐ。見本は各5枚を維持し、判定写真は片方の猫の1枚から実行可能。診断の分母は実際の選択枚数で、未選択の枠を保留として埋めない。厳密なheldout検証は従来の40枚・同じ条件を維持する。候補CIは成功（38対象テスト・失敗0）、Appleアップロードも成功。処理完了・内部配布状態はASCログイン待ちで未確認。実写の識別精度が改善したとの主張ではない。

## 含むもの

Build 6は1枚診断の検出内訳を追加し、候補CIの43対象テストとAppleアップロードが成功した（2026-09-08）。Appleの処理完了・内部配布状態はログイン待ちで未確認。本人のBuild 5結果では1024×768の読み取り成功後に`catNotDetected`となり、モデル未実行だった。旧JSONでは動物候補なし・低信頼度・ラベル条件不一致を区別できないため、原因はまだ確定していない。同じ保存済みの1枚を使い、Visionの1回の結果から候補数・動物クラス名・信頼度の集計を表示/任意共有する。写真・参照ID・特徴量・座標は共有しない。`Cat`完全一致、信頼度0.5、切り抜き、モデル、個体判定は変更せず、本体アプリへの組み込みも行わない。[診断追補](LOW-BURDEN-DIAGNOSIS.md#build-6-検出内訳の診断)参照。

- 別アプリ `jp.nekowidget.petidentityprobe`。実写評価だけ写真アクセスを要求し、限定許可に対応。App Group、iCloud capability、通知、通信実装、解析SDKなし。
- CPU基準→Core ML優先の2操作。推論は専用actorで実行し、UIを処理スレッドにしない。
- 固定モデルのサイズ／SHA-256確認、合成RGB 3種類、18回のwarm処理、512次元出力の検査。
- Core ML結果とCPU基準のコサイン類似度を比較（合成入力間の最低値0.999以上）。GPU／ANE使用率を確認したことにはしない。
- 結果はメモリ内のみ。任意の共有は集計JSONのみで、入力と特徴量を含めない。再測定開始時に旧結果を無効化し、失敗後に古い成功値を共有しない。
- 実写処理は[固定protocol v1と診断追補](REAL-PHOTO-PROTOCOL.md)。Build 5候補は入力1枚→見本5枚/猫と判定写真1〜30枚の診断専用。既存の部分選択・40枚選択を同じ保存形式で再利用できる。写真取得は選択IDだけ・PhotoKitネットワーク無効、個別結果は端末内だけに表示。本体の所属へ書き戻さない。

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
python3 prepare-notices.py
swift make-icon.swift
xcodegen generate
open PetIdentityProbe.xcodeproj
```

`prepare.py`が公開モデルを固定URLから取得し、`prepare-notices.py`がハッシュ固定した上流ライセンスを取得する。アプリ実行時は通信しない。既存モデルの検証が失敗した時は上書きせず停止する。モデルと生成プロジェクトはgit対象外。

無署名の端末向けコンパイルとSimulator起動は`run-ci.sh`。既存の手動`ios-scale.yml`へ`pet_identity_probe=true`を渡すと、写真の大量投入テストを起動せず、この試作だけを確認する。既定値falseで既存のscale動作は変わらない。通常の本体CI、main更新、TestFlightアップロードにはつながない。

Macを使う場合は独立bundleの開発署名と接続したiPhoneを選ぶ。`CODE_SIGNING_ALLOWED=NO`は無署名確認用なので、実機実行時だけ署名を有効にする。Macを持たないユーザー向けには、以下の承認済み独立TestFlight経路を使用する。

## 独立TestFlight（2026-09-05承認）

ユーザー承認に基づき、本体を置き換えない専用アプリを登録した。

| 対象 | 登録値 |
| --- | --- |
| アプリ名 | 猫識別・動作確認 |
| Bundle ID | `jp.nekowidget.petidentityprobe` |
| App Store Connect ID | `6808865207` |
| 配布プロファイル | `NekoWidget Pet Identity Probe AppStore 2026` (`72JM846MGP`) |
| 配布範囲 | 本人向け内部TestFlightのみ |

専用workflowは`.github/workflows/pet-identity-testflight.yml`。`main`上の手動実行だけを許可し、既存`testflight` Environmentの承認・branch制約は変更しない。証明書とASC APIキーは既存のものを利用し、専用profileだけを`PET_IDENTITY_PROVISIONING_PROFILE_BASE64`へ追加する。本体profile secret・本体workflow・共有サーバーは変更しない。

`release.sh`と`verify-release.py`で、Appleのアプリレコード／profile／archive／IPAが専用bundleに一致することを検査する。`testFlightInternalTestingOnly=true`でexportし、外部テスターやApp Store公開へ転用しない。公開GitHub artifactにはIPA、モデル、秘密情報を含むログを保存しない。アップロード成功はAppleの処理完了・インストール可能を意味しないため、配布状態は別途確認する。

速度測定は「CPUで測定する」→「JSONを共有」で、実際の猫写真は使わない。次の実写評価は「実写真で2匹を見分ける」から別途明示操作する。どちらも結果はメモリ内のみ。Core MLは任意の追加比較で、未共有結果を失う可能性の警告を出す。今回のCIはCPUと実写処理の合成fixtureに絞り、既に確認したCore MLの重い比較は既定で再実行しない（必要な場合だけ`PROBE_INCLUDE_COREML=1`）。

上流MIT、Apache-2.0、ORT第三者告知とソース案内をアプリ内ライセンスページへ同梱する。内部試作の配布準備であり、実写精度・商用採用・学習データ権利の審査が完了したことにはしない。

### 配布準備の到達点（2026-09-05）

- コード候補`2475104885790c8acb7d42ef42625d37a23c53b4`の[CI 33941248554](https://github.com/soso-so-27/neko-widget/actions/runs/33941248554)、統合後の[main CI 33942111316](https://github.com/soso-so-27/neko-widget/actions/runs/33942111316)が成功。iPhone向け無署名ビルド、Simulatorの合成入力検査、CPUを主操作にした初期画面を確認済み。実機性能・実写精度の確認ではない。
- 本人用内部グループ「自分用（猫識別検証）」を作成し、既存の本人テスター1人だけを追加済み。自動配布は有効、登録ビルドはまだ0。
- ユーザーが専用profileを手動保存。CMS署名・専用bundle・Team・有効期限・既存配布証明書一致を検査し、`PET_IDENTITY_PROVISIONING_PROFILE_BASE64`だけを新規設定済み。本体と本体用署名設定は変更していない。
- 初回配布準備で3点を修正：Appleのprofileに標準で含まれる`com.apple.token`の許容漏れ、XcodeGenがInfo.plistへ書く既定バージョン、`codesign --extract-certificates`の省略可能引数を別argvにした不備。profileの許容リストとアプリ自身の権限は区別し、アプリのtoken・別bundle・別Teamアクセスは引き続き拒否する。署名検証の失敗箇所は秘密を出さず固定文言で識別する。
- 根拠：[Apple TN3125](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles)、[XcodeGenのInfo.plist初期値](https://github.com/yonaskolb/XcodeGen/blob/master/Sources/XcodeGenKit/InfoPlistGenerator.swift)、[Apple codesign引数定義](https://github.com/apple-oss-distributions/security_systemkeychain/blob/security_systemkeychain-55105/src/codesign.cpp#L163)。旧ログが汎用エラーだった最後のrunについて、実際に証明書抽出まで到達したかは確定していない。
- `33942426779`は署名前、`33942624240`と`33942819684`は署名archive後の検証で停止し、いずれもAppleアップロード前。修正後の[配布run 33943089253](https://github.com/soso-so-27/neko-widget/actions/runs/33943089253)（コード`eccb6b9cb177e2337c6654a8bf2e0b4775530bfc`）、Build `0.1 (1)`は成功。archive・IPAの署名/内容検証、Apple validate、Apple uploadをすべて通過し、2026-09-05 12:56 JSTにアップロード完了。同じアプリコードの成功CIは理由なく再実行しない。
- Appleの後段処理でBuild 1は`90208`（`onnxruntime.framework`のMinimum OS不整合）となり配布失敗。TFのルート画面は「ビルドなし」だったが、`testflight/ios`の「ビルドのアップロード」でエラーを確認できた。altoolの成功だけでは処理成功にならない。
- 固定配布zip（SHA-256は上記）を実測し、iOS arm64 frameworkの`MinimumOSVersion=15.1`が存在し、FAT内arm64 sliceの先頭が`!<arch>\n`で静的アーカイブと確認。中身は静的binary・Headers・Info.plistのみで実行時resourcesはない。過去のdevice build logには同frameworkをapp/Frameworksへコピーし`-remove-static-executable`する工程があった。
- 現行Xcodeが静的frameworkのbinaryを除きresourcesをコピーすること自体は正常であり、旧TN2435の非embed説明だけでは判断しない。またXcodeGenのpackageでは`embed:false`だけではコピー抑止にならない可能性があるため、この設定案は採用しない。[現行Apple資料](https://developer.apple.com/documentation/xcode/creating-a-static-framework)、[XcodeGen package処理](https://github.com/yonaskolb/XcodeGen/blob/master/Sources/XcodeGenKit/PBXProjGenerator.swift)。
- device build log 368–371行で、Xcodeが元static archiveを除いた後に`arm64-apple-ios17.1`のstub binaryを注入すると確認。元framework metadataは15.1のままなので、実binaryの最低OSより低い宣言となっていた。空shell除去案は実行前に取り下げた。
- `align-ort-stub-minimum-os.py`は専用app内の生成済ORT 1.24.2 frameworkだけを対象に、`vtool`の全sliceのplatform/minosをアプリdeploymentと照合し、既知の元15.1または補正済み値だけを許容する。metadataの最低OSを実stubに合わせ（引き下げ禁止）、署名有効時は同じ専用Distribution証明書でframeworkを再署名してからXcodeがappを署名する。archive/IPAでも最低OS整合とapp/frameworkの証明書一致を確認。モデル・ライブラリ版・上流バイナリは変更しない。
- 修正`a92d08c2990b3590cff7444f22b6336f2ab55c59`は独立署名レビューと対象self-testを通過。[候補CI 33944286226](https://github.com/soso-so-27/neko-widget/actions/runs/33944286226)でiPhone向けbuildとSimulator起動/合成入力が成功（8分12秒）。同じSHAをmainへ進め、重複した合成入力CIは追加しなかった。
- [main配布CI 33944688433](https://github.com/soso-so-27/neko-widget/actions/runs/33944688433)でBuild `0.1 (2)`の署名archive・IPA検証・Apple validate/uploadが成功（4分9秒、2026-09-05 13:33:59 JST upload完了）。Apple処理完了と内部配布への反映を確認するまで「配布完了」としない。
- 同日、ASCでBuild 2のアップロード「終了」、内部ビルド「テスト中」、グループ「自分用（猫識別検証）」への自動配布を確認。Build UUIDは`ad8023fa-9ce3-433e-a9c4-1be2b53810f3`。Build 1の90208は解消し、本人用TestFlight配布は完了。実機インストール・CPU測定と結果JSON共有は本人の次操作であり、実機性能や個体識別精度の確認済みとは扱わない。

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

モデルの商用採用判断と実写評価は未完了。内部配布用の必要な帰属表示は上記の通り追加した。[単体調査記録](../../NekoWidget/docs/猫個体識別-モデル単体確認.md)も参照。GalleryのAGPLコードは取り込んでいない。

## 実機CPU結果から実写評価へ

ユーザーが共有したBuild 2の実機CPU集計は、固定hash/runtime一致、warm中央値16.71ms・P95 17.54ms、準備92.55ms、初回19.17ms、プロセスメモリ観測230.06MiB、前後thermal nominalだった（18回、合成入力）。CPUで実写評価へ進む見込みはある。写真読込・猫検出込みの時間、長時間の発熱・電池、最低対応機性能、猫の正誤は未検証。

次のBuildではCPU方式だけを実写評価へ利用する。ライブラリ全体の走査・分類保存・モデル更新・高速化方式の追加はしない。実装と署名の確認が通っても実写のprecision/coverageが確認済みとは扱わず、実機で返された集計を待つ。

実装候補`330b7b5`の[CI 33950686502](https://github.com/soso-so-27/neko-widget/actions/runs/33950686502)は成功（全体5分、19対象テストの実行4.17秒）。分類11件、画像前処理・共有・選択消去7件、合成CPU1件。RGB色順・上下方向、exact bbox変換、旧picker完了による選択復活の拒否、集計JSONの固定項目を確認した。独立レビューで指摘されたpicker遅延完了は提示UUIDの照合で修正済み。初期画面の実描画も確認。写真権限の実機操作と実写の結果は本人の確認待ちで、CIにユーザー写真を投入していない。

同じSHAをmainへ進め、Build 3の[専用配布run 33950970228](https://github.com/soso-so-27/neko-widget/actions/runs/33950970228)が成功（2分21秒）。archive/IPA署名検証、Apple validate/uploadを通過し、2026-09-05 15:54:26 JSTに提出完了。配布完了はApple処理と本人グループの反映を確認してから記録する。

同日ASCでBuild `0.1 (3)`のアップロード「終了」、内部ビルド「テスト中」、グループ「自分用（猫識別検証）」への反映を確認し、内部配布完了。Build UUIDは`2a711a9a-30e3-4493-94c0-708d2fb2f811`。残りは本人による未使用40枚の選択と集計JSONの共有、実写結果の採否判断。CPU速度の再測定やCore ML比較は追加依頼していない。

## Build 4：保留理由の診断と選択の保存

初回実写結果は冒頭のとおりNo-Go。原因別件数が旧JSONにない点を補い、本人の写真選択を繰り返さないために小さな端末内参照保存を追加した。原本・本体は変更なし。独立レビューは保存/プライバシー/古いcallback/診断フラグに絞り、blocking指摘なし。既存の2担当を再利用し、新規サブエージェントと履歴複製は行っていない。

- 初回候補CI `33954550645`はiPhone向けコンパイル成功、29対象テストのうちJSONの小数完全一致2箇所とSimulatorで返らないfile protection属性の確認1箇所が失敗。JSON比較のみ4 ULP許容とし、保護設定は同じCompleteのまま、Simulatorでは指定flags、実機テストでは属性を検査する形に修正した。分類判定・閾値は緩めていない。Simulatorで実機のロック時データ保護を実証したとは扱わない。
- 修正候補`909ec43`の[CI 33954937929](https://github.com/soso-so-27/neko-widget/actions/runs/33954937929)は成功（全体4分38秒、対象29テスト3.8秒・失敗0）。理由内訳15件、画像/共有/選択8件、保存復元5件、CPU smoke1件。独立受け入れとの区別、部分選択・同一欄変更・再起動相当の復元・バックアップ除外・破損時fail-closed・古いpicker拒否を確認。初期画面のスクリーンショットも確認済み。
- 同じ候補SHAをmainへ進め、[専用配布run 33955181731](https://github.com/soso-so-27/neko-widget/actions/runs/33955181731)が成功（3分23秒）。Build `0.1 (4)`のarchive/IPA検証・Apple validate/uploadが完了。2026-09-05 17:28 JSTのASC一覧でBuild UUID `ed5940b8-ef8b-4b03-a6a0-de811f9d23ab`の処理中を確認。内部配布完了は別途Apple表示で確定する。

次の本人操作は、検証用アプリの更新後「実写真で保留の原因を調べる」。旧版に参照保存がなかったため初回だけ再選択が必要だが、前回と同じ写真を使ってよく、新しい独立40枚を求めない。その後は同じ選択で再実行できる。写真・参照IDの共有は求めず、原因別の集計JSONだけを確認する。CPU再測定とCore ML再検証は不要。

同日、ASCのBuild 4行でアップロード「終了」、内部ビルド「テスト中」、本人用グループ「自分用（猫識別検証）」・招待1件を確認し、内部配布完了。Apple反映はこれで確認終了。本人端末での更新・PhotoKit picker操作・実写の診断結果は未確認で、次の本人操作とする。
