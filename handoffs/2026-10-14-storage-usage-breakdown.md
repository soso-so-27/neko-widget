# 保存原価の内訳と安全な削減の前提

月980円を維持し、実機保存・復元の確認と独立して進めるバッチ。初回候補開始2026-10-14 11:50 UTC、基点main03fdd199。3人の販売制限、最大値・予備費込みの試算、未承認の旧月予算を通常1人原価や費用承認に転用しない。

## 実装する範囲

`PreservationService/src/owner-storage-usage.ts` は運営調査用の読み取り専用部品。既存の全ページinventoryを受け、R2写真の物理bytes、S3のphoto/record/manifest/owner別の全版本bytesとdelete-marker数を出す。S3最新版本だけを集計しない。写真の暗号文、記録本文、認証情報は読み取らない。

任意の同一ownerの参照観測を渡すと、R2のrecord参照・upload参照・両方・未一致、S3のexact key/version/size一致・サイズ不一致・未一致、一覧にない参照・delete-markerへの参照を分ける。共有される同じ物理版を二重計上せず、矛盾するhash/size参照、重複物理identity、別owner、整数overflow、合計不一致を拒否する。R2のDB photo_bytesは平文サイズなのでcipher bytesとの一致条件にしない。

これは`provided-objects-only`かつ`supplied-only`の非原子的な観測。recoveryVerifiedとdeletionAuthorizedは常にfalse。未一致は未解決であり、孤立・不要・削除可能を意味しない。参照は呼出し側から供給された範囲だけで、完全なD1/復旧履歴の抽出や暗号文検証はまだ接続していない。record revision全履歴、owner全generation、delete-intent内のexact version、pending deleteや遅延writeを省略しても復旧可能と判定しない。key-only参照からversionを推測しない。

既存collectorは未知key形式を拒否する。純粋集計へowner配下の未知形式を渡した場合はunknownへ残すが、unknownが0でも未知形式・未登録ownerの不存在を証明しない。保存中のownerを停止して計測しない。観測を実際に記録する呼出し側は時刻・対象・入力digest・取得の成否を添える。取得失敗を使用量0としない。

この追加はAPI、DB、既存inventory/restore/purge、定期処理、クラウド設定、圧縮gate、内部255へ未接続。ローカルで呼べる集計部品の完成と、実アカウント全量の取得・請求削減を区別する。請求のrequest/CPU/KMS/転送/marker overhead、共通固定費、他サービスの利用はbytes集計に含まない。

## 費用削減の判断

以前の21MiBはowner一覧の上限で、平均サイズではない。既存の[圧縮検証](2026-09-26-preservation-owner-compression.md)は1,000件の合成一覧で暗号化後341,725→127,438bytes。写真圧縮率・実利用者の平均・実請求削減率ではなく、全owner世代の累積増加も解消しない。成功済みのcodec検証を今回の新規成功として再計上しない。

現在のrecord復旧はrevision1から最新まで連続してcommitと過去photoを読む。単純な古いS3版本削除は復元を壊し得る。次は全参照・未解決writeを含む読み取り専用観測を接続し、写真と管理情報のどちらが増えているか判断する。圧縮の有効化は全reader互換性とrollback条件を確認してから行い、履歴整理はcheckpointからの復旧・削除intent再生・所属/権限境界を別途設計する。保存品質・容量・保持約束を短縮して費用を合わせない。

もう一つの増加要因はツールの新規snapshot。`ToolPreservation.swift`のcaptureは新しいsnapshotと各部品のUUIDを発行し、現在参照される全ファイルをコピーする。中断した同じsnapshotの再開は既送信分を再利用するが、完成後に新しく作るsnapshotには同じ写真も入る。これはコード上の構造確認であり、複数回保存の実機測定ではない。次の設計候補は同一owner内で変更のない部品を再利用すること。ただし現v1のpartはsnapshotIdに束縛され、snapshot削除はその部品も削除するため、UUID/hashだけの使い回しは不正な復元やデータ消失につながる。新旧reader互換・owner/epochの拘束・参照を持つsnapshotがある間の部品保護・delete replay・中断/並行保存・account全削除を一体で設計する必要がある。今回はnativeとprotocolを変更しない。

## 検証と本線反映

型検査と新11件＋既存inventory3件が成功（関連14件6.31秒）。全種類・過去版・参照重複・record/pending重なり・欠落・矛盾・unknown・delete-marker・別owner・byte overflow・取得失敗を検査。独立差分レビューはblockerなし。製品は追加2ファイルのみで既存runtime入力は不変。

本線には独立したmain-firstの固定blob/全tracked入力閉包scopeを先行登録し、同一候補SHAの既存Preservation job全stepとiOS planを要求する。新scopeの所要時間は未計測。直前backend実績104秒、既存job上限5分を参考にし、待ち時間と制御登録は別に記録する。通常iOS全件を最初のprobeにしない。今回新契約、AWS Paid、公開、課金、実データ削除、定期task作成/変更/再実行は行わない。

## 本線反映の結果

[制御PR302](https://github.com/soso-so-27/neko-widget/pull/302)を先にmain9c14722へ反映し、製品をそのmainへrebaseした。制御の独立レビューと新10/旧7件、全development15suite（261.9秒）、owning control plan（50秒）が成功。候補d2f96aaea3f61b4b6a9410e7b6d249f6ff0af16aで両追加blob、control4本、他1185tracked入力閉包を再照合し、成功済みchecker入力を保ってcandidate preflightだけを更新した。

[製品PR303](https://github.com/soso-so-27/neko-widget/pull/303)を2026-10-14 12:21:38UTCにmain6f37b4c502f8d023ab664c8b9be6b8297f38403cへ反映。[同SHAのPreservation push](https://github.com/soso-so-27/neko-widget/actions/runs/38562848918)は型・全test・migration5検査・private bundleを含む必要8stepすべて成功（job99秒）、[iOS plan](https://github.com/soso-so-27/neko-widget/actions/runs/38562848711)は必要3step成功（48秒）。自動PR backendも成功、PR planのskipは証拠に数えない。main全tracked treeと候補の一致を確認した。初回候補11:50から製品mergeまで31分38秒で、99秒を全作業時間とはしない。

製品testの失敗はなし。制御test fixtureの2失敗と修正は制御handoffに保持した。rootのCIログ取得はghのescape-sequence保護で1回停止し、ローカルの証拠取得だけ許可flagを付けて再取得した。CI再実行や製品修正はしていない。

残る作業は実owner/全参照の読み取り観測を接続して通常原価を出すこと、全readerとrollbackを確認して管理情報圧縮を有効化すること、同じ写真を再送しないsnapshot設計、実機での保存・別端末復元。既存の保持・通知・整理運用とLP/審査資料の整合も一般提供前に必要。追加有料契約・AWS Paid・一般公開/課金開始の承認はこの反映に含めない。
