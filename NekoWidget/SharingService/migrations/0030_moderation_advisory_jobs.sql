-- Disconnected advisory processing; no operator grant, disclosure permission,
-- case decision, notification, object access or runtime route is introduced.
-- LF only. Reports and the existing seven-day evidence lifetime own these rows.
CREATE TABLE moderation_advisory_jobs (
    job_id TEXT PRIMARY KEY CHECK (length(job_id) = 36),
    report_id TEXT NOT NULL REFERENCES moment_reports(id) ON DELETE CASCADE,
    case_reference_hmac TEXT NOT NULL REFERENCES moderation_operator_versioned_case_references(case_reference_hmac),
    case_reference_hmac_key_version INTEGER NOT NULL,
    evidence_version INTEGER NOT NULL CHECK (evidence_version BETWEEN 1 AND 2147483647),
    evidence_sha256 TEXT NOT NULL CHECK (length(evidence_sha256) = 64 AND evidence_sha256 NOT GLOB '*[^0-9a-f]*'),
    source_sha256 TEXT NOT NULL,
    source_committed_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL,
    safety_route TEXT NOT NULL CHECK (safety_route IN ('general_review','child_safety_hold','unreviewed')),
    request_sha256 TEXT CHECK (request_sha256 IS NULL OR (length(request_sha256) = 64 AND request_sha256 NOT GLOB '*[^0-9a-f]*')),
    policy TEXT NOT NULL CHECK (policy = 'neko-owner-advisory-v1'),
    created_at INTEGER NOT NULL DEFAULT (unixepoch()),
    UNIQUE(report_id, evidence_version),
    UNIQUE(report_id, evidence_sha256),
    CHECK ((safety_route = 'general_review') = (request_sha256 IS NOT NULL))
) STRICT;

-- This view is the DB-owned admission condition, also checked at completion.
-- A tombstone alone is not decryptable/live evidence. No TTL extension is made.
CREATE VIEW moderation_advisory_live_sources AS
SELECT r.id AS report_id, c.case_reference_hmac, c.case_reference_hmac_key_version,
       r.ciphertext_sha256 AS source_sha256, r.committed_at AS source_committed_at,
       r.content_expires_at AS expires_at
  FROM moment_reports AS r
  JOIN moment_report_tombstones AS t ON t.report_id = r.id
  JOIN moderation_cases AS m ON m.report_id = r.id
  JOIN moderation_operator_versioned_case_references AS c ON c.report_id = r.id
 WHERE r.state = 'committed' AND r.closed_at IS NULL
   AND r.content_expires_at > unixepoch()
   AND t.content_deleted_at IS NULL AND t.content_expires_at = r.content_expires_at
   AND t.committed_at = r.committed_at AND m.committed_at = r.committed_at
   AND NOT EXISTS (SELECT 1 FROM moderation_case_events AS e
                    WHERE e.report_id = r.id AND e.event_type = 'review_decided');

CREATE VIEW moderation_advisory_current_jobs AS
SELECT j.* FROM moderation_advisory_jobs AS j
  JOIN moderation_advisory_live_sources AS s
    ON s.report_id = j.report_id AND s.case_reference_hmac = j.case_reference_hmac
   AND s.case_reference_hmac_key_version = j.case_reference_hmac_key_version
   AND s.source_sha256 = j.source_sha256 AND s.source_committed_at = j.source_committed_at
   AND s.expires_at = j.expires_at
 WHERE j.evidence_version = (SELECT MAX(v.evidence_version)
                              FROM moderation_advisory_jobs AS v WHERE v.report_id = j.report_id);

CREATE TRIGGER moderation_advisory_job_admission
BEFORE INSERT ON moderation_advisory_jobs
BEGIN
    SELECT (CASE WHEN NEW.created_at <> unixepoch() OR EXISTS (
      SELECT 1 FROM moderation_advisory_jobs WHERE job_id = NEW.job_id
        OR (report_id = NEW.report_id AND evidence_sha256 = NEW.evidence_sha256)
    ) OR NOT EXISTS (
      SELECT 1 FROM moderation_advisory_live_sources AS s
       WHERE s.report_id = NEW.report_id AND s.case_reference_hmac = NEW.case_reference_hmac
         AND s.case_reference_hmac_key_version = NEW.case_reference_hmac_key_version
         AND s.source_sha256 = NEW.source_sha256 AND s.source_committed_at = NEW.source_committed_at
         AND s.expires_at = NEW.expires_at
    ) OR NEW.evidence_version <> COALESCE((SELECT MAX(evidence_version) FROM moderation_advisory_jobs
                                           WHERE report_id = NEW.report_id), 0) + 1
      THEN RAISE(ABORT, 'advisory evidence is not current') END);
END;
CREATE TRIGGER moderation_advisory_job_immutable BEFORE UPDATE ON moderation_advisory_jobs
BEGIN SELECT RAISE(ABORT, 'advisory job is immutable'); END;
CREATE TRIGGER moderation_advisory_job_retention BEFORE DELETE ON moderation_advisory_jobs
WHEN OLD.expires_at > unixepoch() AND EXISTS (
    SELECT 1 FROM moment_reports WHERE id = OLD.report_id AND state = 'committed' AND closed_at IS NULL
) AND EXISTS (SELECT 1 FROM moment_report_tombstones WHERE report_id = OLD.report_id AND content_deleted_at IS NULL)
  AND NOT EXISTS (SELECT 1 FROM moderation_case_events WHERE report_id = OLD.report_id AND event_type = 'review_decided')
BEGIN SELECT RAISE(ABORT, 'live advisory cannot be reset'); END;

CREATE TABLE moderation_advisory_attempts (
    job_id TEXT PRIMARY KEY REFERENCES moderation_advisory_jobs(job_id) ON DELETE CASCADE,
    attempt_id TEXT NOT NULL UNIQUE CHECK (length(attempt_id) = 36),
    started_at INTEGER NOT NULL DEFAULT (unixepoch()),
    expires_at INTEGER NOT NULL DEFAULT (unixepoch() + 30),
    CHECK (expires_at = started_at + 30)
) STRICT;
CREATE TRIGGER moderation_advisory_claim_current BEFORE INSERT ON moderation_advisory_attempts
BEGIN
    SELECT (CASE WHEN NEW.started_at <> unixepoch() OR NOT EXISTS (
      SELECT 1 FROM moderation_advisory_current_jobs WHERE job_id = NEW.job_id
    ) OR EXISTS (SELECT 1 FROM moderation_advisory_attempts WHERE job_id = NEW.job_id OR attempt_id = NEW.attempt_id)
      THEN RAISE(ABORT, 'advisory claim is not current') END);
END;
CREATE TRIGGER moderation_advisory_attempt_immutable BEFORE UPDATE ON moderation_advisory_attempts
BEGIN SELECT RAISE(ABORT, 'advisory attempt is immutable'); END;
CREATE TRIGGER moderation_advisory_attempt_no_reset BEFORE DELETE ON moderation_advisory_attempts
WHEN EXISTS (SELECT 1 FROM moderation_advisory_jobs WHERE job_id = OLD.job_id)
BEGIN SELECT RAISE(ABORT, 'advisory attempt cannot be reset'); END;

CREATE TABLE moderation_advisory_results (
    job_id TEXT PRIMARY KEY REFERENCES moderation_advisory_attempts(job_id) ON DELETE CASCADE,
    attempt_id TEXT NOT NULL UNIQUE REFERENCES moderation_advisory_attempts(attempt_id),
    recorded_at INTEGER NOT NULL DEFAULT (unixepoch()),
    result_json TEXT NOT NULL CHECK (json_valid(result_json) AND length(CAST(result_json AS BLOB)) <= 16384)
) STRICT;
CREATE TRIGGER moderation_advisory_result_current BEFORE INSERT ON moderation_advisory_results
BEGIN
    SELECT (CASE WHEN NEW.recorded_at <> unixepoch() OR EXISTS (
      SELECT 1 FROM moderation_advisory_results WHERE job_id = NEW.job_id OR attempt_id = NEW.attempt_id
    ) OR NOT EXISTS (
      SELECT 1 FROM moderation_advisory_current_jobs AS j
      JOIN moderation_advisory_attempts AS a ON a.job_id = j.job_id
       WHERE j.job_id = NEW.job_id AND a.attempt_id = NEW.attempt_id AND a.expires_at > unixepoch()
         AND json_extract(NEW.result_json, '$.case.caseReferenceHmac') = j.case_reference_hmac
         AND json_extract(NEW.result_json, '$.case.caseReferenceHmacKeyVersion') = j.case_reference_hmac_key_version
         AND json_extract(NEW.result_json, '$.case.evidenceVersion') = j.evidence_version
         AND json_extract(NEW.result_json, '$.case.evidenceSHA256') = j.evidence_sha256
         AND json_extract(NEW.result_json, '$.requestSHA256') IS j.request_sha256
         AND json_extract(NEW.result_json, '$.policy') = j.policy
         AND json_extract(NEW.result_json, '$.status') = 'owner_review_required'
         AND json_extract(NEW.result_json, '$.canCloseCase') = 0
         AND json_extract(NEW.result_json, '$.canDeleteContent') = 0
         AND json_extract(NEW.result_json, '$.canApproveAction') = 0
    ) THEN RAISE(ABORT, 'advisory result is stale or mismatched') END);
END;
CREATE TRIGGER moderation_advisory_result_immutable BEFORE UPDATE ON moderation_advisory_results
BEGIN SELECT RAISE(ABORT, 'advisory result is immutable'); END;
CREATE TRIGGER moderation_advisory_result_no_reset BEFORE DELETE ON moderation_advisory_results
WHEN EXISTS (SELECT 1 FROM moderation_advisory_jobs WHERE job_id = OLD.job_id)
BEGIN SELECT RAISE(ABORT, 'advisory result cannot be reset'); END;

CREATE TRIGGER moderation_advisory_report_closed AFTER UPDATE OF state, closed_at ON moment_reports
WHEN NEW.state <> 'committed' OR NEW.closed_at IS NOT NULL
BEGIN DELETE FROM moderation_advisory_jobs WHERE report_id = NEW.id; END;
CREATE TRIGGER moderation_advisory_content_deleted AFTER UPDATE OF content_deleted_at ON moment_report_tombstones
WHEN NEW.content_deleted_at IS NOT NULL
BEGIN DELETE FROM moderation_advisory_jobs WHERE report_id = NEW.report_id; END;
CREATE TRIGGER moderation_advisory_case_decided AFTER INSERT ON moderation_case_events
WHEN NEW.event_type = 'review_decided'
BEGIN DELETE FROM moderation_advisory_jobs WHERE report_id = NEW.report_id; END;
