# 本人用運営画面の初回クラウド接続・配布検査

製品候補 c0ca93648c908976a5174621606e4de86d64954a は、main 3b8dfc68cf1fc66b20f55172f0c9879c4ebd02e4 からの47製品ファイルを完全blob pairと通常A/M・100644で固定する。承認前の選択制御と製品を混在させない。このcontrolだけをUbuntu planで確認してmainへ反映し、製品側に取り込む。

`reviewed-owner-cloud-v1` は全Build検査、両OSの実際のfull runtime self-test、同じ候補SHAのSharing4 jobとPreservation1 jobを実行する。runtimeは既存scriptとmarker検証をそのまま使う。配布時の署名・compiled mode・public key・IPA・upload検査も維持する。main再利用と配布は全Build step、runtime実行と成果物保存、5 backend jobの実成功を再照合し、別SHA・skip・未完了は代用しない。

Photos/bootstrap、album UI、Widget galleryは、今回変更していないDebug Swift、project、画像fixture、Simulator scriptを読む。今回のSharingService Workerやprotected v2設定を読まないことを独立レビューで確認したため追加実行しない。製品/制御/handoff以外の全1107 tracked tree recordのmode/type/blobを固定SHA256で照合する。9制御ファイルはbase/headともmain承認済みmerge-baseのtreeと完全一致が必要。通常handoff A/M以外の未知・部分・削除・mode/type変更ではこのprofileを使わない。

初回製品候補は2026-10-11T04:21:42.377Z。実cloud D1/R2から合成JPEGの完全描画とno_action保存、実本人認証と現在の権限、readonly native key custody、v2署名付きreadiness、誤鍵のDB拒否を確認済み。実iPhoneの通報と新archive/uploadは未確認。証拠は C:/dev/neko-operator-local/key-recovery-20261011/live-connection に保存する。

旧full preflightは未分類による8 Mac jobを選び、過去CI64〜98分・upload込み77〜110分の参考値に対して90分枠を超過した。まだ製品CIは起動していない。既知の無関係なUI検査を時間枠の拡大だけで実行せず、この固定profileへ変更する。新profileの時間は未計測として最初の実行を計測し、旧fullの時間やjob timeoutを成功実績・完了保証にしない。経過・失敗・過去証拠を保持する。
