# R05: 受信写真fixtureと製品の操作Viewを共通化

対象ブランチ: `codex/ux-recovery-remaining-20260912`。本メモはローカル実装時点の記録で、native CI・実機・実通信の成功記録ではない。

## 変更

- `FamilyWindowView.swift` の `MomentReceivedPhotoActions` を製品の受信カード・写真詳細とDEBUGの `MomentReceivedLayoutFixture` が共用する。fixture独自の保存/ハートButtonを削除した。
- 製品側 `receivedPhotoActionControls(_:)` が対象の `MomentInboxItem`、保存済み/取込済み、処理中、表示禁止状態、ハートの送信状態を渡す。コールバックは従来どおり保存確認対象・解除確認対象を設定し、ハートだけ既存 `model.sendHeart(item)` へ渡す。保存確認・モデルの状態変更・安全条件・結果メッセージは移動/変更していない。
- 共通Viewは既存の44pt操作域、Dynamic Typeによる縦横切替、保存済みメニュー、再追加、ハート送信済み/再送/送信不可、処理中の表示と無効化、製品のAccessibility名/IDを維持する。
- `AppStoreScreenshotFixture.swift` のDEBUG専用 `ReceivedPhotoActionFixture` が操作種別と写真indexを記録する。保存状態/反応は写真ごとに保持し、「確認用の完了状態を表示」を押したときだけ表示状態を進める。通信・写真への保存を行わない旨を画面に明記する。

## 検証の境界

`PhotoPermissionUITests.swift` の既存3表示条件（標準/狭幅/最大文字）は製品IDのコントロールを操作するよう追従。追加の `testReceivedProductControlsBindRequestsAndPendingStateToTheVisiblePhoto` は保存/ハートの対象写真、待機中の無効化、完了前に成功状態を出さないこと、保存解除後の取込済み区別、別写真に状態が混ざらないことを対象にする。既存の `MomentDeliveryComposerUITests` 実行対象に含まれる。native実行は主担当の候補CIで行う。

既存Python境界テストは、旧関数の内容を新adapter（モデル状態と対象ID）と共通View（操作・無効化・44pt）に対応させて追従。次の3件はローカル成功、`git diff --check` 成功。

- `test_family_widget_memory_link_requires_exact_window_and_photo`
- `test_memory_action_has_visible_result_and_remains_available_during_sync`
- `test_family_window_photo_and_memory_actions_match_the_ui_contract`

確認できるのは製品コントロールの描画/操作と注入コールバックまで。fixtureには確認用の説明・完了ボタンがあり、製品画面全体と完全に同じ内容量ではない。実際の保存確認ダイアログ、PhotoKitのコピー、モデルへの状態反映、バックエンド受付、相手へのハート到着はこのfixtureでは検証しない。実猫写真の品質、実機操作も未確認。R05の「独自Buttonしか通らない」不足を解消する変更であり、実送受信の証明とは扱わない。
