-- Reconstructible operation state only; never a logical-save acknowledgement.
-- One current batch/work row per owner bounds successful-operation history.
CREATE TABLE pa_tool_metadata_batches (
  owner_id TEXT PRIMARY KEY REFERENCES pa_owners(owner_id),
  batch_id TEXT NOT NULL,
  batch_nonce TEXT NOT NULL,
  owner_epoch INTEGER NOT NULL CHECK(owner_epoch >= 0),
  manifest_json TEXT NOT NULL CHECK(json_valid(manifest_json)),
  state TEXT NOT NULL CHECK(state IN ('open','ready')),
  created_at INTEGER NOT NULL CHECK(created_at > 0)
);
CREATE UNIQUE INDEX pa_tool_metadata_batch_id ON pa_tool_metadata_batches(batch_id);

CREATE TABLE pa_owner_delta_work (
  owner_id TEXT PRIMARY KEY REFERENCES pa_owners(owner_id),
  work_id TEXT NOT NULL,
  generation INTEGER NOT NULL,
  inventory_generation INTEGER NOT NULL,
  record_sequence INTEGER NOT NULL,
  record_count INTEGER NOT NULL,
  plan_json TEXT NOT NULL CHECK(json_valid(plan_json)),
  plan_mac TEXT NOT NULL,
  revision INTEGER NOT NULL DEFAULT 0 CHECK(revision >= 0)
);
-- Ciphertext prepared before PUT makes an uncertain retry use the exact key
-- and bytes. No decrypted record, key material or photo is stored here.
CREATE TABLE pa_owner_delta_nodes (
  owner_id TEXT NOT NULL REFERENCES pa_owners(owner_id),
  work_id TEXT NOT NULL,
  step_id TEXT NOT NULL,
  object_key TEXT NOT NULL,
  ciphertext BLOB NOT NULL,
  checkpoint_revision INTEGER NOT NULL DEFAULT 0 CHECK(checkpoint_revision >= 0),
  confirmed INTEGER NOT NULL DEFAULT 0 CHECK(confirmed IN (0,1)),
  PRIMARY KEY(owner_id,work_id,step_id)
);
