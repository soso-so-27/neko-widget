import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { base64urlEncode, sha256Base64url } from "../src/encoding";
import type { Env } from "../src/env";
import { requestBillingReconciliation } from "../src/billing-reconciliation-queue";
import { runBillingSubscriptionReconciliation } from "../src/billing-authority";
import type { VerifiedBillingTransaction } from "../src/billing-verifier-client";
import { route } from "../src/index";
import { signedRequestTranscript } from "../src/protocol";
import {
  billingSignedRequestTranscript,
  windowSponsorshipConsentTranscript,
} from "../src/billing-protocol";

const testEnv = env as unknown as Env;
function random(bytes: number) {
  const value = new Uint8Array(bytes);
  crypto.getRandomValues(value);
  return base64urlEncode(value);
}

interface SigningKeyPair {
  privateKey: CryptoKey;
  publicKey: CryptoKey;
}
interface SignedMember {
  id: string;
  keys: SigningKeyPair;
}

function arrayBuffer(value: Uint8Array): ArrayBuffer {
  const copy = new Uint8Array(value.length);
  copy.set(value);
  return copy.buffer;
}
async function signingKeys(): Promise<SigningKeyPair> {
  return crypto.subtle.generateKey({ name: "Ed25519" }, true, [
    "sign",
    "verify",
  ]) as Promise<SigningKeyPair>;
}
async function publicKey(keys: SigningKeyPair): Promise<string> {
  return base64urlEncode(
    new Uint8Array(await crypto.subtle.exportKey("raw", keys.publicKey)),
  );
}
async function signature(keys: SigningKeyPair, transcript: Uint8Array) {
  return base64urlEncode(
    new Uint8Array(
      await crypto.subtle.sign(
        { name: "Ed25519" },
        keys.privateKey,
        arrayBuffer(transcript),
      ),
    ),
  );
}
async function signedGrantRequest(member: SignedMember): Promise<Request> {
  const pathname = "/v1/window-sponsorship",
    timestamp = Math.floor(Date.now() / 1000),
    nonce = random(16);
  const signature = base64urlEncode(
    new Uint8Array(
      await crypto.subtle.sign(
        { name: "Ed25519" },
        member.keys.privateKey,
        arrayBuffer(
          signedRequestTranscript({
            memberId: member.id,
            timestamp,
            nonce,
            method: "GET",
            pathname,
            bodySHA256: await sha256Base64url(new Uint8Array()),
          }),
        ),
      ),
    ),
  );
  return new Request(`https://sharing.invalid${pathname}`, {
    method: "GET",
    headers: {
      "CF-Connecting-IP": "192.0.2.81",
      "Neko-Protocol-Version": "1",
      "Neko-Member-ID": member.id,
      "Neko-Timestamp": String(timestamp),
      "Neko-Nonce": nonce,
      "Neko-Signature": signature,
    },
  });
}

async function signedMemberMutationRequest(input: {
  member: SignedMember;
  method: "DELETE";
  pathname: string;
  body: Record<string, unknown>;
}) {
  const body = JSON.stringify(input.body);
  const timestamp = Math.floor(Date.now() / 1000);
  const nonce = random(16);
  const memberSignature = await signature(
    input.member.keys,
    signedRequestTranscript({
      memberId: input.member.id,
      timestamp,
      nonce,
      method: input.method,
      pathname: input.pathname,
      bodySHA256: await sha256Base64url(new TextEncoder().encode(body)),
    }),
  );
  return new Request(`https://sharing.invalid${input.pathname}`, {
    method: input.method,
    headers: {
      "Content-Type": "application/json",
      "CF-Connecting-IP": "192.0.2.83",
      "Neko-Protocol-Version": "1",
      "Neko-Member-ID": input.member.id,
      "Neko-Timestamp": String(timestamp),
      "Neko-Nonce": nonce,
      "Neko-Signature": memberSignature,
    },
    body,
  });
}

async function account() {
  const id = crypto.randomUUID().toLowerCase();
  const key = random(16);
  const keys = await signingKeys();
  await testEnv.DB.prepare("INSERT INTO billing_accounts(id) VALUES(?)")
    .bind(id)
    .run();
  await testEnv.DB.prepare(
    "INSERT INTO billing_account_keys(id,billing_account_id,signing_public_key,state) VALUES(?,?,?,'active')",
  )
    .bind(key, id, await publicKey(keys))
    .run();
  return { id, key, keys };
}

type BillingAccount = Awaited<ReturnType<typeof account>>;

async function signedBillingRequest(input: {
  account: BillingAccount;
  method: "PUT" | "DELETE";
  lineage: string;
  body: Record<string, unknown>;
  nonce?: string;
}) {
  const pathname = `/v1/billing/window-sponsorships/${input.lineage}`;
  const body = JSON.stringify(input.body);
  const timestamp = Math.floor(Date.now() / 1000);
  const nonce = input.nonce ?? random(16);
  const payerSignature = await signature(
    input.account.keys,
    billingSignedRequestTranscript({
      billingAccountId: input.account.id,
      billingKeyId: input.account.key,
      timestamp,
      nonce,
      method: input.method,
      pathname,
      bodySHA256: await sha256Base64url(new TextEncoder().encode(body)),
    }),
  );
  return new Request(`https://sharing.invalid${pathname}`, {
    method: input.method,
    headers: {
      "Content-Type": "application/json",
      "CF-Connecting-IP": "192.0.2.82",
      "Neko-Billing-Protocol-Version": "1",
      "Neko-Billing-Account-ID": input.account.id,
      "Neko-Billing-Key-ID": input.account.key,
      "Neko-Billing-Timestamp": String(timestamp),
      "Neko-Billing-Nonce": nonce,
      "Neko-Billing-Signature": payerSignature,
    },
    body,
  });
}

async function sponsorBody(input: {
  account: BillingAccount;
  signedWindow: Awaited<ReturnType<typeof signedSpace>>;
  clientRequestId?: string;
  expectedGeneration?: number;
  expectedCurrentBillingAccountId?: string | null;
}) {
  const clientRequestId =
    input.clientRequestId ?? crypto.randomUUID().toLowerCase();
  const expectedGeneration = input.expectedGeneration ?? 0;
  const expectedCurrentBillingAccountId =
    input.expectedCurrentBillingAccountId ?? null;
  const consentIssuedAt = Math.floor(Date.now() / 1000);
  const ownerConsentNonce = random(16);
  const consent = {
    operation: "sponsor" as const,
    clientRequestId,
    billingAccountId: input.account.id,
    windowLineageId: input.signedWindow.window.lineage,
    expectedGeneration,
    expectedCurrentBillingAccountId:
      expectedCurrentBillingAccountId ?? undefined,
    consentSpaceId: input.signedWindow.window.space,
    ownerParticipantId: input.signedWindow.window.owner,
    ownerDeviceId: input.signedWindow.window.device,
    consentIssuedAt,
    consentMembershipRevision: input.signedWindow.window.revision,
    ownerConsentNonce,
  };
  return {
    protocolVersion: 1,
    clientRequestId,
    expectedGeneration,
    expectedCurrentBillingAccountId,
    consentSpaceId: consent.consentSpaceId,
    ownerParticipantId: consent.ownerParticipantId,
    ownerDeviceId: consent.ownerDeviceId,
    consentMembershipRevision: consent.consentMembershipRevision,
    consentIssuedAt,
    ownerConsentNonce,
    ownerConsentSignature: await signature(
      input.signedWindow.owner.keys,
      windowSponsorshipConsentTranscript(consent),
    ),
  };
}

async function grantPlus(accountId: string) {
  const original = String(
      BigInt(Date.now()) * 1000n +
        BigInt(Math.floor(Math.random() * 900 + 100)),
    ),
    now = Date.now();
  await testEnv.DB.prepare(
    "INSERT INTO billing_transaction_lineages(original_transaction_id,billing_account_id,environment,subscription_group_id) VALUES(?,?,'Sandbox','20999999')",
  )
    .bind(original, accountId)
    .run();
  const gate = await testEnv.DB.prepare(
    "SELECT generation,subscription_reconciliation_enabled FROM billing_runtime_gate WHERE singleton=1",
  ).first<{
    generation: number;
    subscription_reconciliation_enabled: number;
  }>();
  if (gate!.subscription_reconciliation_enabled !== 1)
    await testEnv.DB.prepare(
      "UPDATE billing_runtime_gate SET generation=generation+1,subscription_reconciliation_enabled=1,updated_at=unixepoch() WHERE singleton=1 AND generation=?",
    )
      .bind(gate!.generation)
      .run();
  await requestBillingReconciliation(testEnv, original, Math.floor(now / 1000));
  const transaction: VerifiedBillingTransaction = {
    transactionId: original,
    originalTransactionId: original,
    billingAccountId: accountId,
    productId: "jp.nekowidget.plus.monthly",
    subscriptionGroupId: "20999999",
    bundleId: "jp.nekowidget.app",
    environment: "Sandbox",
    ownershipType: "PURCHASED",
    transactionReason: "PURCHASE",
    purchaseDateMs: now - 1000,
    originalPurchaseDateMs: now - 1000,
    expiresDateMs: now + 86_400_000,
    signedDateMs: now,
    revocationDateMs: null,
    revocationReason: null,
    isUpgraded: false,
  };
  await runBillingSubscriptionReconciliation(
    testEnv,
    async () => ({
      requestedTransactionId: original,
      environment: "Sandbox",
      bundleId: transaction.bundleId,
      fetchedAtMs: now,
      items: [
        {
          status: 1,
          originalTransactionId: original,
          transaction,
          renewal: {
            originalTransactionId: original,
            billingAccountId: accountId,
            productId: transaction.productId,
            autoRenewProductId: transaction.productId,
            autoRenewStatus: 1,
            isInBillingRetryPeriod: false,
            gracePeriodExpiresDateMs: null,
            renewalDateMs: transaction.expiresDateMs,
            signedDateMs: now,
            environment: "Sandbox",
          },
        },
      ],
    }),
    Math.floor(now / 1000),
  );
  return testEnv.DB.prepare(
    "SELECT decision_id,request_generation,evaluated_at_ms FROM billing_effective_entitlement_current WHERE original_transaction_id=?",
  )
    .bind(original)
    .first<{
      decision_id: string;
      request_generation: number;
      evaluated_at_ms: number;
    }>();
}

async function windowFixture() {
  const lineage = random(16);
  const space = random(16);
  const owner = random(16);
  const device = random(16);
  const now = Math.floor(Date.now() / 1000);
  await testEnv.DB.prepare(
    "INSERT INTO moment_space_lineages(id,created_at) VALUES(?,?)",
  )
    .bind(lineage, now)
    .run();
  await testEnv.DB.prepare(
    "INSERT INTO moment_spaces(space_id,lineage_id,state,current_key_epoch,membership_revision,created_at,updated_at) VALUES(?,?,'active',1,1,?,?)",
  )
    .bind(space, lineage, now, now)
    .run();
  await testEnv.DB.prepare(
    "INSERT INTO moment_participants(id,space_id,role,state,created_at,activated_at) VALUES(?,?,'owner','active',?,?)",
  )
    .bind(owner, space, now, now)
    .run();
  await testEnv.DB.prepare(
    "INSERT INTO moment_devices(id,participant_id,agreement_public_key,signing_public_key,state,created_at,activated_at) VALUES(?,?,?,?, 'active',?,?)",
  )
    .bind(device, owner, random(32), random(32), now, now)
    .run();
  const revision = (await testEnv.DB.prepare(
    "SELECT membership_revision FROM moment_spaces WHERE space_id=?",
  )
    .bind(space)
    .first<{ membership_revision: number }>())!.membership_revision;
  return { lineage, space, owner, device, revision };
}

async function signedSpace(inviteeState: "active" | "pending" = "active") {
  const now = Math.floor(Date.now() / 1000),
    space = random(16),
    owner = random(16),
    invitee = random(16);
  const ownerKeys = await signingKeys(),
    inviteeKeys = await signingKeys();
  await testEnv.DB.prepare(
    `INSERT INTO spaces(
    id,creation_request_id,protocol_version,daily_boundary_minute_utc,state,
    created_at,last_activity_at,metadata_expires_at
   ) VALUES(?,?,1,0,'active',?,?,?)`,
  )
    .bind(space, crypto.randomUUID().toLowerCase(), now, now, now + 2_592_000)
    .run();
  await testEnv.DB.prepare(
    `INSERT INTO members(
    id,space_id,role,participant_id,agreement_public_key,signing_public_key,
    state,created_at,activated_at
   ) VALUES(?,?, 'owner',?,?,?,'active',?,?)`,
  )
    .bind(
      owner,
      space,
      random(16),
      random(32),
      await publicKey(ownerKeys),
      now,
      now,
    )
    .run();
  await testEnv.DB.prepare(
    `INSERT INTO members(
    id,space_id,role,participant_id,agreement_public_key,signing_public_key,
    state,created_at,activated_at
   ) VALUES(?,?,'invitee',?,?,?,?,?,?)`,
  )
    .bind(
      invitee,
      space,
      random(16),
      random(32),
      await publicKey(inviteeKeys),
      inviteeState,
      now,
      inviteeState === "active" ? now : null,
    )
    .run();
  const revision = (await testEnv.DB.prepare(
    "SELECT membership_revision FROM moment_spaces WHERE space_id=?",
  )
    .bind(space)
    .first<{ membership_revision: number }>())!.membership_revision;
  return {
    window: { lineage: space, space, owner, device: owner, revision },
    owner: { id: owner, keys: ownerKeys },
    invitee: { id: invitee, keys: inviteeKeys },
  };
}

async function operation(input: {
  account: { id: string; key: string };
  window: Awaited<ReturnType<typeof windowFixture>>;
  operation: "sponsor" | "unsponsor";
  generation: number;
  expectedCurrent?: string | null;
  entitlement?: Awaited<ReturnType<typeof grantPlus>>;
  consentWindow?: Awaited<ReturnType<typeof windowFixture>>;
  consentIssuedAt?: number;
  consentMembershipRevision?: number;
}) {
  const sponsor = input.operation === "sponsor";
  const consent = input.consentWindow ?? input.window;
  return testEnv.DB.prepare(
    `INSERT INTO billing_window_sponsorship_requests(
      client_request_id,request_hash,operation,billing_account_id,submitted_by_billing_key_id,
      window_lineage_id,expected_generation,expected_current_billing_account_id,consent_space_id,owner_participant_id,
      owner_device_id,consent_membership_revision,consent_issued_at,owner_consent_nonce_hash,owner_consent_hash,
      entitlement_decision_id,entitlement_request_generation,entitlement_evaluated_at_ms,resulting_generation
    ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`,
  )
    .bind(
      crypto.randomUUID().toLowerCase(),
      random(32),
      input.operation,
      input.account.id,
      input.account.key,
      input.window.lineage,
      input.generation,
      input.expectedCurrent ?? null,
      sponsor ? consent.space : null,
      sponsor ? consent.owner : null,
      sponsor ? consent.device : null,
      sponsor ? (input.consentMembershipRevision ?? consent.revision) : null,
      sponsor ? (input.consentIssuedAt ?? Math.floor(Date.now() / 1000)) : null,
      sponsor ? random(32) : null,
      sponsor ? random(32) : null,
      sponsor ? input.entitlement?.decision_id : null,
      sponsor ? input.entitlement?.request_generation : null,
      sponsor ? input.entitlement?.evaluated_at_ms : null,
      input.generation + 1,
    )
    .run();
}

async function openD1SponsorshipGates() {
  await testEnv.DB.prepare(
    `UPDATE billing_runtime_gate
      SET generation=generation+1,window_sponsorship_enabled=1,
          effective_entitlement_enabled=1,updated_at=unixepoch()
    WHERE singleton=1`,
  ).run();
}

async function closeD1SponsorshipGate() {
  await testEnv.DB.prepare(
    `UPDATE billing_runtime_gate
      SET generation=generation+1,window_sponsorship_enabled=0,
          updated_at=unixepoch()
    WHERE singleton=1`,
  ).run();
}

async function enableSponsorshipGates() {
  await openD1SponsorshipGates();
  return {
    ...testEnv,
    BILLING_WINDOW_SPONSORSHIP_RUNTIME_ENABLED: "YES",
    BILLING_EFFECTIVE_ENTITLEMENT_RUNTIME_ENABLED: "YES",
  } as Env;
}

describe("Plus window sponsorship foundation", () => {
  it("sponsors and unsponsors through the HTTP route with payer and owner proofs", async () => {
    const defaultGate = await testEnv.DB.prepare(
      "SELECT window_sponsorship_enabled FROM billing_runtime_gate WHERE singleton=1",
    ).first<{ window_sponsorship_enabled: number }>();
    expect(defaultGate?.window_sponsorship_enabled).toBe(0);
    const payer = await account();
    const signedWindow = await signedSpace();
    await grantPlus(payer.id);
    const enabledEnv = await enableSponsorshipGates();
    const putBody = await sponsorBody({ account: payer, signedWindow });

    const first = await route(
      await signedBillingRequest({
        account: payer,
        method: "PUT",
        lineage: signedWindow.window.lineage,
        body: putBody,
      }),
      enabledEnv,
    );
    expect(first.status).toBe(200);
    const firstBody = await first.json<Record<string, unknown>>();
    expect(firstBody).toMatchObject({
      clientRequestId: putBody.clientRequestId,
      billingAccountId: payer.id,
      windowLineageId: signedWindow.window.lineage,
      state: "active",
      generation: 1,
    });

    // A response-loss retry uses a fresh payer nonce while preserving the exact body.
    const replay = await route(
      await signedBillingRequest({
        account: payer,
        method: "PUT",
        lineage: signedWindow.window.lineage,
        body: putBody,
      }),
      enabledEnv,
    );
    expect(replay.status).toBe(200);
    expect(await replay.json()).toEqual(firstBody);

    const deleteBody = {
      protocolVersion: 1,
      clientRequestId: crypto.randomUUID().toLowerCase(),
      expectedGeneration: 1,
      expectedCurrentBillingAccountId: payer.id,
    };
    const removed = await route(
      await signedBillingRequest({
        account: payer,
        method: "DELETE",
        lineage: signedWindow.window.lineage,
        body: deleteBody,
      }),
      enabledEnv,
    );
    expect(removed.status).toBe(200);
    expect(await removed.json()).toMatchObject({
      clientRequestId: deleteBody.clientRequestId,
      billingAccountId: payer.id,
      windowLineageId: signedWindow.window.lineage,
      state: "unsponsored",
      generation: 2,
    });
  });

  it("rejects reuse of one HTTP request ID for another lineage, operation, or body", async () => {
    const payer = await account();
    const firstWindow = await signedSpace();
    const secondWindow = await signedSpace();
    await grantPlus(payer.id);
    const enabledEnv = await enableSponsorshipGates();
    const clientRequestId = crypto.randomUUID().toLowerCase();
    const original = await sponsorBody({
      account: payer,
      signedWindow: firstWindow,
      clientRequestId,
    });
    expect(
      (
        await route(
          await signedBillingRequest({
            account: payer,
            method: "PUT",
            lineage: firstWindow.window.lineage,
            body: original,
          }),
          enabledEnv,
        )
      ).status,
    ).toBe(200);

    const anotherLineage = await sponsorBody({
      account: payer,
      signedWindow: secondWindow,
      clientRequestId,
    });
    await expect(
      route(
        await signedBillingRequest({
          account: payer,
          method: "PUT",
          lineage: secondWindow.window.lineage,
          body: anotherLineage,
        }),
        enabledEnv,
      ),
    ).rejects.toMatchObject({
      status: 409,
      code: "sponsorship_request_conflict",
    });

    const changedBody = await sponsorBody({
      account: payer,
      signedWindow: firstWindow,
      clientRequestId,
      expectedGeneration: 1,
      expectedCurrentBillingAccountId: payer.id,
    });
    await expect(
      route(
        await signedBillingRequest({
          account: payer,
          method: "PUT",
          lineage: firstWindow.window.lineage,
          body: changedBody,
        }),
        enabledEnv,
      ),
    ).rejects.toMatchObject({
      status: 409,
      code: "sponsorship_request_conflict",
    });

    const changedOperation = {
      protocolVersion: 1,
      clientRequestId,
      expectedGeneration: 1,
      expectedCurrentBillingAccountId: payer.id,
    };
    await expect(
      route(
        await signedBillingRequest({
          account: payer,
          method: "DELETE",
          lineage: firstWindow.window.lineage,
          body: changedOperation,
        }),
        enabledEnv,
      ),
    ).rejects.toMatchObject({
      status: 409,
      code: "sponsorship_request_conflict",
    });
  });

  it("lets the active owner detach without the payer key and later consent to responsoring", async () => {
    const payer = await account();
    const signedWindow = await signedSpace();
    await grantPlus(payer.id);
    const enabledEnv = await enableSponsorshipGates();
    const initialBody = await sponsorBody({ account: payer, signedWindow });
    expect(
      (
        await route(
          await signedBillingRequest({
            account: payer,
            method: "PUT",
            lineage: signedWindow.window.lineage,
            body: initialBody,
          }),
          enabledEnv,
        )
      ).status,
    ).toBe(200);

    const beforeDetach = await route(
      await signedGrantRequest(signedWindow.owner),
      enabledEnv,
    );
    expect(await beforeDetach.json()).toMatchObject({
      windowLineageSponsored: true,
      grantsPlus: true,
      generation: 1,
    });

    const detachBody = {
      protocolVersion: 1,
      clientRequestId: crypto.randomUUID().toLowerCase(),
      expectedGeneration: 1,
    };
    const detachEnv = {
      ...enabledEnv,
      BILLING_EFFECTIVE_ENTITLEMENT_RUNTIME_ENABLED: "NO",
    } as Env;
    const detached = await route(
      await signedMemberMutationRequest({
        member: signedWindow.owner,
        method: "DELETE",
        pathname: "/v1/window-sponsorship",
        body: detachBody,
      }),
      detachEnv,
    );
    expect(detached.status).toBe(200);
    const detachedBody = await detached.json<Record<string, unknown>>();
    expect(detachedBody).toMatchObject({
      clientRequestId: detachBody.clientRequestId,
      windowLineageSponsored: false,
      generation: 2,
    });
    expect(detachedBody.billingAccountId).toBeUndefined();

    const replay = await route(
      await signedMemberMutationRequest({
        member: signedWindow.owner,
        method: "DELETE",
        pathname: "/v1/window-sponsorship",
        body: detachBody,
      }),
      detachEnv,
    );
    expect(await replay.json()).toEqual(detachedBody);
    await expect(
      route(
        await signedMemberMutationRequest({
          member: signedWindow.owner,
          method: "DELETE",
          pathname: "/v1/window-sponsorship",
          body: { ...detachBody, expectedGeneration: 2 },
        }),
        detachEnv,
      ),
    ).rejects.toMatchObject({
      status: 409,
      code: "sponsorship_request_conflict",
    });
    await expect(
      testEnv.DB.prepare(
        `UPDATE billing_window_sponsorship_owner_detach_requests
            SET request_hash=request_hash
          WHERE client_request_id=?`,
      )
        .bind(detachBody.clientRequestId)
        .run(),
    ).rejects.toThrow(/owner detach audit immutable/u);
    await expect(
      testEnv.DB.prepare(
        `DELETE FROM billing_window_sponsorship_owner_detach_requests
          WHERE client_request_id=?`,
      )
        .bind(detachBody.clientRequestId)
        .run(),
    ).rejects.toThrow(/owner detach audit cannot be deleted/u);

    const afterDetach = await route(
      await signedGrantRequest(signedWindow.invitee),
      enabledEnv,
    );
    expect(await afterDetach.json()).toMatchObject({
      windowLineageSponsored: false,
      grantsPlus: false,
      generation: 2,
      accessUntilMs: null,
    });

    const responsorBody = await sponsorBody({
      account: payer,
      signedWindow,
      expectedGeneration: 2,
      expectedCurrentBillingAccountId: null,
    });
    const responsored = await route(
      await signedBillingRequest({
        account: payer,
        method: "PUT",
        lineage: signedWindow.window.lineage,
        body: responsorBody,
      }),
      enabledEnv,
    );
    expect(await responsored.json()).toMatchObject({
      state: "active",
      generation: 3,
    });
  });

  it("rejects owner detach by an invitee or with a stale generation", async () => {
    const payer = await account();
    const signedWindow = await signedSpace();
    const entitlement = await grantPlus(payer.id);
    await openD1SponsorshipGates();
    await operation({
      account: payer,
      window: signedWindow.window,
      operation: "sponsor",
      generation: 0,
      entitlement,
    });
    const enabledEnv = await enableSponsorshipGates();

    await expect(
      route(
        await signedMemberMutationRequest({
          member: signedWindow.invitee,
          method: "DELETE",
          pathname: "/v1/window-sponsorship",
          body: {
            protocolVersion: 1,
            clientRequestId: crypto.randomUUID().toLowerCase(),
            expectedGeneration: 1,
          },
        }),
        enabledEnv,
      ),
    ).rejects.toMatchObject({ status: 403, code: "owner_required" });

    await expect(
      route(
        await signedMemberMutationRequest({
          member: signedWindow.owner,
          method: "DELETE",
          pathname: "/v1/window-sponsorship",
          body: {
            protocolVersion: 1,
            clientRequestId: crypto.randomUUID().toLowerCase(),
            expectedGeneration: 2,
          },
        }),
        enabledEnv,
      ),
    ).rejects.toMatchObject({ status: 409, code: "sponsorship_conflict" });
  });

  it("fails owner detach closed at both sponsorship gates", async () => {
    const payer = await account();
    const signedWindow = await signedSpace();
    const entitlement = await grantPlus(payer.id);
    await openD1SponsorshipGates();
    await operation({
      account: payer,
      window: signedWindow.window,
      operation: "sponsor",
      generation: 0,
      entitlement,
    });
    const body = {
      protocolVersion: 1,
      clientRequestId: crypto.randomUUID().toLowerCase(),
      expectedGeneration: 1,
    };
    const upperOff = {
      ...testEnv,
      BILLING_WINDOW_SPONSORSHIP_RUNTIME_ENABLED: "NO",
      BILLING_EFFECTIVE_ENTITLEMENT_RUNTIME_ENABLED: "YES",
    } as Env;
    await expect(
      route(
        await signedMemberMutationRequest({
          member: signedWindow.owner,
          method: "DELETE",
          pathname: "/v1/window-sponsorship",
          body,
        }),
        upperOff,
      ),
    ).rejects.toMatchObject({ status: 503, code: "billing_runtime_disabled" });

    await closeD1SponsorshipGate();
    const upperOn = {
      ...testEnv,
      BILLING_WINDOW_SPONSORSHIP_RUNTIME_ENABLED: "YES",
      BILLING_EFFECTIVE_ENTITLEMENT_RUNTIME_ENABLED: "NO",
    } as Env;
    await expect(
      route(
        await signedMemberMutationRequest({
          member: signedWindow.owner,
          method: "DELETE",
          pathname: "/v1/window-sponsorship",
          body,
        }),
        upperOn,
      ),
    ).rejects.toMatchObject({ status: 503, code: "billing_runtime_disabled" });
  });

  it("serializes an owner detach racing the payer unsponsor", async () => {
    const payer = await account();
    const signedWindow = await signedSpace();
    const entitlement = await grantPlus(payer.id);
    await openD1SponsorshipGates();
    await operation({
      account: payer,
      window: signedWindow.window,
      operation: "sponsor",
      generation: 0,
      entitlement,
    });
    const enabledEnv = await enableSponsorshipGates();
    const ownerBody = {
      protocolVersion: 1,
      clientRequestId: crypto.randomUUID().toLowerCase(),
      expectedGeneration: 1,
    };
    const payerBody = {
      protocolVersion: 1,
      clientRequestId: crypto.randomUUID().toLowerCase(),
      expectedGeneration: 1,
      expectedCurrentBillingAccountId: payer.id,
    };
    const results = await Promise.allSettled([
      route(
        await signedMemberMutationRequest({
          member: signedWindow.owner,
          method: "DELETE",
          pathname: "/v1/window-sponsorship",
          body: ownerBody,
        }),
        enabledEnv,
      ),
      route(
        await signedBillingRequest({
          account: payer,
          method: "DELETE",
          lineage: signedWindow.window.lineage,
          body: payerBody,
        }),
        enabledEnv,
      ),
    ]);
    expect(
      results.filter((result) => result.status === "fulfilled"),
    ).toHaveLength(1);
    const rejected = results.find((result) => result.status === "rejected");
    expect(rejected).toMatchObject({
      status: "rejected",
      reason: { status: 409, code: "sponsorship_conflict" },
    });
    const current = await testEnv.DB.prepare(
      `SELECT state,generation,billing_account_id
         FROM billing_window_sponsorships
        WHERE window_lineage_id=?`,
    )
      .bind(signedWindow.window.lineage)
      .first<{
        state: string;
        generation: number;
        billing_account_id: string | null;
      }>();
    expect(current).toEqual({
      state: "unsponsored",
      generation: 2,
      billing_account_id: null,
    });
  });

  it("rechecks owner membership revision at the detach commit", async () => {
    const payer = await account();
    const signedWindow = await signedSpace();
    const entitlement = await grantPlus(payer.id);
    await openD1SponsorshipGates();
    await operation({
      account: payer,
      window: signedWindow.window,
      operation: "sponsor",
      generation: 0,
      entitlement,
    });
    await testEnv.DB.prepare(
      `UPDATE moment_spaces
          SET membership_revision=membership_revision+1
        WHERE space_id=?`,
    )
      .bind(signedWindow.window.space)
      .run();
    await expect(
      testEnv.DB.prepare(
        `INSERT INTO billing_window_sponsorship_owner_detach_requests(
           client_request_id,request_hash,window_lineage_id,space_id,
           owner_participant_id,owner_device_id,membership_revision,
           expected_generation,expected_billing_account_id,resulting_generation
         ) VALUES(?,?,?,?,?,?,?,?,?,?)`,
      )
        .bind(
          crypto.randomUUID().toLowerCase(),
          random(32),
          signedWindow.window.lineage,
          signedWindow.window.space,
          signedWindow.window.owner,
          signedWindow.window.device,
          signedWindow.window.revision,
          1,
          payer.id,
          2,
        )
        .run(),
    ).rejects.toThrow(/current unblocked owner required/u);
  });

  it("fails closed at the upper sponsorship runtime gate", async () => {
    await openD1SponsorshipGates();
    const disabledEnv = {
      ...testEnv,
      BILLING_WINDOW_SPONSORSHIP_RUNTIME_ENABLED: "NO",
      BILLING_EFFECTIVE_ENTITLEMENT_RUNTIME_ENABLED: "YES",
    } as Env;
    await expect(
      route(
        new Request(
          `https://sharing.invalid/v1/billing/window-sponsorships/${random(16)}`,
          { method: "PUT" },
        ),
        disabledEnv,
      ),
    ).rejects.toMatchObject({ status: 503, code: "billing_runtime_disabled" });
  });

  it("is disabled at the independent D1 lower gate", async () => {
    await closeD1SponsorshipGate();
    const row = await testEnv.DB.prepare(
      "SELECT window_sponsorship_enabled FROM billing_runtime_gate WHERE singleton=1",
    ).first<{ window_sponsorship_enabled: number }>();
    expect(row?.window_sponsorship_enabled).toBe(0);
    const sponsor = await account(),
      window = await windowFixture(),
      entitlement = await grantPlus(sponsor.id);
    await expect(
      operation({
        account: sponsor,
        window,
        operation: "sponsor",
        generation: 0,
        entitlement,
      }),
    ).rejects.toThrow(/runtime gate closed/u);
  });

  it("atomically caps one billing account at three active private windows", async () => {
    await openD1SponsorshipGates();
    const sponsor = await account();
    const windows = await Promise.all([
      windowFixture(),
      windowFixture(),
      windowFixture(),
      windowFixture(),
    ]);
    const entitlement = await grantPlus(sponsor.id);
    const attempts = await Promise.allSettled(
      windows.map((window) =>
        operation({
          account: sponsor,
          window,
          operation: "sponsor",
          generation: 0,
          entitlement,
        }),
      ),
    );
    expect(attempts.filter((item) => item.status === "fulfilled")).toHaveLength(
      3,
    );
    expect(attempts.filter((item) => item.status === "rejected")).toHaveLength(
      1,
    );
    const count = await testEnv.DB.prepare(
      "SELECT COUNT(*) AS count FROM billing_window_sponsorships WHERE billing_account_id=? AND state='active'",
    )
      .bind(sponsor.id)
      .first<{ count: number }>();
    expect(count?.count).toBe(3);
  });

  it("fails closed on cross-account claim races and permits reassignment only after unsponsor", async () => {
    await openD1SponsorshipGates();
    const first = await account();
    const second = await account();
    const window = await windowFixture();
    const firstEnt = await grantPlus(first.id),
      secondEnt = await grantPlus(second.id);
    await operation({
      account: first,
      window,
      operation: "sponsor",
      generation: 0,
      entitlement: firstEnt,
    });
    await expect(
      operation({
        account: second,
        window,
        operation: "sponsor",
        generation: 1,
        expectedCurrent: first.id,
        entitlement: secondEnt,
      }),
    ).resolves.toBeDefined();
    await operation({
      account: second,
      window,
      operation: "unsponsor",
      generation: 2,
      expectedCurrent: second.id,
    });
    await operation({
      account: first,
      window,
      operation: "sponsor",
      generation: 3,
      entitlement: firstEnt,
    });
    const current = await testEnv.DB.prepare(
      "SELECT billing_account_id,state,generation FROM billing_window_sponsorships WHERE window_lineage_id=?",
    )
      .bind(window.lineage)
      .first<{
        billing_account_id: string;
        state: string;
        generation: number;
      }>();
    expect(current).toEqual({
      billing_account_id: first.id,
      state: "active",
      generation: 4,
    });
    expect(
      await testEnv.DB.prepare("SELECT id FROM moment_participants WHERE id=?")
        .bind(window.owner)
        .first(),
    ).not.toBeNull();
    const audit = await testEnv.DB.prepare(
      "SELECT operation FROM billing_window_sponsorship_requests WHERE window_lineage_id=? ORDER BY resulting_generation",
    )
      .bind(window.lineage)
      .all<{ operation: string }>();
    expect(audit.results.map((row) => row.operation)).toEqual([
      "sponsor",
      "sponsor",
      "unsponsor",
      "sponsor",
    ]);
  });

  it("lets the current payer unsponsor after entitlement loss without deleting window data", async () => {
    await openD1SponsorshipGates();
    const sponsor = await account(),
      window = await windowFixture(),
      entitlement = await grantPlus(sponsor.id);
    await operation({
      account: sponsor,
      window,
      operation: "sponsor",
      generation: 0,
      entitlement,
    });
    const before = await testEnv.DB.prepare(
      `SELECT
        (SELECT COUNT(*) FROM moment_spaces WHERE space_id=?) AS spaces,
        (SELECT COUNT(*) FROM moment_participants WHERE space_id=?) AS participants,
        (SELECT COUNT(*) FROM moment_devices WHERE participant_id=?) AS devices,
        (SELECT COUNT(*) FROM moment_object_deletions) AS deletions`,
    )
      .bind(window.space, window.space, window.owner)
      .first<Record<string, number>>();
    await testEnv.DB.prepare(
      "DELETE FROM billing_effective_entitlement_current WHERE billing_account_id=?",
    )
      .bind(sponsor.id)
      .run();
    await operation({
      account: sponsor,
      window,
      operation: "unsponsor",
      generation: 1,
      expectedCurrent: sponsor.id,
    });
    const after = await testEnv.DB.prepare(
      `SELECT
        (SELECT COUNT(*) FROM moment_spaces WHERE space_id=?) AS spaces,
        (SELECT COUNT(*) FROM moment_participants WHERE space_id=?) AS participants,
        (SELECT COUNT(*) FROM moment_devices WHERE participant_id=?) AS devices,
        (SELECT COUNT(*) FROM moment_object_deletions) AS deletions`,
    )
      .bind(window.space, window.space, window.owner)
      .first<Record<string, number>>();
    expect(after).toEqual(before);
  });

  it("rejects stale generation and non-owner consent references", async () => {
    await openD1SponsorshipGates();
    const sponsor = await account();
    const window = await windowFixture();
    const wrong = await windowFixture();
    const entitlement = await grantPlus(sponsor.id);
    await expect(
      operation({
        account: sponsor,
        window,
        operation: "sponsor",
        generation: 0,
        entitlement,
        consentWindow: wrong,
      }),
    ).rejects.toThrow(/current unblocked owner consent required/u);
    await expect(
      operation({
        account: sponsor,
        window,
        operation: "sponsor",
        generation: 0,
        entitlement,
        consentIssuedAt: Math.floor(Date.now() / 1000) - 301,
      }),
    ).rejects.toThrow(/owner consent stale/u);
    await operation({
      account: sponsor,
      window,
      operation: "sponsor",
      generation: 0,
      entitlement,
    });
    await expect(
      operation({
        account: sponsor,
        window,
        operation: "unsponsor",
        generation: 0,
        expectedCurrent: sponsor.id,
      }),
    ).rejects.toThrow();
  });

  it("rechecks membership revision and active blocks at the database commit", async () => {
    await openD1SponsorshipGates();
    const sponsor = await account(),
      entitlement = await grantPlus(sponsor.id);
    const changed = await windowFixture();
    await testEnv.DB.prepare(
      "UPDATE moment_spaces SET membership_revision=membership_revision+1 WHERE space_id=?",
    )
      .bind(changed.space)
      .run();
    await expect(
      operation({
        account: sponsor,
        window: changed,
        operation: "sponsor",
        generation: 0,
        entitlement,
      }),
    ).rejects.toThrow(/current unblocked owner consent required/u);

    const blocked = await windowFixture(),
      member = random(16),
      device = random(16),
      now = Math.floor(Date.now() / 1000);
    await testEnv.DB.prepare(
      `INSERT INTO moment_participants(id,space_id,role,state,created_at,activated_at)
       VALUES(?,?,'member','active',?,?)`,
    )
      .bind(member, blocked.space, now, now)
      .run();
    await testEnv.DB.prepare(
      `INSERT INTO moment_devices(
        id,participant_id,agreement_public_key,signing_public_key,state,created_at,activated_at
       ) VALUES(?,?,?,?,'active',?,?)`,
    )
      .bind(device, member, random(32), random(32), now, now)
      .run();
    const context = await testEnv.DB.prepare(
      "SELECT current_key_epoch,membership_revision FROM moment_spaces WHERE space_id=?",
    )
      .bind(blocked.space)
      .first<{ current_key_epoch: number; membership_revision: number }>();
    await testEnv.DB.prepare(
      `INSERT INTO moment_blocks(
        space_id,blocker_participant_id,blocked_participant_id,state,created_key_epoch,created_at
       ) VALUES(?,?,?,'active',?,?)`,
    )
      .bind(
        blocked.space,
        blocked.owner,
        member,
        context!.current_key_epoch + 1,
        now,
      )
      .run();
    const blockedRevision = (await testEnv.DB.prepare(
      "SELECT membership_revision FROM moment_spaces WHERE space_id=?",
    )
      .bind(blocked.space)
      .first<{ membership_revision: number }>())!.membership_revision;
    await expect(
      operation({
        account: sponsor,
        window: blocked,
        operation: "sponsor",
        generation: 0,
        entitlement,
        consentMembershipRevision: blockedRevision,
      }),
    ).rejects.toThrow(/current unblocked owner consent required/u);
  });

  it("rejects direct current-state insert and update without an exact audit row", async () => {
    await openD1SponsorshipGates();
    const sponsor = await account(),
      window = await windowFixture();
    await expect(
      testEnv.DB.prepare(
        `INSERT INTO billing_window_sponsorships(window_lineage_id,billing_account_id,state,generation,sponsored_at,updated_at,last_request_id) VALUES(?,?,'active',1,unixepoch(),unixepoch(),?)`,
      )
        .bind(window.lineage, sponsor.id, crypto.randomUUID().toLowerCase())
        .run(),
    ).rejects.toThrow();
    const entitlement = await grantPlus(sponsor.id);
    await operation({
      account: sponsor,
      window,
      operation: "sponsor",
      generation: 0,
      entitlement,
    });
    await expect(
      testEnv.DB.prepare(
        "UPDATE billing_window_sponsorships SET generation=2,updated_at=unixepoch() WHERE window_lineage_id=?",
      )
        .bind(window.lineage)
        .run(),
    ).rejects.toThrow();
  });

  it("returns consent identifiers only to the active owner", async () => {
    const signedWindow = await signedSpace();
    const enabledEnv = await enableSponsorshipGates();

    const ownerResponse = await route(
      await signedGrantRequest(signedWindow.owner),
      enabledEnv,
    );
    expect(ownerResponse.status).toBe(200);
    const ownerBody = await ownerResponse.json<Record<string, unknown>>();
    expect(ownerBody.ownerConsentContext).toEqual({
      windowLineageId: signedWindow.window.lineage,
      membershipRevision: signedWindow.window.revision,
    });
    expect(ownerBody.billingAccountId).toBeUndefined();
    expect(ownerBody.transactionId).toBeUndefined();
    expect(ownerBody.decisionId).toBeUndefined();

    const inviteeResponse = await route(
      await signedGrantRequest(signedWindow.invitee),
      enabledEnv,
    );
    expect(inviteeResponse.status).toBe(200);
    const inviteeBody = await inviteeResponse.json<Record<string, unknown>>();
    expect(inviteeBody.ownerConsentContext).toBeUndefined();
    expect(inviteeBody.windowLineageId).toBeUndefined();
    expect(inviteeBody.membershipRevision).toBeUndefined();
    expect(inviteeBody.billingAccountId).toBeUndefined();
    expect(inviteeBody.transactionId).toBeUndefined();
    expect(inviteeBody.decisionId).toBeUndefined();
  });

  it("lets an active invitee read only the current unblocked window grant", async () => {
    const sponsor = await account(),
      first = await signedSpace(),
      second = await signedSpace();
    const entitlement = await grantPlus(sponsor.id);
    await operation({
      account: sponsor,
      window: first.window,
      operation: "sponsor",
      generation: 0,
      entitlement,
    });
    const enabledEnv = await enableSponsorshipGates();

    const granted = await route(
      await signedGrantRequest(first.invitee),
      enabledEnv,
    );
    expect(granted.status).toBe(200);
    const grantedBody = await granted.json<Record<string, unknown>>();
    expect(grantedBody.windowLineageSponsored).toBe(true);
    expect(grantedBody.grantsPlus).toBe(true);
    expect(grantedBody.billingAccountId).toBeUndefined();
    expect(grantedBody.transactionId).toBeUndefined();
    expect(grantedBody.decisionId).toBeUndefined();
    expect(grantedBody.ownerConsentContext).toBeUndefined();

    const other = await route(
      await signedGrantRequest(second.invitee),
      enabledEnv,
    );
    expect(await other.json()).toMatchObject({
      windowLineageSponsored: false,
      grantsPlus: false,
      accessUntilMs: null,
    });

    const epoch = (await testEnv.DB.prepare(
      "SELECT current_key_epoch FROM moment_spaces WHERE space_id=?",
    )
      .bind(first.window.space)
      .first<{ current_key_epoch: number }>())!.current_key_epoch;
    await testEnv.DB.prepare(
      `INSERT INTO moment_blocks(
        space_id,blocker_participant_id,blocked_participant_id,state,created_key_epoch,created_at
       ) VALUES(?,?,?,'active',?,unixepoch())`,
    )
      .bind(first.window.space, first.window.owner, first.invitee.id, epoch + 1)
      .run();
    const blocked = await route(
      await signedGrantRequest(first.invitee),
      enabledEnv,
    );
    expect(await blocked.json()).toMatchObject({
      windowLineageSponsored: false,
      grantsPlus: false,
      accessUntilMs: null,
    });
  });

  it("does not expose a window grant to a pending invitee", async () => {
    const pending = await signedSpace("pending"),
      enabledEnv = await enableSponsorshipGates();
    await expect(
      route(await signedGrantRequest(pending.invitee), enabledEnv),
    ).rejects.toMatchObject({
      status: 403,
      code: "active_member_required",
    });
  });

  it("rate limits participant grant reads before authentication", async () => {
    const active = await signedSpace();
    const enabledEnv = await enableSponsorshipGates();
    const limitedEnv = {
      ...enabledEnv,
      MEMBER_RATE_LIMITER: {
        limit: async () => ({ success: false }),
      },
    } as Env;
    await expect(
      route(await signedGrantRequest(active.invitee), limitedEnv),
    ).rejects.toMatchObject({ status: 429, code: "rate_limited" });
  });

  it("rejects INSERT OR REPLACE attempts that reuse an obsolete audit row", async () => {
    await openD1SponsorshipGates();
    const sponsor = await account(),
      window = await windowFixture();
    const entitlement = await grantPlus(sponsor.id);
    await operation({
      account: sponsor,
      window,
      operation: "sponsor",
      generation: 0,
      entitlement,
    });
    const first = await testEnv.DB.prepare(
      `SELECT client_request_id,recorded_at
         FROM billing_window_sponsorship_requests
        WHERE window_lineage_id=? AND resulting_generation=1`,
    )
      .bind(window.lineage)
      .first<{ client_request_id: string; recorded_at: number }>();
    await operation({
      account: sponsor,
      window,
      operation: "unsponsor",
      generation: 1,
      expectedCurrent: sponsor.id,
    });
    await expect(
      testEnv.DB.prepare(
        `INSERT OR REPLACE INTO billing_window_sponsorships(
         window_lineage_id,billing_account_id,state,generation,sponsored_at,updated_at,last_request_id
       ) VALUES(?,?,'active',1,?,?,?)`,
      )
        .bind(
          window.lineage,
          sponsor.id,
          first!.recorded_at,
          first!.recorded_at,
          first!.client_request_id,
        )
        .run(),
    ).rejects.toThrow();
    const current = await testEnv.DB.prepare(
      "SELECT state,generation FROM billing_window_sponsorships WHERE window_lineage_id=?",
    )
      .bind(window.lineage)
      .first<{ state: string; generation: number }>();
    expect(current).toEqual({ state: "unsponsored", generation: 2 });
  });
});
