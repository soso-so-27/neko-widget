PRAGMA foreign_keys = ON;

-- Separate, immutable exchange evidence. Billing identifiers never leave the
-- billing/requester boundary. Photos, participants and keys are not moved.
CREATE TABLE billing_window_support_requests(
 id TEXT PRIMARY KEY CHECK(length(id)=36), request_hash TEXT NOT NULL CHECK(length(request_hash)=43),
 space_id TEXT NOT NULL REFERENCES moment_spaces(space_id) ON DELETE RESTRICT,
 window_lineage_id TEXT NOT NULL REFERENCES moment_space_lineages(id) ON DELETE RESTRICT,
 requester_member_id TEXT NOT NULL REFERENCES members(id) ON DELETE RESTRICT,
 requester_participant_id TEXT NOT NULL REFERENCES moment_participants(id) ON DELETE RESTRICT,
 requester_device_id TEXT NOT NULL REFERENCES moment_devices(id) ON DELETE RESTRICT,
 billing_account_id TEXT NOT NULL REFERENCES billing_accounts(id) ON DELETE RESTRICT,
 billing_key_id TEXT NOT NULL REFERENCES billing_account_keys(id) ON DELETE RESTRICT,
 membership_revision INTEGER NOT NULL CHECK(membership_revision>0),
 expected_generation INTEGER NOT NULL CHECK(expected_generation>=0),
 expected_current_billing_account_id TEXT REFERENCES billing_accounts(id) ON DELETE RESTRICT,
 created_at INTEGER NOT NULL DEFAULT(unixepoch()),
 expires_at INTEGER NOT NULL CHECK(expires_at=created_at+300)
) STRICT;
CREATE INDEX billing_window_support_request_space ON billing_window_support_requests(space_id,created_at DESC);

CREATE TABLE billing_window_support_approvals(
 request_id TEXT PRIMARY KEY REFERENCES billing_window_support_requests(id) ON DELETE RESTRICT,
 client_request_id TEXT NOT NULL UNIQUE CHECK(length(client_request_id)=36),
 request_hash TEXT NOT NULL CHECK(length(request_hash)=43),
 owner_participant_id TEXT NOT NULL REFERENCES moment_participants(id) ON DELETE RESTRICT,
 owner_device_id TEXT NOT NULL REFERENCES moment_devices(id) ON DELETE RESTRICT,
 consent_nonce_hash TEXT NOT NULL CHECK(length(consent_nonce_hash)=43),
 consent_hash TEXT NOT NULL CHECK(length(consent_hash)=43),
 recorded_at INTEGER NOT NULL DEFAULT(unixepoch())
) STRICT;
CREATE TABLE billing_window_support_commits(
 request_id TEXT PRIMARY KEY REFERENCES billing_window_support_approvals(request_id) ON DELETE RESTRICT,
 client_request_id TEXT NOT NULL UNIQUE CHECK(length(client_request_id)=36),
 request_hash TEXT NOT NULL CHECK(length(request_hash)=43),
 recorded_at INTEGER NOT NULL DEFAULT(unixepoch())
) STRICT;

-- All three stages use the same live context, inside their writing statement.
-- A fresh effective grant is required for the new payer. An existing valid
-- sponsor is never replaced by this resume-only flow; unknown old authority
-- also fails closed. The existing sponsorship trigger separately enforces the
-- owner proof, CAS, entitlement fence and the three-window limit at commit.
CREATE VIEW billing_window_support_live_requests AS
SELECT r.* FROM billing_window_support_requests r
 JOIN moment_spaces s ON s.space_id=r.space_id AND s.lineage_id=r.window_lineage_id
 JOIN spaces legacy ON legacy.id=s.space_id
 JOIN members m ON m.id=r.requester_member_id AND m.space_id=r.space_id
 JOIN moment_participants p ON p.id=r.requester_participant_id AND p.legacy_member_id=m.id AND p.space_id=s.space_id
 JOIN moment_devices d ON d.id=r.requester_device_id AND d.participant_id=p.id
 JOIN billing_account_keys k ON k.id=r.billing_key_id AND k.billing_account_id=r.billing_account_id
 JOIN billing_runtime_gate gate ON gate.singleton=1
 LEFT JOIN billing_window_sponsorships sponsor ON sponsor.window_lineage_id=r.window_lineage_id
WHERE gate.window_sponsorship_enabled=1 AND gate.effective_entitlement_enabled=1
 AND s.state='active' AND legacy.state='active' AND m.state='active' AND p.state='active' AND d.state='active' AND k.state='active'
 AND p.role=(CASE m.role WHEN 'owner' THEN 'owner' ELSE 'member' END)
 AND s.membership_revision=r.membership_revision AND r.expires_at>unixepoch()
 AND COALESCE(sponsor.generation,0)=r.expected_generation
 AND (CASE WHEN sponsor.state='active' THEN sponsor.billing_account_id END) IS r.expected_current_billing_account_id
 AND NOT EXISTS(SELECT 1 FROM moment_blocks b WHERE b.space_id=r.space_id AND b.state='active')
 AND EXISTS(SELECT 1 FROM billing_effective_entitlement_current c WHERE c.billing_account_id=r.billing_account_id
   AND c.materialized_grants_plus=1 AND c.ownership_type='PURCHASED' AND c.materialized_status IN('active','gracePeriod')
   AND c.revocation_date_ms IS NULL AND c.revocation_reason IS NULL AND c.is_upgraded=0
   AND c.access_until_ms>CAST(unixepoch('subsec')*1000 AS INTEGER) AND c.authority_stale_at_ms>CAST(unixepoch('subsec')*1000 AS INTEGER))
 AND (r.expected_current_billing_account_id IS NULL OR (
   NOT EXISTS(SELECT 1 FROM billing_effective_entitlement_current c WHERE c.billing_account_id=r.expected_current_billing_account_id
     AND c.materialized_grants_plus=1 AND c.ownership_type='PURCHASED' AND c.materialized_status IN('active','gracePeriod')
     AND c.revocation_date_ms IS NULL AND c.revocation_reason IS NULL AND c.is_upgraded=0
     AND c.access_until_ms>CAST(unixepoch('subsec')*1000 AS INTEGER) AND c.authority_stale_at_ms>CAST(unixepoch('subsec')*1000 AS INTEGER))
   AND (SELECT c.ownership_type='PURCHASED' AND (c.apple_status IN(2,3,5) OR c.revocation_date_ms IS NOT NULL
       OR c.revocation_reason IS NOT NULL OR c.is_upgraded=1
       OR (CASE WHEN c.apple_status=4 THEN c.grace_period_expires_date_ms ELSE c.expires_date_ms END) IS NULL
       OR (CASE WHEN c.apple_status=4 THEN c.grace_period_expires_date_ms ELSE c.expires_date_ms END)<=CAST(unixepoch('subsec')*1000 AS INTEGER))
     FROM billing_effective_entitlement_current c WHERE c.billing_account_id=r.expected_current_billing_account_id
     ORDER BY c.evaluated_at_ms DESC,c.original_transaction_id ASC LIMIT 1)
 ));

CREATE TRIGGER billing_window_support_request_validate AFTER INSERT ON billing_window_support_requests BEGIN
 SELECT (CASE WHEN NEW.created_at<>unixepoch() OR NOT EXISTS(SELECT 1 FROM billing_window_support_live_requests WHERE id=NEW.id)
   THEN RAISE(ABORT,'invalid support request context') END);
END;
CREATE TRIGGER billing_window_support_approval_validate BEFORE INSERT ON billing_window_support_approvals BEGIN
 SELECT (CASE WHEN NEW.recorded_at<>unixepoch() OR NOT EXISTS(
   SELECT 1 FROM billing_window_support_live_requests r
    JOIN moment_participants p ON p.space_id=r.space_id AND p.id=NEW.owner_participant_id AND p.role='owner' AND p.state='active'
    JOIN moment_devices d ON d.participant_id=p.id AND d.id=NEW.owner_device_id AND d.state='active'
   WHERE r.id=NEW.request_id)
   THEN RAISE(ABORT,'invalid support approval context') END);
END;
CREATE TRIGGER billing_window_support_commit_validate BEFORE INSERT ON billing_window_support_commits BEGIN
 SELECT (CASE WHEN NEW.recorded_at<>unixepoch() OR NOT EXISTS(
   SELECT 1 FROM billing_window_support_live_requests r JOIN billing_window_support_approvals a ON a.request_id=r.id
    JOIN moment_participants p ON p.space_id=r.space_id AND p.id=a.owner_participant_id AND p.role='owner' AND p.state='active'
    JOIN moment_devices d ON d.participant_id=p.id AND d.id=a.owner_device_id AND d.state='active'
   WHERE r.id=NEW.request_id AND a.recorded_at>unixepoch()-300)
   THEN RAISE(ABORT,'invalid support commit context') END);
END;
CREATE TRIGGER billing_window_support_commit_apply AFTER INSERT ON billing_window_support_commits BEGIN
 INSERT INTO billing_window_sponsorship_requests(
   client_request_id,request_hash,operation,billing_account_id,submitted_by_billing_key_id,window_lineage_id,
   expected_generation,expected_current_billing_account_id,consent_space_id,owner_participant_id,owner_device_id,
   consent_membership_revision,consent_issued_at,owner_consent_nonce_hash,owner_consent_hash,
   entitlement_decision_id,entitlement_request_generation,entitlement_evaluated_at_ms,resulting_generation)
 SELECT NEW.client_request_id,NEW.request_hash,'sponsor',r.billing_account_id,r.billing_key_id,r.window_lineage_id,
   r.expected_generation,r.expected_current_billing_account_id,r.space_id,a.owner_participant_id,a.owner_device_id,
   r.membership_revision,a.recorded_at,a.consent_nonce_hash,a.consent_hash,
   c.decision_id,c.request_generation,c.evaluated_at_ms,r.expected_generation+1
 FROM billing_window_support_requests r JOIN billing_window_support_approvals a ON a.request_id=r.id
 JOIN billing_effective_entitlement_current c ON c.billing_account_id=r.billing_account_id
 WHERE r.id=NEW.request_id AND c.materialized_grants_plus=1 AND c.ownership_type='PURCHASED'
   AND c.materialized_status IN('active','gracePeriod') AND c.revocation_date_ms IS NULL AND c.revocation_reason IS NULL
   AND c.is_upgraded=0 AND c.access_until_ms>CAST(unixepoch('subsec')*1000 AS INTEGER)
   AND c.authority_stale_at_ms>CAST(unixepoch('subsec')*1000 AS INTEGER)
 ORDER BY MIN(c.access_until_ms,c.authority_stale_at_ms) DESC,c.original_transaction_id ASC LIMIT 1;
 SELECT (CASE WHEN NOT EXISTS(SELECT 1 FROM billing_window_sponsorship_requests WHERE client_request_id=NEW.client_request_id)
   THEN RAISE(ABORT,'support commit was not applied') END);
END;

CREATE TRIGGER billing_window_support_requests_immutable BEFORE UPDATE ON billing_window_support_requests BEGIN SELECT RAISE(ABORT,'support request immutable'); END;
CREATE TRIGGER billing_window_support_requests_no_delete BEFORE DELETE ON billing_window_support_requests BEGIN SELECT RAISE(ABORT,'support request audit retained'); END;
CREATE TRIGGER billing_window_support_approvals_immutable BEFORE UPDATE ON billing_window_support_approvals BEGIN SELECT RAISE(ABORT,'support approval immutable'); END;
CREATE TRIGGER billing_window_support_approvals_no_delete BEFORE DELETE ON billing_window_support_approvals BEGIN SELECT RAISE(ABORT,'support approval audit retained'); END;
CREATE TRIGGER billing_window_support_commits_immutable BEFORE UPDATE ON billing_window_support_commits BEGIN SELECT RAISE(ABORT,'support commit immutable'); END;
CREATE TRIGGER billing_window_support_commits_no_delete BEFORE DELETE ON billing_window_support_commits BEGIN SELECT RAISE(ABORT,'support commit audit retained'); END;
