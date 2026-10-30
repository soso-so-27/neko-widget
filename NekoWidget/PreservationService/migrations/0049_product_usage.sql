-- Derived logical accounting. Never modify encrypted archives or claim that
-- pre-existing data has been counted. Recovery naturally invalidates these facts.
ALTER TABLE pa_owner_record_counters ADD COLUMN product_bytes INTEGER NOT NULL DEFAULT 0 CHECK(product_bytes>=0);
ALTER TABLE pa_owner_record_counters ADD COLUMN product_records INTEGER NOT NULL DEFAULT 0 CHECK(product_records>=0);
ALTER TABLE pa_owner_record_counters ADD COLUMN product_unknown INTEGER NOT NULL DEFAULT 0 CHECK(product_unknown>=0);
CREATE TABLE pa_product_record_usage (
  owner_id TEXT NOT NULL,
  record_id TEXT NOT NULL,
  revision INTEGER NOT NULL,
  logical_bytes INTEGER,
  visible_records INTEGER,
  PRIMARY KEY(owner_id,record_id),
  FOREIGN KEY(owner_id,record_id) REFERENCES pa_records(owner_id,record_id) ON DELETE CASCADE,
  CHECK((logical_bytes IS NULL AND visible_records IS NULL) OR
    (logical_bytes>=0 AND visible_records>=0))
);
CREATE TRIGGER pa_product_fact_insert AFTER INSERT ON pa_product_record_usage BEGIN
  UPDATE pa_owner_record_counters SET
    product_bytes=product_bytes+coalesce(NEW.logical_bytes,0),
    product_records=product_records+coalesce(NEW.visible_records,0),
    product_unknown=product_unknown+(NEW.logical_bytes IS NULL) WHERE owner_id=NEW.owner_id;
END;
CREATE TRIGGER pa_product_fact_update AFTER UPDATE ON pa_product_record_usage BEGIN
  UPDATE pa_owner_record_counters SET
    product_bytes=product_bytes+coalesce(NEW.logical_bytes,0)-coalesce(OLD.logical_bytes,0),
    product_records=product_records+coalesce(NEW.visible_records,0)-coalesce(OLD.visible_records,0),
    product_unknown=product_unknown+(NEW.logical_bytes IS NULL)-(OLD.logical_bytes IS NULL) WHERE owner_id=NEW.owner_id;
END;
CREATE TRIGGER pa_product_fact_delete AFTER DELETE ON pa_product_record_usage BEGIN
  UPDATE pa_owner_record_counters SET
    product_bytes=product_bytes-coalesce(OLD.logical_bytes,0),
    product_records=product_records-coalesce(OLD.visible_records,0),
    product_unknown=product_unknown-(OLD.logical_bytes IS NULL) WHERE owner_id=OLD.owner_id;
  UPDATE pa_owner_record_counters SET accounting_valid=0 WHERE owner_id=OLD.owner_id
    AND EXISTS(SELECT 1 FROM pa_records WHERE owner_id=OLD.owner_id AND record_id=OLD.record_id);
END;
INSERT INTO pa_product_record_usage SELECT owner_id,record_id,revision,
  CASE WHEN deleted=1 THEN 0 ELSE NULL END,CASE WHEN deleted=1 THEN 0 ELSE NULL END FROM pa_records;
CREATE TRIGGER pa_product_record_insert AFTER INSERT ON pa_records BEGIN
  INSERT INTO pa_product_record_usage VALUES(NEW.owner_id,NEW.record_id,NEW.revision,
    CASE WHEN NEW.deleted=1 THEN 0 ELSE NULL END,CASE WHEN NEW.deleted=1 THEN 0 ELSE NULL END);
END;
CREATE TRIGGER pa_product_record_update AFTER UPDATE OF revision,metadata,deleted ON pa_records BEGIN
  INSERT INTO pa_product_record_usage VALUES(NEW.owner_id,NEW.record_id,NEW.revision,
    CASE WHEN NEW.deleted=1 THEN 0 ELSE NULL END,CASE WHEN NEW.deleted=1 THEN 0 ELSE NULL END)
  ON CONFLICT(owner_id,record_id) DO UPDATE SET revision=excluded.revision,
    logical_bytes=excluded.logical_bytes,visible_records=excluded.visible_records;
END;
