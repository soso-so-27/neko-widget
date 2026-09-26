// A conservative admission budget, not a cloud billing hard cap. One 2-minute
// lease is charged before each start, even when startup fails or ends early.
export const LEASE_MS = 2 * 60_000;
export const MONTHLY_MS = 10 * 60 * 60_000;
const phases = new Set(['idle', 'preparing', 'active', 'stopping', 'blocked']);
const stopped = status => status === 'stopped' || status === 'stopped_with_code';
const month = now => new Date(now).toISOString().slice(0, 7);
const nextMonth = now => {
  const date = new Date(now);
  return Date.UTC(date.getUTCFullYear(), date.getUTCMonth() + 1, 1);
};

export function validBudget(state) {
  return state && state.version === 1 && /^\d{4}-(0[1-9]|1[0-2])$/u.test(state.month)
    && phases.has(state.phase) && Number.isSafeInteger(state.usedMs)
    && state.usedMs >= 0 && state.usedMs <= MONTHLY_MS && state.usedMs % LEASE_MS === 0
    && Number.isSafeInteger(state.generation) && state.generation >= 0
    && Number.isSafeInteger(state.lastNowMs) && state.lastNowMs >= 0
    && Number.isSafeInteger(state.deadlineMs) && state.deadlineMs >= 0
    && (state.phase === 'idle' || state.phase === 'blocked'
      ? state.deadlineMs === 0 : state.deadlineMs > 0);
}

export function admitBudget(previous, now, status) {
  if (!Number.isSafeInteger(now) || now < 0 || typeof status !== 'string')
    return { action: 'deny' };
  if (previous !== undefined && !validBudget(previous)) return { action: 'deny', stop: !stopped(status) };
  let state = previous || { version: 1, month: month(now), usedMs: 0,
    generation: 0, lastNowMs: now, deadlineMs: 0, phase: 'idle' };
  if (now < state.lastNowMs) {
    state = { ...state, phase: 'blocked', deadlineMs: 0 };
    return { action: 'deny', state, stop: !stopped(status) };
  }
  state = { ...state, lastNowMs: now };
  if (state.phase === 'blocked') return { action: 'deny', state, stop: !stopped(status) };
  if (state.phase === 'preparing' || state.phase === 'stopping') {
    if (state.phase === 'preparing' && now >= state.deadlineMs)
      return { action: 'stop', state: { ...state, phase: 'stopping' }, token: state.generation };
    return { action: 'deny', state };
  }
  if (state.phase === 'active') {
    if (now >= state.deadlineMs || month(now) !== state.month)
      return { action: 'stop', state: { ...state, phase: 'stopping' }, token: state.generation };
    if (status === 'healthy') return { action: 'forward', state, token: state.generation };
    if (!stopped(status)) return { action: 'deny', state };
    state = { ...state, phase: 'idle', deadlineMs: 0 }; // Early exit burns the lease.
  }
  if (!stopped(status)) {
    // Never adopt an unmetered container after storage loss or an unknown start.
    return { action: 'deny', state: { ...state, phase: 'blocked' }, stop: true };
  }
  if (month(now) !== state.month) state = { ...state, month: month(now), usedMs: 0 };
  if (state.usedMs + LEASE_MS > MONTHLY_MS || state.generation === Number.MAX_SAFE_INTEGER)
    return { action: 'deny', state };
  state = { ...state, phase: 'preparing', usedMs: state.usedMs + LEASE_MS,
    generation: state.generation + 1, deadlineMs: Math.min(now + LEASE_MS, nextMonth(now)) };
  return { action: 'start', state, token: state.generation };
}

export function confirmBudget(previous, token, now) {
  if (!validBudget(previous)) return { action: 'deny', stopUnmetered: true };
  if (!Number.isSafeInteger(now) || previous.generation !== token) return { action: 'deny' };
  if (now < previous.lastNowMs)
    return { action: 'stop', state: { ...previous, phase: 'blocked', deadlineMs: 0 } };
  if (previous.phase === 'idle')
    return { action: 'stop', state: { ...previous, phase: 'stopping',
      deadlineMs: Math.max(now, 1), lastNowMs: now } };
  if (previous.phase !== 'preparing' && previous.phase !== 'active') return { action: 'deny' };
  if (now >= previous.deadlineMs || month(now) !== previous.month)
    return { action: 'stop', state: { ...previous, phase: 'stopping', lastNowMs: now } };
  return { action: 'forward', state: { ...previous, phase: 'active', lastNowMs: now } };
}

export function expireBudget(previous, token) {
  if (!validBudget(previous)) return { action: 'deny', stopUnmetered: true };
  if (previous.generation !== token) return { action: 'deny' };
  if (previous.phase === 'idle')
    return { action: 'stop', state: { ...previous, phase: 'stopping',
      deadlineMs: Math.max(previous.lastNowMs, 1) } };
  if (previous.phase === 'preparing' || previous.phase === 'active'
      || previous.phase === 'stopping' || previous.phase === 'blocked')
    return { action: 'stop', state: { ...previous, phase: 'stopping' } };
  return { action: 'deny' }; // A late timer cannot kill a newer lease.
}

export function stoppedBudget(previous, token) {
  if (!validBudget(previous) || previous.generation !== token || previous.phase !== 'stopping')
    return { action: 'deny' };
  return { action: 'done', state: { ...previous, phase: 'idle', deadlineMs: 0 } };
}

export async function readSmallResponse(response, limit = 4096) {
  if (!response.body || !Number.isSafeInteger(limit) || limit < 1) throw new Error('Invalid response');
  const reader = response.body.getReader();
  const chunks = [];
  let size = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      if (!(value instanceof Uint8Array) || (size += value.byteLength) > limit)
        throw new Error('Response too large');
      chunks.push(value);
    }
  } catch (error) {
    try { await reader.cancel(); } catch { /* The lease deadline will destroy the container. */ }
    throw error;
  }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
  return bytes;
}
