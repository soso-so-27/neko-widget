# 未編集ツール候補更新の限定CI登録

- base main `252642bb90b8d8a99ea968245a1afb5fcca57e9e`、製品 `21d148d693bf70a06deb3a5fd4ce58ec9e3541d0`。製品レビューに確定P1/P2なし。制御は別branch/commitで先にmainへ反映する。
- 新scope `reviewed-tool-candidate-refresh-v1` は完全な製品10ファイルのbefore/afterだけを登録し、Care/Evac/Lostの既存3UIメソッドを選択。全文一致で他メソッド/import/helperの変更を認めない。
- Build/既存storage・privacy・migration検査、Photos bootstrap/実写真scan、両OS runtime、owning UIを維持。WidgetやGalleryは今回の依存先でないため追加しない。
- plannerのraw全差分/通常ファイルmode/modify-only拒否を維持。欠落/片側digest不一致/未知/CI・workflow・project・共有モデル混在/テスト欠落はfail-closed。skip/partial/失敗を成功へ読み替えない。
- 制御のPython/Ubuntu plan成功は製品native/配布の証拠でない。新scope native所要時間は未計測。製品は入場時更新のfocused診断を先に実行し、同SHAの通常CI成功からmainと内部配布へ進む。
- 製品の最初の編集は2026-10-01 11:02:35 JST。全体90〜120分計画は以前のBuild/関連UI/Photos再試行/署名uploadの観測に基づく目安。現在の設定登録を実測短縮や配布完了としない。

## 初回diagnosticのfixture修正

- `36805474184` はCare/Evacが成功、Lostがlegacy-emptyの全体比較で止まった。追加検証がsave前のmigration値をafterと比較し、保存時に更新された日時まで一致を求めていた。製品挙動は変えず、保存済みの同一before値に比較を直した `6b4d44c04f4aeb4669acf930467a8c8e292a9da7` を対象に、CatPreparednessViewのafter digest1個だけを再固定する。
- 他9ファイル・before・対象3件・必須job・成功判定は不変。Unknown/partial/mode/type/混在の拒否を弱めない。新SHAのLost focused成功と通常CIの3件成功を必須にし、旧Care/Evac成功を新SHA配布成功に転用しない。

## 再起動用fixtureの初期状態比較

- Lost focused `36807771420` は元情報更新と手編集後のpublic previewまで進み、再起動準備で失敗。AXはfixture-error、製品の候補更新は撮影済み。保存元の特徴をphase2で更新した後にも初期値を毎回要求していた。初期特徴の完全一致を初回の準備へ移し、写真存在/非公開写真除外は毎回維持する `3c0f79a44f5662b8efc3ad6b60c8ae9e2c495dc8` を登録する。
- 変更は同じ1つのafter digestだけ。他19digest、対象3件、必須4job、raw/mode/type/混在拒否と成功証拠は不変。製品・UI本文・保存境界は今回の補正で変えない。
- 17分台のfocusedを更に重ねず、既に配布に必要な通常CI3件で未確認の再起動を直接検証する方法へ変更した。上の「新SHA focused成功を必須」という当初手順はこの計画で置き換えるが、通常3件の失敗/skipは許可しない。診断2回失敗・レビュー・control待機を最初の編集からの累計に残し、制御成功をnative/配布へ読み替えない。
- ローカルは変更する固定digestを直接使う `test-ci-lanes.py` 16件と、製品base/after全文20digest、partial/未知afterの拒否、3件の実宣言を再確認した。前回12suite成功（310.8秒）のうち、変更しないplanner/release/runner/workflowの機能・拒否条件の成功は維持し、安心のためだけにもう一度全suiteを重ねない。companion push CIで既存Pythonゲートはそのまま実行される。
