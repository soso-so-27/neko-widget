import type { Env } from "./env";
import { runMomentCleanup } from "./moments";
import { expireStalePairingState } from "./handlers";
import { expireDeviceRecoveries } from "./device-recovery";

// Space cleanup uses the candidate IDs as bound parameters. Keep ten slots of
// headroom below D1's hard 100-parameter ceiling for timestamps and guards.
export const CLEANUP_SPACE_LIMIT = 90;

// The five-minute cleanup capacities are deliberately independent: a public
// request burst must not consume the budget needed for private-media retention.
// Chunking gives every stage a durable checkpoint between D1 statements, so an
// interrupted invocation resumes oldest-first without an in-memory cursor.
export const CLEANUP_NONCE_LIMIT = 10_000;
export const CLEANUP_NONCE_CHUNK_SIZE = 2_000;
export const CLEANUP_IDEMPOTENCY_LIMIT = 2_500;
export const CLEANUP_IDEMPOTENCY_CHUNK_SIZE = 500;
export const CLEANUP_DAILY_FREEZE_LIMIT = 1_000;
export const CLEANUP_DAILY_FREEZE_CHUNK_SIZE = 500;
export const CLEANUP_GENERATION_CLOSE_LIMIT = 10_000;
export const CLEANUP_GENERATION_CHUNK_SIZE = 100;
export const CLEANUP_TERMINAL_GENERATION_LIMIT = 1_000;
export const CLEANUP_SOURCE_UNBLOCK_LIMIT = 1_000;
export const CLEANUP_FINALIZE_CHUNK_SIZE = 250;
export const CLEANUP_OBJECT_LIMIT = 24_000;
export const CLEANUP_REVOKED_SCOPE_LIMIT = 50;
const R2_PREFIX_LIST_LIMIT = 1_000;
export const R2_DELETE_BATCH_SIZE = 1_000;
export const CLEANUP_SUBREQUEST_GUARD = 980;
export const LEGACY_CLEANUP_CRON = "*/5 * * * *";
export const MOMENT_CLEANUP_CRON = "2,7,12,17,22,27,32,37,42,47,52,57 * * * *";
// Each CAS tuple has two bindings: (object_key, attempts). 48 tuples use 96
// parameters, leaving four below D1's hard ceiling.
export const OBJECT_DELETE_CAS_TUPLE_LIMIT = 48;
const UPLOAD_CLOSE_GRACE_SECONDS = 600;
const EMPTY_PREFIX_CONFIRM_SECONDS = 60;

interface SpaceIDRow {
  id: string;
}

export const PAIRING_EXPIRY_CANDIDATES_SQL = `
  WITH
  expired_invitations AS MATERIALIZED (
    SELECT space_id, expires_at
      FROM invitations INDEXED BY open_invitations_expiry
     WHERE status = 'open' AND expires_at <= ?
     ORDER BY expires_at ASC, space_id ASC
     LIMIT ?
  ),
  expired_enrollments AS MATERIALIZED (
    SELECT space_id, expires_at
      FROM enrollments INDEXED BY live_enrollments_expiry
     WHERE state IN ('pending', 'approved') AND expires_at <= ?
     ORDER BY expires_at ASC, space_id ASC
     LIMIT ?
  ),
  expired_challenges AS MATERIALIZED (
    SELECT i.space_id, c.expires_at
      FROM invitation_challenges AS c INDEXED BY live_invitation_challenges_expiry
      JOIN invitations AS i ON i.id = c.invitation_id
     WHERE c.consumed_at IS NULL AND c.expires_at <= ?
     ORDER BY c.expires_at ASC, c.invitation_id ASC
     LIMIT ?
  ),
  bounded_candidates AS (
    SELECT space_id, expires_at FROM expired_invitations
    UNION ALL
    SELECT space_id, expires_at FROM expired_enrollments
    UNION ALL
    SELECT space_id, expires_at FROM expired_challenges
  )
  SELECT space_id AS id, MIN(expires_at) AS oldest_expiry
    FROM bounded_candidates
   GROUP BY space_id
   ORDER BY oldest_expiry ASC, space_id ASC
   LIMIT ?`;

function placeholders(count: number): string {
  return Array.from({ length: count }, () => "?").join(", ");
}

async function runOldestFirstChunks(
  capacity: number,
  chunkSize: number,
  runChunk: (limit: number) => Promise<D1Result<unknown>>,
): Promise<void> {
  let remaining = capacity;
  while (remaining > 0) {
    const limit = Math.min(chunkSize, remaining);
    const result = await runChunk(limit);
    if (result.meta.changes === 0) return;
    remaining -= limit;
  }
}

async function pairingExpiryCandidates(
  env: Env,
  now: number,
): Promise<string[]> {
  const result = await env.DB.prepare(PAIRING_EXPIRY_CANDIDATES_SQL).bind(
    now,
    CLEANUP_SPACE_LIMIT,
    now,
    CLEANUP_SPACE_LIMIT,
    now,
    CLEANUP_SPACE_LIMIT,
    CLEANUP_SPACE_LIMIT,
  ).all<SpaceIDRow>();
  return result.results.map((row) => row.id);
}

async function pendingDeletionCandidates(env: Env): Promise<string[]> {
  const result = await env.DB.prepare(
    `SELECT space_id AS id
       FROM space_deletion_jobs
      WHERE state = 'pending'
      ORDER BY created_at ASC, space_id ASC
      LIMIT ?`,
  ).bind(CLEANUP_SPACE_LIMIT).all<SpaceIDRow>();
  return result.results.map((row) => row.id);
}

async function inactiveSpaceCandidates(env: Env, now: number): Promise<string[]> {
  const result = await env.DB.prepare(
    `SELECT id
       FROM spaces
      WHERE state = 'active' AND metadata_expires_at <= ?
      ORDER BY metadata_expires_at ASC, id ASC
      LIMIT ?`,
  ).bind(now, CLEANUP_SPACE_LIMIT).all<SpaceIDRow>();
  return result.results.map((row) => row.id);
}

async function revokeAndPurgeSpaces(
  env: Env,
  spaceIds: readonly string[],
  now: number,
  markInactive: boolean,
): Promise<void> {
  if (spaceIds.length === 0) return;
  const ids = [...spaceIds];
  const inList = placeholders(ids.length);
  const statements: D1PreparedStatement[] = [];

  if (markInactive) {
    statements.push(
      env.DB.prepare(
        `UPDATE spaces
            SET state = 'revoked', revoked_at = ?
          WHERE id IN (${inList})
            AND state = 'active'
            AND metadata_expires_at <= ?`,
      ).bind(now, ...ids, now),
      env.DB.prepare(
        `INSERT INTO space_deletion_jobs(
           space_id, state, requires_object_deletion, created_at
         )
         SELECT id, 'pending',
                CASE WHEN EXISTS (
                  SELECT 1 FROM sharing_storage_scopes AS storage
                   WHERE storage.space_id = spaces.id
                ) THEN 1 ELSE 0 END,
                ?
           FROM spaces
          WHERE id IN (${inList})
            AND state = 'revoked'
            AND revoked_at = ?
         ON CONFLICT(space_id) DO UPDATE SET
           state = 'pending',
           requires_object_deletion = MAX(
             space_deletion_jobs.requires_object_deletion,
             excluded.requires_object_deletion
           ),
           created_at = excluded.created_at,
           completed_at = NULL,
           empty_sweep_started_at = NULL,
           last_sweep_at = NULL,
           sweep_count = 0`,
      ).bind(now, ...ids, now),
    );
  }

  statements.push(
    env.DB.prepare(
      `UPDATE sharing_sources
          SET state = 'revoked', updated_at = ?
        WHERE space_id IN (${inList})
          AND EXISTS (
            SELECT 1
              FROM space_deletion_jobs AS j
             WHERE j.space_id = sharing_sources.space_id AND j.state = 'pending'
          )`,
    ).bind(now, ...ids),
    env.DB.prepare(
      `UPDATE members
          SET state = 'revoked', revoked_at = COALESCE(revoked_at, ?)
        WHERE space_id IN (${inList})
          AND EXISTS (
            SELECT 1
              FROM space_deletion_jobs AS j
             WHERE j.space_id = members.space_id AND j.state = 'pending'
          )`,
    ).bind(now, ...ids),
    env.DB.prepare(
      `UPDATE invitations
          SET status = 'revoked', invite_proof_public_key = NULL
        WHERE space_id IN (${inList})
          AND status = 'open'
          AND EXISTS (
            SELECT 1
              FROM space_deletion_jobs AS j
             WHERE j.space_id = invitations.space_id AND j.state = 'pending'
          )`,
    ).bind(...ids),
    env.DB.prepare(
      `UPDATE enrollments
          SET state = 'revoked'
        WHERE space_id IN (${inList})
          AND state IN ('pending', 'approved')
          AND EXISTS (
            SELECT 1
              FROM space_deletion_jobs AS j
             WHERE j.space_id = enrollments.space_id AND j.state = 'pending'
          )`,
    ).bind(...ids),
    env.DB.prepare(
      `UPDATE approval_events
          SET key_envelope = NULL, approval_signature = NULL
        WHERE enrollment_id IN (
          SELECT e.id
            FROM enrollments AS e
            JOIN space_deletion_jobs AS j ON j.space_id = e.space_id
           WHERE e.space_id IN (${inList}) AND j.state = 'pending'
        )`,
    ).bind(...ids),
    env.DB.prepare(
      `DELETE FROM invitation_challenges
        WHERE invitation_id IN (
          SELECT i.id
            FROM invitations AS i
            JOIN space_deletion_jobs AS j ON j.space_id = i.space_id
           WHERE i.space_id IN (${inList}) AND j.state = 'pending'
        )`,
    ).bind(...ids),
    env.DB.prepare(
      `DELETE FROM spaces
        WHERE id IN (${inList})
          AND state = 'revoked'
          AND EXISTS (
            SELECT 1
              FROM space_deletion_jobs AS j
             WHERE j.space_id = spaces.id
               AND j.state = 'pending'
               AND j.requires_object_deletion = 0
          )`,
    ).bind(...ids),
    env.DB.prepare(
      `DELETE FROM space_deletion_jobs
        WHERE space_id IN (${inList})
          AND state = 'pending'
          AND requires_object_deletion = 0
          AND NOT EXISTS (
            SELECT 1 FROM spaces WHERE spaces.id = space_deletion_jobs.space_id
          )`,
    ).bind(...ids),
  );

  // One bounded candidate set is revoked and physically removed atomically.
  await env.DB.batch(statements);
}

async function closeExpiredSharingGenerations(env: Env, now: number): Promise<void> {
  await runOldestFirstChunks(
    CLEANUP_GENERATION_CLOSE_LIMIT,
    CLEANUP_GENERATION_CHUNK_SIZE,
    (limit) => env.DB.prepare(
      `INSERT INTO sharing_close_events(generation_id, reason, created_at)
       SELECT id, 'staging_expired', ?
         FROM sharing_generations INDEXED BY sharing_generations_staging_expiry
        WHERE state IN ('reserved', 'uploading', 'prepared')
          AND staging_expires_at <= ?
        ORDER BY staging_expires_at ASC, id ASC
        LIMIT ?`,
    ).bind(now, now, limit).run(),
  );

  await runOldestFirstChunks(
    CLEANUP_GENERATION_CLOSE_LIMIT,
    CLEANUP_GENERATION_CHUNK_SIZE,
    (limit) => env.DB.prepare(
      `INSERT INTO sharing_close_events(generation_id, reason, created_at)
       SELECT g.id, 'content_expired', ?
         FROM sharing_generations AS g INDEXED BY sharing_generations_content_expiry
         JOIN sharing_currents AS current ON current.generation_id = g.id
        WHERE g.state = 'committed' AND g.content_expires_at <= ?
        ORDER BY g.content_expires_at ASC, g.id ASC
        LIMIT ?`,
    ).bind(now, now, limit).run(),
  );
}

async function processExplicitObjectDeletions(env: Env, now: number): Promise<void> {
  if (env.MEDIA === undefined) return;
  let remaining = CLEANUP_OBJECT_LIMIT;
  while (remaining > 0) {
    const batchSize = Math.min(R2_DELETE_BATCH_SIZE, remaining);
    const rows = await env.DB.prepare(
      `SELECT object_key, attempts
         FROM sharing_object_deletions
        WHERE state = 'pending' AND not_before <= ?
        ORDER BY not_before ASC, created_at ASC, object_key ASC
        LIMIT ?`,
    ).bind(now, batchSize).all<{ object_key: string; attempts: number }>();
    if (rows.results.length === 0) return;

    // R2 multi-delete is strongly consistent and accepts at most 1,000 keys.
    // D1 is changed only after it succeeds. If D1 then fails, retrying the same
    // keys is harmless. The attempts CAS preserves a concurrently re-armed key.
    await env.MEDIA.delete(rows.results.map((row) => row.object_key));
    const statements: D1PreparedStatement[] = [];
    for (let offset = 0; offset < rows.results.length; offset += OBJECT_DELETE_CAS_TUPLE_LIMIT) {
      const chunk = rows.results.slice(offset, offset + OBJECT_DELETE_CAS_TUPLE_LIMIT);
      const tuples = chunk.map(() => "(?, ?)").join(", ");
      statements.push(env.DB.prepare(
        `DELETE FROM sharing_object_deletions
          WHERE state = 'pending'
            AND (object_key, attempts) IN (${tuples})`,
      ).bind(...chunk.flatMap((row) => [row.object_key, row.attempts])));
    }
    await env.DB.batch(statements);
    remaining -= rows.results.length;
    if (rows.results.length < batchSize) return;
  }
}

interface PrefixJobRow {
  space_id: string;
  object_prefix: string;
  created_at: number;
  empty_sweep_started_at: number | null;
}

async function processRevokedStorageScopes(env: Env, now: number): Promise<void> {
  if (env.MEDIA === undefined) return;
  const jobs = await env.DB.prepare(
    `SELECT job.space_id, storage.object_prefix, job.created_at,
            job.empty_sweep_started_at
       FROM space_deletion_jobs AS job
       JOIN sharing_storage_scopes AS storage ON storage.space_id = job.space_id
      WHERE job.state = 'pending' AND job.requires_object_deletion = 1
        AND job.created_at + ? <= ?
      ORDER BY job.created_at ASC, job.space_id ASC
      LIMIT ?`,
  ).bind(UPLOAD_CLOSE_GRACE_SECONDS, now, CLEANUP_REVOKED_SCOPE_LIMIT).all<PrefixJobRow>();

  if (jobs.results.length === 0) return;
  const jobSpaceIds = jobs.results.map((job) => job.space_id);
  const inList = placeholders(jobSpaceIds.length);
  await env.DB.batch([
    env.DB.prepare(
      `UPDATE sharing_generations
          SET state = 'expired', closed_at = COALESCE(closed_at, ?)
        WHERE space_id IN (${inList})
          AND state IN ('reserved', 'uploading', 'prepared', 'committed')
          AND EXISTS (
            SELECT 1 FROM space_deletion_jobs AS job
             WHERE job.space_id = sharing_generations.space_id
               AND job.state = 'pending' AND job.requires_object_deletion = 1
          )`,
    ).bind(now, ...jobSpaceIds),
    env.DB.prepare(
      `DELETE FROM sharing_currents
        WHERE source_id IN (
          SELECT source.id
            FROM sharing_sources AS source
            JOIN space_deletion_jobs AS job ON job.space_id = source.space_id
           WHERE source.space_id IN (${inList})
             AND job.state = 'pending' AND job.requires_object_deletion = 1
        )`,
    ).bind(...jobSpaceIds),
  ]);

  for (const job of jobs.results) {
    const prefix = `v1/${job.object_prefix}/`;
    const objects = await env.MEDIA.list({ prefix, limit: R2_PREFIX_LIST_LIMIT });
    if (objects.objects.length > 0) {
      await env.MEDIA.delete(objects.objects.map((object) => object.key));
      await env.DB.prepare(
        `UPDATE space_deletion_jobs
            SET empty_sweep_started_at = NULL, last_sweep_at = ?,
                sweep_count = sweep_count + 1
          WHERE space_id = ? AND state = 'pending'`,
      ).bind(now, job.space_id).run();
      continue;
    }

    if (job.empty_sweep_started_at === null) {
      await env.DB.prepare(
        `UPDATE space_deletion_jobs
            SET empty_sweep_started_at = ?, last_sweep_at = ?,
                sweep_count = sweep_count + 1
          WHERE space_id = ? AND state = 'pending'`,
      ).bind(now, now, job.space_id).run();
      continue;
    }
    if (now - job.empty_sweep_started_at >= EMPTY_PREFIX_CONFIRM_SECONDS) {
      await env.DB.batch([
        env.DB.prepare(
          "DELETE FROM sharing_object_deletions WHERE space_id = ?",
        ).bind(job.space_id),
        env.DB.prepare(
          `UPDATE space_deletion_jobs
              SET requires_object_deletion = 0, last_sweep_at = ?,
                  sweep_count = sweep_count + 1
            WHERE space_id = ? AND state = 'pending'`,
        ).bind(now, job.space_id),
      ]);
    }
  }
}

async function finalizeNormalSharingCleanup(env: Env, now: number): Promise<void> {
  await runOldestFirstChunks(
    CLEANUP_TERMINAL_GENERATION_LIMIT,
    CLEANUP_FINALIZE_CHUNK_SIZE,
    (limit) => env.DB.prepare(
      `DELETE FROM sharing_generations
        WHERE id IN (
          WITH terminal_candidates AS MATERIALIZED (
            SELECT id, manifest_object_key
              FROM sharing_generations INDEXED BY sharing_generations_terminal_cleanup
             WHERE state IN ('superseded', 'expired') AND closed_at IS NOT NULL
             ORDER BY closed_at ASC, id ASC
             LIMIT ?
          )
          SELECT candidate.id
            FROM terminal_candidates AS candidate
           WHERE NOT EXISTS (
               SELECT 1
                 FROM sharing_object_deletions AS deletion
                WHERE deletion.object_key = candidate.manifest_object_key
                   OR deletion.object_key IN (
                     SELECT object_key FROM sharing_generation_media
                      WHERE generation_id = candidate.id
                   )
             )
        )`,
    ).bind(limit).run(),
  );
  await runOldestFirstChunks(
    CLEANUP_SOURCE_UNBLOCK_LIMIT,
    CLEANUP_FINALIZE_CHUNK_SIZE,
    (limit) => env.DB.prepare(
      `UPDATE sharing_sources
          SET cleanup_blocked = 0, updated_at = ?
        WHERE id IN (
          WITH blocked_candidates AS MATERIALIZED (
            SELECT id
              FROM sharing_sources INDEXED BY sharing_sources_cleanup
             WHERE cleanup_blocked = 1 AND state = 'active'
             ORDER BY updated_at ASC, id ASC
             LIMIT ?
          )
          SELECT candidate.id
            FROM blocked_candidates AS candidate
           WHERE NOT EXISTS (
               SELECT 1 FROM sharing_object_deletions AS deletion
                WHERE deletion.source_id = candidate.id AND deletion.state = 'pending'
             )
        )`,
    ).bind(now, limit).run(),
  );
}

async function cleanupEphemeralRows(env: Env, now: number): Promise<void> {
  await runOldestFirstChunks(
    CLEANUP_NONCE_LIMIT,
    CLEANUP_NONCE_CHUNK_SIZE,
    (limit) => env.DB.prepare(
      `DELETE FROM request_nonces
        WHERE rowid IN (
          SELECT rowid
            FROM request_nonces
           WHERE expires_at <= ?
           ORDER BY expires_at ASC, member_id ASC, nonce ASC
           LIMIT ?
        )`,
    ).bind(now, limit).run(),
  );
  await runOldestFirstChunks(
    CLEANUP_IDEMPOTENCY_LIMIT,
    CLEANUP_IDEMPOTENCY_CHUNK_SIZE,
    (limit) => env.DB.prepare(
      `DELETE FROM idempotency_records
        WHERE rowid IN (
          SELECT rowid
            FROM idempotency_records
           WHERE expires_at <= ?
           ORDER BY expires_at ASC, operation ASC, actor_id ASC, client_request_id ASC
           LIMIT ?
        )`,
    ).bind(now, limit).run(),
  );
  await runOldestFirstChunks(
    CLEANUP_DAILY_FREEZE_LIMIT,
    CLEANUP_DAILY_FREEZE_CHUNK_SIZE,
    (limit) => env.DB.prepare(
      `DELETE FROM sharing_daily_freezes
        WHERE rowid IN (
          SELECT rowid
            FROM sharing_daily_freezes
           WHERE expires_at <= ?
           ORDER BY expires_at ASC, source_id ASC, share_day_key ASC
           LIMIT ?
        )`,
    ).bind(now, limit).run(),
  );
}

/**
 * Runs bounded, oldest-first retention work. A backlog is deliberately carried
 * into the next five-minute invocation instead of risking an unbounded transaction
 * that can roll back all privacy cleanup under abusive public space creation.
 */
export async function runLegacyScheduledCleanup(
  env: Env,
  now = Math.floor(Date.now() / 1000),
): Promise<void> {
  await cleanupEphemeralRows(env, now);
  await expireDeviceRecoveries(env, now);

  const pairingSpaceIds = await pairingExpiryCandidates(env, now);
  await expireStalePairingState(env, now, { spaceIds: pairingSpaceIds });

  const inactiveSpaceIds = await inactiveSpaceCandidates(env, now);
  await revokeAndPurgeSpaces(env, inactiveSpaceIds, now, true);

  await closeExpiredSharingGenerations(env, now);
  await processExplicitObjectDeletions(env, now);
  await processRevokedStorageScopes(env, now);
  await finalizeNormalSharingCleanup(env, now);

  // Once R2 cleanup has cleared the deletion gate, Phase 1 metadata can be
  // removed atomically with credentials already disabled.
  const queuedSpaceIds = await pendingDeletionCandidates(env);
  await revokeAndPurgeSpaces(env, queuedSpaceIds, now, false);
}

// Integration tests and local maintenance can run both deterministic phases
// together. Production dispatches them to separate cron invocations so v1 and
// v2 retention cannot exhaust each other's D1/subrequest budget.
export async function runScheduledCleanup(
  env: Env,
  now = Math.floor(Date.now() / 1000),
): Promise<void> {
  await runLegacyScheduledCleanup(env, now);
  await runMomentCleanup(env, now);
}
