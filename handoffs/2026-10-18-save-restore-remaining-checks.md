# 保存・復元の残確認

## 引き継げる成功

- 通常写真メモのクラウド到着、最新headの34部品保全、旧31記録保全、端末の自動整理と案内消失は実機/クラウドで確認済み。旧手動コピー復元も成功済み。
- 262の実UI検査は合成別端末から通常ツール・写真メモへ復元し、元記録を残す2caseが成功。両OS runtime42caseには901秒後session更新・同時更新1回・503時credential保持を含む。262 sourceから現在のapp/Shared/UITests/project入力は同一で再検査不要。ただし実Apple通信はfixtureであり、実機クラウド復元とは区別する。
- 17:04の実端末の署名challenge→既存grantによるsession更新とhead revision4の到着、利用者の「保存済み」を照合した。前access期限後かつ明示ログインから約30分後に、再確認ボタンを押さない依頼の手順で成功。17:06には自動整理・全acknowledgement・旧記録保全も確認。[実機証拠](2026-10-18-session-renewal-recovery.md)。

## 実機でまだ確定していない部分

- 接続期限後の通常編集の自動保存は上記で確認完了。実Appleの翌日再検証・30日未使用失効など、長時間経過の全ケースを今回の1回で実機検証済みとはしない（既存合成境界検査は成功済み）。
- v3の実クラウド復元。同期済みの同じ1台はhead revisionが同じなら復元しない。旧コピー一覧はv3を含めず、旧コピー復元は代用できない。同じ本人で接続できる別端末の空の通常ストアで確認する必要がある。元データ削除・再インストール・強制競合・owner変更は検査手順にしない。

## 一般利用量への未完了事項

- 現在の内部受付は1GiB/200内部recordの有限設定。200は利用者の写真件数ではなく、JSON部品・index/head・旧コピーも含む。これを一般向けの容量設計完了と説明しない。
- 2026-10-18 16:52 JSTに製品`validateDocument`と`parseToolIndex`をそのままbundleし、合成index metadataを実行した。8つのJSON manifest（各2bytes/1record）＋写真、source参照なしでは991写真/999fileを受理し、992写真でINVALID_RECORD。全fileに既存sourceSnapshotIDがあるケースでは950写真/258,462bytesは受理、980写真/266,562bytesは拒否。index本文256KiBと999fileの双方が制約になる。Swift側にも256KiB/999file/1000recordの制約があるが、このprobeはnative JSONEncoderや実UIの検証ではない。
- 合成metadataなので実利用件数・転送速度・請求の実測とはしない。通常の記録を長く蓄積する設計では、単純に受付上限を上げるだけでは足りず、indexの分割/参照、1変更時のowner復旧コピー量、export上限、端末の旧snapshot整理を合わせて設計・検査する必要がある。現行写真や本文を読み出す必要はない。
- 動画クラウド保存は未実装。今回の接続修正で追加した扱いにしない。980円維持、一般公開・課金開始・追加有料枠の承認を得た扱いにしない。

証拠: `C:/dev/neko-evidence/automatic-test-20261018/automatic-capacity-parser-probe.json`。製品parser入力はmain266a305と同一。独立レビューによる262の成功証拠照合と現UI導線確認は主チャットへ統合済み。
