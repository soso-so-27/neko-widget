// Only the generated loopback configuration points to this entry point.
import { ingestVerifiedAppleBillingNotification, reconcileBillingTransactionNow } from '../src/billing-authority';
import { requestBillingReconciliation } from '../src/billing-reconciliation-queue';
import type { VerifiedBillingTransaction } from '../src/billing-verifier-client';
import { randomBase64url, sha256Base64url } from '../src/encoding';
import type { Env } from '../src/env';
import { ApiError, errorResponse } from '../src/errors';
import { drainFamilyNotifications } from '../src/family-notebook-push';
import { route } from '../src/index';

type LocalEnv = Env & { E2E_TOKEN?: string };

async function grantPlus(request: Request, env: LocalEnv): Promise<Response> {
  const { billingAccountId } = await request.json<{ billingAccountId?: string }>();
  if (typeof billingAccountId !== 'string' || !/^[\da-f]{8}(?:-[\da-f]{4}){3}-[\da-f]{12}$/u.test(billingAccountId)) {
    throw new ApiError(400, 'expected_billing_account', 'Pass the ID of a bootstrapped test billing account.');
  }
  const account = await env.DB.prepare("SELECT 1 FROM billing_account_keys WHERE billing_account_id=? AND state='active'")
    .bind(billingAccountId).first();
  if (!account) throw new ApiError(404, 'expected_billing_account', 'Bootstrap the test billing account first.');

  // Substitute only the verified Apple response. The entitlement ledger,
  // reconciliation, dual-signature billing connection and Plus gate are real.
  const now = Date.now();
  const id = BigInt('0x' + billingAccountId.replaceAll('-', '').slice(-16)).toString();
  const transaction: VerifiedBillingTransaction = {
    transactionId: id, originalTransactionId: id, billingAccountId,
    productId: 'jp.nekowidget.plus.monthly', subscriptionGroupId: '20999999',
    bundleId: 'jp.nekowidget.app', environment: 'Sandbox', ownershipType: 'PURCHASED',
    transactionReason: 'PURCHASE', purchaseDateMs: now - 1000, originalPurchaseDateMs: now - 1000,
    expiresDateMs: now + 86400000, signedDateMs: now,
    revocationDateMs: null, revocationReason: null, isUpgraded: false,
  };
  await ingestVerifiedAppleBillingNotification(env, {
    notificationUUID: crypto.randomUUID(), notificationType: 'DID_RENEW', subtype: null,
    signedDateMs: now, environment: 'Sandbox', bundleId: transaction.bundleId,
    status: 1, relevant: true, transaction, renewal: null,
  }, randomBase64url(32));
  await requestBillingReconciliation(env, id);
  await reconcileBillingTransactionNow(env, billingAccountId, id, async () => ({
    requestedTransactionId: id, environment: 'Sandbox', bundleId: transaction.bundleId, fetchedAtMs: now,
    items: [{
      status: 1, originalTransactionId: id, transaction,
      renewal: {
        originalTransactionId: id, billingAccountId, productId: transaction.productId,
        autoRenewProductId: transaction.productId, autoRenewStatus: 1, isInBillingRetryPeriod: false,
        gracePeriodExpiresDateMs: null, renewalDateMs: transaction.expiresDateMs,
        signedDateMs: now, environment: 'Sandbox',
      },
    }],
  }));
  const granted = await env.DB.prepare(`SELECT 1 FROM billing_effective_entitlement_current
    WHERE billing_account_id=? AND environment='Sandbox' AND apple_status=1 AND ownership_type='PURCHASED'`)
    .bind(billingAccountId).first();
  if (!granted) throw new ApiError(503, 'fixture_plus_unavailable', 'Synthetic entitlement was not reconciled.');
  return Response.json({ plus: true });
}

async function captureNotifications(env: LocalEnv): Promise<Response> {
  const destinations: { tokenSHA256: string; kind: string; pushType: string | null }[] = [];
  const result = await drainFamilyNotifications(env, Math.floor(Date.now() / 1000), async (input, init) => {
    const request = new Request(input, init);
    const url = new URL(request.url);
    const token = /^\/3\/device\/([0-9a-f]{64})$/u.exec(url.pathname)?.[1];
    if (!token || url.origin !== 'https://api.push.apple.com') throw new Error('Unexpected APNs destination');
    const body = await request.json<{ neko: { kind: string } }>();
    const bytes = Uint8Array.from(token.match(/../gu)!, byte => Number.parseInt(byte, 16));
    destinations.push({
      tokenSHA256: await sha256Base64url(bytes), kind: body.neko.kind,
      pushType: request.headers.get('apns-push-type'),
    });
    return new Response(null, { status: 200 });
  });
  return Response.json({ ...result, destinations });
}

export default {
  async fetch(request, env): Promise<Response> {
    const url = new URL(request.url);
    if (env.ENVIRONMENT !== 'local' || url.hostname !== '127.0.0.1' || !env.E2E_TOKEN) {
      return new Response(null, { status: 404 });
    }
    try {
      if (!url.pathname.startsWith('/__e2e/')) {
        // Route through the real HTTP handlers. Family APNs is drained only by
        // the explicit fixture endpoint below, so it never calls Apple.
        return await route(request, env);
      }
      if (request.method === 'POST' && request.headers.get('neko-e2e-token') === env.E2E_TOKEN) {
        if (url.pathname === '/__e2e/plus') return await grantPlus(request, env);
        if (url.pathname === '/__e2e/drain-notifications') return await captureNotifications(env);
      }
      return new Response(null, { status: 404 });
    } catch (error) {
      return errorResponse(error);
    }
  },
} satisfies ExportedHandler<LocalEnv>;
