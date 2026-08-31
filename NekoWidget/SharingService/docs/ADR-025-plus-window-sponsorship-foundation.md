# ADR-025: Plusによる非公開まどのsponsorship基盤

Status: disabled foundation。payer sponsorship、owner detach、iOS署名clientと有界offline状態を実装済み。既存β、通常UI、配布、写真保存には未接続。

## 境界

BillingAccountIDは課金主体だけを表し、window lineage、space、participant、device、写真、
暗号鍵とは別物である。Plus購入者は最大3つのdurable window lineageをsponsorでき、
そのまどの招待相手はBillingAccountIDを持たずに同じgrantを利用できる。

変更APIはactive billing keyで署名する。新規sponsorまたはAからBへのtransferには、
server-confirmed effective entitlementの上限・下限gateとread-time freshnessを要求する。
さらにcurrent owner deviceが、request ID、payer、lineage、current space、owner participant、
device、membership revision、expected current payer、CAS generation、5分timestamp、nonceを
含むcanonical transcriptへ署名する。inviteeの署名では成立しない。

`DELETE` unsponsorは現在のpayerのactive keyとgeneration CASだけで許可する。解約後に
解除不能にしないためentitlementは要求しない。exact-body lost-response replayも新しい
billing nonceで保存済み結果を返し、現在のentitlementには依存しない。

## Atomicityとprivacy

D1 triggerはcommit時にowner/device/space/revision/block、expected current payer、上限3、
active billing key、entitlement decision ID・reconciliation generation・evaluatedAt・期限・
authority freshnessを再確認する。initial sponsor、transfer、unsponsorは単一audit INSERTの
trigger内でcurrent stateへ反映するため、4件目、A/B競合、transfer/unsponsor競合は一方だけが
成功する。current tableへの直接INSERT/UPDATEはexact append-only auditなしに成立しない。

保存するのはsemantic body hash、owner transcript/nonce digest、参照ID、generation、DB時刻だけ。
raw signature、raw nonce、network address、写真、暗号文、E2E keyは保存しない。unsponsorや
entitlement失効はsponsorship stateだけを変え、window、participant、device、写真を削除しない。

## Participant read

active window participantはmember署名GET `/v1/window-sponsorship` で、自分のcurrent spaceに
限り `windowLineageSponsored`、`grantsPlus`、`generation`、`accessUntilMs` を取得できる。payer ID、
transaction、decision IDは返さない。他windowのlineageを指定する入力自体を持たない。

active ownerは同じmember署名境界の`DELETE /v1/window-sponsorship`で、payerの課金鍵や同意を
必要とせず現在のsponsorshipをdetachできる。bodyはrequest IDと確認済みgenerationだけを持ち、
owner participant、device、current space、lineage、membership revision、block、generationをD1の
同じcommitで再確認する。owner detachもappend-only auditからcurrent stateへ反映し、payer IDは
responseへ返さない。invitee、pending/revoked member、stale generationは拒否する。

## Gatesと残件

Worker `BILLING_WINDOW_SPONSORSHIP_RUNTIME_ENABLED` とD1
`window_sponsorship_enabled` は既定OFF。新規sponsor/transferはeffective entitlementの
既存上下gateも必須。production deploy・gate enableはこの変更に含めない。

iOSにはparticipant署名GET、payer署名PUT/DELETE、owner署名DELETE、ThisDeviceOnly Keychainでの
exact retryを無効状態のfoundationとして実装した。確認済みgrantのoffline利用はServerの
`accessUntilMs`と評価時刻から24時間の早い方までに限定し、確認不能・非加入・期限切れを同じ
booleanへ潰さない。通常画面、起動、Widget、Share Extensionには未接続である。販売前には、
owner detachの明示操作、解約・返金・請求猶予・失効表示をmacOS/Xcode、署名実機、隔離stagingで
検証する。
