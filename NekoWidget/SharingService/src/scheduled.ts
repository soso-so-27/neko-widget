import type { Env } from "./env";
import { expireStalePairingState } from "./handlers";

// Leaves room under D1's 100 bound-parameter ceiling for timestamps.
export const CLEANUP_SPACE_LIMIT = 90;
export const CLEANUP_EPHEMERAL_ROW_LIMIT = 1_000;

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
         SELECT id, 'pending', 0, ?
           FROM spaces
          WHERE id IN (${inList})
            AND state = 'revoked'
            AND revoked_at = ?
         ON CONFLICT(space_id) DO NOTHING`,
      ).bind(now, ...ids, now),
    );
  }

  statements.push(
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

/**
 * Runs bounded, oldest-first retention work. A backlog is deliberately carried
 * into the next hourly invocation instead of risking an unbounded transaction
 * that can roll back all privacy cleanup under abusive public space creation.
 */
export async function runScheduledCleanup(
  env: Env,
  now = Math.floor(Date.now() / 1000),
): Promise<void> {
  await env.DB.batch([
    env.DB.prepare(
      `DELETE FROM request_nonces
        WHERE rowid IN (
          SELECT rowid
            FROM request_nonces
           WHERE expires_at <= ?
           ORDER BY expires_at ASC, member_id ASC, nonce ASC
           LIMIT ?
        )`,
    ).bind(now, CLEANUP_EPHEMERAL_ROW_LIMIT),
    env.DB.prepare(
      `DELETE FROM idempotency_records
        WHERE rowid IN (
          SELECT rowid
            FROM idempotency_records
           WHERE expires_at <= ?
           ORDER BY expires_at ASC, operation ASC, actor_id ASC, client_request_id ASC
           LIMIT ?
        )`,
    ).bind(now, CLEANUP_EPHEMERAL_ROW_LIMIT),
  ]);

  const pairingSpaceIds = await pairingExpiryCandidates(env, now);
  await expireStalePairingState(env, now, { spaceIds: pairingSpaceIds });

  // User-requested revocations are processed before inactivity expiry.
  const queuedSpaceIds = await pendingDeletionCandidates(env);
  await revokeAndPurgeSpaces(env, queuedSpaceIds, now, false);

  const inactiveSpaceIds = await inactiveSpaceCandidates(env, now);
  await revokeAndPurgeSpaces(env, inactiveSpaceIds, now, true);
}
