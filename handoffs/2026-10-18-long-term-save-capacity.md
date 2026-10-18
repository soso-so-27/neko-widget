# 長期利用の保存容量対応

- 利用者依頼: 月980円を維持し、普段の記録を長期間残しても容量を気にしなくてよい設計へ進める。追加費用・有料契約は事前説明。対象は通常の写真メモ、ツール入力・添付写真、猫情報。写真ライブラリ全体・動画を新たに保存対象へ加えた意味ではない。
- 作業checkout `C:/dev/neko-bounded-membership-ci-control-20261016`、branch `codex/long-term-save-capacity-20261018`。最新main `56b48be`から開始。研究worktreeは変更しない。新規/手動定期・公開・課金開始・保存枠拡張は行っていない。

## 直接確認と先行修正

- 初回候補/REDは2026-10-18 17:23:37 JST。real local D1へ合成12,000件のtombstone/現行markerを投入し、旧captureが `OWNER_RECOVERY_UNAVAILABLE` で失敗した。元の集約SQLを直接実行すると `D1_ERROR: string or blob too big: SQLITE_TOOBIG`。単一valueへ全履歴を集約することが原因。既存の20,000件tree試験だけではこの入口を通っていなかった。
- owner metadataを単一SELECT、inventoryを256行のkeyset pageで読む。全page・終端・最終確認でowner generationとinventory generationを照合する。初回countとの一致、昇順/重複、現行marker必須、既存100,000件上限を保持する。空inventory行なし=0も維持。snapshot wire/復旧形式/旧262/暗号化/削除履歴の保持は変更しない。
- ACK新規挿入・既存ACK再利用・S3読戻し後の成功直前にも両世代を条件化。recordが更新され、まだmarkerが到着していない期間に不完全なsnapshotを成功扱いしない。
- 17:26の関連2file/22cases成功。追加race3件は成功したが、同じtest fileに未完ownerを残し、既存の全owner修復試験が1件失敗した。製品原因ではなくtest fixtureの共有状態。新規raceを別fileの独立fixtureへ移し、元test fileは差分0へ戻した。失敗を消さず、元の該当修復1caseを再実行して成功（他10skipを成功に数えない）。
- 17:32のcapture/auth/device integrationは3file/69cases成功、typecheck成功。17:33の最終capture16casesは16.60秒で成功し、100,000件読取・100,001件拒否、空/255/256/257件、途中のrecord更新・marker到着だけの世代進行・最後page後のowner変更、欠落/重複/逆順、marker欠落、ACK挿入前/新規読戻し/既存読戻しの競合を含む。実クラウド・native UIの証拠には代用しない。
- `journal_identity_review`の独立レビューでblocking指摘なし。全履歴の配列保持/tree計算はなお残ると指摘され、全容量対応の完了とは扱わない。

## 検査・反映前の計画

- changed behaviorは上記のbounded D1 capture/ACK fenceのみ。直接証拠は旧SQLITE_TOOBIGと新16cases。未確定: live D1/Worker負荷、長期の全tree CPU/メモリ、native容量/復元、全アプリ原価。
- 必須: 型検査、関連認証/復旧成功の保持、独立レビュー、既存のbackend全suite/migration/private bundleを同候補SHAで実行する通常CI、main統合、既存archiveへのcode-only反映と実code/settings/データ保全の読取。native入力は不変なので本先行修正のMac再検査/TestFlightは不要。
- 新scopeのCI実測はまだない。直前backend実測123秒、制御ローカル検査は約4分が参考。先行backend反映は初候補から60分程度を計画するが保証ではない。失敗/待機/検討も含めて実績を追記する。アプリ保存形式の変更・配布は別の候補と見積もりが必要。
- owner captureは全件count＋bounded pageになるためD1 SELECT回数は増える。S3/KMSの回数・保存コピー・有料契約は増やしていない。月980円、受付/予算/secret/cronは維持。実反映前に既存枠と増分を照合する。従量原価0とは主張しない。

## 全体としてまだ必要な対応

1. アプリのv3 indexは999files/1000IDs/256KiB、JSON各8MiB。内部200件/1GiBだけ引き上げても長期利用を保証できない。
2. 新しい保存形式は項目・page単位の変更/復元と、新旧端末の明示的な互換境界が必要。旧262が読むheadへ未対応形式を先に書かない。
3. 全写真の準備領域→保存領域コピーと全件再hashを減らす。filename不変だけで内容不変と決めない。通常manifestの大きさ、更新時の新旧同居枠も含める。
4. server/native exportの1000件上限、災害復旧で全S3世代を列挙する境界、全owner配列/tree CPUを調整する。tombstoneや旧revisionの単純削除は削除済みデータ復活の危険があり行わない。
5. 年数・写真メモ件数/ツール変更を明示した1人当たり原価を再計測する。既存月2の14.42円は保存関連の既知小計で、長期・全アプリの確定原価に読み替えない。無料共通枠/予備費を1人ずつ加減しない。
6. 別端末の通常画面へのv3実復元は未確認のまま保持する。既存1台での手動コピー復元を代用しない。
