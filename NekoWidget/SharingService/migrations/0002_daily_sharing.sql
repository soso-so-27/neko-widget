PRAGMA foreign_keys = ON;

-- Phase 2 arms object deletion before the first R2 write. Rebuild the Phase 1
-- job table so an active space can carry an inert deletion gate.
DROP TRIGGER revocations_disable_space;
DROP INDEX space_deletion_jobs_pending;
ALTER TABLE space_deletion_jobs RENAME TO space_deletion_jobs_phase1;

CREATE TABLE space_deletion_jobs (
    space_id TEXT PRIMARY KEY,
    state TEXT NOT NULL CHECK (state IN ('armed', 'pending', 'complete')),
    requires_object_deletion INTEGER NOT NULL DEFAULT 0 CHECK (requires_object_deletion IN (0, 1)),
    created_at INTEGER NOT NULL,
    completed_at INTEGER,
    empty_sweep_started_at INTEGER,
    last_sweep_at INTEGER,
    sweep_count INTEGER NOT NULL DEFAULT 0 CHECK (sweep_count >= 0)
) STRICT;

INSERT INTO space_deletion_jobs(
    space_id, state, requires_object_deletion, created_at, completed_at
)
SELECT space_id, state, requires_object_deletion, created_at, completed_at
  FROM space_deletion_jobs_phase1;

DROP TABLE space_deletion_jobs_phase1;

CREATE INDEX space_deletion_jobs_pending
    ON space_deletion_jobs(state, created_at, space_id);

CREATE INDEX space_deletion_jobs_object_pending
    ON space_deletion_jobs(state, requires_object_deletion, created_at, space_id);

DROP INDEX spaces_metadata_expiry;
CREATE INDEX spaces_metadata_expiry
    ON spaces(state, metadata_expires_at, id);

CREATE TABLE sharing_storage_scopes (
    space_id TEXT PRIMARY KEY REFERENCES spaces(id) ON DELETE CASCADE,
    object_prefix TEXT NOT NULL UNIQUE,
    created_at INTEGER NOT NULL
) STRICT;

CREATE TABLE sharing_sources (
    id TEXT PRIMARY KEY,
    space_id TEXT NOT NULL REFERENCES spaces(id) ON DELETE CASCADE,
    publisher_member_id TEXT NOT NULL REFERENCES members(id) ON DELETE CASCADE,
    state TEXT NOT NULL CHECK (state IN ('active', 'revoked')),
    current_revision INTEGER NOT NULL DEFAULT 0 CHECK (current_revision >= 0),
    last_committed_share_day_key INTEGER,
    cleanup_blocked INTEGER NOT NULL DEFAULT 0 CHECK (cleanup_blocked IN (0, 1)),
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    UNIQUE (space_id, publisher_member_id)
) STRICT;

CREATE INDEX sharing_sources_space
    ON sharing_sources(space_id, state, id);

CREATE INDEX sharing_sources_cleanup
    ON sharing_sources(cleanup_blocked, state, updated_at, id);

CREATE TRIGGER sharing_sources_require_active_member
BEFORE INSERT ON sharing_sources
BEGIN
    SELECT CASE WHEN NOT EXISTS (
        SELECT 1
          FROM members AS m
          JOIN spaces AS s ON s.id = m.space_id
         WHERE m.id = NEW.publisher_member_id
           AND m.space_id = NEW.space_id
           AND m.state = 'active'
           AND s.state = 'active'
    ) THEN RAISE(ABORT, 'publisher must be an active member') END;
END;

CREATE TABLE sharing_daily_freezes (
    source_id TEXT NOT NULL REFERENCES sharing_sources(id) ON DELETE CASCADE,
    share_day_key INTEGER NOT NULL,
    generation_id TEXT NOT NULL UNIQUE,
    created_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL,
    PRIMARY KEY (source_id, share_day_key),
    CHECK (expires_at > created_at)
) STRICT;

CREATE INDEX sharing_daily_freezes_expiry
    ON sharing_daily_freezes(expires_at, source_id, share_day_key);

CREATE TABLE sharing_generations (
    id TEXT PRIMARY KEY,
    source_id TEXT NOT NULL REFERENCES sharing_sources(id) ON DELETE CASCADE,
    space_id TEXT NOT NULL REFERENCES spaces(id) ON DELETE CASCADE,
    publisher_member_id TEXT NOT NULL REFERENCES members(id) ON DELETE CASCADE,
    share_day_key INTEGER NOT NULL,
    state TEXT NOT NULL CHECK (
        state IN ('reserved', 'uploading', 'prepared', 'committed', 'superseded', 'expired')
    ),
    item_count INTEGER NOT NULL CHECK (item_count BETWEEN 1 AND 20),
    reserve_request_hash TEXT NOT NULL,
    descriptor_request_hash TEXT,
    created_at INTEGER NOT NULL,
    staging_expires_at INTEGER NOT NULL,
    prepare_attempt_revision INTEGER NOT NULL DEFAULT 0 CHECK (prepare_attempt_revision >= 0),
    prepare_attempt_id TEXT UNIQUE,
    reserved_revision INTEGER,
    rotation_anchor_utc INTEGER,
    prepare_expires_at INTEGER,
    manifest_object_key TEXT UNIQUE,
    manifest_ciphertext_size INTEGER,
    manifest_ciphertext_sha256 TEXT,
    manifest_verified_at INTEGER,
    committed_at INTEGER,
    content_expires_at INTEGER,
    revision INTEGER,
    closed_at INTEGER,
    CHECK (staging_expires_at > created_at),
    CHECK (staging_expires_at <= created_at + 3600),
    CHECK (manifest_ciphertext_size IS NULL OR manifest_ciphertext_size BETWEEN 29 AND 65536),
    UNIQUE (source_id, share_day_key)
) STRICT;

CREATE UNIQUE INDEX one_staging_generation_per_source
    ON sharing_generations(source_id)
    WHERE state IN ('reserved', 'uploading', 'prepared');

CREATE INDEX sharing_generations_staging_expiry
    ON sharing_generations(staging_expires_at, id)
    WHERE state IN ('reserved', 'uploading', 'prepared');

CREATE INDEX sharing_generations_content_expiry
    ON sharing_generations(content_expires_at, id)
    WHERE state = 'committed';

CREATE INDEX sharing_generations_terminal_cleanup
    ON sharing_generations(closed_at, id)
    WHERE state IN ('superseded', 'expired');

CREATE TRIGGER sharing_generations_require_live_source
BEFORE INSERT ON sharing_generations
BEGIN
    SELECT CASE WHEN NOT EXISTS (
        SELECT 1
          FROM sharing_sources AS src
          JOIN members AS m ON m.id = src.publisher_member_id
          JOIN spaces AS s ON s.id = src.space_id
          JOIN sharing_storage_scopes AS storage ON storage.space_id = src.space_id
          JOIN space_deletion_jobs AS deletion ON deletion.space_id = src.space_id
         WHERE src.id = NEW.source_id
           AND src.space_id = NEW.space_id
           AND src.publisher_member_id = NEW.publisher_member_id
           AND src.state = 'active'
           AND src.cleanup_blocked = 0
           AND m.state = 'active'
           AND s.state = 'active'
           AND deletion.state = 'armed'
           AND deletion.requires_object_deletion = 1
           AND EXISTS (
             SELECT 1 FROM sharing_daily_freezes AS freeze
              WHERE freeze.source_id = NEW.source_id
                AND freeze.share_day_key = NEW.share_day_key
                AND freeze.generation_id = NEW.id
           )
    ) THEN RAISE(ABORT, 'generation requires a live armed source') END;
END;

CREATE TABLE sharing_generation_media (
    generation_id TEXT NOT NULL REFERENCES sharing_generations(id) ON DELETE CASCADE,
    media_id TEXT NOT NULL,
    object_key TEXT NOT NULL UNIQUE,
    state TEXT NOT NULL CHECK (state IN ('reserved', 'expected', 'verified')),
    ciphertext_size INTEGER,
    ciphertext_sha256 TEXT,
    verified_at INTEGER,
    PRIMARY KEY (generation_id, media_id),
    CHECK (ciphertext_size IS NULL OR ciphertext_size BETWEEN 29 AND 307200),
    CHECK ((ciphertext_size IS NULL) = (ciphertext_sha256 IS NULL)),
    CHECK (
      (state = 'reserved' AND ciphertext_size IS NULL AND verified_at IS NULL)
      OR (state = 'expected' AND ciphertext_size IS NOT NULL AND verified_at IS NULL)
      OR (state = 'verified' AND ciphertext_size IS NOT NULL AND verified_at IS NOT NULL)
    )
) STRICT;

CREATE INDEX sharing_generation_media_state
    ON sharing_generation_media(generation_id, state, media_id);

CREATE TRIGGER sharing_media_capacity_and_state
BEFORE INSERT ON sharing_generation_media
BEGIN
    SELECT CASE WHEN NOT EXISTS (
        SELECT 1 FROM sharing_generations
         WHERE id = NEW.generation_id AND state = 'reserved'
    ) THEN RAISE(ABORT, 'media requires reserved generation') END;
    SELECT CASE WHEN (
        SELECT COUNT(*) FROM sharing_generation_media
         WHERE generation_id = NEW.generation_id
    ) >= 20 THEN RAISE(ABORT, 'generation media capacity exceeded') END;
END;

CREATE TRIGGER sharing_media_descriptors_are_immutable
BEFORE UPDATE OF ciphertext_size, ciphertext_sha256 ON sharing_generation_media
WHEN OLD.ciphertext_size IS NOT NULL
  AND (
    OLD.ciphertext_size IS NOT NEW.ciphertext_size
    OR OLD.ciphertext_sha256 IS NOT NEW.ciphertext_sha256
  )
BEGIN
    SELECT RAISE(ABORT, 'media descriptor is immutable');
END;

CREATE TRIGGER sharing_media_verified_state_is_terminal
BEFORE UPDATE OF state, verified_at ON sharing_generation_media
WHEN OLD.state = 'verified'
  AND (NEW.state IS NOT OLD.state OR NEW.verified_at IS NOT OLD.verified_at)
BEGIN
    SELECT RAISE(ABORT, 'verified media is immutable');
END;

CREATE TABLE sharing_descriptor_events (
    generation_id TEXT PRIMARY KEY REFERENCES sharing_generations(id) ON DELETE CASCADE,
    actor_member_id TEXT NOT NULL REFERENCES members(id) ON DELETE CASCADE,
    client_request_id TEXT NOT NULL,
    request_hash TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    UNIQUE (actor_member_id, client_request_id)
) STRICT;

CREATE TRIGGER sharing_descriptors_require_reserved_generation
BEFORE INSERT ON sharing_descriptor_events
BEGIN
    SELECT CASE WHEN NOT EXISTS (
        SELECT 1
          FROM sharing_generations AS g
          JOIN sharing_sources AS src ON src.id = g.source_id
          JOIN members AS m ON m.id = NEW.actor_member_id
          JOIN spaces AS s ON s.id = g.space_id
         WHERE g.id = NEW.generation_id
           AND g.publisher_member_id = NEW.actor_member_id
           AND g.state = 'reserved'
           AND g.staging_expires_at > NEW.created_at
           AND src.state = 'active'
           AND m.state = 'active'
           AND s.state = 'active'
           AND (SELECT COUNT(*) FROM sharing_generation_media AS gm
                 WHERE gm.generation_id = g.id AND gm.state = 'reserved') = g.item_count
    ) THEN RAISE(ABORT, 'invalid descriptor transition') END;
END;

CREATE TRIGGER sharing_descriptors_mark_generation
AFTER INSERT ON sharing_descriptor_events
BEGIN
    UPDATE sharing_generations
       SET state = 'uploading', descriptor_request_hash = NEW.request_hash
     WHERE id = NEW.generation_id;
END;

CREATE TABLE sharing_media_verification_events (
    generation_id TEXT NOT NULL,
    media_id TEXT NOT NULL,
    actor_member_id TEXT NOT NULL REFERENCES members(id) ON DELETE CASCADE,
    object_key TEXT NOT NULL,
    ciphertext_size INTEGER NOT NULL CHECK (ciphertext_size BETWEEN 29 AND 307200),
    ciphertext_sha256 TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    PRIMARY KEY (generation_id, media_id),
    FOREIGN KEY (generation_id, media_id)
      REFERENCES sharing_generation_media(generation_id, media_id) ON DELETE CASCADE
) STRICT;

CREATE TRIGGER sharing_media_verification_requires_live_upload
BEFORE INSERT ON sharing_media_verification_events
BEGIN
    SELECT CASE WHEN NOT EXISTS (
        SELECT 1
          FROM sharing_generation_media AS gm
          JOIN sharing_generations AS g ON g.id = gm.generation_id
          JOIN sharing_sources AS src ON src.id = g.source_id
          JOIN members AS m ON m.id = NEW.actor_member_id
          JOIN spaces AS s ON s.id = g.space_id
          JOIN space_deletion_jobs AS deletion ON deletion.space_id = g.space_id
         WHERE gm.generation_id = NEW.generation_id
           AND gm.media_id = NEW.media_id
           AND gm.object_key = NEW.object_key
           AND gm.state = 'expected'
           AND gm.ciphertext_size = NEW.ciphertext_size
           AND gm.ciphertext_sha256 = NEW.ciphertext_sha256
           AND g.state = 'uploading'
           AND g.publisher_member_id = NEW.actor_member_id
           AND g.staging_expires_at > NEW.created_at
           AND src.state = 'active'
           AND m.state = 'active'
           AND s.state = 'active'
           AND deletion.state = 'armed'
           AND deletion.requires_object_deletion = 1
    ) THEN RAISE(ABORT, 'invalid media verification transition') END;
END;

CREATE TRIGGER sharing_media_verification_marks_object
AFTER INSERT ON sharing_media_verification_events
BEGIN
    UPDATE sharing_generation_media
       SET state = 'verified', verified_at = NEW.created_at
     WHERE generation_id = NEW.generation_id AND media_id = NEW.media_id;
END;

CREATE TABLE sharing_currents (
    source_id TEXT PRIMARY KEY REFERENCES sharing_sources(id) ON DELETE CASCADE,
    generation_id TEXT NOT NULL UNIQUE REFERENCES sharing_generations(id) ON DELETE CASCADE,
    revision INTEGER NOT NULL CHECK (revision > 0),
    updated_at INTEGER NOT NULL
) STRICT;

CREATE TABLE sharing_object_deletions (
    object_key TEXT PRIMARY KEY,
    space_id TEXT NOT NULL,
    source_id TEXT,
    reason TEXT NOT NULL CHECK (
        reason IN ('rotation', 'staging_expired', 'content_expired', 'reprepare', 'revoke_or_inactivity')
    ),
    state TEXT NOT NULL DEFAULT 'pending' CHECK (state IN ('pending', 'deleted')),
    not_before INTEGER NOT NULL,
    attempts INTEGER NOT NULL DEFAULT 0 CHECK (attempts >= 0),
    created_at INTEGER NOT NULL,
    deleted_at INTEGER
) STRICT;

CREATE INDEX sharing_object_deletions_pending
    ON sharing_object_deletions(state, not_before, created_at, object_key);

CREATE INDEX sharing_object_deletions_source
    ON sharing_object_deletions(source_id, state);

CREATE TABLE sharing_prepare_events (
    generation_id TEXT NOT NULL REFERENCES sharing_generations(id) ON DELETE CASCADE,
    actor_member_id TEXT NOT NULL REFERENCES members(id) ON DELETE CASCADE,
    client_request_id TEXT NOT NULL,
    request_hash TEXT NOT NULL,
    attempt_id TEXT NOT NULL UNIQUE,
    attempt_revision INTEGER NOT NULL CHECK (attempt_revision > 0),
    reserved_revision INTEGER NOT NULL CHECK (reserved_revision > 0),
    rotation_anchor_utc INTEGER NOT NULL,
    created_at INTEGER NOT NULL,
    PRIMARY KEY (generation_id, attempt_revision),
    UNIQUE (actor_member_id, client_request_id)
) STRICT;

CREATE TRIGGER sharing_prepare_requires_complete_latest_generation
BEFORE INSERT ON sharing_prepare_events
BEGIN
    SELECT CASE WHEN NOT EXISTS (
        SELECT 1
          FROM sharing_generations AS g
          JOIN sharing_sources AS src ON src.id = g.source_id
          JOIN members AS m ON m.id = NEW.actor_member_id
          JOIN spaces AS s ON s.id = g.space_id
         WHERE g.id = NEW.generation_id
           AND g.publisher_member_id = NEW.actor_member_id
           AND g.state IN ('uploading', 'prepared')
           AND g.staging_expires_at > NEW.created_at
           AND src.state = 'active'
           AND src.cleanup_blocked = 0
           AND m.state = 'active'
           AND s.state = 'active'
           AND NEW.attempt_revision = g.prepare_attempt_revision + 1
           AND NEW.reserved_revision = src.current_revision + 1
           AND NEW.rotation_anchor_utc >= NEW.created_at + 300
           AND NEW.rotation_anchor_utc % 1200 = 0
           AND (
             g.state = 'uploading'
             OR (g.state = 'prepared' AND g.rotation_anchor_utc <= NEW.created_at)
           )
           AND (SELECT COUNT(*) FROM sharing_generation_media AS gm
                 WHERE gm.generation_id = g.id AND gm.state = 'verified') = g.item_count
    ) THEN RAISE(ABORT, 'invalid prepare transition') END;
END;

CREATE TRIGGER sharing_prepare_replaces_expired_attempt
AFTER INSERT ON sharing_prepare_events
BEGIN
    INSERT OR IGNORE INTO sharing_object_deletions(
        object_key, space_id, source_id, reason, not_before, created_at
    )
    SELECT manifest_object_key, space_id, source_id, 'reprepare', NEW.created_at + 600, NEW.created_at
      FROM sharing_generations
     WHERE id = NEW.generation_id AND manifest_object_key IS NOT NULL;

    UPDATE sharing_generations
       SET state = 'prepared',
           prepare_attempt_revision = NEW.attempt_revision,
           prepare_attempt_id = NEW.attempt_id,
           reserved_revision = NEW.reserved_revision,
           rotation_anchor_utc = NEW.rotation_anchor_utc,
           prepare_expires_at = NEW.rotation_anchor_utc,
           manifest_object_key = NULL,
           manifest_ciphertext_size = NULL,
           manifest_ciphertext_sha256 = NULL,
           manifest_verified_at = NULL
     WHERE id = NEW.generation_id;
END;

CREATE TABLE sharing_manifest_verification_events (
    generation_id TEXT NOT NULL REFERENCES sharing_generations(id) ON DELETE CASCADE,
    attempt_id TEXT NOT NULL,
    actor_member_id TEXT NOT NULL REFERENCES members(id) ON DELETE CASCADE,
    object_key TEXT NOT NULL,
    ciphertext_size INTEGER NOT NULL CHECK (ciphertext_size BETWEEN 29 AND 65536),
    ciphertext_sha256 TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    PRIMARY KEY (generation_id, attempt_id)
) STRICT;

CREATE TRIGGER sharing_manifest_verification_requires_latest_attempt
BEFORE INSERT ON sharing_manifest_verification_events
BEGIN
    SELECT CASE WHEN NOT EXISTS (
        SELECT 1
          FROM sharing_generations AS g
          JOIN sharing_sources AS src ON src.id = g.source_id
          JOIN members AS m ON m.id = NEW.actor_member_id
          JOIN spaces AS s ON s.id = g.space_id
          JOIN space_deletion_jobs AS deletion ON deletion.space_id = g.space_id
         WHERE g.id = NEW.generation_id
           AND g.prepare_attempt_id = NEW.attempt_id
           AND g.publisher_member_id = NEW.actor_member_id
           AND g.state = 'prepared'
           AND g.rotation_anchor_utc > NEW.created_at
           AND g.prepare_expires_at > NEW.created_at
           AND g.staging_expires_at > NEW.created_at
           AND g.manifest_object_key = NEW.object_key
           AND g.manifest_ciphertext_size IS NULL
           AND g.manifest_ciphertext_sha256 IS NULL
           AND src.state = 'active'
           AND m.state = 'active'
           AND s.state = 'active'
           AND deletion.state = 'armed'
           AND deletion.requires_object_deletion = 1
    ) THEN RAISE(ABORT, 'invalid manifest verification transition') END;
END;

CREATE TRIGGER sharing_manifest_verification_marks_object
AFTER INSERT ON sharing_manifest_verification_events
BEGIN
    UPDATE sharing_generations
       SET manifest_ciphertext_size = NEW.ciphertext_size,
           manifest_ciphertext_sha256 = NEW.ciphertext_sha256,
           manifest_verified_at = NEW.created_at
     WHERE id = NEW.generation_id;
END;

CREATE TABLE sharing_commit_events (
    generation_id TEXT PRIMARY KEY REFERENCES sharing_generations(id) ON DELETE CASCADE,
    actor_member_id TEXT NOT NULL REFERENCES members(id) ON DELETE CASCADE,
    client_request_id TEXT NOT NULL,
    request_hash TEXT NOT NULL,
    attempt_id TEXT NOT NULL,
    attempt_revision INTEGER NOT NULL,
    reserved_revision INTEGER NOT NULL,
    manifest_ciphertext_sha256 TEXT NOT NULL,
    server_share_day_key INTEGER NOT NULL,
    created_at INTEGER NOT NULL,
    UNIQUE (actor_member_id, client_request_id)
) STRICT;

CREATE TRIGGER sharing_commit_requires_latest_verified_attempt
BEFORE INSERT ON sharing_commit_events
BEGIN
    SELECT CASE WHEN NOT EXISTS (
        SELECT 1
          FROM sharing_generations AS g
          JOIN sharing_sources AS src ON src.id = g.source_id
          JOIN members AS m ON m.id = NEW.actor_member_id
          JOIN spaces AS s ON s.id = g.space_id
         WHERE g.id = NEW.generation_id
           AND g.publisher_member_id = NEW.actor_member_id
           AND g.state = 'prepared'
           AND g.staging_expires_at > NEW.created_at
           AND g.prepare_attempt_id = NEW.attempt_id
           AND g.prepare_attempt_revision = NEW.attempt_revision
           AND g.reserved_revision = NEW.reserved_revision
           AND g.rotation_anchor_utc > NEW.created_at
           AND g.prepare_expires_at > NEW.created_at
           AND g.manifest_object_key IS NOT NULL
           AND g.manifest_ciphertext_sha256 = NEW.manifest_ciphertext_sha256
           AND g.manifest_verified_at IS NOT NULL
           AND g.share_day_key = NEW.server_share_day_key
           AND src.state = 'active'
           AND src.current_revision + 1 = NEW.reserved_revision
           AND (src.last_committed_share_day_key IS NULL
                OR src.last_committed_share_day_key < g.share_day_key)
           AND m.state = 'active'
           AND s.state = 'active'
           AND (SELECT COUNT(*) FROM sharing_generation_media AS gm
                 WHERE gm.generation_id = g.id AND gm.state = 'verified') = g.item_count
    ) THEN RAISE(ABORT, 'invalid commit transition') END;
END;

CREATE TRIGGER sharing_commit_switches_current
AFTER INSERT ON sharing_commit_events
BEGIN
    INSERT OR IGNORE INTO sharing_object_deletions(
        object_key, space_id, source_id, reason, not_before, created_at
    )
    SELECT gm.object_key, old.space_id, old.source_id, 'rotation', NEW.created_at + 600, NEW.created_at
      FROM sharing_currents AS current
      JOIN sharing_generations AS old ON old.id = current.generation_id
      JOIN sharing_generation_media AS gm ON gm.generation_id = old.id
     WHERE current.source_id = (SELECT source_id FROM sharing_generations WHERE id = NEW.generation_id);

    INSERT OR IGNORE INTO sharing_object_deletions(
        object_key, space_id, source_id, reason, not_before, created_at
    )
    SELECT old.manifest_object_key, old.space_id, old.source_id, 'rotation', NEW.created_at + 600, NEW.created_at
      FROM sharing_currents AS current
      JOIN sharing_generations AS old ON old.id = current.generation_id
     WHERE current.source_id = (SELECT source_id FROM sharing_generations WHERE id = NEW.generation_id)
       AND old.manifest_object_key IS NOT NULL;

    UPDATE sharing_generations
       SET state = 'superseded', closed_at = NEW.created_at
     WHERE id = (
       SELECT generation_id FROM sharing_currents
        WHERE source_id = (SELECT source_id FROM sharing_generations WHERE id = NEW.generation_id)
     );

    UPDATE sharing_sources
       SET current_revision = NEW.reserved_revision,
           last_committed_share_day_key = NEW.server_share_day_key,
           cleanup_blocked = CASE
             WHEN EXISTS (
               SELECT 1 FROM sharing_currents
                WHERE source_id = sharing_sources.id
             ) THEN 1 ELSE cleanup_blocked END,
           updated_at = NEW.created_at
     WHERE id = (SELECT source_id FROM sharing_generations WHERE id = NEW.generation_id);

    UPDATE sharing_generations
       SET state = 'committed',
           revision = NEW.reserved_revision,
           committed_at = NEW.created_at,
           content_expires_at = NEW.created_at + 2592000
     WHERE id = NEW.generation_id;

    INSERT INTO sharing_currents(source_id, generation_id, revision, updated_at)
    SELECT source_id, id, NEW.reserved_revision, NEW.created_at
      FROM sharing_generations WHERE id = NEW.generation_id
    ON CONFLICT(source_id) DO UPDATE SET
      generation_id = excluded.generation_id,
      revision = excluded.revision,
      updated_at = excluded.updated_at;
END;

CREATE TABLE sharing_close_events (
    generation_id TEXT PRIMARY KEY REFERENCES sharing_generations(id) ON DELETE CASCADE,
    reason TEXT NOT NULL CHECK (reason IN ('staging_expired', 'content_expired')),
    created_at INTEGER NOT NULL
) STRICT;

CREATE TRIGGER sharing_close_requires_expired_live_generation
BEFORE INSERT ON sharing_close_events
BEGIN
    SELECT CASE WHEN NOT EXISTS (
        SELECT 1
          FROM sharing_generations AS g
         WHERE g.id = NEW.generation_id
           AND (
             (NEW.reason = 'staging_expired'
              AND g.state IN ('reserved', 'uploading', 'prepared')
              AND g.staging_expires_at <= NEW.created_at)
             OR
             (NEW.reason = 'content_expired'
              AND g.state = 'committed'
              AND g.content_expires_at <= NEW.created_at
              AND EXISTS (
                SELECT 1 FROM sharing_currents WHERE generation_id = g.id
              ))
           )
    ) THEN RAISE(ABORT, 'invalid generation close transition') END;
END;

CREATE TRIGGER sharing_close_disables_upload_then_queues_objects
AFTER INSERT ON sharing_close_events
BEGIN
    UPDATE sharing_generations
       SET state = 'expired', closed_at = NEW.created_at
     WHERE id = NEW.generation_id;

    DELETE FROM sharing_currents WHERE generation_id = NEW.generation_id;

    INSERT OR IGNORE INTO sharing_object_deletions(
        object_key, space_id, source_id, reason, not_before, created_at
    )
    SELECT gm.object_key, g.space_id, g.source_id, NEW.reason,
           NEW.created_at + 600, NEW.created_at
      FROM sharing_generation_media AS gm
      JOIN sharing_generations AS g ON g.id = gm.generation_id
     WHERE gm.generation_id = NEW.generation_id;

    INSERT OR IGNORE INTO sharing_object_deletions(
        object_key, space_id, source_id, reason, not_before, created_at
    )
    SELECT manifest_object_key, space_id, source_id, NEW.reason,
           NEW.created_at + 600, NEW.created_at
      FROM sharing_generations
     WHERE id = NEW.generation_id AND manifest_object_key IS NOT NULL;

    UPDATE sharing_sources
       SET cleanup_blocked = 1, updated_at = NEW.created_at
     WHERE id = (SELECT source_id FROM sharing_generations WHERE id = NEW.generation_id);
END;

CREATE TRIGGER revocations_disable_space
AFTER INSERT ON revocation_events
BEGIN
    UPDATE spaces
       SET state = 'revoked', revoked_at = NEW.created_at
     WHERE id = NEW.space_id;
    UPDATE members
       SET state = 'revoked', revoked_at = NEW.created_at
     WHERE space_id = NEW.space_id;
    UPDATE invitations
       SET status = 'revoked', invite_proof_public_key = NULL
     WHERE space_id = NEW.space_id AND status = 'open';
    UPDATE enrollments
       SET state = 'revoked'
     WHERE space_id = NEW.space_id AND state IN ('pending', 'approved');
    UPDATE approval_events
       SET key_envelope = NULL, approval_signature = NULL
     WHERE enrollment_id IN (SELECT id FROM enrollments WHERE space_id = NEW.space_id);
    DELETE FROM invitation_challenges
     WHERE invitation_id IN (SELECT id FROM invitations WHERE space_id = NEW.space_id);
    UPDATE sharing_sources
       SET state = 'revoked', updated_at = NEW.created_at
     WHERE space_id = NEW.space_id;
    INSERT INTO space_deletion_jobs(
        space_id, state, requires_object_deletion, created_at,
        completed_at, empty_sweep_started_at, last_sweep_at, sweep_count
    )
    VALUES (
        NEW.space_id,
        'pending',
        CASE WHEN EXISTS (
          SELECT 1 FROM sharing_storage_scopes WHERE space_id = NEW.space_id
        ) THEN 1 ELSE 0 END,
        NEW.created_at, NULL, NULL, NULL, 0
    )
    ON CONFLICT(space_id) DO UPDATE SET
      state = 'pending',
      requires_object_deletion = MAX(
        space_deletion_jobs.requires_object_deletion,
        excluded.requires_object_deletion
      ),
      created_at = excluded.created_at,
      completed_at = NULL,
      empty_sweep_started_at = NULL,
      last_sweep_at = NULL,
      sweep_count = 0;
END;
