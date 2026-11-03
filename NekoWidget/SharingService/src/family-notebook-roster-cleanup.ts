import type { Env } from './env';

const retentionSeconds = 30 * 24 * 60 * 60;
// The signed roster packet lives in crypto_rosters.packet, not a separate table.
// Children are deleted before parents; certificate removal shares the transaction.
const tables = ['family_notebook_crypto_operations', 'family_notebook_crypto_envelopes',
  'family_notebook_crypto_heads', 'family_notebook_crypto_rosters', 'family_notebook_crypto_devices'] as const;

export async function cleanupDissolvedFamilyRosters(env: Pick<Env, 'DB'>,
  nowSeconds = Math.floor(Date.now() / 1000)): Promise<void> {
  if (!await env.DB.prepare("SELECT 1 FROM sqlite_master WHERE type='table' AND name='family_notebook_governance_events'").first()) return;
  const eligible = `f.state='closed' AND EXISTS (
    SELECT 1 FROM family_notebook_governance_events e WHERE e.family_id=f.id AND e.action='dissolve'
      AND e.resulting_generation=f.generation AND e.recorded_at<=?
      AND (e.recorded_at<=? OR NOT EXISTS (SELECT 1 FROM family_notebook_crypto_operations o WHERE o.family_id=f.id)))`;
  const times = [nowSeconds, nowSeconds - retentionSeconds];
  const candidates = await env.DB.prepare(`SELECT f.id FROM family_notebook_spaces f WHERE ${eligible}
    AND (${tables.map(t => `EXISTS (SELECT 1 FROM ${t} x WHERE x.family_id=f.id)`).join(' OR ')})
    ORDER BY f.id LIMIT 50`).bind(...times).all<{id: string}>();
  const ids = candidates.results.map(f => f.id);
  if (!ids.length) return;
  // Re-evaluate the deadline and governance evidence inside the atomic batch.
  const selected = `SELECT f.id FROM family_notebook_spaces f WHERE ${eligible}
    AND f.id IN (${ids.map(() => '?').join(',')})`;
  await env.DB.batch(tables.map(t => env.DB.prepare(`DELETE FROM ${t} WHERE family_id IN (${selected})`).bind(...times, ...ids)));
}
