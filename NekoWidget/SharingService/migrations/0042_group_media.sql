PRAGMA foreign_keys = ON;

-- Group traffic is a separate, gated namespace. Legacy two-person records,
-- private archives and their object keys are not altered or removed here.
CREATE TABLE group_moments (
    id TEXT PRIMARY KEY,
    space_id TEXT NOT NULL REFERENCES group_windows(space_id),
    client_moment_id TEXT NOT NULL,
    sender_participant_id TEXT NOT NULL REFERENCES group_members(participant_id),
    sender_device_id TEXT NOT NULL REFERENCES group_person_devices(id),
    key_epoch INTEGER NOT NULL,
    roster_revision INTEGER NOT NULL,
    roster_hash TEXT NOT NULL,
    ciphertext_size INTEGER NOT NULL CHECK(ciphertext_size BETWEEN 29 AND 1048576),
    ciphertext_sha256 TEXT NOT NULL,
    sender_signature TEXT NOT NULL,
    kind TEXT NOT NULL CHECK(kind='photo'),
    state TEXT NOT NULL CHECK(state IN ('reserved','uploaded','committed','expired')),
    object_key TEXT NOT NULL UNIQUE,
    created_at INTEGER NOT NULL,
    upload_expires_at INTEGER NOT NULL,
    committed_at INTEGER,
    unreceived_expires_at INTEGER NOT NULL,
    expired_at INTEGER,
    UNIQUE(space_id,sender_device_id,client_moment_id),
    FOREIGN KEY(space_id,roster_revision) REFERENCES group_rosters(space_id,revision)
) STRICT;
CREATE INDEX group_moments_daily ON group_moments(space_id,sender_participant_id,created_at,state);
CREATE INDEX group_moments_expiry ON group_moments(state,unreceived_expires_at,id);
CREATE TRIGGER group_reservation_authority BEFORE INSERT ON group_moments
BEGIN
    SELECT (CASE WHEN NOT EXISTS (
        SELECT 1 FROM group_windows w JOIN group_window_devices d ON d.space_id=w.space_id
        JOIN group_members m ON m.participant_id=d.participant_id JOIN group_person_devices p ON p.id=d.device_id
        WHERE w.space_id=NEW.space_id AND w.mode='active' AND w.rotation_required=0
            AND w.revision=NEW.roster_revision AND w.key_epoch=NEW.key_epoch AND w.roster_hash=NEW.roster_hash
            AND d.device_id=NEW.sender_device_id AND d.state='active' AND m.state='active' AND p.state='active'
            AND m.participant_id=NEW.sender_participant_id)
        THEN RAISE(ABORT,'group_stale_epoch_or_membership') END);
    SELECT (CASE WHEN (SELECT COUNT(*) FROM group_moments
        WHERE space_id=NEW.space_id AND sender_participant_id=NEW.sender_participant_id
            AND created_at >= CAST(NEW.created_at / 86400 AS INTEGER) * 86400
            AND (state='committed' OR (state IN ('reserved','uploaded') AND upload_expires_at>NEW.created_at))) >= 5
        THEN RAISE(ABORT,'group_photo_daily_limit') END);
END;
CREATE TRIGGER group_moment_commit BEFORE UPDATE OF state ON group_moments
WHEN NEW.state IN ('uploaded','committed') AND NEW.state <> OLD.state
BEGIN
    SELECT (CASE WHEN OLD.state NOT IN ('reserved','uploaded') OR OLD.upload_expires_at<=unixepoch()
        OR (NEW.state='committed' AND OLD.state<>'uploaded')
        THEN RAISE(ABORT,'group_reservation_expired') END);
    SELECT (CASE WHEN NOT EXISTS (
        SELECT 1 FROM group_windows w JOIN group_window_devices d ON d.space_id=w.space_id
        JOIN group_members m ON m.participant_id=d.participant_id JOIN group_person_devices p ON p.id=d.device_id
        WHERE w.space_id=NEW.space_id AND w.mode='active' AND w.rotation_required=0 AND w.key_epoch=NEW.key_epoch
            AND w.revision=NEW.roster_revision AND w.roster_hash=NEW.roster_hash AND d.device_id=NEW.sender_device_id
            AND d.state='active' AND p.state='active' AND m.state='active' AND m.participant_id=NEW.sender_participant_id)
        THEN RAISE(ABORT,'group_stale_epoch_or_membership') END);
    SELECT (CASE WHEN NEW.state='committed' AND (SELECT COUNT(*) FROM group_moments
        WHERE space_id=NEW.space_id AND sender_participant_id=NEW.sender_participant_id AND state='committed'
            AND created_at >= CAST(NEW.created_at / 86400 AS INTEGER)*86400) >= 5
        THEN RAISE(ABORT,'group_photo_daily_limit') END);
END;
CREATE TABLE group_moment_deliveries (
    moment_id TEXT NOT NULL REFERENCES group_moments(id) ON DELETE CASCADE,
    device_id TEXT NOT NULL REFERENCES group_person_devices(id),
    participant_id TEXT NOT NULL REFERENCES group_members(participant_id),
    roster_revision INTEGER NOT NULL,
    state TEXT NOT NULL CHECK(state IN ('pending','acknowledged','expired')),
    access_expires_at INTEGER NOT NULL,
    acknowledged_at INTEGER,
    PRIMARY KEY(moment_id,device_id)
) STRICT;
CREATE INDEX group_deliveries_device ON group_moment_deliveries(device_id,state,access_expires_at,moment_id);
CREATE TABLE group_participant_blocks (
    space_id TEXT NOT NULL REFERENCES group_windows(space_id),
    blocker_id TEXT NOT NULL REFERENCES group_members(participant_id),
    blocked_id TEXT NOT NULL REFERENCES group_members(participant_id),
    active INTEGER NOT NULL CHECK(active IN (0,1)),
    updated_at INTEGER NOT NULL,
    PRIMARY KEY(space_id,blocker_id,blocked_id),
    CHECK(blocker_id<>blocked_id)
) STRICT;
CREATE TABLE group_media_access_checks (
    id TEXT PRIMARY KEY,
    device_id TEXT NOT NULL,
    moment_id TEXT NOT NULL REFERENCES group_moments(id),
    now INTEGER NOT NULL
) STRICT;
CREATE TRIGGER group_media_access BEFORE INSERT ON group_media_access_checks
BEGIN
    SELECT (CASE WHEN NOT EXISTS (
        SELECT 1 FROM group_moments p JOIN group_windows w ON w.space_id=p.space_id
        JOIN group_moment_deliveries delivery ON delivery.moment_id=p.id AND delivery.device_id=NEW.device_id
        JOIN group_window_devices d ON d.space_id=w.space_id AND d.device_id=NEW.device_id
        JOIN group_members m ON m.participant_id=d.participant_id
        JOIN group_person_devices global_device ON global_device.id=d.device_id
        JOIN group_people person ON person.id=global_device.person_id
        WHERE p.id=NEW.moment_id AND p.state='committed' AND p.unreceived_expires_at>NEW.now
            AND w.mode='active' AND d.state='active' AND m.state='active' AND global_device.state='active' AND person.state='active'
            AND delivery.state IN ('pending','acknowledged') AND delivery.access_expires_at>NEW.now
            AND delivery.roster_revision>=d.added_revision AND delivery.roster_revision>=m.joined_revision
            AND NOT EXISTS (SELECT 1 FROM group_participant_blocks b WHERE b.space_id=w.space_id AND b.active=1
                AND ((b.blocker_id=m.participant_id AND b.blocked_id=p.sender_participant_id)
                    OR (b.blocked_id=m.participant_id AND b.blocker_id=p.sender_participant_id))))
        THEN RAISE(ABORT,'group_delivery_unavailable') END);
END;
CREATE TABLE group_moment_hearts (
    moment_id TEXT NOT NULL REFERENCES group_moments(id) ON DELETE CASCADE,
    participant_id TEXT NOT NULL REFERENCES group_members(participant_id),
    device_id TEXT NOT NULL REFERENCES group_person_devices(id),
    active INTEGER NOT NULL CHECK(active IN (0,1)),
    key_epoch INTEGER NOT NULL,
    roster_revision INTEGER NOT NULL,
    roster_hash TEXT NOT NULL,
    operation_id TEXT NOT NULL,
    signature TEXT NOT NULL,
    updated_at INTEGER NOT NULL,
    PRIMARY KEY(moment_id,participant_id)
) STRICT;
CREATE TABLE group_heart_usage (
    space_id TEXT NOT NULL REFERENCES group_windows(space_id),
    participant_id TEXT NOT NULL REFERENCES group_members(participant_id),
    day_key INTEGER NOT NULL,
    used INTEGER NOT NULL CHECK(used BETWEEN 0 AND 30),
    PRIMARY KEY(space_id,participant_id,day_key)
) STRICT;
CREATE TABLE group_push_subscriptions (
    space_id TEXT NOT NULL,
    device_id TEXT NOT NULL,
    token_ciphertext TEXT NOT NULL,
    token_nonce TEXT NOT NULL,
    token_digest TEXT NOT NULL,
    encryption_key_id TEXT NOT NULL,
    environment TEXT NOT NULL CHECK(environment IN ('sandbox','production')),
    generation INTEGER NOT NULL,
    expires_at INTEGER NOT NULL,
    PRIMARY KEY(space_id,device_id),
    FOREIGN KEY(space_id,device_id) REFERENCES group_window_devices(space_id,device_id)
) STRICT;
CREATE INDEX group_push_token_digest ON group_push_subscriptions(token_digest);
CREATE TABLE group_notification_events (
    id TEXT PRIMARY KEY,
    space_id TEXT NOT NULL REFERENCES group_windows(space_id),
    moment_id TEXT NOT NULL REFERENCES group_moments(id) ON DELETE CASCADE,
    kind TEXT NOT NULL CHECK(kind IN ('new_moment','paw')),
    actor_participant_id TEXT NOT NULL REFERENCES group_members(participant_id),
    created_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL
) STRICT;
CREATE TABLE group_notification_deliveries (
    event_id TEXT NOT NULL REFERENCES group_notification_events(id) ON DELETE CASCADE,
    device_id TEXT NOT NULL REFERENCES group_person_devices(id),
    token_digest TEXT NOT NULL,
    subscription_generation INTEGER NOT NULL,
    state TEXT NOT NULL CHECK(state IN ('pending','leased','accepted','invalid','skipped')),
    attempts INTEGER NOT NULL DEFAULT 0,
    available_at INTEGER NOT NULL,
    lease_id TEXT,
    lease_expires_at INTEGER,
    PRIMARY KEY(event_id,device_id)
) STRICT;
CREATE INDEX group_notification_queue ON group_notification_deliveries(state,available_at,event_id,device_id);
CREATE TABLE group_object_deletions (
    moment_id TEXT PRIMARY KEY REFERENCES group_moments(id) ON DELETE CASCADE,
    object_key TEXT NOT NULL UNIQUE,
    attempts INTEGER NOT NULL DEFAULT 0,
    available_at INTEGER NOT NULL,
    state TEXT NOT NULL CHECK(state IN ('pending','completed'))
) STRICT;
