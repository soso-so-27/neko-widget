# ADR-007：Build 8で計測表示を修復し、表示・体験変更を凍結する

- 状態：承認済み（Like修復は維持、1週間計測は撤回）
- 日付：2026-08-17
- 対象：TestFlight Build 8のLike表示修復と最終UX

> **2026-08-17追記：** Build 8のLike同期修復は維持するが、高解像度20件TimelineによりMedium / Largeがplaceholder相当となったため、実機ゲートは未達だった。Build 9でTimelineを修復し、Build 10で写真ブラウザの標準ページングを修復した。同日、結果が製品判断を変えないため1週間計測の再実施を撤回した。新しいbaselineから再開せず、計測を理由に端末へのbuild導入を制限しない。resource条件は[ADR-008](ADR-008-高解像度WidgetのTimeline負荷制限.md)を正本とする。

> **2026-08-24後続決定：** 下記のApp Store Connect名はBuild 8時点の判断として残す。完全ローカル版の現行metadata正本では、製品表示名とApp Store Connect名をともに`ねこのまど`へ統一した。

## 背景

Build 7ではWidgetの肉球操作そのものはApp GroupのLikeストアへ保存されていたが、アプリを開いた直後の「好き」総数と一覧へ即時反映されず、再スキャン後に初めて見える場合があった。主指標の表示を信用できないため、2026-08-17にBuild 7で始めた1週間計測を中断した。中断までの値は製品判断へ使わない。当初はBuild 8の実機ゲート後に取り直す予定だったが、その再計測案も同日に撤回した。

原因は、共有Likeストアの同期時に`@Published`なsnapshotの配列要素だけをその場で変更し、snapshot全体を再代入していなかったことにある。Likeストアへの原子的な保存は成功していても、SwiftUIへ確実な変更通知が届かず、後続スキャンがsnapshot全体を代入するまで総数と一覧が古いまま残り得た。

同じBuild 7の確定snapshotを使ったdetected無作為100枚レビューは完了した。`reviewNo 74`だけを製品候補から除外し、ほかの99件は採用したため、この標本のProduct Precision推定値は99 / 100 = 99.0%である。scanner、analysis fingerprint、標本抽出方法を変更しないbuildでは、この結果を再利用して同じ100枚をやり直さない。

## 判断

Build 8のLike表示修復は製品機能として維持する。WidgetのApp Intentは従来どおりApp GroupのLikeストアへ1回の原子的なread-modify-writeを行う。アプリは起動、フォアグラウンド復帰、Deep Link受信時に共有Likeストアを読み、更新済みsnapshotを新しい値として明示的に再代入する。これにより手動再スキャンを待たず、総数、一覧、押した日時を同じ共有状態から表示する。

Build 8には、最後の表示・体験修正もまとめる。

- 製品表示名：`ねこのまど`
- App Store Connect上の名前：`ねこのまど - 猫の写真ウィジェット`。これはコードだけでは変わらないため、既存アプリレコードも手動で更新する
- Widget派生画像の入力request：`2048×2048`、high-quality、networkなし
- Small：`500×500px`、JPEG `100KiB`以下
- Medium：`1050×500px`、JPEG `200KiB`以下
- Large：`1050×1100px`、JPEG `220KiB`以下
- 猫unionの余白：各辺`8%`。Build 7の`18%`を同じ候補へ影計算し、CI artifactへ8%と18%のfallback件数を併記する
- 肉球：SF Symbolsの犬にも見える`pawprint`ではなく、指球を小さく丸く寄せ、掌球を横長にした共有`CatPawMark`を使う。Widgetでは約20pxでも輪郭／塗りつぶしを判別できることを確認する
- Widget cache：最大8 generation、最大400ファイル。全ファイルが最大上限の220KiBだった場合でも約85.9MiBを超えない保守的なdisk上限とする
- Widget ExtensionはTimelineEntryへ画像を保持しない。ただしWidgetKitが20件の未来Viewを受理時に評価することを実機で確認したため、Build 9ではTimelineを最大2件に制限する。Largeは実機row alignment込みで約4.41MiB／枚、約8.83MiB／2件とする
- Widgetタップ先：写真を大きく表示し、左右スワイプ、肉球、撮影日、「この日の写真をすべて見る」、約20分ごとの切り替えと最後に変わった時刻を示す。任意に写真を進める「次へ」ボタンは置かない
- 猫0件：故障に見える空白ではなく、スキャン結果であること、猫写真を追加すること、写真アクセスを確認すること、再スキャンすることを案内する

Build 7の画像仕様は`400×400 / 800×374 / 400×420`、各50KiB、余白18%、algorithm v4だった。これは履歴として残すが、Build 8では上記の実ピクセル相当、family別byte上限、余白8%、algorithm v5が現行仕様となる。

## Like、Widget、写真ブラウザの実機ゲート

Build 8では本ゲートを完了できなかった。Build 10で次を同じ実機で順に確認する。これは計測開始条件ではない。

1. Build 10をインストールし、既設Widgetを削除してSmall / Medium / Largeを再配置する。
2. アプリを開き、差分確認用に好き総数と一覧を記録して終了する。
3. Widgetの肉球で未押下の写真を押す。アプリを勝手に開かず、輪郭から塗りつぶしへ変わることを確認する。
4. アプリを開き、手動の再スキャン操作をせず、好き総数が1増え、同じ写真と押した日時が一覧へ現れることを確認する。診断ログでは共有Like同期が`Scan generation started`より前に記録されることを確認する。
5. 再びアプリを終了し、同じ写真をWidgetで解除する。アプリを開き、手動再スキャンなしで総数が1減り、一覧から消えることを確認する。
6. Smallだけ、次にMedium、最後にLargeを段階配置し、各familyの描画、timeline切り替え、肉球ON/OFFで消失、再読込ループ、クラッシュがないことを確認する。診断ログの各decode推定が5MiB以下で、TestFlight crash／iOS Analyticsに該当時刻のJetsamがないことも確認する。
7. 3サイズの解像感、full-bleed、例外fallback、約20pxの猫の肉球、タップ先のスワイプ／日付／同日一覧／切り替え説明、猫0件の案内を確認する。
8. App Groupのイベント履歴と診断ログが押下／解除の時刻・写真・操作元で一致することを確認する。
9. Build 10の写真ブラウザが固まる場合は待機せず、`LazyHStack`と標準pagingを含む開発branchのbuildを同じ端末へ入れ、[ADR-010](ADR-010-大規模写真ブラウザの遅延ページング.md)の実機ゲートを行う。

CIが保証するのはLarge 1枚が5MiB以下、最大2件がfamily別10MiB以下という静的予算までであり、Widget Extension全体の実peakが30MiB未満であることではない。TestFlightの段階配置、ログ、crash／Jetsamなしも実peak数値の保証ではない。数値が必要ならMacとXcode／Instrumentsで測る。

Build 7で完了済みのランダム100枚レビューは再実施しない。Build 8でscannerやanalysis fingerprintを変更した場合だけ、結果を再利用せずレビューをやり直す。

## 変更の凍結

画像構図と写真詳細の改善はBuild 8で打ち止めとする。この凍結は表示scopeの判断であり、端末へのbuild導入を禁じるものではない。Build 10以降のアルバム／共有開発は別branchで進め、実機検証が必要なら同じ端末へ入れてよい。

この範囲では、次を実装しない。

- Subject Lifting
- 新しい背景ぼかし方式。Small / Largeの幾何学的に収容不能な場合に使う既存fallbackだけを維持する
- Mediumの2枚表示
- 顔検出、saliency、姿勢・美的構図理解
- 日付、場所、個体などの新しい選別軸
- 共有機能

## Deferred probe

[ADR-006](ADR-006-iCloudローカル派生画像の検証.md)の512px fast-format paired probeはBuild 10へ入れない。週待ちなしで、番号を割り当てたInternal TestFlight buildから非破壊probeを1回実行できる。採用する場合の通常scanner／Widget cacheへの反映は後続のproduction buildとする。
