# 980円の採算確認と保存処理の費用削減（2026-10-19）

月額980円を維持する。利用者指定の優先①総費用・採算、②保存コスト削減を進める。実機の依頼、新契約、Paid移行、定期タスクの作成・再実行、受付延長、利用枠の補充、利用者データや履歴の削除は含めない。

## 保存処理の候補と検査経路

製品候補 `3349283dadd3e072ca67f157cea9634fa15cb857` は、ownerの復旧目録を1回更新する間のS3書き込み保護をまとめる。個々のPUT前の削除要求・有効なowner確認、PUTとHEADの完全成功、不明な通信結果で永続保護を残す条件、全非同期処理の終了待ち、旧version保持を維持する。鍵キャッシュ、保存形式、アプリ、料金、容量、暗号方式は変更しない。独立レビューでブロッカーなし。新しい失敗コードが外側のlease解放失敗で伝わる場合も503で停止する。

ローカルでは既存lease/owner/keyの31検査と、追加後lease全13検査・型検査が成功。13検査には実D1 migration＋実S3 adapter＋暗号codecのfull-copy fallback/readback、generation競合と旧version保持を含む。失敗したGETの注入や本番速度の証拠とはしない。型検査の一度目の失敗は追加fixtureのBodyInit型だけで、訂正後成功。unittest discoverの0件を成功数に算入せず、直接実行でplanner535件/212.280秒、preflight198件/29.189秒が成功した。

同一の3,650写真・1メモ編集の実ArchiveStore経路で、D1行書込1,579→1,351（約14.4%減）。S3 PUT/HEAD/GETとKMS API件数は同じ。削除要求の新鮮な確認によりR2 GETは38回増える。外部通信0、凍結入力の不変を確認した合成測定であり、本番の総原価が14.4%下がるとはしない。fixture出力の`actualBackendTree`は旧固定ラベルで、実入力の識別は凍結ファイルhashと候補の実service tree `f2e26488e11b5d1ce8ba037e60d3762ddda972b1`を使う。

既存full-v1はpreflight参照64〜98分で30分目標を満たさないため開始せず、独立レビューした既存backend専用profileをv27の完全service treeに固定する。制御4ファイルをmainへ先行反映し、製品と混在させない。workflow・必須8step・5分上限・native/release CLIは不変。製品の同SHA owning Preservation push全8stepとiOS plan必須3stepを確認する。新profileは初回計測として扱い、旧成功・skipを新しい成功へ代用しない。制御・backendに15〜30分の計画参考を記録した。未取得・失敗・待機も累積時間へ含める。

作業開始2026-10-19 02:37:19 UTCを保守的な計時開始とし、最終候補だけでリセットしない。private証拠は `C:/dev/neko-evidence/save-cost-reduction-20261019/`。前batchのクラウド反映・内部265・アプリ検査の成功と残る実機未確認は、[直前の記録](2026-10-19-long-term-save-cost-and-recovery.md)を保持する。今回のクラウド反映は別の資格確認後に行う。
