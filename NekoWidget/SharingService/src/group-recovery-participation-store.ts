import type { Env } from './env';
import { ApiError } from './errors';
import type { VerifiedGroupRoster } from './group-protocol';
import { verifyParticipation } from './group-recovery-participation';

/** Called inside the ordinary owner transition, never a server-generated
 * signature/backfill. Proofs and roster commit in the same guarded batch. */
export async function participationStatements(env: Env, value: unknown, next: VerifiedGroupRoster,
  previous?: VerifiedGroupRoster, newlyAdmitted?: string): Promise<D1PreparedStatement[]> {
  if (value === undefined) return []; // Legacy updates leave stale proofs unusable.
  const fail=()=>new ApiError(400,'invalid_participation','Invalid participation proof.');
  if (env.GROUP_RECOVERY_CATALOG_ENABLED!=='YES' || !['production','staging'].includes(env.ENVIRONMENT)
    || !Array.isArray(value) || value.length>6) throw fail();
  const environment=env.ENVIRONMENT as 'production'|'staging';
  const seen=new Set<string>(), statements:D1PreparedStatement[]=[];
  for (const raw of value) {
    if (!raw || typeof raw.personId!=='string' || seen.has(raw.personId)) throw fail();
    seen.add(raw.personId);
    const proof=await verifyParticipation(raw,next,environment,raw.personId);
    if (!proof) throw fail();
    if (!previous || proof.participantId===newlyAdmitted) {
      if (proof.admissionRevision!==next.packet.roster.revision) throw fail();
    } else {
      const row=await env.DB.prepare('SELECT proof_json FROM group_recovery_participation WHERE window_id=? AND person_id=?')
        .bind(proof.windowId,proof.personId).first<{proof_json:string}>();
      const old=row ? await verifyParticipation(JSON.parse(row.proof_json),previous,environment,proof.personId) : null;
      if (!old || old.admissionRevision!==proof.admissionRevision || old.participantId!==proof.participantId) throw fail();
    }
    statements.push(env.DB.prepare(`INSERT INTO group_recovery_participation VALUES (?,?,?,?,?)
      ON CONFLICT(window_id,person_id) DO UPDATE SET participant_id=excluded.participant_id,
      roster_hash=excluded.roster_hash,proof_json=excluded.proof_json`)
      .bind(proof.windowId,proof.personId,proof.participantId,proof.rosterHash,JSON.stringify(raw)));
  }
  return statements;
}
