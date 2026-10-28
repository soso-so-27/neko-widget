# 内部TestFlight 311

- 所有者指示: 1028h。診断候補開始は2026-10-28 17:16 JST、最初の製品修正候補は17:35頃。途中の環境拒否・診断出力エラー・承認待ちも累計に含める。
- 309の2件を同一UUIDの保存済みdSYMで解析。snapshotのJSON decodeとpublishの状態検証が、同じpersonal-rediscoveryのflock内にあることを特定した。過去の実保持時間は記録がなく不明。
- snapshotはatomic保存された状態をロックなしで読み、decode・検証・集計する。publishはdecode・検証・計算・encodeをロック外へ移し、commit時に元の全bytesを比較する。不一致だけ最大3回再計算し、callbackや保存の失敗は再試行しない。
- 保存形式・権限・quota・plan・旧Widgetとの共用lockは維持。最終ファイル確認と保存callbackは同じcommitの排他内に残す。空データへの置換や書込み途中の強制unlockは行わない。

## 直接確認と残る検査

- 固定309の診断run `40657128838` 成功。認証・archive digest・UUID照合を維持し、空のatos結果は未解決と明記した。原本はリポジトリへ保存していない。
- 診断用branchの一時許可は所有者の明示承認に基づく。17:30 JSTに最後の追加許可を削除し、元のmainだけに戻ったことをAPIの許可一覧で確認済み。最終workflowもmainからのみ実行する。
- 先行モデル検査run `40658522340` 成功（候補 `a2b528b0`、ジョブ35秒）。別processがflockを保持したままsnapshotが完了し、publishのCASとquota消費・権限取消・3回競合・callback例外を検査。missing/破損/未知schemaの原本保全と既存の状態機械・8process quota競合も成功した。
- 配布readinessは今回の製品差分の影響を受けず、既存の検証器で2署名・現在コード・期限の照合に成功。期限は2026-10-29 15:41 JST。更新や権限拡張は行っていない。
- 次の必須チェック: 通常のBuild/unit/launchとPrivacy/saved-data/sharing、固定mainからのarchive/export/upload、TestFlightの内部配布表示。
- 実機未確認: 通常のbackground移行、起動直後のbackground移行、background起動での再発有無。Simulatorやモデル検査を実機のsuspension確認とは扱わない。
- 他のmutation、共有ストア、ファイルIOを伴うcommitにもflockは残る。全保存経路の0xdead10ccを解消したとは断定しない。307/304/300はクラッシュ原本を取得できず原因未分類。

## 配布設定と時間

- 310と同じ既存内部グループ「自分用」。build_number=311、release_mode=media-staging、preservation_pilot/internal_reports/billing_sandbox/group_windows=true、upload_to_testflight/retain_signed_artifacts=true、legacy_release_evidence=false。
- official_window_feed_url: `https://neko-widget-official-cats-preview.nakanishisoya.workers.dev/catalog.json`。
- グループの本物通報adapterはNOのまま。Workerの配備、一般公開、App Store審査提出、外部TestFlightは含まない。
- 通常CIは直近約17分、配布ジョブは約16分。候補CIから内部配布表示まで約35〜45分を見込む。17:42時点は通常CI開始前、311は未配布。
