import assert from 'node:assert/strict';
import test from 'node:test';
import { SignJWT } from 'jose';
import { OfflineIdentityVerifier } from './identity.mjs';
import { createSyntheticIdentity, login } from './synthetic-identity.mjs';

const START = Date.UTC(2026, 8, 22);
const identity = await createSyntheticIdentity({ now: () => START });
const outsider = await createSyntheticIdentity({ now: () => START });
function fixture(overrides = {}) {
  let time = START;
  const verifier = new OfflineIdentityVerifier({ ...identity, now: () => time, ...overrides });
  return { verifier, advance: (ms) => { time += ms; } };
}
async function attempt(verifier, claims = {}, signer = identity) {
  const challenge = verifier.beginLogin();
  const idToken = await signer.signToken({ nonce: challenge.nonce, ...claims });
  return { ...challenge, idToken };
}

test('same verified subject survives a new device/session and expired billing', async () => {
  const first = fixture().verifier;
  const nextDevice = fixture().verifier;
  const a = await identity.login(first, { sub: 'cat-owner', email: 'old@example.invalid', billing: 'paid' });
  const b = await login(nextDevice, identity, {
    sub: 'cat-owner', email: 'new@example.invalid', billing: 'expired', device: 'new', ownerID: 'attacker',
  });
  assert.notEqual(a, b);
  assert.equal(first.requireOwner(a), nextDevice.requireOwner(b));
  assert.notEqual(first.requireOwner(a), 'attacker');
  assert.throws(() => nextDevice.requireOwner(a), /Invalid session/);
});

test('different subjects sharing an email never share an owner', async () => {
  const { verifier } = fixture();
  const a = await identity.login(verifier, { sub: 'alice', email: 'same@example.invalid' });
  const b = await identity.login(verifier, { sub: 'bob', email: 'same@example.invalid' });
  assert.notEqual(verifier.requireOwner(a), verifier.requireOwner(b));
});

test('owner encoding preserves issuer/subject boundaries and subject case', async () => {
  const { verifier } = fixture();
  const a = await identity.login(verifier, { sub: 'Alice:猫' });
  const b = await identity.login(verifier, { sub: 'alice:猫' });
  const owner = verifier.requireOwner(a);
  assert.deepEqual(JSON.parse(Buffer.from(owner.slice('owner:v1:'.length), 'base64url').toString()),
    [identity.issuer, 'Alice:猫']);
  assert.notEqual(owner, verifier.requireOwner(b));
  const otherIssuer = 'https://other-issuer.invalid';
  const otherVerifier = fixture({ issuer: otherIssuer }).verifier;
  const c = await otherVerifier.completeLogin(await attempt(otherVerifier, { iss: otherIssuer, sub: 'Alice:猫' }));
  assert.notEqual(owner, otherVerifier.requireOwner(c));
});

for (const [name, claims] of [
  ['issuer', { iss: 'https://wrong.invalid' }],
  ['audience', { aud: 'wrong-audience' }],
  ['expiry', { exp: START / 1_000 }],
  ['missing expiry', { exp: undefined }],
  ['future issued-at', { iat: START / 1_000 + 1 }],
  ['stale issued-at', { iat: START / 1_000 - 301 }],
  ['missing issued-at', { iat: undefined }],
  ['non-integer issued-at', { iat: START / 1_000 - 0.5 }],
  ['nonce', { nonce: 'wrong-nonce' }],
  ['missing nonce', { nonce: undefined }],
  ['empty subject', { sub: '' }],
  ['non-string subject', { sub: 42 }],
  ['missing subject', { sub: undefined }],
]) {
  test(`rejects invalid ${name}`, async () => {
    const { verifier } = fixture();
    await assert.rejects(verifier.completeLogin(await attempt(verifier, claims)), /Invalid login/);
  });
}

test('rejects a signature from an untrusted local key', async () => {
  const { verifier } = fixture();
  await assert.rejects(verifier.completeLogin(await attempt(verifier, {}, outsider)), /Invalid login/);
});

test('rejects a tampered signature and consumes even failed challenges', async () => {
  const { verifier } = fixture();
  const request = await attempt(verifier);
  const parts = request.idToken.split('.');
  parts[2] = (parts[2][0] === 'A' ? 'B' : 'A') + parts[2].slice(1);
  await assert.rejects(verifier.completeLogin({ ...request, idToken: parts.join('.') }), /Invalid login/);
  await assert.rejects(verifier.completeLogin(request), /Invalid login/);
});

test('rejects algorithms outside RS256', async () => {
  const { verifier } = fixture();
  const challenge = verifier.beginLogin();
  const idToken = await new SignJWT({ iss: identity.issuer, aud: identity.audience, sub: 'owner',
    nonce: challenge.nonce, iat: START / 1_000, exp: START / 1_000 + 300 })
    .setProtectedHeader({ alg: 'HS256' }).sign(new Uint8Array(32));
  await assert.rejects(verifier.completeLogin({ ...challenge, idToken }), /Invalid login/);
});

test('a challenge succeeds once, including concurrent completion', async () => {
  const { verifier } = fixture();
  const request = await attempt(verifier);
  const results = await Promise.allSettled([verifier.completeLogin(request), verifier.completeLogin(request)]);
  assert.equal(results.filter((r) => r.status === 'fulfilled').length, 1);
  await assert.rejects(verifier.completeLogin(request), /Invalid login/);
});

test('rejects expired challenges even with a still-valid token', async () => {
  const { verifier, advance } = fixture();
  const request = await attempt(verifier, { exp: START / 1_000 + 600 });
  advance(300_000);
  await assert.rejects(verifier.completeLogin(request), /Invalid login/);
});

test('rejects unknown, fabricated and expired sessions', async () => {
  const { verifier, advance } = fixture();
  for (const session of [undefined, null, '', 'owner:v1:fake', {}, 'fabricated']) {
    assert.throws(() => verifier.requireOwner(session), /Invalid session/);
  }
  const session = await identity.login(verifier);
  advance(899_999);
  assert.ok(verifier.requireOwner(session));
  advance(1);
  assert.throws(() => verifier.requireOwner(session), /Invalid session/);
});

test('rejects unknown challenges and tokens bound to a different challenge', async () => {
  const { verifier } = fixture();
  const a = await attempt(verifier);
  const b = verifier.beginLogin();
  await assert.rejects(verifier.completeLogin({ challengeId: 'unknown', idToken: a.idToken }), /Invalid login/);
  await assert.rejects(verifier.completeLogin({ ...b, idToken: a.idToken }), /Invalid login/);
  assert.ok(await verifier.completeLogin(a));
});
