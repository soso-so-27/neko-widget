# お世話引き継ぎの検証範囲

新規ツールの製品差分とは独立したCI選択だけの変更。通常の未登録service差分はfull-v1（過去配布込み75.5〜109分）に戻るため、独立安全レビュー済みの9ソースに限定した`reviewed-care-handoff-ui-v1`を定義する。

- 製品候補5cd8704 / base44d17aeの9before/after全文を固定。新規5ファイルはapp-only。既存4ファイルと1つの許可されたhandoff文書以外の未知差分は対象外。
- 新規5本は000000→100644 A、既存4本は100644→100644 M。削除/移動/symlink/実行属性化/mixed CI/Widget差分はfullへ戻す。
- 必須はBuild、実Photos許可とscan、両OS runtime、新UI2操作＋実MainTab標準/大文字1操作。署名・privacy・成功証拠・配布workflowは変更しない。
- CIのみ先にmainへ統合し、その後製品へ取り込む。selector自己ハッシュや混在companion例外は作らない。
- lane14件とplanner78件は局所成功。CI候補はUbuntu planだけで確認し、この成功をiOS製品の検証として流用しない。
- 製品は先にfocused診断でnativeフォーム/保存/開示/実PNGとPDFページを確認する。診断はリリース成功証拠ではない。初回製品通常CIは未計測として記録し、避難の20分28秒を新scopeの実績とは扱わない。

CI制御の独立レビュー結果および新候補のhash変更があれば、確定後に記録する。
