import type { AuthenticatedModerationOperatorAccess } from "./moderation-operator-auth";

export interface Actor {
  operator_id: string;
  credential_id_sha256: string;
  public_key_cose: number[] | ArrayBuffer;
  sign_count: number;
  enrollment_admission_id: string;
}
// The newest admitted, unrevoked credential is the local candidate's credential
// epoch. A second query inside every transaction prevents role/alias/credential
// changes between the initial read and a write or protected metadata read.
export const actorSQL = `SELECT identity.operator_id, credential.credential_id_sha256,
    credential.public_key_cose, admission.enrollment_admission_id,
    (SELECT sign_count FROM moderation_operator_credential_counters
      WHERE credential_id_sha256 = credential.credential_id_sha256) AS sign_count
  FROM moderation_operator_subject_identities AS identity
  JOIN moderation_operator_enrollment_requests AS enrollment
    ON enrollment.target_operator_id = identity.operator_id
   AND enrollment.target_access_subject_hmac_key_version = identity.access_subject_hmac_key_version
   AND enrollment.target_access_subject_hmac = identity.access_subject_hmac
  JOIN moderation_operator_enrollment_admissions AS admission
    ON admission.enrollment_request_id = enrollment.enrollment_request_id
  JOIN moderation_operator_credentials AS credential
    ON credential.credential_id_sha256 = enrollment.target_credential_id_sha256
   AND credential.operator_id = identity.operator_id
   AND credential.public_key_cose = enrollment.target_public_key_cose_snapshot
   AND credential.registration_sign_count = enrollment.target_registration_sign_count
  WHERE identity.access_subject_hmac = ? AND identity.access_subject_hmac_key_version = ?
    AND NOT EXISTS (SELECT 1 FROM moderation_operator_subject_identities AS newer
      WHERE newer.operator_id = identity.operator_id
        AND newer.access_subject_hmac_key_version > identity.access_subject_hmac_key_version)
    AND EXISTS (SELECT 1 FROM moderation_operator_state_events
      WHERE operator_id = identity.operator_id AND event_type = 'activated')
    AND NOT EXISTS (SELECT 1 FROM moderation_operator_state_events
      WHERE operator_id = identity.operator_id AND event_type = 'revoked')
    AND EXISTS (SELECT 1 FROM moderation_operator_role_events
      WHERE operator_id = identity.operator_id AND role_code = 'triage' AND event_type = 'granted')
    AND NOT EXISTS (SELECT 1 FROM moderation_operator_role_events
      WHERE operator_id = identity.operator_id AND role_code = 'triage' AND event_type = 'revoked')
    AND EXISTS (SELECT 1 FROM moderation_operator_credential_events
      WHERE credential_id_sha256 = credential.credential_id_sha256 AND event_type = 'registered')
    AND NOT EXISTS (SELECT 1 FROM moderation_operator_credential_events
      WHERE credential_id_sha256 = credential.credential_id_sha256 AND event_type = 'revoked')
    AND NOT EXISTS (SELECT 1 FROM moderation_operator_enrollment_admissions AS newer_admission
      JOIN moderation_operator_enrollment_requests AS newer_enrollment
        ON newer_enrollment.enrollment_request_id = newer_admission.enrollment_request_id
      WHERE newer_enrollment.target_operator_id = identity.operator_id
        AND newer_admission.rowid > admission.rowid)
  ORDER BY admission.rowid DESC LIMIT 1`;

export function guard(db: D1Database, access: AuthenticatedModerationOperatorAccess, actor: Actor): D1PreparedStatement {
  // SQLite json() deliberately raises on denial so D1 rolls back the entire
  // batch. A SELECT returning zero rows would silently permit later statements.
  return db.prepare(`WITH current_actor AS (${actorSQL})
    SELECT json(CASE WHEN EXISTS (SELECT 1 FROM current_actor
      WHERE operator_id = ? AND credential_id_sha256 = ? AND enrollment_admission_id = ?)
      AND ? <= unixepoch() AND ? > unixepoch() THEN 'true' ELSE 'denied' END) AS admitted`)
    .bind(access.operatorSubjectHmac, access.subjectHmacKeyVersion,
      actor.operator_id, actor.credential_id_sha256, actor.enrollment_admission_id,
      access.issuedAt, access.expiresAt);
}
export function admitSession(db: D1Database, access: AuthenticatedModerationOperatorAccess, actor: Actor): D1PreparedStatement {
  return db.prepare(`INSERT INTO moderation_operator_access_sessions(
    access_session_sha256, operator_id, access_subject_hmac_key_version, access_subject_hmac,
    token_issued_at, token_expires_at)
    SELECT ?, ?, ?, ?, ?, ? WHERE NOT EXISTS (SELECT 1 FROM moderation_operator_access_sessions WHERE access_session_sha256 = ?)`)
    .bind(access.accessSessionSHA256, actor.operator_id, access.subjectHmacKeyVersion,
      access.operatorSubjectHmac, access.issuedAt, access.expiresAt, access.accessSessionSHA256);
}
