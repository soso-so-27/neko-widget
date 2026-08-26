PRAGMA foreign_keys = ON;

-- Keep this migration LF-only; Wrangler remote trigger parsing rejects CRLF.
-- v1 routes are the shipped active-window-only contract. v2 routes require an
-- exact opaque window/photo target and are used only by additive v3
-- subscriptions, allowing an old binary to reject those pushes fail closed.
ALTER TABLE apns_subscriptions
    ADD COLUMN route_schema_version INTEGER NOT NULL DEFAULT 1
        CHECK (route_schema_version IN (1, 2));

-- A Worker rollback cannot name the new column. Its legacy UPSERT still
-- updates token/timestamp columns, so normalize that row to the legacy route
-- automatically. The forward Worker restores route 2 with a separate,
-- route-only UPDATE after its v3 UPSERT. This keeps rollback -> forward from
-- stranding an old client behind a stale targeted-route marker.
CREATE TRIGGER apns_subscriptions_normalize_legacy_route_update
AFTER UPDATE OF participant_id, environment,
                token_ciphertext, token_nonce, token_digest,
                encryption_key_id, updated_at, expires_at
ON apns_subscriptions
BEGIN
    UPDATE apns_subscriptions
       SET route_schema_version = 1
     WHERE device_id = NEW.device_id;
END;
