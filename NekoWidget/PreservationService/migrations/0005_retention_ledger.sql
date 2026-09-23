-- Dedicated preservation DB only. No migration-time deletion or status inference.
CREATE TABLE pa_retention (
  owner_id TEXT PRIMARY KEY NOT NULL REFERENCES pa_owners(owner_id) ON DELETE RESTRICT,
  revision INTEGER NOT NULL DEFAULT 1 CHECK (revision > 0),
  episode INTEGER NOT NULL DEFAULT 0 CHECK (episode >= 0),
  verified_status TEXT NOT NULL DEFAULT 'unknown' CHECK (verified_status IN ('active', 'grace', 'expired', 'unknown')),
  checked_at INTEGER NOT NULL DEFAULT 0 CHECK (checked_at >= 0),
  expired_at INTEGER CHECK (expired_at IS NULL OR expired_at >= 0),
  due_at INTEGER CHECK (due_at IS NULL OR due_at > expired_at),
  paused_at INTEGER CHECK (paused_at IS NULL OR paused_at >= expired_at),
  notice_not_before_at INTEGER NOT NULL DEFAULT 0 CHECK (notice_not_before_at >= 0),
  final_notice_delivered_at INTEGER CHECK (final_notice_delivered_at IS NULL OR final_notice_delivered_at >= 0),
  final_notice_receipt TEXT,
  CHECK ((final_notice_delivered_at IS NULL) = (final_notice_receipt IS NULL)),
  CHECK ((expired_at IS NULL AND due_at IS NULL AND paused_at IS NULL
      AND notice_not_before_at=0 AND final_notice_delivered_at IS NULL)
    OR (expired_at IS NOT NULL AND due_at IS NOT NULL AND notice_not_before_at >= expired_at))
);
CREATE INDEX pa_retention_due ON pa_retention(verified_status, due_at);
CREATE INDEX pa_retention_checked ON pa_retention(checked_at);
