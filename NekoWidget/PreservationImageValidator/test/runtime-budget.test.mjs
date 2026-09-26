import assert from 'node:assert/strict';
import { registerHooks } from 'node:module';
import test from 'node:test';
import { admitBudget, confirmBudget, expireBudget, LEASE_MS, MONTHLY_MS,
  readSmallResponse, stoppedBudget, validBudget } from '../src/runtime-budget.mjs';

const start = Date.parse('2026-09-01T00:00:00Z');
const finish = (state, token) => stoppedBudget(expireBudget(state, token).state, token).state;

// Import the real Worker class; only Cloudflare's unavailable Node imports are mocked.
class MockContainer {
  constructor(ctx, env) { this.ctx = ctx; this.env = env; }
  async getState() { return { status: this.ctx.physical }; }
  async schedule(when, callback, payload) {
    this.ctx.schedules.push({ when, callback, payload });
    return { taskId: String(this.ctx.schedules.length) };
  }
  async startAndWaitForPorts({ cancellationOptions }) {
    this.ctx.starts++;
    const state = await this.ctx.storage.get('neko-validator-runtime-budget-v1');
    assert.equal(state.usedMs, this.ctx.starts * LEASE_MS, 'the lease is durable before startup');
    assert.equal(this.ctx.schedules.at(-1)?.payload.generation, state.generation,
      'the current deadline is scheduled before startup');
    this.ctx.physical = 'running';
    if (this.ctx.holdStart) {
      const pending = new Promise((resolve, reject) => {
        this.ctx.releaseStart = resolve;
        cancellationOptions.abort.addEventListener('abort', () => reject(new Error('startup aborted')), { once: true });
      });
      this.ctx.signalStart();
      await pending;
    } else this.ctx.signalStart();
    if (cancellationOptions.abort.aborted) throw new Error('startup aborted');
    this.ctx.physical = 'healthy';
  }
  renewActivityTimeout() { this.ctx.renewals++; }
  async destroy() { this.ctx.destroys++; this.ctx.physical = 'stopped'; }
}

globalThis.__nekoContainerTest = { Container: MockContainer, getContainer: () => null,
  WorkerEntrypoint: class {} };
const virtual = new Map([
  ['@cloudflare/containers', 'export const { Container, getContainer } = globalThis.__nekoContainerTest;'],
  ['cloudflare:workers', 'export const { WorkerEntrypoint } = globalThis.__nekoContainerTest;'],
]);
registerHooks({ resolve(specifier, context, nextResolve) {
  if (virtual.has(specifier)) return { url: 'data:text/javascript,' + encodeURIComponent(virtual.get(specifier)),
    shortCircuit: true };
  return nextResolve(specifier, context);
} });
const { JPEGValidatorContainer } = await import('../src/container-worker.mjs');

function mockWorker({ holdStart = false } = {}) {
  const values = new Map();
  let releaseGate = Promise.resolve();
  let signalStart;
  const ctx = { physical: 'stopped', starts: 0, destroys: 0, renewals: 0,
    schedules: [], holdStart, startEntered: new Promise(resolve => { signalStart = resolve; }),
    signalStart: () => signalStart(),
    storage: {
      async get(key) { return structuredClone(values.get(key)); },
      async put(key, value) { values.set(key, structuredClone(value)); },
    },
    async blockConcurrencyWhile(callback) {
      const previous = releaseGate;
      let release;
      releaseGate = new Promise(resolve => { release = resolve; });
      await previous;
      try { return await callback(); } finally { release(); }
    },
    container: { getTcpPort() { return { async fetch() {
      ctx.forwards = (ctx.forwards || 0) + 1;
      return Response.json({ valid: true, mediaType: 'image/jpeg', frames: 1 });
    } }; } },
  };
  const worker = new JPEGValidatorContainer(ctx, { JPEG_VALIDATOR_CALLER_SECRET: 'a'.repeat(43) });
  const request = () => new Request('https://preservation-internal/images/validate-jpeg',
    { method: 'POST', body: '{}' });
  return { ctx, worker, request };
}

test('reserves each activation before startup and rejects the 301st in the same month', () => {
  let state;
  for (let count = 0; count < MONTHLY_MS / LEASE_MS; count++) {
    const decision = admitBudget(state, start + count * LEASE_MS, 'stopped');
    assert.equal(decision.action, 'start');
    state = finish(decision.state, decision.token); // Failed starts still consume time.
  }
  assert.equal(state.usedMs, MONTHLY_MS);
  assert.equal(admitBudget(state, start + MONTHLY_MS, 'stopped').action, 'deny');
});

test('preparing is not a second admission; a deadline stops even under fresh activity', () => {
  const first = admitBudget(undefined, start, 'stopped');
  assert.equal(admitBudget(first.state, start + 1, 'running').action, 'deny');
  const active = confirmBudget(first.state, first.token, start + 1);
  assert.equal(active.action, 'forward');
  assert.equal(admitBudget(active.state, start + 30_000, 'healthy').action, 'forward');
  assert.equal(expireBudget(active.state, first.token).action, 'stop');
  assert.equal(admitBudget(active.state, start + LEASE_MS, 'healthy').action, 'stop');
  assert.equal(admitBudget(active.state, start + 30_001, 'running').action, 'deny');
});

test('month crossing ends the old lease before a new month is admitted', () => {
  const late = Date.parse('2026-09-30T23:59:30Z');
  const first = admitBudget(undefined, late, 'stopped');
  assert.equal(first.state.deadlineMs, Date.parse('2026-10-01T00:00:00Z'));
  const active = confirmBudget(first.state, first.token, late + 1);
  const crossed = admitBudget(active.state, late + 31_000, 'healthy');
  assert.equal(crossed.action, 'stop');
  assert.equal(admitBudget(crossed.state, late + 32_000, 'healthy').action, 'deny');
  const next = admitBudget(finish(crossed.state, first.token), late + 33_000, 'stopped');
  assert.equal(next.action, 'start');
  assert.equal(next.state.month, '2026-10');
  assert.equal(next.state.usedMs, LEASE_MS);
});

test('rollback, corrupt state and unmetered physical starts fail closed', () => {
  const first = admitBudget(undefined, start, 'stopped');
  const rollback = admitBudget(first.state, start - 1, 'healthy');
  assert.equal(rollback.action, 'deny');
  assert.equal(rollback.stop, true);
  assert.equal(rollback.state.phase, 'blocked');
  assert.equal(admitBudget(rollback.state, start + LEASE_MS, 'stopped').action, 'deny');
  assert.equal(expireBudget(rollback.state, first.token).action, 'stop');
  const corrupt = { ...first.state, usedMs: -1 };
  assert.equal(admitBudget(corrupt, start, 'stopped').action, 'deny');
  assert.equal(confirmBudget(corrupt, first.token, start).stopUnmetered, true);
  assert.equal(expireBudget(corrupt, first.token).stopUnmetered, true);
  assert.equal(admitBudget(undefined, start, 'healthy').stop, true);
  assert.equal(validBudget(first.state), true);
});

test('a late deadline cannot stop a newer activation after an early exit', () => {
  const first = admitBudget(undefined, start, 'stopped');
  const firstStopped = finish(first.state, first.token);
  assert.equal(expireBudget(firstStopped, first.token).action, 'stop');
  assert.equal(confirmBudget(firstStopped, first.token, start + 1_000).action, 'stop');
  const second = admitBudget(firstStopped, start + 1_000, 'stopped');
  assert.equal(second.action, 'start');
  assert.equal(expireBudget(second.state, first.token).action, 'deny');
  assert.equal(stoppedBudget(second.state, first.token).action, 'deny');
  assert.equal(second.state.usedMs, 2 * LEASE_MS);
});

test('container response is fully consumed with a small byte cap', async () => {
  const response = new Response('{"valid":true}');
  assert.equal(new TextDecoder().decode(await readSmallResponse(response)), '{"valid":true}');
  assert.equal(response.bodyUsed, true);
  let cancelled = false;
  const oversized = new Response(new ReadableStream({
    start(controller) { controller.enqueue(new Uint8Array(4097)); },
    cancel() { cancelled = true; },
  }));
  await assert.rejects(readSmallResponse(oversized));
  assert.equal(cancelled, true);
});

test('real Worker class reserves before start and denies a concurrent second start', async () => {
  const { ctx, worker, request } = mockWorker({ holdStart: true });
  const first = worker.fetch(request());
  await ctx.startEntered;
  assert.equal(ctx.starts, 1);
  assert.equal((await worker.fetch(request())).status, 503);
  assert.equal(ctx.starts, 1);
  assert.equal(ctx.forwards || 0, 0);
  ctx.releaseStart();
  assert.equal((await first).status, 200);
  assert.equal(ctx.forwards, 1);
});

test('real Worker deadline aborts pending startup and destroys the same lease', async () => {
  const { ctx, worker, request } = mockWorker({ holdStart: true });
  const pending = worker.fetch(request());
  await ctx.startEntered;
  await worker.expireLease(ctx.schedules[0].payload);
  assert.equal((await pending).status, 503);
  assert.equal(ctx.destroys, 1);
  assert.equal(ctx.physical, 'stopped');
  assert.equal((await ctx.storage.get('neko-validator-runtime-budget-v1')).usedMs, LEASE_MS);
});

test('real Worker ignores an old alarm after a newer lease starts', async () => {
  const { ctx, worker, request } = mockWorker();
  assert.equal((await worker.fetch(request())).status, 200);
  const oldAlarm = ctx.schedules[0].payload;
  await worker.expireLease(oldAlarm);
  assert.equal(ctx.destroys, 1);
  assert.equal((await worker.fetch(request())).status, 200);
  assert.equal(ctx.starts, 2);
  await worker.expireLease(oldAlarm);
  assert.equal(ctx.destroys, 1);
  assert.equal(ctx.physical, 'healthy');
  assert.equal((await ctx.storage.get('neko-validator-runtime-budget-v1')).usedMs, 2 * LEASE_MS);
});
