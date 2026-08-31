PRAGMA foreign_keys = ON;

-- The window owner must be able to remove a payer's sponsorship without
-- possessing the payer's billing credential. Keep this authorization and its
-- audit trail separate from payer-signed billing mutations.
CREATE TABLE billing_window_sponsorship_owner_detach_requests(
 client_request_id TEXT PRIMARY KEY CHECK(length(client_request_id)=36 AND client_request_id=lower(client_request_id) AND substr(client_request_id,15,1)='4' AND substr(client_request_id,20,1) GLOB '[89ab]' AND length(replace(client_request_id,'-',''))=32 AND client_request_id NOT GLOB '*[^0-9a-f-]*'),
 request_hash TEXT NOT NULL CHECK(length(request_hash)=43 AND request_hash NOT GLOB '*[^A-Za-z0-9_-]*'),
 window_lineage_id TEXT NOT NULL REFERENCES moment_space_lineages(id) ON DELETE RESTRICT,
 space_id TEXT NOT NULL REFERENCES moment_spaces(space_id) ON DELETE RESTRICT,
 owner_participant_id TEXT NOT NULL REFERENCES moment_participants(id) ON DELETE RESTRICT,
 owner_device_id TEXT NOT NULL REFERENCES moment_devices(id) ON DELETE RESTRICT,
 membership_revision INTEGER NOT NULL CHECK(membership_revision>0),
 expected_generation INTEGER NOT NULL CHECK(expected_generation>0),
 expected_billing_account_id TEXT NOT NULL REFERENCES billing_accounts(id) ON DELETE RESTRICT,
 resulting_generation INTEGER NOT NULL CHECK(resulting_generation=expected_generation+1),
 recorded_at INTEGER NOT NULL DEFAULT(unixepoch()),
 UNIQUE(window_lineage_id,resulting_generation)
) STRICT;

ALTER TABLE billing_window_sponsorships
 ADD COLUMN last_owner_detach_request_id TEXT
 REFERENCES billing_window_sponsorship_owner_detach_requests(client_request_id)
 ON DELETE RESTRICT;

CREATE UNIQUE INDEX billing_window_sponsorship_last_owner_detach
 ON billing_window_sponsorships(last_owner_detach_request_id)
 WHERE last_owner_detach_request_id IS NOT NULL;

DROP TRIGGER billing_window_sponsorship_apply;
DROP TRIGGER billing_window_sponsorship_state_validate_insert;
DROP TRIGGER billing_window_sponsorship_state_validate_update;

CREATE TRIGGER billing_window_owner_detach_request_validate
BEFORE INSERT ON billing_window_sponsorship_owner_detach_requests BEGIN
 SELECT (CASE WHEN NOT EXISTS(
   SELECT 1 FROM billing_runtime_gate
    WHERE singleton=1 AND window_sponsorship_enabled=1
 ) THEN RAISE(ABORT,'sponsorship runtime gate closed') END);
 SELECT (CASE WHEN NEW.recorded_at<>unixepoch() THEN RAISE(ABORT,'owner detach audit requires database time') END);
 SELECT (CASE WHEN NOT EXISTS(
   SELECT 1
     FROM billing_window_sponsorships current
    WHERE current.window_lineage_id=NEW.window_lineage_id
      AND current.state='active'
      AND current.generation=NEW.expected_generation
      AND current.billing_account_id=NEW.expected_billing_account_id
 ) THEN RAISE(ABORT,'owner detach sponsorship conflict') END);
 SELECT (CASE WHEN NOT EXISTS(
   SELECT 1
     FROM moment_spaces space
     JOIN moment_participants owner ON owner.space_id=space.space_id
     JOIN moment_devices device ON device.participant_id=owner.id
    WHERE space.space_id=NEW.space_id
      AND space.lineage_id=NEW.window_lineage_id
      AND space.state='active'
      AND space.membership_revision=NEW.membership_revision
      AND owner.id=NEW.owner_participant_id
      AND owner.role='owner'
      AND owner.state='active'
      AND device.id=NEW.owner_device_id
      AND device.state='active'
      AND NOT EXISTS(
        SELECT 1 FROM moment_blocks block
         WHERE block.space_id=space.space_id AND block.state='active'
      )
 ) THEN RAISE(ABORT,'current unblocked owner required') END);
END;

CREATE TRIGGER billing_window_sponsorship_apply
AFTER INSERT ON billing_window_sponsorship_requests BEGIN
 INSERT INTO billing_window_sponsorships(
   window_lineage_id,billing_account_id,state,generation,sponsored_at,
   updated_at,last_request_id,last_owner_detach_request_id
 ) VALUES(
   NEW.window_lineage_id,
   (CASE WHEN NEW.operation='sponsor' THEN NEW.billing_account_id ELSE NULL END),
   (CASE WHEN NEW.operation='sponsor' THEN 'active' ELSE 'unsponsored' END),
   NEW.resulting_generation,
   (CASE WHEN NEW.operation='sponsor' THEN NEW.recorded_at ELSE NULL END),
   NEW.recorded_at,NEW.client_request_id,NULL
 )
 ON CONFLICT(window_lineage_id) DO UPDATE SET
   billing_account_id=excluded.billing_account_id,
   state=excluded.state,
   generation=excluded.generation,
   sponsored_at=(CASE
     WHEN excluded.state='active' THEN excluded.updated_at
     ELSE billing_window_sponsorships.sponsored_at
   END),
   updated_at=excluded.updated_at,
   last_request_id=excluded.last_request_id,
   last_owner_detach_request_id=NULL;
END;

CREATE TRIGGER billing_window_owner_detach_apply
AFTER INSERT ON billing_window_sponsorship_owner_detach_requests BEGIN
 UPDATE billing_window_sponsorships
    SET billing_account_id=NULL,
        state='unsponsored',
        generation=NEW.resulting_generation,
        updated_at=NEW.recorded_at,
        last_owner_detach_request_id=NEW.client_request_id
  WHERE window_lineage_id=NEW.window_lineage_id;
END;

CREATE TRIGGER billing_window_sponsorship_state_validate_insert
BEFORE INSERT ON billing_window_sponsorships
WHEN NEW.last_owner_detach_request_id IS NOT NULL OR NOT EXISTS(
 SELECT 1 FROM billing_window_sponsorship_requests audit
 WHERE audit.client_request_id=NEW.last_request_id
   AND audit.window_lineage_id=NEW.window_lineage_id
   AND audit.resulting_generation=NEW.generation
   AND audit.recorded_at=NEW.updated_at
   AND (
     (audit.operation='sponsor'
       AND audit.billing_account_id=NEW.billing_account_id
       AND NEW.state='active'
       AND audit.recorded_at=NEW.sponsored_at
       AND (
         (audit.expected_generation=0
           AND audit.expected_current_billing_account_id IS NULL
           AND NOT EXISTS(
             SELECT 1 FROM billing_window_sponsorships current
              WHERE current.window_lineage_id=NEW.window_lineage_id
           ))
         OR EXISTS(
           SELECT 1 FROM billing_window_sponsorships current
            WHERE current.window_lineage_id=NEW.window_lineage_id
              AND current.generation=audit.expected_generation
              AND (
                (current.state='active'
                  AND audit.expected_current_billing_account_id IS current.billing_account_id)
                OR
                (current.state='unsponsored'
                  AND audit.expected_current_billing_account_id IS NULL)
              )
         )
       ))
     OR
     (audit.operation='unsponsor'
       AND NEW.state='unsponsored'
       AND NEW.billing_account_id IS NULL
       AND NEW.sponsored_at IS NULL
       AND EXISTS(
         SELECT 1 FROM billing_window_sponsorships current
          WHERE current.window_lineage_id=NEW.window_lineage_id
            AND current.state='active'
            AND current.generation=audit.expected_generation
            AND current.billing_account_id=audit.billing_account_id
            AND audit.expected_current_billing_account_id IS current.billing_account_id
       ))
   )
)
BEGIN SELECT RAISE(ABORT,'sponsorship insert requires exact audit'); END;

CREATE TRIGGER billing_window_sponsorship_state_validate_update
BEFORE UPDATE ON billing_window_sponsorships
WHEN NEW.window_lineage_id<>OLD.window_lineage_id OR NOT (
  (
    NEW.last_owner_detach_request_id IS NULL
    AND EXISTS(
      SELECT 1 FROM billing_window_sponsorship_requests audit
       WHERE audit.client_request_id=NEW.last_request_id
         AND audit.window_lineage_id=OLD.window_lineage_id
         AND audit.expected_generation=OLD.generation
         AND audit.resulting_generation=NEW.generation
         AND audit.recorded_at=NEW.updated_at
         AND (
           (audit.operation='sponsor'
             AND NEW.state='active'
             AND NEW.billing_account_id=audit.billing_account_id
             AND NEW.sponsored_at=audit.recorded_at)
           OR
           (audit.operation='unsponsor'
             AND audit.billing_account_id=OLD.billing_account_id
             AND audit.expected_current_billing_account_id IS OLD.billing_account_id
             AND NEW.state='unsponsored'
             AND NEW.billing_account_id IS NULL
             AND NEW.sponsored_at IS OLD.sponsored_at)
         )
    )
  )
  OR
  (
    NEW.last_request_id IS OLD.last_request_id
    AND NEW.last_owner_detach_request_id IS NOT NULL
    AND EXISTS(
      SELECT 1 FROM billing_window_sponsorship_owner_detach_requests audit
       WHERE audit.client_request_id=NEW.last_owner_detach_request_id
         AND audit.window_lineage_id=OLD.window_lineage_id
         AND audit.expected_generation=OLD.generation
         AND audit.resulting_generation=NEW.generation
         AND audit.expected_billing_account_id IS OLD.billing_account_id
         AND audit.recorded_at=NEW.updated_at
         AND OLD.state='active'
         AND NEW.state='unsponsored'
         AND NEW.billing_account_id IS NULL
         AND NEW.sponsored_at IS OLD.sponsored_at
    )
  )
)
BEGIN SELECT RAISE(ABORT,'sponsorship update requires exact audit'); END;

CREATE TRIGGER billing_window_owner_detach_requests_are_immutable
BEFORE UPDATE ON billing_window_sponsorship_owner_detach_requests
BEGIN SELECT RAISE(ABORT,'owner detach audit immutable'); END;

CREATE TRIGGER billing_window_owner_detach_requests_cannot_be_deleted
BEFORE DELETE ON billing_window_sponsorship_owner_detach_requests
BEGIN SELECT RAISE(ABORT,'owner detach audit cannot be deleted'); END;
