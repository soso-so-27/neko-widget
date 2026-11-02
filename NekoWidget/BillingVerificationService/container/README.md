# 非公開購入確認Container

Node 22のApple公式検証ライブラリを既存Cloudflare Containerで動かす構成。新しい常時稼働サーバーやRedisの契約は不要。9月30日の配備は全gate OFF、10月1日の読取でもversion `607f1990-2cc6-4b3f-961f-0552556f7184`が100%。これは実購入成功の証拠ではない。

既存のnamed `BillingVerificationService` bindingはSandbox専用で、Production store・production環境・HTTPS入口有効時は拒否する。workers.devは引き続き無効。呼出先origin固定、HMAC request/responseを照合し、redirectを転送しない。秘密・Apple root・実商品IDはrepoに置かない。

default fetchのHTTPS入口は既定OFF。将来の別途承認された配備では、`BILLING_VERIFIER_HTTPS_ENABLED=YES`と既存Container gateに加え、`BILLING_VERIFIER_HTTPS_ORIGIN`（末尾スラッシュなしのHTTPS origin）、`BILLING_VERIFIER_ACCESS_ISSUER`（固定teamの`https://<team>.cloudflareaccess.com`）、`BILLING_VERIFIER_ACCESS_AUD`（当該Access applicationの64桁小文字hex）を必要とする。値はrequest/JWTから選ばない。対象originへのPOST・内部5パスだけを許可し、RS256署名・issuer・AUD・iat/exp/nbfを検証してから既存の本文上限・HMAC・永続nonce検査へ進む。Access headers/cookieはContainerへ渡さない。JWTにAppleのstore environmentを推測させず、各配備の固定origin/AUD/HMAC/nonceを分ける。

この変更はCustom Domain、Access Service Auth policy/token、secretの作成や投入、Container起動をしない。実Access policyによる専用caller制限・到達制御・資格情報失効の即時性は合成JWT検査の証明範囲外。JWKSは固定issuerだけから取得し、3秒期限、64KiB/8key上限、5分cache・未知kid再取得30秒間隔を使う。鍵取得失敗・設定欠落・認証不正は拒否し、HMAC・nonce・Container予算の既存停止境界は維持する。

nonce台帳はDurable ObjectのSQLiteで共有し、601秒保持、競合・再起動・容量上限・後退時計を確認する。Nodeのnonce送信は内部hostへのoutbound handlerだけで、Redis/HTTP公開先へfallbackしない。Containerは非root、最大1instance、2分leaseを事前予約し、月10時間の予算内でだけ起動する。期限はtrafficと別にdestroyする。

月額SKUは必須、年額SKUは未設定なら不要。空・不正・重複SKUは拒否。Server APIの3鍵はStatusまたはHistoryの正確YES時だけNodeへ渡す。保管復元・本人確認のApple鍵と購入確認の鍵は別用途。

ローカル確認は親ディレクトリで `npm run check`、PreservationServiceとこのディレクトリのlocked dependencyを入れて `npm test`。nonce/secret転送境界は実workerd/SQLite、Node検証はNode22。WindowsのローカルContainer起動を配備成功の証拠には使わない。Docker image buildと実Sandbox購入/復元/失効は別の未確認項目。

旧一度限りのremote probeとその承認は引き継がない。実配備では現version・既存binding・secret名・registry image・OFFを照合し、既存値を上書きする合成secret試験を行わない。
