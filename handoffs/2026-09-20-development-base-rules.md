# 共通の開発ルールを実行へ反映

目的は、同じ遅延を記録するだけで次回も繰り返す運用を止めること。変更の影響・失敗時の被害・確認費用・既存証拠で判断する。利用者へ追加の承認やテスト作業を求めるルールではない。

## 実装した入口

- 全開発共通の原則はユーザーのglobal AGENTS.mdへ反映。セッション履歴の保全規則は維持。
- `check-development-flow.py` のローカル既定実行にpreflightを接続。commitした全差分を実CI plannerで選択し、必要job、全件の理由、scope別の過去所要時間を表示する。未計測/超過は主担当の判断へ戻す。`--decision` は費用判断の記録であり必要jobを減らさない。署名や実行証拠を発行するものではない。
- watcherは失敗jobが終わった時点で結果を返す。兄弟jobをcancelせず、調査が先に始められる。`--wait-for-completion` は調査後の完了待ち用。
- 開発補助ツールのみの既存通常ファイル変更はPython検証で確認する。アプリ・build・安全検証・配布判定・選択器・workflow変更はこの軽量経路に入れない。軽量結果はTestFlight証拠として拒否する。

## 適用と限界

導入そのものは選択器とcheck runnerの変更を含むため、既存のCI選択変更用経路で検証する。アプリ変更がないため新しいTestFlightは作らない。

保存・共有等の未知の製品差分を自動的に短縮するものではない。全件へ戻る場合を事前に可視化する。job内のXCTest一件目の失敗通知、別SHA間のjob入力単位の証拠再利用は未実装。これらを実装済み・20〜30分達成と報告しない。

計測資料は元runと失敗/再試行を残す。過去の同scopeの時間は目安で、新しい変更の保証ではない。scopeが変わった場合は未計測として扱う。

## 検証結果

- 導入commit `005872f85885b0541b729dad1400f790dfb6da99`。ローカル開発検証11群は38.3秒で成功。preflight9件（実Gitの古いmain・製品混在・別cwd・不正時間値を含む）、watcher11件を含む。
- 独立レビューの3指摘（古いmain、別cwd、非有限の時間値）を修正済み。時間超過の判断を付けても必要jobが減らないこと、軽量成功をTestFlight証拠にできないことを検証。
- 実Gitで、今回の差分はci-selection-v1、以前の保存変更を含めるとfull-v1・目標超過・ready=falseになることを確認。後者の検証は判定のみで、製品テストを実行していない。
- [候補CI 35495098428](https://github.com/soso-so-27/neko-widget/actions/runs/35495098428) は必要5jobとplanが成功。**22分21秒、runner合計88.6分**（課金額ではない）。再試行なし。候補確定15:45:23 JSTからCI終了約16:08:43まで約23分20秒。
- [main CI 35496125531](https://github.com/soso-so-27/neko-widget/actions/runs/35496125531) は18秒。同一SHAの成功証拠を再利用。アプリ・workflow・署名・公開・課金は変更せず、TestFlightは追加していない。
- 実測値とhandoffだけの更新 `19cd7fe` は、[CI 35496202405](https://github.com/soso-so-27/neko-widget/actions/runs/35496202405) で **development-tools-v1・12秒**。plan内のPython検証だけが実行成功し、Mac jobは起動していない。新しい軽量経路を実際のpushで確認。この12秒も計測資料へ反映し、次回に未計測判断を繰り返さない。導入自体の22分21秒は全機能変更の短縮実績ではない。
- 証拠：`C:/dev/neko-evidence/development-base-rules-20260920/`。global AGENTS.mdの更新はユーザー環境のルールで、リポジトリcommitには含まれない。
