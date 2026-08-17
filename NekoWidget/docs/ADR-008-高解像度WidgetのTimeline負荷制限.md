# ADR-008：高解像度WidgetのTimeline負荷を2件に制限する

- 状態：承認済み・実機ゲート待ち
- 日付：2026-08-17
- 対象：Build 8表示不具合を修復するTestFlight Build 9

## 背景

Build 8はWidget派生画像をSmall 500×500、Medium 1050×500、Large 1050×1100へ高解像度化した。一方、providerはBuild 7までと同じく20件の未来entryを一度にWidgetKitへ返していた。

実機ではSmallだけが写真を表示し、Medium / Largeは写真なしのplaceholder相当となった。診断ログでは、3 familyともmanifestが`available=20 / missing=0`で、20件のtimeline作成、lease、個別JPEG decodeまで成功し、cache欠損、画像破損、1枚5MiB guard超過はなかった。したがって失敗点は、20件分の高解像度ViewをWidgetKitが描画・snapshot / archiveとして採用する段階にある。

1 timelineに含まれるraw decode推定は、Small約19.1MiB、Medium約40.1MiB、Large約88.3MiBだった。TimelineEntryがJPEG DataやUIImageを保持しなくても、WidgetKitは未来entryを受理するときに各Viewを評価するため、「現在表示中の1枚だけがdecodeされる」というBuild 8までの前提は誤りだった。

## 判断

- manifestは従来どおり最大20件を保持し、写真候補の幅を減らさない。
- providerが1回に返すtimelineは最大2件だけにする。1件目は現在時刻、2件目はmanifest先頭日時を基準にした次のcadence境界とする。
- reload policyは、その次のcadence境界を指定する`.after(...)`とする。既定cadence 20分なら、2件目を1区間表示し終えた約40分ごとの要求となり、約36要求／日を目安にできる。WidgetKitの実行時刻はbest effortである。
- manifest先頭の予定日時から経過したcadence数を求め、item indexをmanifest件数で剰余計算する。同じmanifestでは元の6時間余りの予定期間を過ぎても先頭2枚へ固定せず、20件全体を循環する。reloadが遅れても、`now`を新たな基準にしてcadenceを後ろへずらさない。アプリがcache／manifestを再生成した場合は、新manifestの先頭日時が新しいanchorとなる。
- 肉球操作直後は、既存どおり直近で変更した写真を1件目にして即時フィードバックを優先する。2件目と次回要求時刻は元の時刻基準を維持し、押下のたびに切り替え時刻をずらさない。
- family別leaseは、そのtimelineが実際に参照する最大2ファイルだけを記録する。active manifestとhistoryによる他候補の保持は維持する。
- 高解像度、JPEG上限、8%余白、full-bleed、CatPawMarkは変更しない。表示構図の再調整ではなく、Timelineのresource修復として扱う。

最大2件ならraw decode推定は、Small約1.9MiB、Medium約4.0MiB、Large約8.8MiBである。3 familyを同時に置いた単純合計も約14.8MiBで、20件一括より大幅に小さい。ただしWidget Extension全体の実peak 30MiB未満を静的計算だけで保証せず、TestFlight実機で確認する。

## CIと実機の受け入れ条件

- providerの最大entry件数が2以下である。
- family別に`最大entry件数 × 16-byte align(pixelWidth × 4) × pixelHeight`を計算し、Timeline全体の静的decode予算が10MiB以下である。3 family単純合計も20MiB以下にする。
- manifestは最大20件を維持し、provider logは`entries <= 2`、family、次回要求時刻を残す。
- 20分後に2件目へbest effortで切り替わり、次回timelineで時刻基準の続きへ進む。
- 直近の肉球操作後はその写真が先頭となり、好き状態が更新される。
- Small / Medium / Largeを段階配置し、写真、Deep Link、肉球が機能し、placeholder化、再読込ループ、Widget crash / Jetsamがない。

Simulator smokeはHome Screenへ実Widgetを配置しないため、静的な合計予算とprovider sourceの制限を検査する。実際のWidgetKit描画、snapshot / archive、実peakはTestFlight実機ゲートを正本とする。

## 計測と後続build

Build 8の1週間計測は、この表示不具合のため開始または再開しない。Build 9で3 family、Deep Link、肉球の即時同期、20分切り替えを確認した後、新しいbaselineから計測を始める。

[ADR-006](ADR-006-iCloudローカル派生画像の検証.md)のdeferred paired probeは、1週間計測の完了後のInternal Build 10へ送る。採用する場合のproduction反映はBuild 11以降とする。
