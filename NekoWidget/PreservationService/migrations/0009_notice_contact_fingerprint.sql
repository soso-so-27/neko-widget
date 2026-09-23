-- The Apple address is encrypted. A domain-separated keyed fingerprint lets
-- repeated verification of the same address retain its delivery evidence.
-- Existing NULL rows are conservatively replaced on the next verified login.
-- If a legacy owner has a delivered final notice, this creates a one-time
-- re-notice rather than risking deletion after an unverified contact change.
ALTER TABLE pa_notice_contacts ADD COLUMN email_tag TEXT
  CHECK (email_tag IS NULL OR length(email_tag) = 64);

-- A genuinely changed recipient invalidates an already delivered final notice.
-- Keep the original deadline; the next delivered notice extends it by at least
-- 30 days if necessary. The provider event and old submission remain for audit.
CREATE TRIGGER pa_notice_contact_change_after_delivery
AFTER UPDATE OF email_tag ON pa_notice_contacts
WHEN OLD.email_tag IS NOT NEW.email_tag
BEGIN
  UPDATE pa_retention SET revision=revision+1,
    final_notice_delivered_at=NULL, final_notice_receipt=NULL,
    notice_not_before_at=MAX(notice_not_before_at,NEW.updated_at)
  WHERE owner_id=NEW.owner_id AND verified_status='expired'
    AND paused_at IS NULL AND final_notice_delivered_at IS NOT NULL;
END;

-- A missing contact re-established after delivery is also a new delivery
-- target. Otherwise the old receipt could suppress every future notice.
CREATE TRIGGER pa_notice_contact_insert_after_delivery
AFTER INSERT ON pa_notice_contacts
BEGIN
  UPDATE pa_retention SET revision=revision+1,
    final_notice_delivered_at=NULL, final_notice_receipt=NULL,
    notice_not_before_at=MAX(notice_not_before_at,NEW.updated_at)
  WHERE owner_id=NEW.owner_id AND verified_status='expired'
    AND paused_at IS NULL AND final_notice_delivered_at IS NOT NULL;
END;
