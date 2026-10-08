-- General-mode HTTP allowance: one fixed UTC minute, shared by every session.
-- Keep transient counters on the owner so deletion leaves no extra identifier.
-- They are not recovery content; updating them must not advance snapshot generations.
ALTER TABLE pa_owners ADD COLUMN http_request_minute INTEGER NOT NULL DEFAULT 0
  CHECK(typeof(http_request_minute)='integer' AND http_request_minute>=0);
ALTER TABLE pa_owners ADD COLUMN http_request_count INTEGER NOT NULL DEFAULT 0
  CHECK(typeof(http_request_count)='integer' AND http_request_count BETWEEN 0 AND 30);
