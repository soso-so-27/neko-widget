PRAGMA foreign_keys = ON;
ALTER TABLE billing_runtime_gate ADD COLUMN window_sponsorship_enabled INTEGER NOT NULL DEFAULT 0 CHECK(window_sponsorship_enabled IN(0,1));

CREATE TABLE billing_window_sponsorship_requests(
 client_request_id TEXT PRIMARY KEY CHECK(length(client_request_id)=36 AND client_request_id=lower(client_request_id) AND substr(client_request_id,15,1)='4' AND substr(client_request_id,20,1) GLOB '[89ab]' AND length(replace(client_request_id,'-',''))=32 AND client_request_id NOT GLOB '*[^0-9a-f-]*'),
 request_hash TEXT NOT NULL CHECK(length(request_hash)=43 AND request_hash NOT GLOB '*[^A-Za-z0-9_-]*'),
 operation TEXT NOT NULL CHECK(operation IN('sponsor','unsponsor')),
 billing_account_id TEXT NOT NULL REFERENCES billing_accounts(id) ON DELETE RESTRICT,
 submitted_by_billing_key_id TEXT NOT NULL REFERENCES billing_account_keys(id) ON DELETE RESTRICT,
 window_lineage_id TEXT NOT NULL REFERENCES moment_space_lineages(id) ON DELETE RESTRICT,
 expected_generation INTEGER NOT NULL CHECK(expected_generation>=0),
 expected_current_billing_account_id TEXT REFERENCES billing_accounts(id) ON DELETE RESTRICT,
 consent_space_id TEXT, owner_participant_id TEXT, owner_device_id TEXT,
 consent_membership_revision INTEGER CHECK(consent_membership_revision>0), consent_issued_at INTEGER,
 owner_consent_nonce_hash TEXT CHECK(owner_consent_nonce_hash IS NULL OR (length(owner_consent_nonce_hash)=43 AND owner_consent_nonce_hash NOT GLOB '*[^A-Za-z0-9_-]*')),
 owner_consent_hash TEXT CHECK(owner_consent_hash IS NULL OR (length(owner_consent_hash)=43 AND owner_consent_hash NOT GLOB '*[^A-Za-z0-9_-]*')),
 entitlement_decision_id TEXT REFERENCES billing_effective_entitlement_decisions(decision_id) ON DELETE RESTRICT,
 entitlement_request_generation INTEGER CHECK(entitlement_request_generation>0),
 entitlement_evaluated_at_ms INTEGER CHECK(entitlement_evaluated_at_ms>0),
 resulting_generation INTEGER NOT NULL CHECK(resulting_generation=expected_generation+1),
 recorded_at INTEGER NOT NULL DEFAULT(unixepoch()),
 CHECK((operation='sponsor' AND consent_space_id IS NOT NULL AND owner_participant_id IS NOT NULL AND owner_device_id IS NOT NULL AND consent_membership_revision IS NOT NULL AND consent_issued_at IS NOT NULL AND owner_consent_nonce_hash IS NOT NULL AND owner_consent_hash IS NOT NULL AND entitlement_decision_id IS NOT NULL AND entitlement_request_generation IS NOT NULL AND entitlement_evaluated_at_ms IS NOT NULL) OR (operation='unsponsor' AND consent_space_id IS NULL AND owner_participant_id IS NULL AND owner_device_id IS NULL AND consent_membership_revision IS NULL AND consent_issued_at IS NULL AND owner_consent_nonce_hash IS NULL AND owner_consent_hash IS NULL AND entitlement_decision_id IS NULL AND entitlement_request_generation IS NULL AND entitlement_evaluated_at_ms IS NULL))
) STRICT;

CREATE TABLE billing_window_sponsorships(
 window_lineage_id TEXT PRIMARY KEY REFERENCES moment_space_lineages(id) ON DELETE RESTRICT,
 billing_account_id TEXT REFERENCES billing_accounts(id) ON DELETE RESTRICT,
 state TEXT NOT NULL CHECK(state IN('active','unsponsored')), generation INTEGER NOT NULL CHECK(generation>0),
 sponsored_at INTEGER, updated_at INTEGER NOT NULL,
 last_request_id TEXT NOT NULL UNIQUE REFERENCES billing_window_sponsorship_requests(client_request_id) ON DELETE RESTRICT,
 CHECK((state='active' AND billing_account_id IS NOT NULL AND sponsored_at IS NOT NULL) OR (state='unsponsored' AND billing_account_id IS NULL))
) STRICT;
CREATE INDEX billing_window_sponsorship_account_active ON billing_window_sponsorships(billing_account_id,window_lineage_id) WHERE state='active';

CREATE TRIGGER billing_window_sponsorship_request_validate BEFORE INSERT ON billing_window_sponsorship_requests BEGIN
 SELECT CASE WHEN NOT EXISTS(
   SELECT 1 FROM billing_runtime_gate
    WHERE singleton=1
      AND window_sponsorship_enabled=1
      AND (NEW.operation='unsponsor' OR effective_entitlement_enabled=1)
 ) THEN RAISE(ABORT,'sponsorship runtime gate closed') END;
 SELECT CASE WHEN NEW.recorded_at<>unixepoch() THEN RAISE(ABORT,'sponsorship audit requires database time') END;
 SELECT CASE WHEN NOT EXISTS(SELECT 1 FROM billing_account_keys WHERE id=NEW.submitted_by_billing_key_id AND billing_account_id=NEW.billing_account_id AND state='active') THEN RAISE(ABORT,'active billing key required') END;
 SELECT CASE WHEN COALESCE((SELECT generation FROM billing_window_sponsorships WHERE window_lineage_id=NEW.window_lineage_id),0)<>NEW.expected_generation THEN RAISE(ABORT,'sponsorship generation conflict') END;
 SELECT CASE WHEN (SELECT billing_account_id FROM billing_window_sponsorships WHERE window_lineage_id=NEW.window_lineage_id AND state='active') IS NOT NEW.expected_current_billing_account_id THEN RAISE(ABORT,'current sponsor conflict') END;
 SELECT CASE WHEN NEW.operation='unsponsor' AND (NEW.expected_current_billing_account_id IS NOT NEW.billing_account_id OR NOT EXISTS(SELECT 1 FROM billing_window_sponsorships WHERE window_lineage_id=NEW.window_lineage_id AND state='active' AND billing_account_id=NEW.billing_account_id)) THEN RAISE(ABORT,'unsponsor requires current payer') END;
 SELECT CASE WHEN NEW.operation='sponsor' AND NOT EXISTS(SELECT 1 FROM moment_spaces s JOIN moment_participants p ON p.space_id=s.space_id JOIN moment_devices d ON d.participant_id=p.id WHERE s.space_id=NEW.consent_space_id AND s.lineage_id=NEW.window_lineage_id AND s.state='active' AND s.membership_revision=NEW.consent_membership_revision AND p.id=NEW.owner_participant_id AND p.role='owner' AND p.state='active' AND d.id=NEW.owner_device_id AND d.state='active' AND NOT EXISTS(SELECT 1 FROM moment_blocks b WHERE b.space_id=s.space_id AND b.state='active')) THEN RAISE(ABORT,'current unblocked owner consent required') END;
 SELECT CASE WHEN NEW.operation='sponsor' AND (NEW.consent_issued_at<unixepoch()-300 OR NEW.consent_issued_at>unixepoch()+300) THEN RAISE(ABORT,'owner consent stale') END;
 SELECT CASE WHEN NEW.operation='sponsor' AND (SELECT COUNT(*) FROM billing_window_sponsorships WHERE billing_account_id=NEW.billing_account_id AND state='active' AND window_lineage_id<>NEW.window_lineage_id)>=3 THEN RAISE(ABORT,'sponsorship limit reached') END;
 SELECT CASE WHEN NEW.operation='sponsor' AND NOT EXISTS(SELECT 1 FROM billing_effective_entitlement_current c JOIN billing_effective_entitlement_decisions d ON d.decision_id=c.decision_id WHERE c.billing_account_id=NEW.billing_account_id AND c.decision_id=NEW.entitlement_decision_id AND c.request_generation=NEW.entitlement_request_generation AND c.evaluated_at_ms=NEW.entitlement_evaluated_at_ms AND c.materialized_grants_plus=1 AND c.ownership_type='PURCHASED' AND c.materialized_status IN('active','gracePeriod') AND c.revocation_date_ms IS NULL AND c.revocation_reason IS NULL AND c.is_upgraded=0 AND c.access_until_ms>unixepoch()*1000 AND c.authority_stale_at_ms>unixepoch()*1000) THEN RAISE(ABORT,'fresh Plus entitlement required') END;
END;

CREATE TRIGGER billing_window_sponsorship_apply AFTER INSERT ON billing_window_sponsorship_requests BEGIN
 INSERT INTO billing_window_sponsorships(window_lineage_id,billing_account_id,state,generation,sponsored_at,updated_at,last_request_id) VALUES(NEW.window_lineage_id,CASE WHEN NEW.operation='sponsor' THEN NEW.billing_account_id ELSE NULL END,CASE WHEN NEW.operation='sponsor' THEN 'active' ELSE 'unsponsored' END,NEW.resulting_generation,CASE WHEN NEW.operation='sponsor' THEN NEW.recorded_at ELSE NULL END,NEW.recorded_at,NEW.client_request_id)
 ON CONFLICT(window_lineage_id) DO UPDATE SET billing_account_id=excluded.billing_account_id,state=excluded.state,generation=excluded.generation,sponsored_at=CASE WHEN excluded.state='active' THEN excluded.updated_at ELSE billing_window_sponsorships.sponsored_at END,updated_at=excluded.updated_at,last_request_id=excluded.last_request_id;
END;

CREATE TRIGGER billing_window_sponsorship_state_validate_insert BEFORE INSERT ON billing_window_sponsorships
WHEN NOT EXISTS(
 SELECT 1 FROM billing_window_sponsorship_requests a
 WHERE a.client_request_id=NEW.last_request_id
   AND a.window_lineage_id=NEW.window_lineage_id
   AND a.resulting_generation=NEW.generation
   AND a.recorded_at=NEW.updated_at
   AND (
     (a.operation='sponsor'
       AND a.billing_account_id=NEW.billing_account_id
       AND NEW.state='active'
       AND a.recorded_at=NEW.sponsored_at
       AND (
         (a.expected_generation=0
           AND a.expected_current_billing_account_id IS NULL
           AND NOT EXISTS(
             SELECT 1 FROM billing_window_sponsorships current
             WHERE current.window_lineage_id=NEW.window_lineage_id
           ))
         OR EXISTS(
           SELECT 1 FROM billing_window_sponsorships current
           WHERE current.window_lineage_id=NEW.window_lineage_id
             AND current.generation=a.expected_generation
             AND (
               (current.state='active'
                 AND a.expected_current_billing_account_id IS current.billing_account_id)
               OR (current.state='unsponsored'
                 AND a.expected_current_billing_account_id IS NULL)
             )
         )
       ))
     OR
     (a.operation='unsponsor'
       AND NEW.state='unsponsored'
       AND NEW.billing_account_id IS NULL
       AND NEW.sponsored_at IS NULL
       AND EXISTS(
         SELECT 1 FROM billing_window_sponsorships current
         WHERE current.window_lineage_id=NEW.window_lineage_id
           AND current.state='active'
           AND current.generation=a.expected_generation
           AND current.billing_account_id=a.billing_account_id
           AND a.expected_current_billing_account_id IS current.billing_account_id
       ))
   )
)
BEGIN SELECT RAISE(ABORT,'sponsorship insert requires exact audit'); END;
CREATE TRIGGER billing_window_sponsorship_state_validate_update BEFORE UPDATE ON billing_window_sponsorships WHEN NEW.window_lineage_id<>OLD.window_lineage_id OR NOT EXISTS(SELECT 1 FROM billing_window_sponsorship_requests a WHERE a.client_request_id=NEW.last_request_id AND a.window_lineage_id=OLD.window_lineage_id AND a.expected_generation=OLD.generation AND a.resulting_generation=NEW.generation AND a.recorded_at=NEW.updated_at AND ((a.operation='sponsor' AND NEW.state='active' AND NEW.billing_account_id=a.billing_account_id AND NEW.sponsored_at=a.recorded_at) OR (a.operation='unsponsor' AND a.billing_account_id=OLD.billing_account_id AND a.expected_current_billing_account_id IS OLD.billing_account_id AND NEW.state='unsponsored' AND NEW.billing_account_id IS NULL AND NEW.sponsored_at IS OLD.sponsored_at))) BEGIN SELECT RAISE(ABORT,'sponsorship update requires exact audit'); END;
CREATE TRIGGER billing_window_sponsorship_requests_are_immutable BEFORE UPDATE ON billing_window_sponsorship_requests BEGIN SELECT RAISE(ABORT,'sponsorship audit immutable'); END;
CREATE TRIGGER billing_window_sponsorship_requests_cannot_be_deleted BEFORE DELETE ON billing_window_sponsorship_requests BEGIN SELECT RAISE(ABORT,'sponsorship audit cannot be deleted'); END;
CREATE TRIGGER billing_window_sponsorships_cannot_be_deleted BEFORE DELETE ON billing_window_sponsorships BEGIN SELECT RAISE(ABORT,'sponsorship state cannot be deleted'); END;
