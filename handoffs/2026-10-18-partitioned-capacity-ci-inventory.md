# 容量対応の復元テストを通常CIへ登録

製品の新しい`testAutomaticPartitionedRecordsMigrationAndRestore`をfull-v1のsolo-1へ1件追加する。既存の両shard割当て・必須job・写真/Widget/両OS runtimeを維持する。新しい限定scope、旧成功の別入力への流用、失敗の免除は追加しない。

旧main `2c4843801118f7dc0b27a9be5555d952765ff2bd`の完全UI source digestだけを移行前一覧として認める。追加後は登録済み全methodを要求し、未知追加/欠落/重複を拒否する。先行control PRへ製品Swiftや新UI methodを混在させない。

独立担当による実装を主担当がdiffレビュー。`test-ci-lanes.py`28件/34.052秒成功。元製品候補の最初は2026-10-18T09:18:58Z、途中のMac診断失敗/成功を保持する。このcontrolのplan成功はnative・cloud・TestFlight成功ではない。Ubuntu planの既存経路を使い、通常candidateはcontrol main反映後に必要scopeを再判定する。
