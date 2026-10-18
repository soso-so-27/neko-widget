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

## 先行修正の反映結果

- 制御PR362をmainへ先行反映。固定scope `preservation-owner-capture-capacity-v1` は製品2blobと通常handoff以外を拒否し、同SHAのbackend全必須stepを要求する。ローカルdevelopment-flowの15suiteは276.2秒で成功。製品最終候補 `d5e903e5c62e33198318a41b4ad5777b1c7ecf9f` は元 `8304ef1` と製品treeが同一。
- push plan `39112581807`、backend `39112581811` とも成功。後者は型検査・Node32件・Vitest617件/71files・旧notice移行・両private bundleの全必須step成功、128秒。PR363をmerge commit `09b8cd072a13486e37f46f315449b124c287eada` で統合した。native入力は不変で、262の成功証拠を保持し再配布0。
- 17:50に一度だけversion upload成功。activation前の読取で401となり停止した。旧版が稼働したまま、activation request/resultとも未作成であることを確認した。新tokenで旧baseline不変を確認し、review済み4executionファイルhash・CI・main・versionを固定したresume helperでactivationだけ一度実行。再uploadは0。
- **17:54:03 JSTに既存archive Workerへ反映完了**。version `1e504e73-8c00-4bb4-a837-1e5b14462b3c`、実bundle SHA256 `fed580953e21bc46c42c5352323353f197afb15e59fdae20ed33b74eb8171f43`。bindings/secret継承・settings・cron・公開範囲不変をfresh GET/実byteで確認。独立レビューの再開helper hash固定指摘を修正した。初回17:23:37から30分26秒（test fixture失敗・認証中断・再開レビュー込み）、先行60分計画内。
- 17:55/18:00のD1読取でinventory世代88・43,756,122bytes・予約0・owner世代157/全ACK・修復エラー0・未参照live部品0・受付/全counter不変。18:01の公開参照読取でhead revision4/必要34部品すべてlive、旧31記録のrevision・bytes不変を確認。本文復号/アプリAPI呼出/手動cron/定期作成0。反映直後の観測だけで大量実クラウド負荷を確認済みにはしない。
- 月980円、既存200物理record/1GiBの内部枠、受付期限10月19日03:09 JSTを維持。追加契約0。将来の容量枠引上げや全アプリ原価の承認にこの結果を流用しない。

## 負荷の直接計測

既存local D1を用いた合成capture（画像本文なし、S3/KMSなし）の観測。100,000行を「写真100,000枚が保存可能」と解釈しない。

| 履歴行数 | D1照会数 | 読取行数 | 書込行数 | 時間 |
| --- | ---: | ---: | ---: | ---: |
| 100 | 3 | 408 | 0 | 35ms |
| 12,000 | 49 | 48,100 | 0 | 452ms |
| 100,000 | 393 | 400,788 | 0 | 2,266ms |

Workers test poolが成功時のconsole出力を抑制したため、計測専用の別probeは`EXPECTED_CAPTURE_COST_PROBE_OUTPUT`を意図的にthrowして観測値を保存した。これは通常製品検査617件へ含めず、製品失敗/成功に読み替えない。全treeのCPU/メモリ、全S3世代、復元、アプリ料金はこの表では測れていない。D1の[$0.001/100万read行](https://developers.cloudflare.com/d1/platform/pricing/)は共通込み枠超過時の単価であり、利用者ごとに無料枠を付けない。

## 次の保存形式の直接試作と設計境界

`partition-shape-probe.mjs` は合成メモをUUIDのprefixで必要に応じて再分割し、各子のmetadataを**現行の製品v3 parser**に通した設計試作。新catalog・新native store・JPEG本文・実復元の実装/検査ではない。1日10枚を利用者の実使用量と断定せず、10年間の容量設計シナリオとして36,500枚を使った。

| 合成メモ | 本文長 | 全件JSON | 子page数 | 最大子JSON | 1編集で変わった子JSON |
| --- | ---: | ---: | ---: | ---: | ---: |
| 3,650 | 21文字 | 1,529,373bytes | 16 | 106,030bytes | 103,058bytes |
| 36,500 | 21文字 | 15,293,523bytes | 256 | 73,767bytes | 58,644bytes |
| 36,500 | 500文字 | 67,744,023bytes | 256 | 326,679bytes | 258,387bytes |

- 36,500件は現行のnative JSON8MiB制限を超える。単にwireのindexを分割しても、復元後に一つのstate.jsonへ戻せば次回保存が停止する。端末内PhotoMemoryNoteStoreの保存/読込/編集・fingerprintも分割する必要がある。
- 各子の上限は256メモ/512KiBという**試作上の条件**。1編集で子1pageだけ変わり、写真descriptorは不変。別途index、祖先2page、head、整理、owner復旧の操作が必要であり、1編集の総料金・総通信を58,644bytesとはしない。
- 固定prefixだけを容量保証にしない。同じ長いprefixへ300件を集中させた試作は30桁まで降りて2leafへ分割し、全300件を保持。再分割・rootの多段pageも必要。実保存先を使った再起動/再読込は未確認。
- 独立レビューで、VeterinaryVisitStoreの100 visits×20 entriesと他toolの添付増加も制約になると判明。単に「一つのtool=一つの子」に分ける案では長期対応にならない。論理項目単位で各storeを扱う。
- `app-records-v2`という別head ID/kindの案は採用しない。262は`app-records-v1`をsaltに固定IDを作るため別IDだと端末が分岐し、kind変更は旧一覧の非表示filterから漏れる。同じ論理headを維持し、index versionで移行し、移行済みheadへの旧writerをserver側で拒否する。未送信の旧端末が新headを上書きしない確認が必要。
- 参照保護をhead→catalog→子index→partsへ通し、公開CASと参照追加を同じtransactionに含める。子間のUUID重複、誤prefix、欠落、owner/schema/hash違い、循環、削除競合を拒否する。復元は全部を私有領域で検証してから一度だけlive化する。途中の子だけ公開しない。readerを先に用意し、未対応の262へ新形式を先行公開しない。
- 現immutable-record-treeはすでにradixであり、変更されたleaf/祖先のS3書込みだけを更新する。`create`の全件logical計算、owner captureの全件D1 read、100,000履歴、全S3世代列挙、export1000はなお残る。tombstone・復旧世代を単純に削除して軽くしない。
- 次のnative候補は上記ストア/形式/復元/互換境界の実装と直接runtime試作が先。成功した617件や262 nativeを無関係にやり直さず、変更経路の境界検査と新配布が必要。先行backendの60分計画や128秒CIをnative作業の所要時間に読み替えない。候補が具体化した時点で必要CIと初候補時刻・所要見積もりを別記する。

## 費用の扱い

- 10月18日18時台に東京S3/KMS/転送の公式price APIを再読取し、既存のS3 Standard $0.025/GB-month、PUT $0.0047/1,000、GET $0.0037/10,000、KMS $0.03/10,000を確認。R2は[公式価格](https://developers.cloudflare.com/r2/pricing/)のStandard $0.015/GB-month。共通固定費/込み枠は利用者の人数で配分し、予備費や架空の3人区切りを入れない。
- 今回はcapacityの値・保存対象・価格・有料プランを変更していない。次形式の全provider呼出、保持する世代数、旧新同居、復元まで測れていないので、長期の1人当たり総額はまだ確定しない。旧月2の14.42円や写真bytesだけの保管料を総額として案内しない。容量枠や有料契約を変える前に、実測条件と増分を利用者へ説明する。

証拠は `C:/dev/neko-evidence/automatic-test-20261018/` の `owner-capture-backend-ci.log`、`owner-capture-capacity-cloud-final/execution/completion.json`、`resume-owner-capture-activation.py`、`capture-cost-observation.json`、`partition-shape-probe.json`、`long-term-unit-prices-20261018.json`、時刻付きmetadata読取summary。draft cloud packageは未実行で保持し、task historyを削除/圧縮していない。
