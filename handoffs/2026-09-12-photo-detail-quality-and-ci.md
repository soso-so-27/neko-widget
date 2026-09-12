# 写真詳細の回復・拡大とCI選択 — Build157アップロード済み

起点: 最新main `0780c7a`。worktree `C:/dev/neko-photo-detail-20260912` / branch `codex/photo-detail-quality-20260912`。研究worktreeは対象外。

## 対象と完了条件

| 対象 | 確認した問題と対応 | 完了条件 |
|---|---|---|
| ローカル写真の画質取得 | PhotoKitのdegraded画像後にfinal取得が失敗すると、粗い画像だけが残り再読み込みできない | 表示中の写真を維持して再試行でき、同じIDのfinal画像へ回復。取得中と未完了を区別。retryは現在のPhotos権限/assetを再確認し、存在しない写真を残さない |
| 画像差替え時の拡大 | 同じ写真の高画質版へ差替えるだけでもsetImageがzoomを1へ戻す | 同じ写真・同等縦横比の差替えでzoom/panを維持。別写真はリセット。保存/閉じる/ページ送りを維持 |
| 送信済み詳細 | canonical参照はあるが一時的に読めない場合、旧小画像表示のままで再確認できない | 現行参照がある場合だけ同じStore経路へローカル再確認。連打禁止、写真ID/参照/世代の不一致結果を拒否。期限/削除/hash/共有終了を回避しない |
| CI待ち時間 | 写真画面の小変更でも全UIと追加Widget Galleryの再ビルドが走る | 明示した写真/公式画面の純粋な文言・装飾変更だけUI試験を選択。Release/境界/SMOKE/両OS共有runtimeは維持。未知・権限/保存/通信・Shared/Widget・CI・試験/fixture変更はfull。mainの再利用でscopeを照合 |

既存内部TestFlightへ一バッチとして進める。CI自身を変更する今回の候補はfullで確認し、選択処理を使って自己検証を省かない。

## 画質経路の確認

- ローカル詳細の要求は1600px、周辺の先読みは既存の小範囲。今回一律に原本decode/解像度増加を追加しない。
- 共有: ingressは最大2048pxへ。canonical builderは容量に応じJPEG品質0.92〜0.56、必要なら寸法も縮小するが、各試行は元ピクセルから生成しており再圧縮の積み重ねではない。
- 受信JPEGはそのまま保管され、詳細は2048pxとして一覧と異なる要求サイズのキャッシュへ。PhotoKit取り込みも同じ受信JPEGを渡す。
- 新しい送信控えは一覧512pxとcanonical詳細を別保管。旧小画像だけの控えには説明と引伸ばし抑制がある。失われた原本を復元する機能ではない。
- 公式の配信JPEGは最大2048px・品質88。詳細は一覧650/1100pxとは別に2048px読込。
- この経路では通常詳細へのサムネイル誤用は確認しなかった。写真原本はまだ提供されておらず、実写真の精細さ/好みの評価は未完了。コピーの上限や共有のプライバシー境界を変更する根拠にはしない。

## APIの根拠

Appleの[requestImage](https://developer.apple.com/documentation/photos/phimagemanager/requestimage(for:targetsize:contentmode:options:resulthandler:))は、非同期で一時的な低品質画像と最終画像を複数回返す場合があり、degradedキーで区別する。[exact resize](https://developer.apple.com/documentation/photos/phimagerequestoptionsresizemode/exact)もdegraded画像自体を指定サイズにする保証ではない。[networkAccessAllowed](https://developer.apple.com/documentation/photos/phimagerequestoptions/isnetworkaccessallowed)はiCloudからの取得可否。既存フラグを維持し、「通信失敗」と原因を断定しない。

## レビューと検証予定

- 主担当はローカル取得/zoom、別担当は送信詳細を実装。相互に差分をレビュー。
- 独立レビューでretry時のPHAssetキャッシュ再利用が現在のアクセス確認にならない点を指摘。明示retryだけ現在の権限とfresh fetchを確認し、対象がない場合は旧画像を消す修正を追加。
- nativeは既存Soloクラスに1ケース追加: 120px preview→final失敗→拡大/pan→再試行→同じ写真の最終画像、倍率と表示位置保持、同じIDの保存。この合成経路は実iCloud障害の再現ではない。
- 既存共有/Widget境界61件（既存1件skip）、写真permission/bootstrap9件は成功。nativeと候補CIはこれから。
- CIは別担当が実装し主担当が独立レビュー。キーワードによる危険変更の除外だけでは十分でないため、純粋な表示行の変更に限定し、それ以外をfullへ戻す方針へ絞った。
- 再レビューでPhotos retryのキャッシュ迂回修正を確認。送信詳細は既存runtimeのhash不一致→元JPEG復元に、同じrecord/spaceで再解決し元JPEGと一致する確認を追加。ボタン操作そのもののnative fixtureは製品Model/Storeを通らないため追加せず、実機未確認として区別する。
- CI選択20件、既存screenshot workflow12件を主担当でも実行成功。純粋な補間なしText/明示スタイル以外、追加/削除/移動/mode/type変更、条件付きfixture変更はfull。scope/versionが一致する成功jobまたはfullだけをmain再利用の根拠にする。縮小経路のmacOS実行時間は未実測。
- 初回候補CI `34690078543` は旧表記 `if !showsFullImage, !degraded` を探す静的grepで停止（Swift policy実行は成功）。製品の新しい最終画像/エラーなし/thumbnail限定条件にgrepを追随させ、同stepの全shellガードをローカル再実行成功。未完了のnative/ビルドは次候補で実行する。

## 候補eef6182の確認

- CI `34690287093` attempt1: Release/境界ビルド成功、Simulator smoke成功。iOS18.5/26.2の共有runtimeは各37ケース成功。送信詳細のhash拒否→同じrecordの元JPEG復旧確認も通過。
- iOS26.2 native主suiteは31件/失敗0。追加の `testPartialPhotoRetryPreservesZoomAndVisibleRegion` は14.274秒で成功。120pxプレビュー→再読み込み→最終画像、zoomとoffset保持、同じ写真IDの保存を確認。
- artifact `10297556015` の `runtime-scope.json` はcommit `eef618218b03e69a39b1b4b563687dfd4e8dda55` / `full-v1` / 両OS / 全UI選択 / Gallery=trueと一致。取得先は `output/photo-detail/native`。
- 追加試験の前後PNGを目視確認。画像の表示範囲と下部操作を保ち、回復後に再読み込みボタンが消える。合成イラストによるUI確認であり、実写真の画質評価ではない。
- 同attemptの追加白背景/最大文字Widget Gallery撮影だけ、検索結果に「ねこのまど」が出ず失敗。最終AX/PNGでもSearch Widgetsの値が正しく、No Results表示、背後にアプリアイコンがあることを確認。Widget本体/Shared/撮影テストの差分はなく、full時のerase→boot→build/install手順も従来と同じ。独立レビューでも製品変更との因果は見つからず、Simulatorカタログ側の失敗が有力（登録遅延とは未断定）。
- 成功条件は変えず、同じSHAでfailed jobだけ1回再実行（attempt2）。成功済みbuild/smokeは再実行しない。現状は共有runtime・アプリUI・Galleryが同じjobなので、その中の成功ケースも再実行される。
- 残るCI構成の課題: Galleryを独立jobに分け、同種の環境失敗だけを局所再実行できるようにする余地がある。今回の軽い表示変更のscope選択とは別で、未着手。現行の必要ジョブ証拠を弱めて今回の失敗を成功扱いにはしない。
- attempt2は全成功（sharing job `103551473803`、最終artifact `10298640828`）。両OS各37ケース、native31件/失敗0、追加の白背景/最大文字・文字なしGalleryも成功。追加のretry/zoom試験は14.484秒。job開始12:11:33Z、matrix終了13:04:23Z。写真の目視には同じSHAのattempt1のPNGを使用し、同じ画面のartifact再取得はしていない。

## mainとTestFlight

- 製品SHA `eef618218b03e69a39b1b4b563687dfd4e8dda55` をmainへfast-forward反映。main CI `34695491530` 成功。計画ログでcandidate `34690287093` の同じSHA/full-v1の必要ジョブ成功を再利用したことを確認。
- TestFlight157: run `34695533104` / job `103558256728`、署名・検証・アップロード成功。既存testflight Environmentで従来どおりmedia-staging＋同じ公式preview feed、既存内部グループ向け。外部テスター追加・審査提出・課金開始はしていない。
- 署名artifact `10298108507`、diagnostics `10298651258`。署名artifact内のmetadataでversion1.0 / build157 / sourceCommit eef6182 / releaseMode media-staging / run34695533104を確認。ローカルは `output/photo-detail/signed-157/moderation-release-metadata.json`。
- **残る配布操作**: 長いCI待機中にApp Store Connectのセッションが失効。アップロードは完了したが、Apple側の処理完了・既存内部グループ「自分用」（1人）の157「テスト中」表示確認と、日本語のテスト内容保存はログイン待ち。利用者へログインを依頼済み。自動配布の有無を未確認のまま完了扱いにしない。
- ログイン後は既存グループ `d315ba6b-0def-4490-8037-d2b17b13c4d6` で157を確認し、`output/photo-detail/testflight-notes.txt` の内容を保存する。再ビルドや再アップロードは不要。ASC appID6801962436 / team c0938ad3-2941-4079-8248-0769666c8fd8。
- 原本との実写真の精細さ比較、実iCloudの障害回復、Photos権限変更後の実機操作、送信済み詳細retryボタン自体のnative操作は未確認。確認済みの合成UI/Store runtimeと区別する。
