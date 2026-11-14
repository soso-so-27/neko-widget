PRAGMA foreign_keys = ON;

-- Track ciphertext only. Enforcement starts OFF and needs separate approval.
CREATE TABLE family_notebook_quota_policy (
  singleton INTEGER PRIMARY KEY CHECK(singleton=1),
  enabled INTEGER NOT NULL CHECK(enabled IN (0,1)),
  maximum_operations INTEGER NOT NULL CHECK(maximum_operations>0),
  maximum_bytes INTEGER NOT NULL CHECK(maximum_bytes>0),
  daily_operations INTEGER NOT NULL CHECK(daily_operations>0),
  daily_bytes INTEGER NOT NULL CHECK(daily_bytes>0)
) STRICT;
INSERT INTO family_notebook_quota_policy VALUES(1,0,500000,536870912,10000,16777216);
CREATE TRIGGER family_notebook_quota_policy_keep BEFORE DELETE ON family_notebook_quota_policy
BEGIN SELECT RAISE(ABORT,'family_notebook_quota_unavailable'); END;

CREATE TABLE family_notebook_usage (
  family_id TEXT PRIMARY KEY REFERENCES family_notebook_spaces(id) ON DELETE CASCADE,
  operations INTEGER NOT NULL CHECK(operations>=0),
  bytes INTEGER NOT NULL CHECK(bytes>=0)
) STRICT;
INSERT INTO family_notebook_usage
SELECT f.id,COUNT(o.operation_id),COALESCE(SUM(length(CAST(o.packet AS BLOB))),0)
FROM family_notebook_spaces f LEFT JOIN family_notebook_crypto_operations o ON o.family_id=f.id GROUP BY f.id;
CREATE TRIGGER family_notebook_usage_create AFTER INSERT ON family_notebook_spaces
BEGIN INSERT INTO family_notebook_usage VALUES(NEW.id,0,0); END;

-- A person's daily allowance is shared across their notebooks. Deleting an
-- operation does not refund today's allowance. No plaintext or device ID.
CREATE TABLE family_notebook_daily_usage (
  person_id TEXT NOT NULL REFERENCES group_people(id) ON DELETE CASCADE,
  day INTEGER NOT NULL,
  operations INTEGER NOT NULL CHECK(operations>=0),
  bytes INTEGER NOT NULL CHECK(bytes>=0),
  PRIMARY KEY(person_id,day)
) STRICT;
CREATE INDEX family_notebook_daily_usage_day ON family_notebook_daily_usage(day);

CREATE TRIGGER family_notebook_quota_admit BEFORE INSERT ON family_notebook_crypto_operations
BEGIN
  SELECT CASE WHEN NOT EXISTS(SELECT 1 FROM family_notebook_quota_policy WHERE singleton=1)
    OR NOT EXISTS(SELECT 1 FROM family_notebook_usage WHERE family_id=NEW.family_id)
    THEN RAISE(ABORT,'family_notebook_quota_unavailable') END;
  SELECT CASE WHEN (SELECT enabled FROM family_notebook_quota_policy)=1 AND
    (SELECT operations FROM family_notebook_usage WHERE family_id=NEW.family_id)+1>(SELECT maximum_operations FROM family_notebook_quota_policy)
    THEN RAISE(ABORT,'family_quota_total_operations') END;
  SELECT CASE WHEN (SELECT enabled FROM family_notebook_quota_policy)=1 AND
    (SELECT bytes FROM family_notebook_usage WHERE family_id=NEW.family_id)+length(CAST(NEW.packet AS BLOB))>(SELECT maximum_bytes FROM family_notebook_quota_policy)
    THEN RAISE(ABORT,'family_quota_total_bytes') END;
  SELECT CASE WHEN (SELECT enabled FROM family_notebook_quota_policy)=1 AND
    COALESCE((SELECT operations FROM family_notebook_daily_usage WHERE person_id=NEW.actor_person_id AND day=(unixepoch()+32400)/86400),0)+1>(SELECT daily_operations FROM family_notebook_quota_policy)
    THEN RAISE(ABORT,'family_quota_daily_operations') END;
  SELECT CASE WHEN (SELECT enabled FROM family_notebook_quota_policy)=1 AND
    COALESCE((SELECT bytes FROM family_notebook_daily_usage WHERE person_id=NEW.actor_person_id AND day=(unixepoch()+32400)/86400),0)+length(CAST(NEW.packet AS BLOB))>(SELECT daily_bytes FROM family_notebook_quota_policy)
    THEN RAISE(ABORT,'family_quota_daily_bytes') END;
END;
CREATE TRIGGER family_notebook_usage_append AFTER INSERT ON family_notebook_crypto_operations
BEGIN
  UPDATE family_notebook_usage SET operations=operations+1,bytes=bytes+length(CAST(NEW.packet AS BLOB)) WHERE family_id=NEW.family_id;
  INSERT INTO family_notebook_daily_usage VALUES(NEW.actor_person_id,(unixepoch()+32400)/86400,1,length(CAST(NEW.packet AS BLOB)))
    ON CONFLICT(person_id,day) DO UPDATE SET operations=operations+1,bytes=bytes+excluded.bytes;
  DELETE FROM family_notebook_daily_usage WHERE day<(unixepoch()+32400)/86400-1;
END;
CREATE TRIGGER family_notebook_usage_remove AFTER DELETE ON family_notebook_crypto_operations
BEGIN
  UPDATE family_notebook_usage SET operations=operations-1,bytes=bytes-length(CAST(OLD.packet AS BLOB)) WHERE family_id=OLD.family_id;
END;
CREATE TRIGGER family_notebook_operations_immutable BEFORE UPDATE ON family_notebook_crypto_operations
BEGIN SELECT RAISE(ABORT,'family_notebook_crypto_stale'); END;
