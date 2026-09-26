import { ServiceError } from './contracts';

const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;
const unavailable = () => new ServiceError('OWNER_D1_RESIDUE_UNAVAILABLE', 503);

/** Every owner-id-bearing table must appear in exactly one group. The schema
 * coverage test fails when a new table is added without a purge disposition.
 */
export const ownerContentTables = [
  'pa_identity_credentials', 'pa_inventory', 'pa_membership_challenges',
  'pa_membership_links', 'pa_notice_claims', 'pa_notice_contacts',
  'pa_notice_submissions', 'pa_owner_recovery_generations',
  'pa_owner_recovery_repair_failures', 'pa_owner_recovery_versions',
  'pa_owners', 'pa_record_commit_markers', 'pa_record_delete_intents',
  'pa_record_legacy_baseline', 'pa_record_recovery_versions', 'pa_records',
  'pa_recovery_repair_failures', 'pa_recovery_write_leases', 'pa_retention',
  'pa_sessions', 'pa_uploads',
] as const;
export const purgeWorkTables = [
  'pa_owner_purge_events', 'pa_purge_execution_claims', 'pa_purge_fences',
  'pa_purge_manifest_chunks', 'pa_purge_manifest_remote_refs',
  'pa_purge_manifest_remote_seals', 'pa_purge_manifests',
] as const;
export const ownerCursorTables = [
  'pa_expiry_review_cursor', 'pa_notice_scan_cursor',
] as const;
/** Child-first order for the eventual owner eraser. The FK test below fails
 * on a new table or dependency. This list does not itself issue DELETEs:
 * erasing proof, external copy verification, and policy-specific trigger
 * changes are still required before any row may be removed.
 */
export const ownerD1DeleteOrder = [
  'pa_membership_challenges',
  'pa_notice_claims', 'pa_notice_submissions', 'pa_sessions',
  'pa_record_commit_markers', 'pa_record_delete_intents',
  'pa_record_legacy_baseline', 'pa_recovery_repair_failures',
  'pa_record_recovery_versions', 'pa_records', 'pa_uploads',
  'pa_owner_recovery_repair_failures', 'pa_owner_recovery_versions',
  'pa_owner_recovery_generations', 'pa_recovery_write_leases',
  'pa_notice_contacts', 'pa_retention', 'pa_membership_links',
  'pa_identity_credentials', 'pa_inventory',
  'pa_purge_fences', 'pa_owners',
] as const;
type CountRow = { source: string; n: number };
export type OwnerD1Residue = { ownerId: string;
  content: Readonly<Record<string, number>>; purgeWork: Readonly<Record<string, number>>;
  pendingPhotoDeletes: number; ownerCursors: Readonly<Record<string, number>>;
  recoveryRepairCursors: Readonly<Record<string, number>>;
  contentTotal: number; purgeWorkTotal: number };

/** One read-only query, no plaintext/content bytes. Call after each D1 erase
 * phase and after completion; a zero records count alone is not sufficient.
 */
export async function inspectOwnerD1Residue(db: D1Database,
  ownerId: string): Promise<OwnerD1Residue> {
  if (!uuid.test(ownerId)) throw unavailable();
  const tables = [...ownerContentTables, ...purgeWorkTables];
  const prefix = `personal/${ownerId}/`;
  const upper = `personal/${ownerId}0`;
  const statements = tables.map(name => db.prepare(`SELECT '${name}' AS source,
    COUNT(*) AS n FROM ${name} WHERE owner_id=?`).bind(ownerId));
  statements.push(db.prepare(`SELECT 'pa_pending_deletes' AS source, COUNT(*) AS n
    FROM pa_pending_deletes WHERE object_key>=? AND object_key<?`).bind(prefix, upper));
  statements.push(db.prepare(`SELECT 'pa_expiry_review_cursor' AS source, COUNT(*) AS n
    FROM pa_expiry_review_cursor WHERE owner_id=?`).bind(ownerId));
  statements.push(db.prepare(`SELECT 'pa_notice_scan_cursor' AS source, COUNT(*) AS n
    FROM pa_notice_scan_cursor WHERE owner_id=?`).bind(ownerId));
  statements.push(db.prepare(`SELECT 'pa_recovery_repair_cursor' AS source, COUNT(*) AS n
    FROM pa_recovery_repair_cursor WHERE last_owner_id=?`).bind(ownerId));
  statements.push(db.prepare(`SELECT 'pa_owner_recovery_repair_cursor' AS source, COUNT(*) AS n
    FROM pa_owner_recovery_repair_cursor WHERE last_owner_id=?`).bind(ownerId));
  try {
    const results = await db.batch<CountRow>(statements);
    const rows = results.flatMap(result => result.results);
    if (rows.length !== statements.length) throw unavailable();
    const values = new Map<string, number>();
    for (const row of rows) {
      if (values.has(row.source) || !Number.isSafeInteger(row.n) || row.n < 0) {
        throw unavailable();
      }
      values.set(row.source, row.n);
    }
    const pick = (names: readonly string[]): Record<string, number> =>
      Object.fromEntries(names.map(name => {
        const count = values.get(name);
        if (count === undefined) throw unavailable();
        return [name, count];
      }));
    const content = pick(ownerContentTables);
    const purgeWork = pick(purgeWorkTables);
    const ownerCursors = pick(ownerCursorTables);
    const recoveryRepairCursors = pick([
      'pa_recovery_repair_cursor', 'pa_owner_recovery_repair_cursor']);
    const pendingPhotoDeletes = values.get('pa_pending_deletes');
    if (pendingPhotoDeletes === undefined) throw unavailable();
    const contentTotal = Object.values(content).reduce((sum, n) => sum + n, 0);
    const purgeWorkTotal = Object.values(purgeWork).reduce((sum, n) => sum + n, 0);
    if (!Number.isSafeInteger(contentTotal) || !Number.isSafeInteger(purgeWorkTotal)) {
      throw unavailable();
    }
    return { ownerId, content, purgeWork, pendingPhotoDeletes, ownerCursors,
      recoveryRepairCursors, contentTotal, purgeWorkTotal };
  } catch { throw unavailable(); }
}
