import { MODERATION_ADVISORY_POLICY, prepareModerationAdvisory,
  type ModerationAdvisoryCase, type ModerationAdvisoryInput, type ModerationAdvisoryResult } from "./moderation-ai-advisory";
import { requestModerationAdvisory } from "./moderation-ai-transport";

type Reference = Pick<ModerationAdvisoryCase, "caseReferenceHmac" | "caseReferenceHmacKeyVersion">;
type Evidence = Omit<ModerationAdvisoryInput, "case">;
interface Source {
  report_id: string; case_reference_hmac: string; case_reference_hmac_key_version: number;
  source_sha256: string; source_committed_at: number; expires_at: number;
}
interface Job extends Source {
  job_id: string; evidence_version: number; evidence_sha256: string;
  request_sha256: string | null; safety_route: Evidence["safetyRoute"];
}
export interface DurableAdvisoryOutcome {
  status: "owner_review_required";
  state: "recorded" | "queued" | "already_claimed" | "stale" | "unavailable";
  // Only returned for current evidence. No raw source, object key or report ID.
  jobId?: string;
  advisory?: ModerationAdvisoryResult;
}
const outcome = (state: DurableAdvisoryOutcome["state"]): DurableAdvisoryOutcome => ({status: "owner_review_required", state});
function binding(job: Job): ModerationAdvisoryCase {
  return {caseReferenceHmac: job.case_reference_hmac, caseReferenceHmacKeyVersion: job.case_reference_hmac_key_version,
    evidenceVersion: job.evidence_version, evidenceSHA256: job.evidence_sha256};
}
async function digest(value: unknown): Promise<string> {
  return [...new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(JSON.stringify(value))))]
    .map(byte => byte.toString(16).padStart(2, "0")).join("");
}

/** Trusted LOCAL integration entry, not an HTTP endpoint or disclosure grant.
 * Caller must authenticate/admit the owner, decrypt only this report, minimize
 * and screen evidence, and obtain data-use authorization BEFORE entry. This
 * module cannot prove that the supplied plaintext came from the report.
 * Evidence version means an advisory-input edition, not an object mutation.
 * Claim is durable before network: crash/unknown never automatically resends.
 * No Worker imports this module. No secret, photo, plaintext or provider body
 * is persisted; the report's existing deletion/expiry owns derived results.
 */
export async function runDurableModerationAdvisory(
  db: D1Database, reference: Reference, evidence: Evidence,
  transport: {apiKey: string; signal?: AbortSignal},
): Promise<DurableAdvisoryOutcome> {
  // Own all mutable inputs before the first await; never re-read caller bytes.
  const ref = {...reference};
  if (Object.keys(ref).length !== 2 || Object.keys(evidence).some(key => !["safetyRoute", "text", "jpeg"].includes(key))
    || (evidence.jpeg !== undefined && (!(evidence.jpeg instanceof Uint8Array) || evidence.jpeg.byteLength > 1_048_576))) {
    throw new Error("moderation_advisory_input_invalid");
  }
  const input: ModerationAdvisoryInput = {
    case: {...ref, evidenceVersion: 1, evidenceSHA256: "0".repeat(64)}, safetyRoute: evidence.safetyRoute,
    ...(evidence.text === undefined ? {} : {text: evidence.text}),
    ...(evidence.jpeg === undefined ? {} : {jpeg: new Uint8Array(evidence.jpeg)}),
  };
  const options = {...transport};
  const prepared = await prepareModerationAdvisory(input, Date.now());
  const requestSHA = prepared.requestSHA256;
  try {
    const source = await db.prepare(`SELECT * FROM moderation_advisory_live_sources
      WHERE case_reference_hmac=? AND case_reference_hmac_key_version=?`)
      .bind(ref.caseReferenceHmac, ref.caseReferenceHmacKeyVersion).first<Source>();
    if (!source) return outcome("stale");
    const evidenceSHA = await digest(["NW.MODERATION.ADVISORY-EDITION", MODERATION_ADVISORY_POLICY,
      ref.caseReferenceHmacKeyVersion, ref.caseReferenceHmac, source.source_sha256, source.source_committed_at,
      source.expires_at, input.safetyRoute, requestSHA]);
    const created = await db.batch([
      db.prepare(`INSERT INTO moderation_advisory_jobs(job_id,report_id,case_reference_hmac,case_reference_hmac_key_version,
        evidence_version,evidence_sha256,source_sha256,source_committed_at,expires_at,safety_route,request_sha256,policy)
        SELECT ?,?,?,?,COALESCE((SELECT MAX(evidence_version) FROM moderation_advisory_jobs WHERE report_id=?),0)+1,?,?,?,?,?,?,?
        WHERE NOT EXISTS (SELECT 1 FROM moderation_advisory_jobs WHERE report_id=? AND evidence_sha256=?)`)
        .bind(crypto.randomUUID(), source.report_id, ref.caseReferenceHmac, ref.caseReferenceHmacKeyVersion,
          source.report_id, evidenceSHA, source.source_sha256, source.source_committed_at, source.expires_at,
          input.safetyRoute, requestSHA, MODERATION_ADVISORY_POLICY, source.report_id, evidenceSHA),
      db.prepare("SELECT * FROM moderation_advisory_current_jobs WHERE report_id=? AND evidence_sha256=?")
        .bind(source.report_id, evidenceSHA),
    ]);
    const job = created[1]!.results[0] as unknown as Job | undefined;
    if (!job) return outcome("stale");
    const attempt = crypto.randomUUID();
    const claimed = await db.prepare(`INSERT INTO moderation_advisory_attempts(job_id,attempt_id)
      SELECT job_id,? FROM moderation_advisory_current_jobs WHERE job_id=?
      AND NOT EXISTS (SELECT 1 FROM moderation_advisory_attempts WHERE job_id=?)`)
      .bind(attempt, job.job_id, job.job_id).run();
    if (claimed.meta.changes !== 1) {
      const current = await readDurableModerationAdvisory(db, ref);
      return current.jobId === job.job_id ? current : outcome("stale");
    }
    input.case = binding(job);
    const advisory = await requestModerationAdvisory(input, {...options, readCurrentCase: async () => {
      const current = await db.prepare(`SELECT j.* FROM moderation_advisory_current_jobs AS j
        JOIN moderation_advisory_attempts AS a ON a.job_id=j.job_id
        WHERE j.job_id=? AND a.attempt_id=? AND a.expires_at>unixepoch()`)
        .bind(job.job_id, attempt).first<Job>();
      return current ? binding(current) : null;
    }});
    // The final DB statement checks current source/version AND the winning
    // attempt. A successful HTTP response alone never becomes durable success.
    const saved = await db.prepare(`INSERT INTO moderation_advisory_results(job_id,attempt_id,result_json)
      SELECT j.job_id,?,? FROM moderation_advisory_current_jobs AS j
      JOIN moderation_advisory_attempts AS a ON a.job_id=j.job_id
      WHERE j.job_id=? AND a.attempt_id=? AND a.expires_at>unixepoch()`)
      .bind(attempt, JSON.stringify(advisory), job.job_id, attempt).run();
    if (saved.meta.changes !== 1) return outcome("stale");
    // Re-read through the live view; a concurrently superseded result is hidden.
    const current = await readDurableModerationAdvisory(db, ref);
    return current.jobId === job.job_id ? current : outcome("stale");
  } catch {
    // Errors do not leak credentials/report content or pretend to close a case.
    // The durable claim, if made, stays unresolved and cannot be retried.
    return outcome("unavailable");
  }
}

/** Internal owner-queue adapter only; authentication belongs to future route. */
export async function readDurableModerationAdvisory(db: D1Database, reference: Reference): Promise<DurableAdvisoryOutcome> {
  const row = await db.prepare(`SELECT j.job_id,r.result_json,a.attempt_id FROM moderation_advisory_current_jobs AS j
    LEFT JOIN moderation_advisory_attempts AS a ON a.job_id=j.job_id
    LEFT JOIN moderation_advisory_results AS r ON r.job_id=j.job_id
    WHERE j.case_reference_hmac=? AND j.case_reference_hmac_key_version=?`)
    .bind(reference.caseReferenceHmac, reference.caseReferenceHmacKeyVersion)
    .first<{job_id: string; result_json: string | null; attempt_id: string | null}>();
  if (!row) return outcome("stale");
  return {status: "owner_review_required", state: row.result_json ? "recorded" : row.attempt_id ? "already_claimed" : "queued", jobId: row.job_id,
    ...(row.result_json ? {advisory: JSON.parse(row.result_json) as ModerationAdvisoryResult} : {})};
}

/** Local cleanup primitive. Must be scheduled before live deployment; reads
 * already fail closed at expiry even if cleanup hasn't run. No report deletion. */
export async function purgeExpiredModerationAdvisories(db: D1Database): Promise<number> {
  const result = await db.prepare(`DELETE FROM moderation_advisory_jobs WHERE job_id IN (
    SELECT job_id FROM moderation_advisory_jobs WHERE expires_at<=unixepoch() ORDER BY expires_at,job_id LIMIT 100)
    RETURNING job_id`).all<{job_id: string}>();
  // D1 meta.changes includes cascading attempt/result deletions. Report jobs,
  // not all physical rows, so callers can correctly bound/drain cleanup work.
  return result.results.length;
}
