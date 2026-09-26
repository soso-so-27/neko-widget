import { Container, getContainer } from '@cloudflare/containers';
import { WorkerEntrypoint } from 'cloudflare:workers';
import { admitBudget, confirmBudget, expireBudget, readSmallResponse, stoppedBudget, validBudget } from './runtime-budget.mjs';

const secretPattern = /^[A-Za-z0-9_-]{43,128}$/u;
const budgetKey = 'neko-validator-runtime-budget-v1';
const unavailable = () => Response.json({ error: { code: 'DEPENDENCY_UNAVAILABLE' } }, {
  status: 503, headers: { 'cache-control': 'no-store', 'x-content-type-options': 'nosniff' },
});

export class JPEGValidatorContainer extends Container {
  defaultPort = 8080;
  sleepAfter = '1m';
  enableInternet = false;
  envVars = { JPEG_VALIDATOR_ENABLED: 'YES', JPEG_VALIDATOR_CALLER_SECRET: this.env.JPEG_VALIDATOR_CALLER_SECRET };
  #startup;

  async #change(transition) {
    return this.ctx.blockConcurrencyWhile(async () => {
      const previous = await this.ctx.storage.get(budgetKey);
      const decision = transition(previous);
      if (decision.state) await this.ctx.storage.put(budgetKey, decision.state);
      return decision;
    });
  }

  async #killLease(token) {
    const decision = await this.#change(state => expireBudget(state, token));
    if (decision.stopUnmetered) { await this.destroy(); return; }
    if (decision.action !== 'stop') return;
    if (this.#startup?.token === token) this.#startup.controller.abort();
    try {
      await this.destroy(); // SIGKILL, unlike the graceful stop() signal.
      await this.#change(state => stoppedBudget(state, token));
    } catch {
      // Leave the state as stopping. No admission is possible while retrying.
      try { await this.schedule(5, 'expireLease', { generation: token }); } catch { /* fail closed */ }
    }
  }

  async expireLease({ generation } = {}) {
    if (Number.isSafeInteger(generation)) await this.#killLease(generation);
  }

  async fetch(request) {
    let token;
    let startupController;
    try {
      // The physical state is checked before every forwarding decision: a
      // crashed/slept container needs a fresh reserved lease before restart.
      const physical = await this.getState();
      const decision = await this.#change(state => admitBudget(state, Date.now(), physical.status));
      if (decision.stop) {
        if (validBudget(decision.state) && decision.state.phase === 'blocked')
          await this.#killLease(decision.state.generation);
        else await this.destroy(); // Corrupt state must never run unmetered.
        return unavailable();
      }
      if (decision.action === 'stop') {
        await this.#killLease(decision.token);
        return unavailable();
      }
      if (decision.action !== 'start' && decision.action !== 'forward') return unavailable();
      token = decision.token;
      if (decision.action === 'start') {
        // Reserve before startup, then arrange a deadline independent of traffic.
        // A scheduling failure consumes the lease and denies the request.
        await this.schedule(new Date(decision.state.deadlineMs), 'expireLease', { generation: token });
        const ready = await this.ctx.storage.get(budgetKey);
        if (!validBudget(ready) || ready.generation !== token || ready.phase !== 'preparing'
            || Date.now() >= ready.deadlineMs) return unavailable();
        const controller = new AbortController();
        startupController = controller;
        this.#startup = { token, controller };
        try {
          await this.startAndWaitForPorts({ ports: this.defaultPort,
            cancellationOptions: { abort: controller.signal } });
        } finally {
          if (this.#startup?.token === token) this.#startup = undefined;
        }
      }
      const beforeForward = await this.#change(state => confirmBudget(state, token, Date.now()));
      if (beforeForward.action === 'stop') { await this.#killLease(token); return unavailable(); }
      if (beforeForward.stopUnmetered) { await this.destroy(); return unavailable(); }
      if (beforeForward.action !== 'forward') return unavailable();
      this.renewActivityTimeout();
      // This low-level port never auto-starts a container after an expiry race.
      const response = await this.ctx.container.getTcpPort(this.defaultPort).fetch(request);
      // Fully consume the tiny JSON reply; do not proxy an abandoned body.
      const bytes = await readSmallResponse(response);
      const confirmed = await this.#change(state => confirmBudget(state, token, Date.now()));
      if (confirmed.action === 'stop') {
        await this.#killLease(token);
        return unavailable();
      }
      if (confirmed.stopUnmetered) await this.destroy();
      if (confirmed.action !== 'forward') return unavailable();
      return new Response(bytes, { status: response.status,
        headers: { 'content-type': 'application/json', 'cache-control': 'no-store',
          'x-content-type-options': 'nosniff' } });
    } catch {
      if (token !== undefined && !startupController?.signal.aborted) {
        try { await this.#killLease(token); } catch { /* fail closed */ }
      }
      return unavailable();
    }
  }
}

/** Only this named service entrypoint can reach the decoder container. */
export class JPEGValidationService extends WorkerEntrypoint {
  async fetch(request) {
    const secret = this.env.JPEG_VALIDATOR_CALLER_SECRET;
    if (this.env.JPEG_VALIDATOR_ENABLED !== 'YES' || typeof secret !== 'string'
        || !secretPattern.test(secret) || request.signal.aborted) return unavailable();
    const url = new URL(request.url);
    if (url.pathname !== '/images/validate-jpeg' || url.search || request.method !== 'POST') return unavailable();
    const headers = new Headers(request.headers);
    headers.set('x-neko-validator-secret', secret);
    try {
      const container = getContainer(this.env.VALIDATOR_CONTAINER, 'private-jpeg-validator-v1');
      const response = await container.fetch(new Request(request, { headers }));
      const safe = new Headers(response.headers);
      safe.set('cache-control', 'no-store');
      safe.set('x-content-type-options', 'nosniff');
      return new Response(response.body, { status: response.status, headers: safe });
    } catch { return unavailable(); }
  }
}

// No public URL, even if workers_dev or a route is accidentally enabled later.
export default { fetch() { return new Response(null, { status: 404 }); } };
