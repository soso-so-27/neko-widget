# AI一次分類と本人判断の実装候補

2026-10-09。利用者の「AIでやれば」「お願いします」を受け、日常運営をAIの補助と本人の判断へ寄せる。人数を二択で再質問しない。一般公開・実データの外部送信・新料金・live権限の変更は、この候補では行わない。

## 今回の変更

SharingServiceの新規 `moderation-ai-advisory.ts` と所有テストだけ。Workerから未接続の入出力境界であり、APIを呼ぶ関数ではない。本文と最大1MiBのJPEG派生画像を固定endpoint/model向けの無作用のrequestへ整形する。JPEGは署名と上限だけを検査し、decode・EXIF除去・掲載同意確認を実施したとは扱わない。未来のtrusted callerで最小化した共有の証拠だけを渡す。

case参照の鍵版/HMACと証拠版/hashをコピーし、実wire bodyのSHA256へ結ぶ。入力変更・異なるcase・更新された証拠・30秒超・同ticket再利用を拒否する。ticketは同isolate内だけで、永続jobや認証・DBのcurrent性・ネットワーク応答の由来を保証しない。A requestへB response本文を渡すことはこの純粋境界だけでは検出できない。将来のtrusted senderがネットワーク応答を発信requestへ結び、A/B完了順を逆転したfixtureで確認する。現在のDB証拠を取得するtrusted callerと原子的な保存も接続条件。

固定modelは `omni-moderation-2024-09-26`。13カテゴリと入力種別を厳格に検査し、未対応画像カテゴリの0点を安全と読まない。高い危険信号は優先確認の参考にするだけ。低い信号で既存優先度・期限を下げず、医療文脈・猫の福祉・権利・プライバシー・児童安全は本人確認を残す。通信失敗・不正応答・未判定を正常/解決済みに変換しない。

出力は必ず本人の確認待ち。削除・通報終了・承認権限は常にfalse。返信案は受付の固定文面であり、AI文章生成でも自動送信でもない。本文・URLに書かれた命令や、応答側の別case/actionを実行しない。known/suspected child-safety案件、未screen案件はprovider payloadを作らず本人対応へ残す。この入力routeは検知器でも送信許可でもなく、実際の事前screenは未実装。

## 提供先・費用の具体案

- 分類先候補: OpenAI `POST https://api.openai.com/v1/moderations`。送信候補は当該通報の最小限の本文と必要な共有画像の派生版のみ。case ID、秘密鍵、認証情報、他のアルバム・個人保管は含めない。自由文中の個人情報を自動除去済みとは扱わない。
- 公式ガイドではこの分類endpointは無料。1,000分類/月でも分類API料金の計算は0ドル。Worker、DB、通信、証拠保管、運営時間は別で、運営全体0円・無制限利用の約束ではない。アカウントの利用可能性/制限は未確認。
- 公式 `/v1/moderations` 表は学習利用No、abuse monitoring保持None、application state保持None。一般APIの30日保持をこのendpointへ転記しない。アカウント設定・物理的な処理国・契約上の追加条件まで確認済みとはしない。
- この候補はkeyの取得、API呼出し、実利用者データ送信、課金設定変更を一切していない。実API評価は承認された合成/権利処理済み素材から。実際の通報を送る前に、最小化・事前child-safety route・利用者説明・アカウント条件を仕上げ、具体的な外部送信範囲を確認する。

根拠（2026-10-09実読）: [Moderation guide](https://developers.openai.com/api/docs/guides/moderation)、[request/response schema](https://developers.openai.com/api/reference/resources/moderations/methods/create)、[endpoint別data controls](https://developers.openai.com/api/docs/guides/your-data)。分類器の日本語・猫関連の精度や応答時間を測った証拠ではない。

## 本人一人で扱うための運用案と既存制約

| 操作 | AI | 本人 | 実装状況 |
|---|---|---|---|
| 通報の信号整理・優先確認の提案 | 分類の参考情報 | 全未判定を含め確認 | 入出力境界のみ。実API/永続queue未接続 |
| 受付の返信 | 定型案 | 送信内容を確認 | 案だけ。外部送信なし |
| 通報の理由・対処・異議申立て | 補助のみ | 最終判断、理由を記録 | UI/永続判断/通知未実装 |
| 共有写真の非表示・復旧 | 権限なし | 対象と影響を確認して操作する案 | 本人の署名と監査、復旧可能性を実装・検証後に接続 |
| 個人保管削除・証拠の外部出力・永久削除 | 権限なし | 日常通報とは分ける | 既存の追加承認を維持 |
| 本人の鍵の復旧 | 権限なし | 復旧手段を利用 | 既存の独立復旧条件を維持。本人対応だけで復旧可能とは未確認 |

現行0013/0015/0017の別承認・証拠・登録条件は残っている。AIを二人目の人間として登録しない。独立したread-only調査で、本人の通報判断/復旧可能な共有制限について専用の署名付き操作と永続記録を追加する[具体案と最小検証](2026-10-09-owner-moderation-workflow.md)を作成した。初回offline2鍵と別担当者の承認を区別し、既存blockを復旧可能な非表示へ流用しない。既存triggerを削除して全操作を自己承認へ変える方法は使わない。公開環境の権限を切り替える前に、この具体的な操作範囲と既存復旧条件との差を報告する。

## 検証・残件

合成workerd fixtureで、入力のsnapshot、case/evidence取り違え、期限/再利用、未対応画像カテゴリ、欠落/不正/余分なaction、注入文字列、通信失敗、child-safety hold時のpayload非生成を検査する。APIの判定精度・児童安全検知・実UI・本人運営が完成した証拠ではない。

CIは新規2製品fileの完全before/after・A/A・100644と既存Sharing/Preservation workflowを固定した専用scopeを先に登録する。同SHA owning pushのiOS plan、Sharing4job、Preservationの既存jobを確認。アプリ不変のためnative/Gallery/TestFlightは追加しない。新scopeは初回実測であり旧scopeの117/96秒は計画参考値のみ。

開始01:44:43 UTC、最初の実装01:50:54 UTC。準備/独立レビュー/必須制御チェック/CI含め30〜50分を計画。最終commit/CI/累計は `C:/dev/neko-evidence/launch-readiness-20261009/moderation-ai-advisory/` に記録する。
