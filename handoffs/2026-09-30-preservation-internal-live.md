# 保管サービスの実接続（2026-09-30）

実写真の保存・新しい本人確認での復元・ZIPを完了条件とする。内部版の配布準備を保管サービス完成と扱わない。実owner・実recordはまだ0。

- 製品候補: `d895ba6d16c676b047a11d2f097f040d1bdb6a5e`。PR111はmerge commitでmainへ反映（`541f941720ee6b7c04f70f2ea634154812f0e122`）。
- 候補CI `36722585550` の保管UI2操作が成功。製品入力が不変のBuild/Photos/bootstrap/runtimeは `36715741370` の3成功jobを証明して再利用。旧runの失敗UIを成功扱いしない。サーバーCI `36715741373` は成功。
- 内部TestFlight build228: [run36724761111](https://github.com/soso-so-27/neko-widget/actions/runs/36724761111)で2026-09-30 23:04:27 JSTにAppleアップロード成功。署名・privacy・internal-only exportの確認も成功。保管のみON、Plus/課金OFF。Apple処理完了・iPhone表示は未確認。
- 本体registration Worker `63fa974a-7196-4006-81f3-b2e866fe6fa1`。実配備のoverrideは `C:/dev/neko-evidence/preservation-sandbox-20260930/pilot-registration-runtime.jsonc`。source wranglerは通常配備OFFを維持。
- 非公開KMS `f329bf29-06ae-4013-bbd5-9dc8ece4dc01`、非公開JPEG `89faa393-12cb-4ee5-8bed-616baf2dfbe0` は受付ON。JPEGは既存container/imageを保持。秘密値は記録・表示しない。
- D1 `955a8530-9015-486c-8d0c-1b5a2c5b6d4f` に0028適用済み。owner snapshot / delete intentを必須化済み。pilot/intake controlはOFF、固定本人リスト未登録なので実保存は許可していない。

## 次の実接続

1. build228の初回Apple本人確認を本人のiPhoneで実行してもらう。表示された登録番号またはその画面からUUIDを照合する。番号は10分有効。既存アプリを削除しない。
2. `pa_pilot_registrations` の同UUIDかつ未期限切れの1行だけを照合する。最新行を推測採用しない。HMACを最大3人の `PILOT_IDENTITY_KEYS_JSON` Worker secretへ登録する。メール、Apple subject、tokenで代用せず、鍵をチャットやログへ表示しない。
3. 初回7日、1人1GiB/200件・全体3GiB、intake日50/月300/月3GiB、mutation日100/月500の既承認枠を開く。DB更新で費用確認24時間・予測2200円未満を維持。期間を勝手に延長しない。Cloudflareの9/30実使用量・R2無料枠確認と月1773円の保守的試算は `C:/dev/neko-evidence/preservation-sandbox-20260930/pilot-execution-state.json` に記録。試算は請求上限ではない。
4. 新しいApple確認で登録→写真+メモを1件保存→ログイン解除/新確認で一覧・内容復元→ZIPを確認する。可能なら別端末復元も区別して記録。確認されていない結果をfixture成功で代用しない。

販売の7日体験・月980円は別条件。内部保管を購入認証の完了待ちへ戻さず、active契約やbilling linkを捏造しない。一般公開・外部招待・審査提出・実販売へ範囲を広げない。

初回native CI20.9分で検査のText/Image選択誤りが判明。GitHub jobs取得URLが502/504になった追加runは取り消し、明示page=1で完全応答を取得した。修正UI run13.4分、配布run12.8分。このturn開始から配布成功まで約136分。最初の候補・失敗・取消し・準備・過去の保管作業を含む記録は上記execution-stateに残す。30分以内に配れたとの報告はしない。
