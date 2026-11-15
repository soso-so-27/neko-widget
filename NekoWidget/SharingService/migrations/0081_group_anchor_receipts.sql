-- Public, root-signed pins only. No key material or existing-row backfill.
CREATE TABLE group_anchor_receipts (
  person_id TEXT NOT NULL REFERENCES group_people(id) ON DELETE CASCADE,
  space_id TEXT NOT NULL REFERENCES group_windows(space_id) ON DELETE CASCADE,
  environment TEXT NOT NULL CHECK(environment IN ('production','staging')),
  owner_person_id TEXT NOT NULL,
  owner_public_key TEXT NOT NULL,
  root_signature TEXT NOT NULL,
  PRIMARY KEY(person_id,space_id,environment)
) STRICT;

CREATE TRIGGER group_anchor_receipt_identity_cleanup AFTER UPDATE OF state ON group_people
WHEN NEW.state='revoked'
BEGIN
  DELETE FROM group_anchor_receipts WHERE person_id=NEW.id;
END;
