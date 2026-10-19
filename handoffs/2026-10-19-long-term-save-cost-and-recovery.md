# 長期利用の費用と復元速度（2026-10-19）

月980円を維持する。通常の写真メモ、ツールの入力・添付写真、猫情報を、別の保管操作なしで保存・復元する方針。写真ライブラリ全体、写真原本、動画は現保存対象ではない。容量50GiB/200,000 live records・全体100GiBは有限の内部枠であり、無制限や一般提供の承認と読み替えない。

## 今回反映した変更

- 製品source7dc988f／統合候補4937928。最大50件・24MiB目安で必要な記録をまとめて復元し、完全なpage/file境界で既存端末grantを更新する。所有者・generation・root・hashを照合し、全検証後だけ端末へ一度に反映。未保存編集の保護を維持。
- 制御PR382/main3dafb2bを先行承認。製品PR383/mainb85d348へ統合。診断39180994155はUI2件/runtime42が成功。通常39183357481は全4必須native job・owning UI5件が初回成功（25.883分、runner69.35分は課金額ではない）。同SHA Preservation39183357547はNode32＋Vitest689・型/移行/両bundleの8必須stepが成功。raw UIは各started/passed1回をmain前・cloud前・release前に別途照合し、診断やskipを成功代用しない。
- 既存archive Workerだけcode-only反映（2026-10-19T01:54:05.108965+00:00）。bundle51b6a88c…、version 087acc35-887c-48ca-8d3f-50fe7941e8ef。deletion Worker、schema、secret、bindings、runtime、cron、intake、quota、取得したD1保護policy・counter・record/履歴集計は前後一致。全履歴本文の独立監査まで実行した証拠ではない。新契約・料金プラン変更・一般公開・定期作成/再実行0。
- 初回writerはowner復旧履歴185→186の差でupload前に停止、write0。固定snapshot継続でupload1回は成功したが、最新uploadのcodeと稼働中の旧deploymentを混同した観測方法によりactivation前で停止した。既存upload087acc35を再利用したactivation1回は受理され、応答がdeployment IDだけだったため期待したversions項目の検査で停止した。3回の停止と各partial executionを保持し、追加の書込なしで受理済みdeployment ID・087acc35の100%稼働・元postcheckの全保護条件を読み取り確認した。累計upload1＋activation1であり、再upload・再activationしていない。追加metadata読取で現generation190 ACK/pending0/accounting valid1を確認。呼出元そのものは未特定で、定期処理と断定しない。
- TestFlight265は正規CLIから1回起動、run39187574527でApple検証/upload成功。`2026-10-19T02:06:43.6233970Z`。Appleの処理完了や端末への表示、別iPhoneの復元は未確認。初候補2026-10-19T00:00:24.839408Zからupload job終了まで126.40分（途中の診断・失敗・待機を含む）。成功分だけで計時をリセットしない。

## 1人あたりの費用として言えること

保存済み写真50個の実観測平均872,234.96Bを将来も同じと置き、1ドル160円・1年365日・無料枠を人数分引かずに計算した。将来利用者の実平均や請求額の保証ではない。単価はAWS東京の10/19公開offer、Cloudflare公式料金の直近確認を使用。

| 毎日の追加枚数 | 1年後の月額 | 5年後の月額 | 10年後の月額 |
|---|---:|---:|---:|
| 1枚 | 約2円 | 約10円 | 約20円 |
| 10枚 | 約20円 | 約98円 | 約195円 |

**この表は写真本文のR2/S3各1コピー保管料だけ**。メタデータ、全過去version、D1物理storage、保存・閲覧・暗号化処理、固定費等を含む1人総額ではない。

普通利用寄りの例として、**1日写真1枚を10年（3,650枚）、現在も写真1追加＋メモ1編集/日**という別fixtureを各1回実行した。メモ31.446秒、写真36.600秒で成功、ACK0/予約0/accounting valid1/head2/全旧versionsを保持し、外部通信・CI・製品編集0。これはlocal実行時間で本番速度ではない。旧input guardで4差分を検出した停止を保持し、native2本とselected-export2本のexact差分・非実行依存を限定した新しい入力候補として計測。ArchiveStore保存/暗号化/SQL経路の入力は不変で、現tree全体が旧treeと同一とは呼ばない。

同条件の測れた原価は写真追加26.92＋メモ20.65＋写真2copy現保管19.50＝**67.07円/月の条件付き小計**。既存metadata全履歴、D1物理保管、Workers/container/DO、独立cron、固定費等は小計の外。実請求や普通の一人の総額、10年の累計費用にはしない。[3,650枚の数量と計算](C:/dev/neko-evidence/long-term-cost-recovery-20261019/fullpath-ordinary-3650/ordinary-3650-cost.json)。

実ArchiveStore経路（local D1/AES、S3 transportとKMSは計測用fixture、外部通信0）で、36,500写真時点のメモ1編集・写真1追加を個別に成功させた。写真1追加は19index＋7JSON＋photo＋headを保存し、旧26部品退役、ACK待ち0/予約0/旧S3 versions保全。4KiB写真の実測数量へ料金を当てると処理部分2.0671円、写真本文だけ平均サイズへ置き換える感度値2.0966円/件。現地本番の実請求・CPUやJPEG実行時間ではない。

同じ大きさの状態で写真を1枚ずつ10回/日、メモ編集1回/日の同一workを繰り返す条件なら、測れた保存処理637.71＋38.18円/月と現写真195.01円/月の**条件付き小計は870.90円/月**。既存の全metadata履歴、D1物理保管、Workers/container/DO、定期処理、固定費配賦、税/ストア手数料等は別。過去10年の累計、普通利用の平均/上限、月980円の採算保証にはしない。

この条件の上位処理原価はKMS約263.54円/月、D1書込約236.50円/月。非写真S3履歴は同条件1か月で約674MB増える計算で、既存全蓄積は未確定。固定費はサービス全体の実費を有料会員数で割る別項であり、Apple IDを3人単位にまとめない。任意の予備費は加えない。

根拠: [全計算](C:/dev/neko-evidence/long-term-cost-recovery-20261019/final-cost-and-recovery-20261019.json)、[条件付き小計](C:/dev/neko-evidence/long-term-cost-recovery-20261019/conditional-month-at-36500-20261019.json)。公式単価: [R2](https://developers.cloudflare.com/r2/pricing/)、[D1](https://developers.cloudflare.com/d1/platform/pricing/)、[Workers](https://developers.cloudflare.com/workers/platform/pricing/)、[S3](https://aws.amazon.com/s3/pricing/)、[KMS](https://aws.amazon.com/kms/pricing/)。

## 復元速度

選択した記録のまとめ読み込みと長い復元での接続更新は実装・検査済み。ただし大容量の実クラウド/実iPhone完了時間は未測定。50Mbpsが継続し、非圧縮NDJSON/base64で平均写真を転送すると仮定したデータ転送部分だけでは次の計算となる。

| 10年間の使い方 | 写真枚数 | 転送部分の計算 |
|---|---:|---:|
| 1日1枚 | 3,650枚 | 約11.3分 |
| 1日10枚 | 36,500枚 | 約113.3分 |

認証、暗号化確認、HTTP/TLS外枠、rate待機、再試行、端末への書込等は加わる。実HTTP圧縮も未観測で、実完了時間の保証や無条件の物理下限ではない。診断96秒やlocal SQLite試験の秒数を実機復元速度へ転用しない。

運営側の大規模障害復旧は別問題。保持した100,001件の実tree検査は200件ずつ501段階で成功したが、現15分定期だけなら約125時間（約5日）かかる構造。offline journalの10万件tree歩行と全写真を含む実クラウド復旧は別で、後者は未測定。一般提供前に短縮経路と復旧時間の検証が必要。

## 残作業と費用境界

1. **長期総原価の確定と原価低減**。写真保管料だけで採算を判断しない。48KiBの同offset比較でpointer5片中メモ3片/写真追加2片はbyte完全一致したが、単純再利用は現source/batch契約に不適合。小5片の実D1検査でも旧sourceの新片は新batch abandon/latePUT fenceから外れると確認したため、製品へ採用していない。現clientはこのprototypeを使っておらず現運用障害の証拠ではない。独立batch帰属、current owner/root/file/offsetへ束縛したpiece receipt、安全fallback、旧readerと中断復元の契約を先に定める。
2. **大規模障害時の復旧短縮と全写真を含む計測**。本番データを破損させる試験や、定期の手動再実行を実施した扱いにしない。
3. **別iPhoneでの新形式復元と大量データ性能**。今回は利用者が実機以外を依頼したため端末操作を新たに要求していない。本人限定の保存受付は10/19 09:21:40 JSTに期限切れのまま、残枠を補充/期限延長していない。次の保存実機検査には別途その時間に合わせた有限受付が必要。

月980円は維持する。追加の有料契約・従量課金プランへの変更や一般提供は実行前に説明・承認を受ける。容量無制限、原価改善完了、残作業は実機だけ、と案内しない。
