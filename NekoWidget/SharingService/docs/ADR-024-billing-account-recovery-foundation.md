# ADR-024: BillingAccount recovery and key rotation foundation

Status: disabled foundation. Production activation and deployment are outside this change.

## Boundary

`POST /v1/billing/accounts/recover` is separate from account bootstrap and from every window,
participant, member, and device identifier. It is available only when both
`BILLING_ACCOUNT_RECOVERY_RUNTIME_ENABLED=YES` and D1 `account_recovery_enabled=1`.
The isolated verifier additionally requires
`BILLING_ACCOUNT_RECOVERY_VERIFIER_RUNTIME_ENABLED=YES`. All three default to `NO`.

The exact protocol-v1 body is:

```json
{
  "protocolVersion": 1,
  "clientRequestId": "lowercase UUIDv4",
  "billingAccountId": "lowercase UUIDv4",
  "signingPublicKey": "canonical base64url Ed25519 raw 32 bytes",
  "deviceVerificationId": "canonical lowercase UUID",
  "expectedAppTransactionId": "bounded opaque Apple string",
  "signedAppTransactionInfo": "compact JWS",
  "signedTransactionInfo": "compact JWS",
  "expectedTransactionId": "Apple numeric transaction ID",
  "expectedOriginalTransactionId": "Apple numeric original transaction ID",
  "recoverySignature": "canonical base64url Ed25519 64 bytes"
}
```

The new key signs `encodeCanonicalFields` in this exact order:

1. `NWB1.ACCOUNT.RECOVER`
2. `1`
3. `clientRequestId`
4. `billingAccountId`
5. `signingPublicKey`
6. `deviceVerificationId`
7. `expectedAppTransactionId`
8. `expectedTransactionId`
9. `expectedOriginalTransactionId`
10. SHA-256/base64url of the exact UTF-8 AppTransaction JWS
11. SHA-256/base64url of the exact UTF-8 Transaction JWS

Success returns protocolVersion, the same clientRequestId and billingAccountId, the new
billingKeyId, and recoveredAt. An exact lost-response retry returns the stored result;
reuse of the request ID with another transcript is a conflict.

## Fail-closed evidence

The Node verifier verifies both Apple JWS signatures. Both decoded payloads must contain
the same exact appTransactionId and both must contain valid deviceVerification and
deviceVerificationNonce values for the supplied deviceVerificationId. Device proof is
SHA-384 over the ASCII concatenation of lowercase nonce UUID and lowercase verification-ID
UUID. The transaction must be PURCHASED, not revoked, and not upgraded; Family Shared is
denied. Its signed expiry may already have passed during billing grace, so current access is
decided only by the immediately following Subscription Status check.

The Worker requires an existing original-transaction lineage owned by the requested
BillingAccountID, then synchronously queries App Store Subscription Status immediately
before rotation. A deterministic newest/restrictive selection must be status 1 or 4 and
remain inside its paid or grace interval. Auto-renew off does not end an already-paid term.

Only `(environment, SHA-256(domain || environment || appTransactionId))` is persisted.
Raw JWS, raw appTransactionId, device identifiers, nonces, proofs, signatures and network
addresses are not stored or logged.

## Atomicity

D1 generation fencing and the current active-key ID are checked inside the same INSERT
statement whose trigger revokes the old key, inserts the new key, binds the immutable Apple
identity, and advances the generation. Any failure rolls the statement back. Concurrent
different requests for one generation therefore have exactly one winner, and a loser can
never revoke the winner's key.
