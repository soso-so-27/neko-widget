import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import test from "node:test";

import { moderationStatusQueries } from "../scripts/moderation-staging-status-lib.mjs";

const projectDirectory = join(import.meta.dirname, "..");
const migrationPath = join(
  projectDirectory,
  "migrations",
  "0012_moderation_case_lifecycle.sql",
);
const migration = await readFile(migrationPath, "utf8");

function legacyDatabase(tombstones = []) {
  const database = new DatabaseSync(":memory:");
  database.exec("PRAGMA foreign_keys = ON");
  database.exec(`
    CREATE TABLE moment_report_tombstones (
      report_id TEXT PRIMARY KEY,
      committed_at INTEGER NOT NULL
    ) STRICT;
  `);
  const insert = database.prepare(
    "INSERT INTO moment_report_tombstones(report_id, committed_at) VALUES (?, ?)",
  );
  for (const tombstone of tombstones) {
    insert.run(tombstone.reportID, tombstone.committedAt);
  }
  return database;
}

function insertTombstone(database, reportID, committedAt) {
  database.prepare(
    "INSERT INTO moment_report_tombstones(report_id, committed_at) VALUES (?, ?)",
  ).run(reportID, committedAt);
}

function appendEvent(database, reportID, eventType, outcomeCode = null) {
  database.prepare(`
    INSERT INTO moderation_case_events(report_id, event_type, outcome_code)
    VALUES (?, ?, ?)
  `).run(reportID, eventType, outcomeCode);
}

test("backfills committed reports without inventing a human review receipt", () => {
  const database = legacyDatabase([
    { reportID: "legacy-report", committedAt: 1_780_000_000 },
  ]);
  database.exec(migration);

  assert.deepEqual(
    database.prepare(`
      SELECT report_id, committed_at, review_due_at
        FROM moderation_cases ORDER BY report_id
    `).all().map((row) => ({ ...row })),
    [{
      report_id: "legacy-report",
      committed_at: 1_780_000_000,
      review_due_at: 1_780_172_800,
    }],
  );
  assert.equal(
    database.prepare("SELECT COUNT(*) AS count FROM moderation_case_events").get().count,
    0,
  );

  insertTombstone(database, "new-report", 1_790_000_000);
  assert.deepEqual(
    { ...database.prepare(`
      SELECT committed_at, review_due_at
        FROM moderation_cases WHERE report_id = 'new-report'
    `).get() },
    { committed_at: 1_790_000_000, review_due_at: 1_790_172_800 },
  );

  const caseColumns = database.prepare("PRAGMA table_info(moderation_cases)")
    .all().map((column) => column.name).sort();
  assert.deepEqual(caseColumns, ["committed_at", "report_id", "review_due_at"]);
  assert.throws(
    () => database.exec("UPDATE moderation_cases SET review_due_at = review_due_at + 1"),
    /moderation cases are immutable/u,
  );
  assert.throws(
    () => database.exec("DELETE FROM moderation_cases WHERE report_id = 'legacy-report'"),
    /moderation cases cannot be deleted/u,
  );
  assert.throws(
    () => database.exec(`
      INSERT OR REPLACE INTO moderation_cases(report_id, committed_at, review_due_at)
      VALUES ('legacy-report', 1790000000, 1790172800)
    `),
    /moderation cases cannot be replaced/u,
  );
  database.close();
});

test("enforces append-only database-timestamped review transitions", () => {
  const now = Math.floor(Date.now() / 1_000);
  const database = legacyDatabase([
    { reportID: "review-report", committedAt: now - 3_600 },
  ]);
  database.exec(migration);

  assert.throws(
    () => appendEvent(database, "review-report", "review_decided", "no_action"),
    /decision requires review start/u,
  );
  assert.throws(
    () => database.prepare(`
      INSERT INTO moderation_case_events(
        report_id, event_type, outcome_code, recorded_at
      ) VALUES (?, 'review_started', NULL, ?)
    `).run("review-report", now - 60),
    /must use database time/u,
  );

  appendEvent(database, "review-report", "review_started");
  assert.throws(
    () => appendEvent(database, "review-report", "review_started"),
    /event has already been recorded/u,
  );
  assert.throws(
    () => appendEvent(database, "review-report", "review_decided", "unsupported"),
    /constraint|CHECK/u,
  );
  appendEvent(database, "review-report", "review_decided", "no_action");
  assert.throws(
    () => database.exec(`
      INSERT OR REPLACE INTO moderation_case_events(
        report_id, event_type, outcome_code
      ) VALUES ('review-report', 'review_decided', 'warning')
    `),
    /event has already been recorded/u,
  );

  assert.deepEqual(
    database.prepare(`
      SELECT event_type, outcome_code
        FROM moderation_case_events
       WHERE report_id = 'review-report'
       ORDER BY recorded_at ASC, event_type DESC
    `).all().map((row) => ({ ...row })),
    [
      { event_type: "review_started", outcome_code: null },
      { event_type: "review_decided", outcome_code: "no_action" },
    ],
  );
  assert.throws(
    () => database.exec(`
      UPDATE moderation_case_events SET outcome_code = 'warning'
       WHERE event_type = 'review_decided'
    `),
    /append-only/u,
  );
  assert.throws(
    () => database.exec("DELETE FROM moderation_case_events"),
    /cannot be deleted/u,
  );
  database.close();
});

test("aggregates lifecycle and actual first-review SLA without identifiers", () => {
  const now = Math.floor(Date.now() / 1_000);
  const database = legacyDatabase([
    { reportID: "overdue-unreviewed", committedAt: now - 200_000 },
    { reportID: "recent-unreviewed", committedAt: now - 100 },
    { reportID: "in-review", committedAt: now - 100 },
    { reportID: "late-decided", committedAt: now - 200_000 },
  ]);
  database.exec(migration);
  appendEvent(database, "in-review", "review_started");
  appendEvent(database, "late-decided", "review_started");
  appendEvent(database, "late-decided", "review_decided", "no_action");

  const query = moderationStatusQueries.find((entry) => entry.name === "review-lifecycle");
  assert.notEqual(query, undefined);
  assert.deepEqual({ ...database.prepare(query.sql).get() }, {
    unreviewed: 2,
    in_review: 1,
    decided: 1,
    sla_exceeded: 2,
    future_count: 0,
    future_event_count: 0,
  });
  assert.doesNotMatch(query.sql, /participant|device|object_key|reason_code|ciphertext/iu);
  database.close();
});
