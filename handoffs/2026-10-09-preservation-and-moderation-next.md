# 保管・共有を完成させるための残作業

2026-10-09。利用者の「共有・保管を含めて完成させて提供したい」を継続する。今回の写真検査への送信修正はmain・既存非公開サーバーへ反映済みで、[完了記録](2026-10-09-preservation-provider-stream.md)の成功を保持する。この文書は追加観測と次の実装順序であり、一般公開の完了記録ではない。

09:25 JST更新: [受信buffer解放の完了記録](2026-10-09-preservation-request-buffer.md)が最新。下記の最初の全経路未完は過去の観測で、その後の直前mainでは検証専用輸送の修正により20MiB PUTがHTTP200・復旧確定・最終owner ackまで成功した。今回の専有buffer解放もService424＋27件とplanを通し、main3274698/private version e46ce4ddへ反映済み。本番128MiB適合、実CPU/実機ZIPと共有運営機能は残る。新候補の追加probeは結果保存ミスを伴うためHTTP200成功証拠へ流用しない。

## 大容量保存：復旧までの追加観測

main `05984519b6ab7d5158bb414cee9edce35de8ae13` で同じ20MiB人工JPEGを1回だけ保存し、実route/body・ArchiveStore・暗号化・local D1/R2・実S3署名/復旧adapterの境界を観測した。JPEG provider、KMS、S3 HTTP、会員状態は合成。クラウド操作と本人データへの操作は0回。

- R2保存・読戻し、S3の写真/record PUTとHEADまで到達。D1 record/recovery versionは作成されたが、復旧commit確認で503 `RECOVERY_RECORD_UNAVAILABLE`。最終commit markerは0で、保存全経路の成功ではない。再PUTしていない。
- 保存を伴わない別のGET読取1回で、検証環境の橋渡しが64KiB送出を4KiBへ分割することを直接観測した。既存 `readBoundedBody` が4,097chunk / 16,781,312byteで拒否した。この環境要因を暗号化破損や本番障害へ読み替えず、本番の輸送形状は未確認とする。
- 11停止点を取得。JSON parse直後のJS heapは約85.78MiB、used＋embedder＋backingの参考合算は約144.69MiB。暗号化・R2送信・R2読戻しで大きなbufferが重なる。S3署名は同じbodyを使い、そこでの20MiB追加コピーは観測されなかった。参考合算はresident memoryでも本番ピークでもなく、Inspectorの保持/GCも影響する。
- **本番128MiB内での全経路完走は未証明**。既存の4096chunk制限、容量上限、暗号化・復旧・確定条件は変更していない。検証入口の集約はprobe側だけ。ローカル失敗を通すための制限緩和や重いCI再試行はしない。

証拠: `C:/dev/neko-evidence/launch-readiness-20261008/upload-full-path-probe/{result,transport-only,assessment}.json`。最初の計装buildの失敗も `build-failure-01.json` に保持。実機ZIP・本番CPUの確認はこれとは別の未確認事項。

## R2保存時の余分なコピーを修正・内部反映済み

上記で実測した `bytes(sealedPhoto)` の20,971,805byte別配列を対象に、R2への引数だけを暗号化済み `Uint8Array` 自体へ変更した。一般のbytes helper、暗号化、所有者のlease、R2読戻しの全bytes hash照合、S3復旧と最終確定は変更しない。

実装前にlocal実workerd/R2で20MiB＋285byteの合成暗号文を直接put/getし、元配列が不変でdetachされず、保存・読戻しhashが一致することを確認した。別の小さなoffset3/長さ5のviewでも範囲外のsentinelが保存されず、元配列不変を確認。1境界実験・2put/2get、904ms。これは実R2 binding契約のlocal観測であり、製品経路の本番ピーク測定ではない。

回帰試験は実ArchiveStoreで非ゼロoffsetの暗号文を保存し、同じviewをR2へ渡すこと、入力/周辺bytes不変、R2の正確な長さ/本文、復旧copy一致、元写真/メモの読出しを確認した。型検査とstorage/recovery関連58件が成功（9.71秒）。実装の独立レビューはP1/P2なし。

この追加候補の開始は08:39:54 JST、計画20〜40分。前の候補開始07:59:07からの時間も保持する。既存backend91秒・control35秒を計画の参考とし、新scopeの実績にはしない。製品2パスと通常handoffだけの正確なblobに限定したCI制御を別候補で先行させ、必要なService検査とplanを実行する。入力不変のJPEG/native/Widget成功は繰り返さない。本番128MiB適合・入口JSON等の残件はこの1修正では解決済みにしない。

証拠: 同evidence rootの `r2-view-plan.json`、`r2-view-contract-probe/{result,independent-review}.json`、`r2-view-local-validation.json`。

- [制御PR194](https://github.com/soso-so-27/neko-widget/pull/194)を独立レビューし、必須development-flow14項目164.7秒、preflight、[control CI](https://github.com/soso-so-27/neko-widget/actions/runs/37861459507)成功後にmainへ先行反映。製品へ取り込んだ後もCI/workflow treeとService treeの検証入力一致を照合し、成功済みの同じローカル一式を繰り返していない。
- [製品PR195](https://github.com/soso-so-27/neko-widget/pull/195)、固定候補 `95f7a76f2b89c1a7e60760ca79929913112b4566` の[Service CI](https://github.com/soso-so-27/neko-widget/actions/runs/37861681667)で411 Vitest＋27運用テスト・型検査・migration・private bundle成功、[plan](https://github.com/soso-so-27/neko-widget/actions/runs/37861681675)も成功。自動PR側のServiceも成功。JPEGは直前の成功run37859139318とImageValidator tree・adapter依存6ファイルの不変を照合して保持した。
- main `773be84163e7487629946db1cda3f2550d493533` にmerge commitで反映し、検証候補の祖先関係と全tracked tree一致を確認。
- 08:55:23 JST、既存非公開Workerへ1回配備し、version `fe831572-d26c-498e-aa54-83afa488b1a7`、bundle SHA256 `d9da3245ff22cd4c80421b24c6e90042123de48a9db67c6c2f21fc3b296b4d5a`。実module全体を比較し、R2引数1か所以外のbytes不変、配備後全文一致を確認。全settings/secret参照/exposure/schedules、schema135/migration33、pilot/intake期限、本人1名・記録1件/quota3,358,122byteを保持。新しい費用・権限・受付・本人データへの変更なし。
- この追加候補は開始から内部反映まで15分29秒。今回の全作業は最初の07:59:07から56分16秒で、provider修正・途中の失敗したlocal全経路probeも含む。Service CI93秒、plan41秒、先行control44秒。並行時間を足して全体時間と呼ばず、自動PR/mainのrunも別稼働として保持する。手動再実行0、追加JPEG/native/Widget/TestFlight0。

詳細は `r2-view-validation-reuse.json`、`r2-view-{control,service,plan}-ci.json`、`r2-view-deployment/{helper-review,root-helper-review,bundle-review,completion}.json`。helper93条件と独立レビューを保持。PR194/195のチャット添付はアプリの100件上限で失敗したため、ここに実PR URLを保持し、過去の添付や会話履歴を削除していない。

## 共有：実際に通報へ対応する経路を完成させる

現行mainの読み取りで、通報受付とブロックは実装済みだが、運営者の実運用全体は未完成と確認した。運営者queue/review-startはAccess/WebAuthnと監査を伴うlocal専用実装。production entryはOFFの殻で、flagだけYESにしても503となる。判断・削除は正式な証拠とoutboxが揃うまでDB triggerが拒否する設計であり、この拒否を単に取り除かない。

1. **運営者の登録と確認画面**：実際のWebAuthn登録/認証を直接確認し、認可された担当者が未確認queueから1件を開ける画面を作る。DBへの仮登録を実本人の登録済み証拠にしない。
2. **通報内容の安全な確認**：割り当てられたcaseの暗号化copyと正確なsnapshot manifestだけを監査付きで取得し、既存の隔離された復号手順へつなぐ。誤ったcase・失効した権限・同時解除では内容を渡さない。
3. **判断・返答・異議申立ての記録**：正式な判断証拠と永続outboxを同時に確定し、再試行で二重対応しない。返答の送信失敗は未送信のまま残す。異議申立てや保留と削除の競合を検証する。合成試験から実在者へ連絡しない。
4. **実設定と訓練**：対象アカウント・Access policy・origin/RP・rate・実担当者を具体化した後、合成通報の受付から人による判断、返答、停止/復旧まで確認する。新しい権限・契約・配布対象・一般受付が必要な操作は、その具体的な差分を提示する最終段階で確認する。

日常担当はアプリ所有者を候補とするが、対応可能時間は未確定。認証を失った際の複数管理者による復旧条件は日常の人数とは分ける。agentレビューや同じ人の別アカウントを別担当者の証拠にしない。実装が選んだ復旧人数や48時間目標をApple指定と説明しない。[AppleのUGC要件](https://developer.apple.com/app-store/review/guidelines/#user-generated-content)は通報・適時対応・ブロック・連絡先等であり、このプロジェクト固有の人数は定めていない。

詳細なsource参照と受入条件は `C:/dev/neko-evidence/launch-readiness-20261008/moderation/completion-work-order-20261009.json`。運営者の実登録・画面・判断処理が残っているため、設定変更だけで公開可能とはしない。既存の受付・停止・鍵・強認証境界を維持して実装する。

## 提供条件・公開手続き

保管容量/件数・人数・受付ペース・費用停止を同じ販売条件へそろえ、AWS無料プラン後も保管を続ける契約条件を確定する。通常月・初月投入・負荷が多い場合の費用を分け、未計測のCPU等を0円や予算超過と断定しない。機能と条件が揃った公開構成にストア説明・プライバシー・サポート・審査操作手順を合わせる。新しい費用や契約、一般公開の実行は未承認のまま。

本人向けTestFlightは1.0(247)が利用可能という既存証拠を保持し、このbackend修正のための追加アプリ配布はしない。247の実機導入・大量ZIP、実失効後の表示は未確認。成功済みの購入・復元・解約・保存検証を理由なく繰り返さない。
