# Production billing preparation (1102d, offline only)

This is a preparation checklist, not an approved deployment configuration. The
production foundation remains closed. No Apple request, transaction, DNS change,
Access allow policy, credential creation or resource provisioning is performed by
the rehearsal below.

## Rehearsed boundary

Run from `NekoWidget/SharingService`:

```sh
npm exec -- vitest run test/billing-production-preparation.test.ts
```

The real Worker verifier client sends HTTPS requests to an injected mock edge.
Two synthetic profiles use different origins, Access credential pairs and HMAC
keys. The mock checks the request HMAC independently with Node crypto and signs
the response using the existing wire format. Both store environments deliberately
use the same transaction/account IDs so that IDs alone cannot select a store.

The rehearsal checks valid responses in each environment, missing configuration,
non-HTTPS/ambiguous origins, production private-binding rejection, swapped
origins, cross-environment keys, wrong response environment, wrong request nonce,
Access denial and login redirects. It never calls the global fetch function.

The mock's Access decision is a fixture, not Cloudflare authentication. The Apple
payload/transaction is fabricated. This does not prove real TLS, Cloudflare AUD
validation, Apple certificate validation, transaction eligibility, or deployed
D1/R2 isolation. Existing Apple verifier tests remain separate. No deployment
may treat this rehearsal as permission to grant Plus.

## Required second-stage work

1. Production: dedicated billing environment `Production`, production D1,
   production verifier origin and nonce ledger, separately held HMAC/Access
   credentials. Reject missing configuration; never fall back to staging or the
   owner's Sandbox. Configure and verify the real bundle/app/subscription-group
   identifiers before enabling verification. No annual product is inferred.
2. Reviewer Sandbox: separate ledger, account namespace, verifier/nonce state and
   storage resources, with `Sandbox` transaction validation. A Sandbox receipt
   must not create a production grant. App-facing routing must select this
   isolated realm only after trusted verification; an unverified JWS payload or
   request flag is not a routing authority. The new realm and its admission flow
   have not been implemented or provisioned by this PR.
3. Inspect the current Container's service-binding entrypoint and add a reviewed
   HTTPS/Access ingress before deployment. The existing private-binding client
   path is allowed only for local/staging Sandbox, and is not the production
   route. Keep the foundation's Block Everyone policy until this is ready.
4. Apply #664's recheck generation behavior to each isolated ledger and test
   notifications, subscription status, retries and expiry against the selected
   environment. Do not manually repair a production row or share a recheck queue
   across realms.
5. Ensure Access protects all public ingress, validate the intended audience at
   the origin where applicable, and keep workers.dev/preview closed. Never use
   an Access bypass rule or forward credentials across a redirect.

## Host attachment, not four hand-written CNAME records

For HTTPS fetch between Workers in the same zone, use **Custom Domains**. A DNS
record by itself does not attach a Worker, and ordinary Worker routes have
same-zone fetch limitations. Do not point CNAMEs to disabled workers.dev hosts.

In Cloudflare: Workers & Pages → choose the Worker → Settings → Domains & Routes
→ Add → Custom Domain. The owner enters the domain below; Cloudflare generates
the DNS record and certificate. The exact generated DNS type/target is not a
manually chosen IP or a value inferred from the Worker name.

| Owner-selected Worker | Custom Domain input | Required stage |
|---|---|---|
| neko-window-sharing-production | api.nekonomado.com | 2: billing API; 3: sharing |
| neko-billing-verifier-production | billing-verifier.nekonomado.com | 2: verifier behind Access |
| neko-preservation-production | preservation.nekonomado.com | 4: preservation |
| neko-official-cats-production | official.nekonomado.com | 7: official window |

`operator.nekonomado.com` is deferred to stage 6. Do not attach the existing
staging operator tunnel to it. Do not overwrite a conflicting DNS record: inspect
and report the conflict first. This document itself does not create any domain.

Sources: [Cloudflare Custom Domains](https://developers.cloudflare.com/workers/configuration/routing/custom-domains/),
[Cloudflare Worker routing](https://developers.cloudflare.com/workers/configuration/routing/).
