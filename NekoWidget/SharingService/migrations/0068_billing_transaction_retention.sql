-- B8: independent R2 receipts must be published before these local fences.
-- This migration enables no runtime or external operation.
PRAGMA foreign_keys=ON;
CREATE TABLE billing_retention_checkpoint(
 singleton INTEGER PRIMARY KEY CHECK(singleton=1),
 applied_sequence INTEGER NOT NULL CHECK(applied_sequence>=0)
) STRICT;
INSERT INTO billing_retention_checkpoint VALUES(1,0);
CREATE TABLE billing_retention_requests(
 request_id TEXT PRIMARY KEY,
 sequence INTEGER NOT NULL UNIQUE CHECK(sequence>0),
 billing_account_id TEXT NOT NULL,
 receipt_hash TEXT NOT NULL CHECK(length(receipt_hash)=43),
 reason TEXT NOT NULL CHECK(reason IN('subscription-ended','account-deletion')),
 requested_at_ms INTEGER NOT NULL CHECK(requested_at_ms>0),
 ended_at_ms INTEGER,
 cutoff_ms INTEGER NOT NULL CHECK(cutoff_ms>0 AND cutoff_ms<=requested_at_ms),
 facts_hash TEXT NOT NULL CHECK(length(facts_hash)=43),
 expected_revision INTEGER NOT NULL CHECK(expected_revision>=0),
 state TEXT NOT NULL CHECK(state IN('deleting','completed','canceled')),
 completed_at_ms INTEGER,
 receipt_recorded INTEGER NOT NULL DEFAULT 0 CHECK(receipt_recorded IN(0,1)),
 CHECK((state IN('deleting','canceled') AND completed_at_ms IS NULL) OR (state='completed' AND completed_at_ms>=requested_at_ms))
) STRICT;
CREATE INDEX billing_retention_pending ON billing_retention_requests(state,sequence);
CREATE TABLE billing_retention_fences(
 billing_account_id TEXT PRIMARY KEY,
 sequence INTEGER NOT NULL UNIQUE REFERENCES billing_retention_requests(sequence) ON DELETE RESTRICT,
 state TEXT NOT NULL CHECK(state IN('deleting','closed','recovering','active')),
 cutoff_ms INTEGER NOT NULL CHECK(cutoff_ms>0),
 recovery_environment TEXT CHECK(recovery_environment IN('Production','Sandbox')),
 recovery_lineage_hash TEXT,
 recovery_transaction_hash TEXT,
 recovery_request_id TEXT,
 CHECK((state IN('deleting','closed') AND recovery_environment IS NULL
  AND recovery_lineage_hash IS NULL AND recovery_transaction_hash IS NULL AND recovery_request_id IS NULL)
  OR (state IN('recovering','active') AND recovery_environment IS NOT NULL
   AND length(recovery_lineage_hash)=43 AND length(recovery_transaction_hash)=43 AND recovery_request_id IS NOT NULL))
) STRICT;
CREATE TRIGGER billing_retention_requests_identity_immutable BEFORE UPDATE ON billing_retention_requests
WHEN NEW.request_id<>OLD.request_id OR NEW.sequence<>OLD.sequence OR NEW.billing_account_id<>OLD.billing_account_id
 OR NEW.receipt_hash<>OLD.receipt_hash OR NEW.reason<>OLD.reason OR NEW.requested_at_ms<>OLD.requested_at_ms
 OR NEW.ended_at_ms IS NOT OLD.ended_at_ms OR NEW.cutoff_ms<>OLD.cutoff_ms OR NEW.facts_hash<>OLD.facts_hash OR NEW.expected_revision<>OLD.expected_revision
BEGIN SELECT RAISE(ABORT,'billing retention request identity immutable'); END;
CREATE TRIGGER billing_retention_requests_no_delete BEFORE DELETE ON billing_retention_requests
BEGIN SELECT RAISE(ABORT,'billing retention receipts cannot be deleted'); END;
CREATE TRIGGER billing_retention_fences_no_delete BEFORE DELETE ON billing_retention_fences
BEGIN SELECT RAISE(ABORT,'billing retention fence cannot be deleted'); END;

DROP TRIGGER billing_account_apple_identities_cannot_be_deleted;
CREATE TRIGGER billing_account_apple_identities_cannot_be_deleted
BEFORE DELETE ON billing_account_apple_identities
WHEN NOT EXISTS(SELECT 1 FROM billing_retention_fences f JOIN billing_retention_requests r ON r.sequence=f.sequence WHERE f.billing_account_id=OLD.billing_account_id AND f.state='deleting' AND r.state='deleting')
BEGIN SELECT RAISE(ABORT, 'billing Apple identities cannot be deleted'); END;

CREATE TRIGGER billing_account_apple_identities_retention_insert_guard BEFORE INSERT ON billing_account_apple_identities
WHEN EXISTS(SELECT 1 FROM billing_retention_fences WHERE billing_account_id=NEW.billing_account_id AND state IN('deleting','closed'))
BEGIN SELECT RAISE(ABORT,'billing account is fenced for deletion'); END;

CREATE TRIGGER billing_account_apple_identities_retention_update_guard BEFORE UPDATE ON billing_account_apple_identities
WHEN EXISTS(SELECT 1 FROM billing_retention_fences WHERE billing_account_id=NEW.billing_account_id AND state IN('deleting','closed'))
BEGIN SELECT RAISE(ABORT,'billing account is fenced for deletion'); END;

DROP TRIGGER billing_account_recovery_requests_cannot_be_deleted;
CREATE TRIGGER billing_account_recovery_requests_cannot_be_deleted
BEFORE DELETE ON billing_account_recovery_requests
WHEN NOT EXISTS(SELECT 1 FROM billing_retention_fences f JOIN billing_retention_requests r ON r.sequence=f.sequence WHERE f.billing_account_id=OLD.billing_account_id AND f.state='deleting' AND r.state='deleting')
BEGIN SELECT RAISE(ABORT, 'billing recovery requests cannot be deleted'); END;

CREATE TRIGGER billing_account_recovery_requests_retention_insert_guard BEFORE INSERT ON billing_account_recovery_requests
WHEN EXISTS(SELECT 1 FROM billing_retention_fences WHERE billing_account_id=NEW.billing_account_id AND state IN('deleting','closed'))
BEGIN SELECT RAISE(ABORT,'billing account is fenced for deletion'); END;

CREATE TRIGGER billing_account_recovery_requests_retention_update_guard BEFORE UPDATE ON billing_account_recovery_requests
WHEN EXISTS(SELECT 1 FROM billing_retention_fences WHERE billing_account_id=NEW.billing_account_id AND state IN('deleting','closed'))
BEGIN SELECT RAISE(ABORT,'billing account is fenced for deletion'); END;

DROP TRIGGER billing_transaction_events_cannot_be_deleted;
CREATE TRIGGER billing_transaction_events_cannot_be_deleted
BEFORE DELETE ON billing_transaction_events
WHEN NOT EXISTS(SELECT 1 FROM billing_retention_fences f JOIN billing_retention_requests r ON r.sequence=f.sequence WHERE f.billing_account_id=OLD.billing_account_id AND f.state='deleting' AND r.state='deleting')
BEGIN SELECT RAISE(ABORT, 'billing transaction events cannot be deleted'); END;

CREATE TRIGGER billing_transaction_events_retention_insert_guard BEFORE INSERT ON billing_transaction_events
WHEN EXISTS(SELECT 1 FROM billing_retention_fences WHERE billing_account_id=NEW.billing_account_id AND state IN('deleting','closed'))
BEGIN SELECT RAISE(ABORT,'billing account is fenced for deletion'); END;

CREATE TRIGGER billing_transaction_events_retention_update_guard BEFORE UPDATE ON billing_transaction_events
WHEN EXISTS(SELECT 1 FROM billing_retention_fences WHERE billing_account_id=NEW.billing_account_id AND state IN('deleting','closed'))
BEGIN SELECT RAISE(ABORT,'billing account is fenced for deletion'); END;

DROP TRIGGER billing_apple_notification_events_cannot_be_deleted;
CREATE TRIGGER billing_apple_notification_events_cannot_be_deleted
BEFORE DELETE ON billing_apple_notification_events
WHEN NOT EXISTS(SELECT 1 FROM billing_retention_fences f JOIN billing_retention_requests r ON r.sequence=f.sequence WHERE f.billing_account_id=OLD.billing_account_id AND f.state='deleting' AND r.state='deleting')
BEGIN SELECT RAISE(ABORT, 'billing Apple notification events cannot be deleted'); END;

CREATE TRIGGER billing_apple_notification_events_retention_insert_guard BEFORE INSERT ON billing_apple_notification_events
WHEN EXISTS(SELECT 1 FROM billing_retention_fences WHERE billing_account_id=NEW.billing_account_id AND state IN('deleting','closed'))
BEGIN SELECT RAISE(ABORT,'billing account is fenced for deletion'); END;

CREATE TRIGGER billing_apple_notification_events_retention_update_guard BEFORE UPDATE ON billing_apple_notification_events
WHEN EXISTS(SELECT 1 FROM billing_retention_fences WHERE billing_account_id=NEW.billing_account_id AND state IN('deleting','closed'))
BEGIN SELECT RAISE(ABORT,'billing account is fenced for deletion'); END;

DROP TRIGGER billing_authority_observations_cannot_be_deleted;
CREATE TRIGGER billing_authority_observations_cannot_be_deleted
BEFORE DELETE ON billing_subscription_authority_observations
WHEN NOT EXISTS(SELECT 1 FROM billing_retention_fences f JOIN billing_retention_requests r ON r.sequence=f.sequence WHERE f.billing_account_id=OLD.billing_account_id AND f.state='deleting' AND r.state='deleting')
BEGIN SELECT RAISE(ABORT, 'billing authority observations cannot be deleted'); END;

CREATE TRIGGER billing_subscription_authority_observations_retention_insert_guard BEFORE INSERT ON billing_subscription_authority_observations
WHEN EXISTS(SELECT 1 FROM billing_retention_fences WHERE billing_account_id=NEW.billing_account_id AND state IN('deleting','closed'))
BEGIN SELECT RAISE(ABORT,'billing account is fenced for deletion'); END;

CREATE TRIGGER billing_subscription_authority_observations_retention_update_guard BEFORE UPDATE ON billing_subscription_authority_observations
WHEN EXISTS(SELECT 1 FROM billing_retention_fences WHERE billing_account_id=NEW.billing_account_id AND state IN('deleting','closed'))
BEGIN SELECT RAISE(ABORT,'billing account is fenced for deletion'); END;

DROP TRIGGER billing_entitlement_decisions_cannot_be_deleted;
CREATE TRIGGER billing_entitlement_decisions_cannot_be_deleted
BEFORE DELETE ON billing_effective_entitlement_decisions
WHEN NOT EXISTS(SELECT 1 FROM billing_retention_fences f JOIN billing_retention_requests r ON r.sequence=f.sequence WHERE f.billing_account_id=OLD.billing_account_id AND f.state='deleting' AND r.state='deleting')
BEGIN SELECT RAISE(ABORT, 'billing entitlement decisions cannot be deleted'); END;

CREATE TRIGGER billing_effective_entitlement_decisions_retention_insert_guard BEFORE INSERT ON billing_effective_entitlement_decisions
WHEN EXISTS(SELECT 1 FROM billing_retention_fences WHERE billing_account_id=NEW.billing_account_id AND state IN('deleting','closed'))
BEGIN SELECT RAISE(ABORT,'billing account is fenced for deletion'); END;

CREATE TRIGGER billing_effective_entitlement_decisions_retention_update_guard BEFORE UPDATE ON billing_effective_entitlement_decisions
WHEN EXISTS(SELECT 1 FROM billing_retention_fences WHERE billing_account_id=NEW.billing_account_id AND state IN('deleting','closed'))
BEGIN SELECT RAISE(ABORT,'billing account is fenced for deletion'); END;

CREATE TRIGGER billing_effective_entitlement_current_retention_delete_guard BEFORE DELETE ON billing_effective_entitlement_current
WHEN EXISTS(SELECT 1 FROM billing_retention_fences WHERE billing_account_id=OLD.billing_account_id AND state<>'active') AND NOT EXISTS(SELECT 1 FROM billing_retention_fences f JOIN billing_retention_requests r ON r.sequence=f.sequence WHERE f.billing_account_id=OLD.billing_account_id AND f.state='deleting' AND r.state='deleting')
BEGIN SELECT RAISE(ABORT,'billing retention deletion requires current ticket'); END;

CREATE TRIGGER billing_effective_entitlement_current_retention_insert_guard BEFORE INSERT ON billing_effective_entitlement_current
WHEN EXISTS(SELECT 1 FROM billing_retention_fences WHERE billing_account_id=NEW.billing_account_id AND state IN('deleting','closed'))
BEGIN SELECT RAISE(ABORT,'billing account is fenced for deletion'); END;

CREATE TRIGGER billing_effective_entitlement_current_retention_update_guard BEFORE UPDATE ON billing_effective_entitlement_current
WHEN EXISTS(SELECT 1 FROM billing_retention_fences WHERE billing_account_id=NEW.billing_account_id AND state IN('deleting','closed'))
BEGIN SELECT RAISE(ABORT,'billing account is fenced for deletion'); END;

DROP TRIGGER billing_transaction_lineages_cannot_be_deleted;
CREATE TRIGGER billing_transaction_lineages_cannot_be_deleted
BEFORE DELETE ON billing_transaction_lineages
WHEN NOT EXISTS(SELECT 1 FROM billing_retention_fences f JOIN billing_retention_requests r ON r.sequence=f.sequence WHERE f.billing_account_id=OLD.billing_account_id AND f.state='deleting' AND r.state='deleting')
BEGIN SELECT RAISE(ABORT, 'billing transaction lineages cannot be deleted'); END;

CREATE TRIGGER billing_transaction_lineages_retention_insert_guard BEFORE INSERT ON billing_transaction_lineages
WHEN EXISTS(SELECT 1 FROM billing_retention_fences WHERE billing_account_id=NEW.billing_account_id AND state IN('deleting','closed'))
BEGIN SELECT RAISE(ABORT,'billing account is fenced for deletion'); END;

CREATE TRIGGER billing_transaction_lineages_retention_update_guard BEFORE UPDATE ON billing_transaction_lineages
WHEN EXISTS(SELECT 1 FROM billing_retention_fences WHERE billing_account_id=NEW.billing_account_id AND state IN('deleting','closed'))
BEGIN SELECT RAISE(ABORT,'billing account is fenced for deletion'); END;

DROP TRIGGER billing_window_sponsorship_requests_cannot_be_deleted;
CREATE TRIGGER billing_window_sponsorship_requests_cannot_be_deleted BEFORE DELETE ON billing_window_sponsorship_requests WHEN NOT EXISTS(SELECT 1 FROM billing_retention_fences f JOIN billing_retention_requests r ON r.sequence=f.sequence WHERE f.billing_account_id=OLD.billing_account_id AND f.state='deleting' AND r.state='deleting')
BEGIN SELECT RAISE(ABORT,'sponsorship audit cannot be deleted'); END;

CREATE TRIGGER billing_window_sponsorship_requests_retention_insert_guard BEFORE INSERT ON billing_window_sponsorship_requests
WHEN EXISTS(SELECT 1 FROM billing_retention_fences WHERE billing_account_id=NEW.billing_account_id AND state IN('deleting','closed'))
BEGIN SELECT RAISE(ABORT,'billing account is fenced for deletion'); END;

CREATE TRIGGER billing_window_sponsorship_requests_retention_update_guard BEFORE UPDATE ON billing_window_sponsorship_requests
WHEN EXISTS(SELECT 1 FROM billing_retention_fences WHERE billing_account_id=NEW.billing_account_id AND state IN('deleting','closed'))
BEGIN SELECT RAISE(ABORT,'billing account is fenced for deletion'); END;

CREATE TRIGGER billing_reconciliation_jobs_retention_delete_guard BEFORE DELETE ON billing_reconciliation_jobs
WHEN EXISTS(SELECT 1 FROM billing_retention_fences WHERE billing_account_id=(SELECT billing_account_id FROM billing_transaction_lineages WHERE environment=OLD.environment AND original_transaction_id=OLD.original_transaction_id) AND state<>'active') AND NOT EXISTS(SELECT 1 FROM billing_retention_fences f JOIN billing_retention_requests r ON r.sequence=f.sequence WHERE f.billing_account_id=(SELECT billing_account_id FROM billing_transaction_lineages WHERE environment=OLD.environment AND original_transaction_id=OLD.original_transaction_id) AND f.state='deleting' AND r.state='deleting')
BEGIN SELECT RAISE(ABORT,'billing retention deletion requires current ticket'); END;

CREATE TRIGGER billing_reconciliation_jobs_retention_insert_guard BEFORE INSERT ON billing_reconciliation_jobs
WHEN EXISTS(SELECT 1 FROM billing_retention_fences WHERE billing_account_id=(SELECT billing_account_id FROM billing_transaction_lineages WHERE environment=NEW.environment AND original_transaction_id=NEW.original_transaction_id) AND state IN('deleting','closed'))
BEGIN SELECT RAISE(ABORT,'billing account is fenced for deletion'); END;

CREATE TRIGGER billing_reconciliation_jobs_retention_update_guard BEFORE UPDATE ON billing_reconciliation_jobs
WHEN EXISTS(SELECT 1 FROM billing_retention_fences WHERE billing_account_id=(SELECT billing_account_id FROM billing_transaction_lineages WHERE environment=NEW.environment AND original_transaction_id=NEW.original_transaction_id) AND state IN('deleting','closed'))
BEGIN SELECT RAISE(ABORT,'billing account is fenced for deletion'); END;

DROP TRIGGER billing_apple_notification_reconciliation_causes_cannot_be_deleted;
CREATE TRIGGER billing_apple_notification_reconciliation_causes_cannot_be_deleted
BEFORE DELETE ON billing_apple_notification_reconciliation_causes
WHEN NOT EXISTS(SELECT 1 FROM billing_retention_fences f JOIN billing_retention_requests r ON r.sequence=f.sequence WHERE f.billing_account_id=(SELECT billing_account_id FROM billing_apple_notification_events WHERE environment=OLD.environment AND notification_uuid=OLD.notification_uuid) AND f.state='deleting' AND r.state='deleting')
BEGIN SELECT RAISE(ABORT, 'notification reconciliation causes cannot be deleted'); END;

CREATE TRIGGER billing_apple_notification_reconciliation_causes_retention_insert_guard BEFORE INSERT ON billing_apple_notification_reconciliation_causes
WHEN EXISTS(SELECT 1 FROM billing_retention_fences WHERE billing_account_id=(SELECT billing_account_id FROM billing_transaction_lineages WHERE environment=NEW.environment AND original_transaction_id=NEW.original_transaction_id) AND state IN('deleting','closed'))
BEGIN SELECT RAISE(ABORT,'billing account is fenced for deletion'); END;

CREATE TRIGGER billing_apple_notification_reconciliation_causes_retention_update_guard BEFORE UPDATE ON billing_apple_notification_reconciliation_causes
WHEN EXISTS(SELECT 1 FROM billing_retention_fences WHERE billing_account_id=(SELECT billing_account_id FROM billing_transaction_lineages WHERE environment=NEW.environment AND original_transaction_id=NEW.original_transaction_id) AND state IN('deleting','closed'))
BEGIN SELECT RAISE(ABORT,'billing account is fenced for deletion'); END;

DROP TRIGGER billing_apple_notification_history_page_records_cannot_be_deleted;
CREATE TRIGGER billing_apple_notification_history_page_records_cannot_be_deleted
BEFORE DELETE ON billing_apple_notification_history_page_records
WHEN NOT EXISTS(SELECT 1 FROM billing_retention_fences f JOIN billing_retention_requests r ON r.sequence=f.sequence WHERE f.billing_account_id=(SELECT billing_account_id FROM billing_apple_notification_events WHERE environment=OLD.environment AND notification_uuid=OLD.notification_uuid) AND f.state='deleting' AND r.state='deleting')
BEGIN SELECT RAISE(ABORT, 'notification history page records cannot be deleted'); END;

CREATE TRIGGER billing_apple_notification_history_page_records_retention_insert_guard BEFORE INSERT ON billing_apple_notification_history_page_records
WHEN EXISTS(SELECT 1 FROM billing_retention_fences WHERE billing_account_id=(SELECT billing_account_id FROM billing_apple_notification_events WHERE environment=NEW.environment AND notification_uuid=NEW.notification_uuid) AND state IN('deleting','closed'))
BEGIN SELECT RAISE(ABORT,'billing account is fenced for deletion'); END;

CREATE TRIGGER billing_apple_notification_history_page_records_retention_update_guard BEFORE UPDATE ON billing_apple_notification_history_page_records
WHEN EXISTS(SELECT 1 FROM billing_retention_fences WHERE billing_account_id=(SELECT billing_account_id FROM billing_apple_notification_events WHERE environment=NEW.environment AND notification_uuid=NEW.notification_uuid) AND state IN('deleting','closed'))
BEGIN SELECT RAISE(ABORT,'billing account is fenced for deletion'); END;

DROP TRIGGER billing_window_sponsorships_cannot_be_deleted;
CREATE TRIGGER billing_window_sponsorships_cannot_be_deleted BEFORE DELETE ON billing_window_sponsorships WHEN NOT EXISTS(SELECT 1 FROM billing_retention_fences f JOIN billing_retention_requests r ON r.sequence=f.sequence WHERE f.billing_account_id=(SELECT billing_account_id FROM billing_window_sponsorship_requests WHERE client_request_id=OLD.last_request_id) AND f.state='deleting' AND r.state='deleting')
BEGIN SELECT RAISE(ABORT,'sponsorship state cannot be deleted'); END;

CREATE TRIGGER billing_window_sponsorships_retention_insert_guard BEFORE INSERT ON billing_window_sponsorships
WHEN EXISTS(SELECT 1 FROM billing_retention_fences WHERE billing_account_id=NEW.billing_account_id AND state IN('deleting','closed'))
BEGIN SELECT RAISE(ABORT,'billing account is fenced for deletion'); END;

CREATE TRIGGER billing_window_sponsorships_retention_update_guard BEFORE UPDATE ON billing_window_sponsorships
WHEN EXISTS(SELECT 1 FROM billing_retention_fences WHERE billing_account_id=NEW.billing_account_id AND state IN('deleting','closed'))
BEGIN SELECT RAISE(ABORT,'billing account is fenced for deletion'); END;

CREATE TABLE billing_retention_account_revisions(
 billing_account_id TEXT PRIMARY KEY, revision INTEGER NOT NULL CHECK(revision>=0)
) STRICT;
INSERT INTO billing_retention_account_revisions SELECT id,0 FROM billing_accounts;
CREATE TRIGGER billing_transaction_lineages_retention_revision_insert AFTER INSERT ON billing_transaction_lineages
WHEN NEW.billing_account_id IS NOT NULL BEGIN
 INSERT INTO billing_retention_account_revisions VALUES(NEW.billing_account_id,1)
 ON CONFLICT(billing_account_id) DO UPDATE SET revision=revision+1;
END;
CREATE TRIGGER billing_transaction_lineages_retention_revision_update AFTER UPDATE ON billing_transaction_lineages
WHEN NEW.billing_account_id IS NOT NULL BEGIN
 INSERT INTO billing_retention_account_revisions VALUES(NEW.billing_account_id,1)
 ON CONFLICT(billing_account_id) DO UPDATE SET revision=revision+1;
END;
CREATE TRIGGER billing_transaction_events_retention_revision_insert AFTER INSERT ON billing_transaction_events
WHEN NEW.billing_account_id IS NOT NULL BEGIN
 INSERT INTO billing_retention_account_revisions VALUES(NEW.billing_account_id,1)
 ON CONFLICT(billing_account_id) DO UPDATE SET revision=revision+1;
END;
CREATE TRIGGER billing_transaction_events_retention_revision_update AFTER UPDATE ON billing_transaction_events
WHEN NEW.billing_account_id IS NOT NULL BEGIN
 INSERT INTO billing_retention_account_revisions VALUES(NEW.billing_account_id,1)
 ON CONFLICT(billing_account_id) DO UPDATE SET revision=revision+1;
END;
CREATE TRIGGER billing_apple_notification_events_retention_revision_insert AFTER INSERT ON billing_apple_notification_events
WHEN NEW.billing_account_id IS NOT NULL BEGIN
 INSERT INTO billing_retention_account_revisions VALUES(NEW.billing_account_id,1)
 ON CONFLICT(billing_account_id) DO UPDATE SET revision=revision+1;
END;
CREATE TRIGGER billing_apple_notification_events_retention_revision_update AFTER UPDATE ON billing_apple_notification_events
WHEN NEW.billing_account_id IS NOT NULL BEGIN
 INSERT INTO billing_retention_account_revisions VALUES(NEW.billing_account_id,1)
 ON CONFLICT(billing_account_id) DO UPDATE SET revision=revision+1;
END;
CREATE TRIGGER billing_subscription_authority_observations_retention_revision_insert AFTER INSERT ON billing_subscription_authority_observations
WHEN NEW.billing_account_id IS NOT NULL BEGIN
 INSERT INTO billing_retention_account_revisions VALUES(NEW.billing_account_id,1)
 ON CONFLICT(billing_account_id) DO UPDATE SET revision=revision+1;
END;
CREATE TRIGGER billing_subscription_authority_observations_retention_revision_update AFTER UPDATE ON billing_subscription_authority_observations
WHEN NEW.billing_account_id IS NOT NULL BEGIN
 INSERT INTO billing_retention_account_revisions VALUES(NEW.billing_account_id,1)
 ON CONFLICT(billing_account_id) DO UPDATE SET revision=revision+1;
END;
CREATE TRIGGER billing_effective_entitlement_current_retention_revision_insert AFTER INSERT ON billing_effective_entitlement_current
WHEN NEW.billing_account_id IS NOT NULL BEGIN
 INSERT INTO billing_retention_account_revisions VALUES(NEW.billing_account_id,1)
 ON CONFLICT(billing_account_id) DO UPDATE SET revision=revision+1;
END;
CREATE TRIGGER billing_effective_entitlement_current_retention_revision_update AFTER UPDATE ON billing_effective_entitlement_current
WHEN NEW.billing_account_id IS NOT NULL BEGIN
 INSERT INTO billing_retention_account_revisions VALUES(NEW.billing_account_id,1)
 ON CONFLICT(billing_account_id) DO UPDATE SET revision=revision+1;
END;

CREATE TABLE billing_retention_recoveries(
 billing_account_id TEXT NOT NULL,
 sequence INTEGER NOT NULL,
 environment TEXT NOT NULL CHECK(environment IN('Production','Sandbox')),
 lineage_hash TEXT NOT NULL CHECK(length(lineage_hash)=43),
 transaction_hash TEXT NOT NULL CHECK(length(transaction_hash)=43),
 request_id TEXT NOT NULL,
 PRIMARY KEY(billing_account_id,environment,lineage_hash,transaction_hash),
 FOREIGN KEY(sequence) REFERENCES billing_retention_requests(sequence) ON DELETE RESTRICT
) STRICT;

CREATE TRIGGER billing_retention_recovery_fence BEFORE INSERT ON billing_retention_recoveries
WHEN NOT EXISTS(SELECT 1 FROM billing_retention_fences f JOIN billing_retention_requests r ON r.sequence=f.sequence
 WHERE f.billing_account_id=NEW.billing_account_id AND f.sequence=NEW.sequence AND f.state='active'
 AND f.recovery_request_id=NEW.request_id AND r.state='completed' AND r.receipt_recorded=1)
BEGIN SELECT RAISE(ABORT,'retention recovery fence changed'); END;

CREATE TABLE billing_retention_scan(singleton INTEGER PRIMARY KEY CHECK(singleton=1),last_account_rowid INTEGER NOT NULL CHECK(last_account_rowid>=0)) STRICT;
INSERT INTO billing_retention_scan VALUES(1,0);

CREATE TRIGGER billing_retention_recovery_revision AFTER INSERT ON billing_account_recovery_requests
BEGIN
 INSERT INTO billing_retention_account_revisions(billing_account_id,revision) VALUES(NEW.billing_account_id,1)
 ON CONFLICT(billing_account_id) DO UPDATE SET revision=revision+1;
END;
