# 内部TestFlight 318（1030l・1030m）

## 配布候補 2026-10-30T17:17:18+09:00
- 製品main d001319717e8d5452013a53a76960b04d2e10f72（#628まで）。317からの増分：#618/#619/#620/#621/#622/#623/#624/#625/#626/#627/#628。ひとことのUI/暗号化配送、JSTの日付区切り、くもりのまどのWidget設定、個人iCloud保存の読出し専用、保存policyのAppleファミリー共有OFFを含む。
- 1030mの承認でstaging Workerをversion 554e45d6-26e1-4c99-b1ad-0d860d0b8b19へ更新。既存binding/secret/cron/通報設定を保持。family notebookの2flagは明示NO、D1 family_notebook_runtime_gateはOFF。D1は0059まで適用済み。JST区切りの開始は2026-10-31 00:00:00 JST。
- 更新前後の共有health、/join、通報受付状態GET、保存の未認証境界、合成まどGETを確認。reportingAvailable=false、保存の未認証401を保持。配備バイトはdry-runと一致。既存secret/binding/cron一致、家族の2flagだけ明示NOを追加。
- 写真配送は実機確認へ移すという1030mの承認に従う。試験写真1件は未確定のまま、削除/延長/課金資格追加なし。新しい試験写真/通報/メール送信もなし。
- 運営確認記録は承認済みの2ファイル（SharingAPIConfiguration.swift、Info.plist）へ結び直し、既存2署名を更新。本人/環境/鍵/scope/issuedAt/期限/元の合成確認内容を維持。正規verifierとstaging runtime検査成功。期限は今日21:36:15.223 JSTのまま。新しい鍵・期限延長なし。
- 今回のコード差分は運営確認記録とこのリリースメモだけ。製品コードの成功済みPR #628 iOS/safety、#625〜#627の関連backend/native結果は保持。残る必須確認は候補CI、内部構成のarchive/export、署名/配布設定、Apple検証/uploadとTestFlight状態。
- 317と同じmedia-staging、公式黒猫feed、preservation_pilot=true、internal_reports=true、billing_sandbox=true、group_windows=true、upload_to_testflight=true、retain_signed_artifacts=true、legacy_release_evidence=false。内部グループ「自分用」だけ。Config.Productionは使わない。
- 1030m再開は17:11台、最初の署名候補は17:15台。この後の候補CI約15〜20分＋配布約19分（317実績）＋Apple処理待ちを見込む。過去の試験資料/入力不備による停止・手戻りは1030lの報告に保持し、今回の時間だけで全作業の所要時間とは扱わない。
- 本番・お金・新規資源・App Store設定・一般公開は変更しない。承認済みのWorker以外の外部サービスは未更新。

## 実機確認（中西さんのいつものまど、まだ未確認）
- ひとこと付き/なしで届ける。
- 101文字では「届ける」を押せない。
- 届いた写真の送った人・日付の下にひとことが出る。
- 10月31日0:00 JSTから1日5枚の日付が切り替わる。
