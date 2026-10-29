PRAGMA foreign_keys = ON;

-- No runtime gate is enabled and no existing family/photo content is moved.
CREATE TABLE family_notebook_crypto_devices (
  family_id TEXT NOT NULL REFERENCES family_notebook_spaces(id),
  device_id TEXT NOT NULL REFERENCES group_person_devices(id),
  person_id TEXT NOT NULL REFERENCES group_people(id),
  identity_public_key TEXT NOT NULL,
  signing_public_key TEXT NOT NULL,
  hpke_public_key TEXT NOT NULL,
  person_authorization TEXT NOT NULL,
  PRIMARY KEY(family_id,device_id)
) STRICT;

CREATE TABLE family_notebook_crypto_rosters (
  family_id TEXT NOT NULL REFERENCES family_notebook_spaces(id),
  epoch INTEGER NOT NULL CHECK(epoch BETWEEN 1 AND 1000000000),
  roster_hash TEXT NOT NULL,
  packet TEXT NOT NULL CHECK(json_valid(packet)),
  PRIMARY KEY(family_id,epoch),
  UNIQUE(family_id,roster_hash)
) STRICT;

CREATE TABLE family_notebook_crypto_heads (
  family_id TEXT PRIMARY KEY REFERENCES family_notebook_spaces(id),
  epoch INTEGER NOT NULL,
  FOREIGN KEY(family_id,epoch) REFERENCES family_notebook_crypto_rosters(family_id,epoch)
) STRICT;

CREATE TABLE family_notebook_crypto_envelopes (
  family_id TEXT NOT NULL,
  current_epoch INTEGER NOT NULL,
  key_epoch INTEGER NOT NULL,
  recipient_device_id TEXT NOT NULL REFERENCES group_person_devices(id),
  signer_device_id TEXT NOT NULL REFERENCES group_person_devices(id),
  packet TEXT NOT NULL CHECK(json_valid(packet)),
  PRIMARY KEY(family_id,current_epoch,key_epoch,recipient_device_id,signer_device_id),
  FOREIGN KEY(family_id,current_epoch) REFERENCES family_notebook_crypto_rosters(family_id,epoch),
  FOREIGN KEY(family_id,key_epoch) REFERENCES family_notebook_crypto_rosters(family_id,epoch)
) STRICT;

CREATE TABLE family_notebook_crypto_operations (
  family_id TEXT NOT NULL REFERENCES family_notebook_spaces(id),
  sequence INTEGER NOT NULL CHECK(sequence>0),
  operation_id TEXT NOT NULL,
  epoch INTEGER NOT NULL,
  actor_person_id TEXT NOT NULL REFERENCES group_people(id),
  actor_device_id TEXT NOT NULL REFERENCES group_person_devices(id),
  packet TEXT NOT NULL CHECK(json_valid(packet)),
  PRIMARY KEY(family_id,sequence),
  UNIQUE(family_id,operation_id),
  FOREIGN KEY(family_id,epoch) REFERENCES family_notebook_crypto_rosters(family_id,epoch)
) STRICT;

-- A receipt contains no duplicate ciphertext or private data. It remains
-- usable after a lost response, key rotation or the actor leaving the family.
CREATE TABLE family_notebook_crypto_receipts (
  actor_device_id TEXT NOT NULL REFERENCES group_person_devices(id),
  operation_id TEXT NOT NULL,
  actor_person_id TEXT NOT NULL REFERENCES group_people(id),
  family_id TEXT NOT NULL REFERENCES family_notebook_spaces(id),
  action TEXT NOT NULL CHECK(action IN ('device','roster','key','operation')),
  request_hash TEXT NOT NULL,
  result TEXT NOT NULL CHECK(json_valid(result)),
  PRIMARY KEY(actor_device_id,operation_id)
) STRICT;

CREATE VIEW family_notebook_crypto_live_devices AS
SELECT c.* FROM family_notebook_crypto_devices c
JOIN family_notebook_members m ON m.family_id=c.family_id AND m.person_id=c.person_id AND m.state='active'
JOIN group_people p ON p.id=c.person_id AND p.state='active' AND p.identity_public_key=c.identity_public_key
JOIN group_person_devices d ON d.id=c.device_id AND d.person_id=c.person_id AND d.state='active'
  AND d.signing_public_key=c.signing_public_key AND d.hpke_public_key=c.hpke_public_key;

-- The relay cannot silently keep using a roster after a person/device changes.
-- Every active person must be represented and every registered family device
-- must have the same person/root/device certificate as the signed roster.
CREATE VIEW family_notebook_crypto_ready AS
SELECT h.family_id,h.epoch,r.roster_hash,r.packet FROM family_notebook_crypto_heads h
JOIN family_notebook_crypto_rosters r ON r.family_id=h.family_id AND r.epoch=h.epoch
WHERE NOT EXISTS (
  SELECT 1 FROM family_notebook_members m JOIN group_people p ON p.id=m.person_id AND p.state='active'
  WHERE m.family_id=h.family_id AND m.state='active' AND NOT EXISTS (
    SELECT 1 FROM json_each(r.packet,'$.roster.members') jm WHERE json_extract(jm.value,'$.personId')=m.person_id))
AND NOT EXISTS (
  SELECT 1 FROM json_each(r.packet,'$.roster.members') jm WHERE NOT EXISTS (
    SELECT 1 FROM family_notebook_members m JOIN group_people p ON p.id=m.person_id AND p.state='active'
    WHERE m.family_id=h.family_id AND m.person_id=json_extract(jm.value,'$.personId') AND m.state='active'))
AND NOT EXISTS (
  SELECT 1 FROM family_notebook_crypto_live_devices c WHERE c.family_id=h.family_id AND NOT EXISTS (
    SELECT 1 FROM json_each(r.packet,'$.roster.members') jm,json_each(jm.value,'$.devices') jd
    WHERE json_extract(jm.value,'$.personId')=c.person_id AND json_extract(jd.value,'$.id')=c.device_id
      AND json_extract(jm.value,'$.identityPublicKey')=c.identity_public_key
      AND json_extract(jd.value,'$.signingPublicKey')=c.signing_public_key
      AND json_extract(jd.value,'$.hpkePublicKey')=c.hpke_public_key
      AND json_extract(jd.value,'$.personAuthorization')=c.person_authorization))
AND NOT EXISTS (
  SELECT 1 FROM json_each(r.packet,'$.roster.members') jm,json_each(jm.value,'$.devices') jd WHERE NOT EXISTS (
    SELECT 1 FROM family_notebook_crypto_live_devices c WHERE c.family_id=h.family_id
      AND c.person_id=json_extract(jm.value,'$.personId') AND c.device_id=json_extract(jd.value,'$.id')));

-- A short-lived row in the same D1 batch as each read/write prevents a
-- membership, Plus or roster change between verification and commit.
CREATE TABLE family_notebook_crypto_checks (
  id TEXT PRIMARY KEY,
  family_id TEXT NOT NULL,
  person_id TEXT NOT NULL,
  device_id TEXT NOT NULL,
  generation INTEGER NOT NULL,
  epoch INTEGER,
  mode TEXT NOT NULL CHECK(mode IN ('read','device','roster','key','operation','ready')),
  store_environment TEXT
) STRICT;

CREATE TRIGGER family_notebook_crypto_check_validate BEFORE INSERT ON family_notebook_crypto_checks
BEGIN
  SELECT (CASE WHEN NOT EXISTS(SELECT 1 FROM family_notebook_runtime_gate WHERE singleton=1 AND enabled=1)
    THEN RAISE(ABORT,'family_notebook_disabled') END);
  SELECT (CASE WHEN NOT EXISTS (
    SELECT 1 FROM group_person_devices d JOIN group_people p ON p.id=d.person_id
    WHERE d.id=NEW.device_id AND d.person_id=NEW.person_id AND d.state='active' AND p.state='active')
    THEN RAISE(ABORT,'family_notebook_invalid_authentication') END);
  SELECT (CASE WHEN NOT EXISTS (
    SELECT 1 FROM family_notebook_members m JOIN family_notebook_spaces f ON f.id=m.family_id
    WHERE m.family_id=NEW.family_id AND m.person_id=NEW.person_id AND m.state='active' AND f.state='active')
    THEN RAISE(ABORT,'family_notebook_not_member') END);
  SELECT (CASE WHEN (SELECT generation FROM family_notebook_spaces WHERE id=NEW.family_id)<>NEW.generation
    THEN RAISE(ABORT,'family_notebook_stale_generation') END);
  SELECT (CASE WHEN NEW.epoch IS NOT NULL AND COALESCE((SELECT epoch FROM family_notebook_crypto_heads WHERE family_id=NEW.family_id),0)<>NEW.epoch
    THEN RAISE(ABORT,'family_notebook_crypto_stale') END);
  SELECT (CASE WHEN NEW.mode IN ('key','operation','ready') AND NOT EXISTS (
    SELECT 1 FROM family_notebook_crypto_ready WHERE family_id=NEW.family_id)
    THEN RAISE(ABORT,'family_notebook_crypto_stale') END);
  SELECT (CASE WHEN NEW.mode='operation' AND NOT EXISTS (
    SELECT 1 FROM family_notebook_spaces f JOIN group_verified_plus_people p ON p.person_id=f.payer_person_id
    WHERE f.id=NEW.family_id AND p.environment=NEW.store_environment)
    THEN RAISE(ABORT,'family_notebook_paused') END);
END;
