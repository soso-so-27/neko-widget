# 非公開Sandboxの配備候補

これは配備準備で、AWSの購入・起動、DNS変更、Tunnel公開、Workerへのsecret登録を行っていない。
既存のNode entrypointを保つため、同一Linux hostでNode・TLS Redis・named Cloudflare Tunnelを動かす。
Nodeは127.0.0.1のみ。アプリport 8080/Redis 6380をLightsail firewallに開けない。
AccessはService Authで指定Workerのservice tokenだけを許可し、Tunnel connectorでもAccess JWTのaudienceを検査する。
HMAC署名と時刻・nonceは引き続き必須。

## 費用と開始条件

公式価格のIPv4付きLinuxは512MiBが月$5、1GiBが月$7。1GiBを候補にする。
512MiBで実Apple SDK・Redis・Tunnelが同時に収まるとは確認していない。
同梱のestimate-verifier-budget.mjsは既存pilot-planの為替・税率・無料枠を引かない条件を再利用する。
既存2735円に$7相当1386円を追加すると月4121円。最小$5構成でも3725円。
R2の無料操作枠が本当に残っている場合の比較額は別に出すが、根拠なしに適用しない。
いずれも新規受付停止の2200円を超える。3000円目標や停止条件を黙って変更しない。
今回の候補では新規受付を開始できない。既存の余剰hostを使えるか、費用方針を決めてから作成する。

## インストールに使う資材

- 固定候補からbuildしたdist/package-lock、Node 22の固定runtimeを `/opt/neko-billing-verifier` に置く。
- `billing-sandbox.env.template` の空欄は秘密管理から注入する。実商品ID・Apple rootsはローカル配備artifactを使い、Gitに入れない。
- `neko-billing-verifier.service` を専用userで使う。既定NOのままでは起動を拒否する。
- `neko-billing-nonce.service` と `redis-nonce.conf` をRedis専用user・専用data volumeで使う。
  OSのdefault redis-server.serviceや既存のRedisへ上書きしない。passwordの設定は `redis-auth.conf` に分離し、secretとして配置する。
- Redis CAとserver keyを専用に作り、証明書のSANに実際の接続先 `localhost` を含める。
  URLは `rediss://:SECRET@localhost:6380/0`。passwordはURL encodingし、ファイルを必要な主体だけが読めるようにする。
- Redis server key/password/AOFとNode HMAC secretはそれぞれ所有userのみ。CA証明書だけNodeにも読ませる。
  NodeのRedis専用CA設定を使い、NODE_EXTRA_CA_CERTSやTLS検証OFFでApple通信のtrustを変えない。
- `cloudflared.yml.template` のhostname・Tunnel UUID・Access team/audienceを確定する。
  固定hostnameのnamed Tunnelにし、Quick TunnelやAccess bypass policyを使わない。

## 最初の実接続で確かめること

1. 費用条件、host、port非公開、DNS・Access accountとaudienceを照合する。
2. 合成nonce1件を異なるNode接続から同時予約し、成功1件・replay1件を確認する。
   Redis認証不正・証明書不正・切断・容量不足では予約成功にせず、Appleを呼ばないことを確認する。
3. Redis再起動後も既存nonceを拒否する。AOFが失われた・新規volumeへ置換した場合は入口を止め、
   最後に受理可能だった署名requestの601秒の期間が終了してから再開する。空のRedisへ即fallbackしない。
4. 実Sandbox JWSで証明書失効確認を含むApple検証と同時4件のメモリを測る。
   systemdの上限設定は容量検証の成功証拠ではない。繰り返すOOMを自動restartで隠さない。
5. purchase/JWS確認後、Subscription Status専用API keyを別用途で準備する。
   Sign in with Appleの秘密鍵をServer APIへ流用しない。失効・再契約の照合が成立するまで保管受付はOFF。

以上は未来の開始チェックで、今回成功したとは記録しない。実写真・メール・課金を合成試験に混ぜない。
