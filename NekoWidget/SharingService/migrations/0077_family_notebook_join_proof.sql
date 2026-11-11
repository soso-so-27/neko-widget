-- Older joins have no stored proof. They remain readable as historical events.
ALTER TABLE family_notebook_admission_events ADD COLUMN join_proof_signature TEXT;
