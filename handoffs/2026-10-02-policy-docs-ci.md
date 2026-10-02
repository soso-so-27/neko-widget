# 公開説明ページだけの検証経路（2026-10-02）

保管の説明を公開privacy/supportページへ足す候補 `479ac0e` は、push前のpreflightで `full-v1`（観測上限97.9分、Widget含む）へ分類されて止まった。実行はしていない。文書がnative製品に影響しないことを確認したうえで、既存HTML検査を実行する専用経路を先に整える。

## この制御候補

- 比較元: `9c69db66c2c8391447453e7d5d074e2d6703c38f`。文書本文を混ぜない。
- 変更挙動: 既存7HTMLのみの通常変更を `public-policy-docs-v1` に分類。既存HTML検査18件をUbuntuのplan jobで実行する。未知・型変更・混在はfull、native/archive/uploadの既存blockは不変。
- 必要な直接証拠: selectorのパス/mode/重複/workflow接続/非release証拠の境界、preflightでuploadを認めないこと、既存orchestration検査、独立レビュー。説明本文の18件・375px描画は前の候補で成功済み。
- 残る不確実性: 新scopeのGitHub上での初回実行時間と実workflowの成功。plan jobは5分の実行上限で、待機を含む所要時間の保証ではない。
- 元の具体的な文書候補は09:59:40 JSTに作成。CI経路修正へ分離しても、この作業全体の計測起点を取り直さない。Mac/Widget/Simulator/TestFlightをこのバッチで起動しない。
- 制御候補をmergeした後、文書候補へmainを統合して専用HTML経路の初回成功を確認する。全件CIへ迂回しない。
