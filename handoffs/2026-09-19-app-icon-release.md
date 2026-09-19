# 窓猫アイコンのアプリ反映・TestFlight 188

## 結果

- 利用者の「アプリの方のアイコンの更新」「はいふして」の依頼に基づく内部配布。
- 製品 SHA: `843943fe9ee21a4c2c9ceaf961039e31d05e5f85`。
- **TestFlight 1.0 (188) は 2026-09-19 16:00:52 JST に Apple アップロード成功。**
- [配布 run 35427859719](https://github.com/soso-so-27/neko-widget/actions/runs/35427859719) は成功。`VERIFY SUCCEEDED with no errors` と `UPLOAD SUCCEEDED with no errors` の実ログを確認。
- Apple 側の処理完了・内部配布画面・188 の iPhone 実機確認は未確認。一般公開・外部招待・審査提出・課金開始は行っていない。

## 変更範囲

187 の製品を維持し、ホーム画面用 `AppIcon` と初回案内用 `OnboardingAppIcon` を、LP 採用済みの「窓からのぞく猫」に揃えた。正本と出典は [アイコン資料](../NekoWidget/docs/design/AppIcon-window-cat.md) を参照。

1024 × 1024、sRGB、透過なし。両画像は同一で、60 px / 120 px の表示も目視確認した。Swift・アセット名・署名設定・機能・保存処理は変更していない。Release の AppIcon 選択と archive 工程が旧素材へ差し戻さないことも独立確認した。

**写真選択フリーズなどの別タスクの修正は含まない。** アイコン更新・配布の成功を、その不具合の解消と扱わない。

## 配布前の証拠

- `python NekoWidget/ci/check-development-flow.py` 成功。
- [候補 CI 35424884785](https://github.com/soso-so-27/neko-widget/actions/runs/35424884785): `full-v1` の全 8 job 成功。開始から完了まで 64 分 56 秒。限定 scope に含まれない画像変更のため全体チェックとなった。検証の省略・再実行はしていない。
- [main CI 35427815149](https://github.com/soso-so-27/neko-widget/actions/runs/35427815149): 同一 SHA の上記成功証拠を再利用して成功。
- `release-testflight.py` の dry-run で main SHA・成功 CI・直前の予約番号 187・build 188 の重複なしを確認。同じ引数に `--dispatch` を付けて一度起動。
- 対象 SHA / build と一致する `testflight` 環境だけを承認。既存の `media-staging` 内部配布設定と暗号化済み署名成果物の保持を維持。
- 配布 run の作成から完了まで 6 分 55 秒。

## 並行開発との調整

本線開発タスクへ配布番号・対象 SHA・範囲を連絡し、CI / 配布の監視を本タスクに一本化した。次の配布では最新 main と予約済み build を再取得し、188 を再利用しない。
