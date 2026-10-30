-- Optional encrypted sidecar; legacy photo bytes and rows keep their format.
CREATE TABLE group_photo_captions (
    moment_id TEXT PRIMARY KEY REFERENCES group_moments(id) ON DELETE CASCADE,
    ciphertext_size INTEGER NOT NULL CHECK(ciphertext_size BETWEEN 29 AND 4124),
    ciphertext_sha256 TEXT NOT NULL,
    sender_signature TEXT NOT NULL
) STRICT;
CREATE TRIGGER group_caption_immutable BEFORE UPDATE ON group_photo_captions
BEGIN SELECT RAISE(ABORT,'group_caption_immutable'); END;
