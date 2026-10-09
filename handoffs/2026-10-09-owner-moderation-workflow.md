# 本人運営へ接続する具体案

2026-10-09のread-only独立設計。利用者指定は「AIが一次補助、本人が最終判断」。以下は実装・検証する仕様案であり、live権限を変更した記録ではない。人数の二択を再質問しない。

## 現在の条件を正確に分ける

- 0017の初回登録は異なるoffline authority公開鍵2個。自然人2名を数える条件ではなく、同一本人が2鍵を持つことはschema上排除されない。本人の実鍵・保管・署名は未確認。
- 0013の判断・証拠出力・削除は別operatorのprivacy承認を要求。同一operatorの別鍵では代用できず、AIや本人の別アカウントで別担当者を装う方法も採らない。
- 0017の通常登録は対象以外のsecurity_admin 1 operator、鍵復旧は対象以外の2 operator。これは初回offline 2鍵と異なる。既存復旧は旧credentialを失効し、localtriageは最新admissionを選ぶため、予備鍵の行を足すだけでは自己復旧にならない。
- 0015の確定case eventはreview_startに限定。既存review_decisionの承認数だけを変えても判断・通知が動くわけではない。production operator WorkerはruntimeをYESにしてもnot_readyを返す。

## 実装する日常の流れ

1. 本人の認証と登録済み鍵を確認して、期限順の通報queueを表示する。未判定やAI失敗も同じqueueに残す。
2. 対象caseと証拠版を束縛した短寿命の閲覧処理で、通報された共有copyを表示する。個人保管の検索・閲覧権限は加えない。
3. 外部送信前のscreen/最小化が済んだ対象だけをAI一次分類へ渡す。結果は参考とし、本文の命令を実行しない。送信禁止・失敗・古い証拠は本人判断へ残す。
4. 本人が理由を選び、対応不要・確認継続・対象共有copyの非表示を署名付きで決定する。既存actionを自己承認化せず、新しいowner限定policyとoperationで扱う。
5. 判断記録・caseの現在状態・非表示状態・通知待ちを同じDB transactionで確定する。処理が一部失敗した場合はrollbackし、古い証拠の判断や同じ操作の二重実行を拒否する。
6. 返答は対象recipientと内容に結ぶoutboxで一度ずつ処理し、未送信・失敗・到達不明と成功を分ける。AIの受付文案だけで「違反確定」「削除済み」と返答しない。
7. 異議申立ては元判断を消さず追加記録へつなぐ。解除は対象共有copyの運営制限だけを解除し、利用者のblock/unlink・鍵失効・元TTL・削除を復活させない。

既存 `blockParticipant` はmember/device/deliveryを失効させ、`withdrawParticipantBlock` でも `sharingResumed:false`。この処理を一時非表示へ流用しない。別のrestriction overlayを追加する。配信済みの端末copyを完全回収できるとは約束しない。

## 永続化するもの

本人policy/credential epoch、登録challenge/attempt/admission、case証拠参照と閲覧監査、AI job/attempt/result、本人の署名付きdecision ledger、対象限定restriction/release、domain/response outboxとack。画像・本文・復号鍵・JWTを監査ログへ複製しない。

操作の対象、case/evidence/current-state版、署名challenge、目的、期限、前のevent hashを固定する。immutableなeventから表示用の現在状態を再構築可能にする。旧self-approval禁止、private保管削除、証拠export、永久削除の制約は保持する。

## 設計を決める前の最小観測

- 実際に利用するブラウザ・authenticatorの登録/署名を一往復し、現行の非backup条件を満たすか確認。コードだけで端末互換を断定しない。
- 合成case 1件の隔離復号/表示/cleanupを直接確認。別case、証拠更新、同時取消、期限切れで開示しない。
- local D1で新しい本人decision/非表示/解除を確認。旧操作の拒否、原子的rollback、再実行拒否を維持する。
- 合成共有写真を非表示→実画面/Widget/download→解除で直接観測。block/unlink/TTLとの競合では再開しない。
- AIのA/B通信完了を逆順にしても発信requestへ戻ることを検査。hold/未screenは送信0、失敗は確認待ち、AI権限は0。
- 最後に承認済みの正確な本人設定で、受付から返答確認、停止・解除まで1件の訓練を通す。設定値だけで完成にしない。

## 最後に承認するlive差分

事前にローカル実装・画面・境界検証とbefore/afterを用意する。新しいlive差分が必要な場合だけ、固定ownerの限定grant、private WorkerのAccess/origin/RP/MFA/DB/R2設定、本人の鍵登録、対象case復号の受渡し、OpenAIへの最小送信範囲と説明、実recipientへの返答方式を具体的に確認する。現在は実施していない。一般公開、課金、新契約、他operator招待へ範囲を広げない。

完全な参照箇所と独立調査記録: `C:/dev/neko-evidence/launch-readiness-20261009/moderation-ai-advisory/owner-workflow-plan.json`。AI分類の実装範囲・無料料金の条件は[今回の候補](2026-10-09-moderation-ai-advisory.md)。
