-- v1 recipient tags were global to an address and predated accepted-at evidence.
-- They are not safe proof for expiry. Keep event IDs for audit, but make old
-- recipient tags unlinkable and require a fresh v2 notice before any deletion.
ALTER TABLE pa_notice_submissions ADD COLUMN evidence_version INTEGER NOT NULL DEFAULT 1
  CHECK (evidence_version IN (1,2));
ALTER TABLE pa_notice_claims ADD COLUMN evidence_version INTEGER NOT NULL DEFAULT 1
  CHECK (evidence_version IN (1,2));

UPDATE pa_notice_submissions SET recipient_tag=lower(hex(randomblob(32)))
  WHERE evidence_version=1;
UPDATE pa_notice_claims SET recipient_tag=lower(hex(randomblob(32)))
  WHERE evidence_version=1;

-- A prior receipt must not suppress replacement notice review. Existing
-- deadlines are never shortened; the next verified delivery extends them by
-- at least 30 days. No record, photo, or submission is deleted here.
UPDATE pa_retention SET revision=revision+1,
  final_notice_delivered_at=NULL,final_notice_receipt=NULL,
  notice_not_before_at=MAX(notice_not_before_at,CAST(unixepoch('now') AS INTEGER)*1000)
  WHERE final_notice_delivered_at IS NOT NULL;

-- During a rolling deployment an old Worker must not re-create v1 tags or
-- promote an in-flight v1 event after the receipt reset above. Old audit rows
-- remain readable; only new or changed evidence must be v2.
CREATE TRIGGER pa_notice_claim_v2_insert BEFORE INSERT ON pa_notice_claims
WHEN NEW.evidence_version<>2 BEGIN SELECT RAISE(ABORT,'notice claim v2 required'); END;
CREATE TRIGGER pa_notice_claim_v2_update BEFORE UPDATE ON pa_notice_claims
WHEN NEW.evidence_version<>2 BEGIN SELECT RAISE(ABORT,'notice claim v2 required'); END;
CREATE TRIGGER pa_notice_submission_v2_insert BEFORE INSERT ON pa_notice_submissions
WHEN NEW.evidence_version<>2 BEGIN SELECT RAISE(ABORT,'notice evidence v2 required'); END;
CREATE TRIGGER pa_notice_submission_v2_update BEFORE UPDATE ON pa_notice_submissions
WHEN NEW.evidence_version<>2 BEGIN SELECT RAISE(ABORT,'notice evidence v2 required'); END;
CREATE TRIGGER pa_legacy_notice_receipt_guard BEFORE UPDATE OF final_notice_receipt ON pa_retention
WHEN NEW.final_notice_receipt IS NOT NULL AND EXISTS (
  SELECT 1 FROM pa_notice_submissions s WHERE s.delivery_event_id=NEW.final_notice_receipt
    AND s.owner_id=NEW.owner_id AND s.evidence_version<>2
) BEGIN SELECT RAISE(ABORT,'legacy notice receipt cannot be promoted'); END;
