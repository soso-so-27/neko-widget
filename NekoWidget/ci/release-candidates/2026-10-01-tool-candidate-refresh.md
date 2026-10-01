# 未編集のツール候補を次の利用で更新する

## 目的・変更範囲

- 最新main `252642bb90b8d8a99ea968245a1afb5fcca57e9e` から別branch。開始調査は2026-10-01 10:50 JST頃、最初の製品編集は11:02:35 JST。製品10ファイルと既存UI本文3件だけ。実装・関連native確認・main・内部TestFlightまで90〜120分の計画で、未計測の短縮を約束しない。
- 預ける・避難・迷子の編集画面へ入った時、候補のままの文章だけ元情報の更新を反映する。本人入力・明示的空欄・確認済み避難情報・旧記録は上書きしない。写真、医療、連絡先、出来事の日時/場所は自動更新しない。
- 一覧/閲覧/プレビューでは更新しない。既に作成した画像/PDF/共有用の控えは独立コピー。病院の既存診察控えも変更しない。
- 既存の候補表示と編集操作を利用し、登録/取り込み/確定を必須にしない。失敗時は保存済み内容をそのまま編集でき、迷子の出力を塞がない。
- foodの全体候補マークに加え、Careの任意段落だけoptional provenanceを持つ。食事の時刻/量だけの編集で、未編集のコピー段落が逆方向の元情報になることを拒否する。legacyの不明な段落も元情報へ昇格しない。

## 判断を変える仮定・安価な証拠

- 過去のnative撮影で、候補は実際の保存値として編集・出力される既存経路を確認（tool-cat-autofill-diagnostic-36655219812）。これは新しい更新挙動の成功証拠ではない。
- コード差分で編集入場時1回の更新、ID一意照合、候補元情報の逆流拒否、commit後だけ公開する原子的更新、既存の控えに値/画像のsnapshotを渡す経路を確認。
- 独立レビューagent `review_tool_autofill` が製品10ファイルを読取専用で確認し、確定P1/P2なし。実UIの入場時更新/再起動保持/薄字は未確認のまま扱う。
- 一覧閲覧だけで変わらない、元写真に障害があっても既存迷子下書きは使える、手入力/空欄/旧記録/同名別猫/重複ID/書込失敗/控え不変を既存DEBUG fixtureの境界に追加。実行結果はnativeの結果待ち。

## 必要な確認と除外

- 既存3件: Care候補→元情報更新→編集→別の元情報→再起動、Evac structured meal→再利用更新と独立写真（AX3）、Lost初回候補→元情報更新→手編集→再起動と画像/PDF・非公開情報除外・同名別猫（AX3）。
- UI依存の仮定を最初に上記3件のfocused diagnosticで直接観察してから、同じSHAの通常候補CI（Build/Photos bootstrap/両OS runtime/owning UI）へ進む。diagnosticは配布証拠に代用しない。
- CI登録は別companionで、全10ファイルの完全before/after・通常mode・3件の実宣言に一致する場合だけ。未知/欠落/共有モデル/Widget/project/workflow/CI混在を拒否する。
- Widget、Gallery、購入/課金、保管backend/runtime/secrets、CloudKit、一般公開は変更せず無関係な画面検証を追加しない。内部配布の `--preservation-pilot` を維持する。
- 実画面/CI/配布は完了時に結果と累計時間を追記する。署名/upload成功を通常の終点とし、Apple処理完了やiPhone表示を確認済みとはしない。

## 初回focused診断と修正

- diagnostic `36805474184`（`086ce7ba0b7f4d4ca95e8ead8851019e5e8ee7c8`）は17分08秒、Mac runner16.9分。3件中Care/Evacは成功し、実際の候補更新を撮影。Lostは追加した保存境界fixtureで止まり、新しい更新操作の確認には到達していない。
- native AXの `lost-cat-fixture-error` は「入力候補の保存境界が成立しません」。新しいlegacy-emptyの比較が、`draft()` のmigration返却値（save前のupdatedAt）と、`save()` が時刻を付けた保存済み値を全体比較していた。製品の内容変更ではなく、fixture比較対象の誤り。保存済みの同一値をbeforeにして「更新されない」を検証する。名前/特徴/独立写真/空欄の条件は弱めない。
- 製品挙動は変えずDEBUG fixtureの比較3行だけ修正。Lostだけfocused診断を行い、新SHAの通常CIでは既存3件すべて必須。旧SHAの成功を新しい配布証拠へ転用しない。失敗/修正/別companion/待機を累計から除かない。

## 再診断と実行方法の変更

- Lostだけのdiagnostic `36807771420`（`ea4192e589ea5d3d42e9f6cc778bd2bec6616aa4`）は17分34秒、runner17.35分で失敗。保存境界・初回画像/PDF・元情報更新・手編集・公開範囲の出力まで進み、AX3の薄字の新特徴と手編集後の出力を実際のPNGで確認した。再起動の新UI操作は未完了であり、全件成功とは扱わない。
- 停止点はUI本文2149行の再起動後の選択ボタン。native AXは `lost-cat-fixture-error`。fixtureが毎回、保存元の特徴を初期値と比較していたため、phase2で変更済みの元情報をphase3の準備時に拒否した。写真の存在/他猫の非公開写真除外は毎回検証し、初期特徴の完全一致は最初の準備だけに移す。製品・UI本文・保存境界の条件は変えない。
- 同じ17分台の単独診断をもう一度重ねるのはやめる。変更後の独立レビューと完全source照合を経て、既に必要な通常候補のBuild/Photos/両OS runtime/3件のUIで未確認の再起動を直接確定する。診断の旧SHA成功を配布証拠へ転用せず、通常3件のskip/失敗は許可しない。約69分の経過と診断2回の失敗を残し、当初120分に対して残りの通常CI・内部uploadを進める。

## 通常CIと本線反映

- 補正を `3c0f79a44f5662b8efc3ad6b60c8ae9e2c495dc8` へcommit。独立レビューに確定P1/P2なし。初期特徴の完全一致を初回へ移しただけで、毎回の写真存在/owner写真除外、製品処理、UI本文、保存境界は不変。
- CI制御はPR131/132/133の別commitで先にmainへ反映。最後の補正は1つのafter digestだけ。ローカルの直接16lane tests・製品20全文digest・partial/未知after拒否・3件の実宣言を再確認し、前回12suite成功（310.8秒）の入力不変の処理/拒否条件を保持。PR133の既存Pythonゲートは25秒/runner0.317分で成功。新たなMac検証は制御には起動しない。
- 固定候補 `80ab1c1455700e73cdf852ceb7ad4faf07da76c8` の[通常push CI36809836668](https://github.com/soso-so-27/neko-widget/actions/runs/36809836668)は必須4jobすべて成功。20分37秒、runner合計63.95分。runtimeのiOS18.5/26.2 JSONはいずれもpassed。Care62.287秒/Evac49.844秒/Lost256.947秒で、実行3件・0失敗・0skip。画像/PDF、AX3、元情報更新、手編集、再起動、非公開情報除外・保存境界を確認。
- nativeのCare更新25gの灰字、手編集後の黒字と25g保持、Evac食事30gの折り返し、Lostの元情報変更後も再起動した手編集の黒字をPNGで直接確認。結果は `C:/dev/neko-evidence/tool-refresh-native-final-36809836668/app-ui/ios-26-2/composer-screenshots/`。旧診断の成功を新候補の証拠に転用していない。
- [製品PR134](https://github.com/soso-so-27/neko-widget/pull/134)を2026-10-01 12:41:16 JSTにmerge commit `7f08643af982e431f167f716612da60cc82a133c` でmain反映。固定候補がmainのancestorであることを確認し、main nativeの再実行を要求しない。
- 内部Build233のdry-runは未使用番号・同SHA成功CI・media-staging・保管pilot維持・公開/課金不変を確認した。同じ引数のdispatch1回で[内部TestFlight233](https://github.com/soso-so-27/neko-widget/actions/runs/36811777939)を実行し、2026-10-01 12:55:40 JSTに実際の `UPLOAD SUCCEEDED with no errors` を確認。archive/export/privacy/署名/App Group/内部runtime境界の検査も成功。既存の限定保管pilotは維持し、一般公開・課金・サーバー受付/期限/秘密値は変更していない。Apple処理完了・iPhone表示は未確認。
- 配布run全体12分55秒（runner11.683分）。最初の編集11:02:35 JSTからApple成功まで113分05秒、最初の製品commit11:15:55 JSTから99分45秒、最初のdiagnostic開始から93分56秒。調査は10:50頃からで、調査を含めたuploadまでの全体は約126分。実装開始からの90〜120分計画と調査時間を区別し、全turn120分以内と報告しない。診断2回の失敗34分42秒、3つの制御用PR、レビュー・補正・ローカル確認・統合・待機を除いて最終greenだけの時間にリセットしない。
- 完了記録はupload後に別branchで追記する。製品/native/配布入力を変更せず、成功済みのnativeと配布をもう一度実行しない。保管の並行UX実装は本バッチの範囲・完成条件ではなく、後続候補から合流できる。
