import { readFileSync } from 'node:fs';

export const billingOperatorStatusSQL = readFileSync(new URL('./billing-operator-status.sql', import.meta.url), 'utf8');
const states = new Set(['idle', 'ready', 'leased', 'retry_wait', 'completed', 'blocked']);
const invalid = () => { throw new Error('invalid billing operator snapshot'); };
function keys(value, expected) {
  if (!value || typeof value !== 'object' || Array.isArray(value)
    || Object.keys(value).sort().join(',') !== [...expected].sort().join(',')) invalid();
}
function count(value) { if (!Number.isSafeInteger(value) || value < 0) invalid(); }
function optionalTime(value, scale = 1) {
  if (value !== null && (!Number.isSafeInteger(value) || value <= 0 || value * scale > 8640000000000000)) invalid();
}

export function parseBillingOperatorSnapshot(text) {
  if (typeof text !== 'string' || Buffer.byteLength(text, 'utf8') > 65536) invalid();
  let value;
  try { value = JSON.parse(text); } catch { invalid(); }
  keys(value, ['schemaVersion', 'capturedAtMs', 'gate', 'environments', 'unknownLegacy']);
  if (value.schemaVersion !== 1 || value.capturedAtMs === null) invalid();
  optionalTime(value.capturedAtMs);
  keys(value.gate, ['generation', 'effectiveEntitlement', 'reconciliation', 'historyRecovery']);
  count(value.gate.generation);
  for (const key of ['effectiveEntitlement', 'reconciliation', 'historyRecovery']) {
    if (![0, 1].includes(value.gate[key])) invalid();
  }
  if (!Array.isArray(value.environments) || value.environments.length !== 2) invalid();
  for (const [index, environment] of ['Production', 'Sandbox'].entries()) {
    const row = value.environments[index];
    keys(row, ['environment', 'history', 'reconciliation', 'entitlement']);
    if (row.environment !== environment) invalid();
    const h = row.history, r = row.reconciliation, e = row.entitlement;
    keys(h, ['state', 'generation', 'pages', 'records', 'attempts', 'notBefore', 'completedAt', 'errorCode']);
    if (!states.has(h.state)) invalid();
    for (const key of ['generation', 'pages', 'records', 'attempts', 'notBefore']) count(h[key]);
    if (h.records > h.pages * 20 || h.attempts > 20) invalid();
    optionalTime(h.completedAt, 1000);
    if (h.notBefore > 8640000000000) invalid();
    if (h.errorCode !== null && (typeof h.errorCode !== 'string' || !/^[a-z0-9_]{1,64}$/u.test(h.errorCode))) invalid();
    keys(r, ['pending', 'leased', 'ready', 'retryWait', 'withErrors']);
    Object.values(r).forEach(count);
    if (r.pending !== r.leased + r.ready + r.retryWait || r.withErrors > r.pending) invalid();
    keys(e, ['lineages', 'freshPlusAccounts', 'staleAuthorityLineages', 'expiredAccessLineages', 'lastObservationAtMs']);
    for (const key of ['lineages', 'freshPlusAccounts', 'staleAuthorityLineages', 'expiredAccessLineages']) count(e[key]);
    if (e.freshPlusAccounts > e.lineages || e.staleAuthorityLineages > e.lineages || e.expiredAccessLineages > e.lineages) invalid();
    optionalTime(e.lastObservationAtMs);
  }
  keys(value.unknownLegacy, ['pages', 'records']);
  Object.values(value.unknownLegacy).forEach(count);
  if (value.unknownLegacy.records > value.unknownLegacy.pages * 20) invalid();
  return value;
}

export function renderBillingOperatorSnapshot(text) {
  const value = parseBillingOperatorSnapshot(text);
  const timestamp = (value, scale = 1) => value ? new Date(value * scale).toISOString() : '-';
  const lines = [
    '課金台帳のローカル集計（接続・制御なし）',
    `取得時刻: ${new Date(value.capturedAtMs).toISOString()} / schema 0062+`,
    'これは取得時点の記録です。現在の上位設定・サービス利用許可・売上は確認しません。',
    `DB 下位 gate: 権利=${value.gate.effectiveEntitlement} 再照合=${value.gate.reconciliation} 履歴=${value.gate.historyRecovery} / 世代=${value.gate.generation}`,
  ];
  for (const row of value.environments) {
    const h = row.history, r = row.reconciliation, e = row.entitlement;
    lines.push('', row.environment === 'Sandbox' ? 'Sandbox（テスト・非売上）' : 'Production（本番台帳・売上集計ではありません）',
      `履歴回復: ${h.state} / 世代 ${h.generation} / ${h.pages} pages・${h.records} records / 試行 ${h.attempts}`,
      `履歴再試行可能時刻: ${timestamp(h.notBefore,1000)} / 最終完了時刻: ${timestamp(h.completedAt,1000)} / エラー: ${h.errorCode ?? '-'}`,
      `再照合待ち: ${r.pending}（実行可能 ${r.ready} / lease 中 ${r.leased} / 再試行待ち ${r.retryWait} / エラーあり ${r.withErrors}）`,
      `新鮮な Plus 対象 account: ${e.freshPlusAccounts} / 台帳 lineage: ${e.lineages}`,
      `照合鮮度切れ lineage: ${e.staleAuthorityLineages} / 権利期限切れ lineage: ${e.expiredAccessLineages} / 最終観測: ${timestamp(e.lastObservationAtMs)}`);
  }
  lines.push('', `環境不明の旧履歴（両環境から除外）: ${value.unknownLegacy.pages} pages・${value.unknownLegacy.records} records`,
    'account は環境ごとに重複を除いています。両環境の人数を合算しないでください。');
  return lines.join('\n');
}
