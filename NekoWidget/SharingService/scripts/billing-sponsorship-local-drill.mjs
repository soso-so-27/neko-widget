import {
  readFileSync,
  readdirSync,
  lstatSync,
  realpathSync,
  rmSync,
  mkdtempSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { DatabaseSync } from "node:sqlite";

const serviceDirectory = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const migrationsDirectory = join(serviceDirectory, "migrations");
const stagingTemplatePath = join(
  serviceDirectory,
  "wrangler.staging.template.jsonc",
);

// Any migration addition must be reviewed here before this drill executes it.
const expectedMigrationNames = [
  "0001_pairing.sql",
  "0002_daily_sharing.sql",
  "0003_append_only_moments.sql",
  "0004_encrypted_window_name.sql",
  "0005_device_recovery.sql",
  "0006_paw_reactions.sql",
  "0007_apns_notifications.sql",
  "0008_additional_participant_devices.sql",
  "0009_multi_window_apns_tokens.sql",
  "0010_multi_device_shared_data.sql",
  "0011_apns_route_schema.sql",
  "0012_moderation_case_lifecycle.sql",
  "0013_moderation_operator_control_plane.sql",
  "0014_moderation_evidence_ledger.sql",
  "0015_moderation_operator_routes.sql",
  "0016_moderation_operator_access_audit.sql",
  "0017_moderation_operator_enrollment_trust.sql",
  "0018_moderation_operator_case_reference_binding.sql",
  "0019_billing_foundation.sql",
  "0020_billing_apple_authority.sql",
  "0021_billing_effective_entitlement.sql",
  "0022_billing_account_recovery.sql",
  "0023_billing_window_sponsorship.sql",
  "0024_billing_window_owner_detach.sql",
  "0025_billing_apple_notification_history_recovery.sql",
];

const databaseGateColumns = [
  "account_bootstrap_enabled",
  "transaction_ingestion_enabled",
  "apple_notification_ingestion_enabled",
  "apple_notification_history_recovery_enabled",
  "subscription_reconciliation_enabled",
  "effective_entitlement_enabled",
  "account_recovery_enabled",
  "window_sponsorship_enabled",
].sort();

const workerGateNames = [
  "BILLING_ACCOUNT_BOOTSTRAP_RUNTIME_ENABLED",
  "BILLING_TRANSACTION_INGESTION_RUNTIME_ENABLED",
  "BILLING_APPLE_NOTIFICATION_RUNTIME_ENABLED",
  "BILLING_APPLE_NOTIFICATION_HISTORY_RECOVERY_RUNTIME_ENABLED",
  "BILLING_SUBSCRIPTION_RECONCILIATION_RUNTIME_ENABLED",
  "BILLING_EFFECTIVE_ENTITLEMENT_RUNTIME_ENABLED",
  "BILLING_ACCOUNT_RECOVERY_RUNTIME_ENABLED",
  "BILLING_WINDOW_SPONSORSHIP_RUNTIME_ENABLED",
].sort();

const fixture = Object.freeze({
  billingAccountId: "10000000-0000-4000-8000-000000000001",
  billingKeyId: "AAAAAAAAAAAAAAAAAAAAAQ",
  billingPublicKey: "A".repeat(43),
  lineageId: "local-drill-lineage",
  spaceId: "local-drill-space",
  ownerParticipantId: "local-drill-owner",
  ownerDeviceId: "local-drill-device",
  originalTransactionId: "900000000000001",
  transactionId: "900000000000002",
  observationFingerprint: "B".repeat(43),
  leaseToken: "CCCCCCCCCCCCCCCCCCCCAQ",
  decisionId: "DDDDDDDDDDDDDDDDDDDDAQ",
});

function requireCondition(value, message) {
  if (!value) throw new Error(message);
}

function expectConstraint(statement, expectedMessage) {
  try {
    statement();
  } catch (error) {
    requireCondition(
      error instanceof Error && error.message.includes(expectedMessage),
      "local drill encountered an unexpected database refusal",
    );
    return;
  }
  throw new Error(
    "local drill expected the database to refuse an unsafe transition",
  );
}

function applyMigrations(database) {
  const migrationNames = readdirSync(migrationsDirectory)
    .filter((name) => /^\d{4}_[a-z0-9_]+\.sql$/u.test(name))
    .sort();
  requireCondition(
    JSON.stringify(migrationNames) === JSON.stringify(expectedMigrationNames),
    "migration inventory changed without local drill review",
  );
  for (const name of migrationNames) {
    database.exec(readFileSync(join(migrationsDirectory, name), "utf8"));
  }
  return migrationNames.length;
}

function verifyDefaultGates(database) {
  const row = database
    .prepare("SELECT * FROM billing_runtime_gate WHERE singleton=1")
    .get();
  requireCondition(row !== undefined, "billing gate singleton is missing");
  const actualColumns = Object.keys(row)
    .filter((name) => !["singleton", "generation", "updated_at"].includes(name))
    .sort();
  requireCondition(
    JSON.stringify(actualColumns) === JSON.stringify(databaseGateColumns),
    "billing database gate set changed without drill review",
  );
  requireCondition(
    actualColumns.every((name) => row[name] === 0),
    "a billing database gate does not default OFF",
  );

  const staging = JSON.parse(readFileSync(stagingTemplatePath, "utf8"));
  const actualWorkerNames = Object.keys(staging.vars)
    .filter(
      (name) =>
        name.startsWith("BILLING_") && name.endsWith("_RUNTIME_ENABLED"),
    )
    .sort();
  requireCondition(
    JSON.stringify(actualWorkerNames) === JSON.stringify(workerGateNames),
    "billing Worker gate set changed without drill review",
  );
  requireCondition(
    actualWorkerNames.every((name) => staging.vars[name] === "NO"),
    "a billing Worker gate does not default OFF",
  );
}

function updateSponsorshipGates(
  database,
  expectedGeneration,
  sponsorship,
  effective,
) {
  return database
    .prepare(
      `UPDATE billing_runtime_gate
      SET generation=generation+1,
          window_sponsorship_enabled=?,effective_entitlement_enabled=?,
          updated_at=unixepoch()
      WHERE singleton=1 AND generation=?`,
    )
    .run(sponsorship, effective, expectedGeneration).changes;
}

function seedReviewedFixture(database) {
  const nowSeconds = Math.floor(Date.now() / 1000);
  const nowMilliseconds = nowSeconds * 1000;
  const accessUntilMilliseconds = nowMilliseconds + 86_400_000;

  database
    .prepare("INSERT INTO billing_accounts(id) VALUES(?)")
    .run(fixture.billingAccountId);
  database
    .prepare(
      `INSERT INTO billing_account_keys(
      id,billing_account_id,signing_public_key,state
    ) VALUES(?,?,?,'active')`,
    )
    .run(
      fixture.billingKeyId,
      fixture.billingAccountId,
      fixture.billingPublicKey,
    );

  database
    .prepare("INSERT INTO moment_space_lineages(id,created_at) VALUES(?,?)")
    .run(fixture.lineageId, nowSeconds);
  database
    .prepare(
      `INSERT INTO moment_spaces(
      space_id,lineage_id,state,current_key_epoch,membership_revision,created_at,updated_at
    ) VALUES(?,?,'active',1,1,?,?)`,
    )
    .run(fixture.spaceId, fixture.lineageId, nowSeconds, nowSeconds);
  database
    .prepare(
      `INSERT INTO moment_participants(
      id,space_id,role,state,created_at,activated_at
    ) VALUES(?,?,'owner','active',?,?)`,
    )
    .run(fixture.ownerParticipantId, fixture.spaceId, nowSeconds, nowSeconds);
  database
    .prepare(
      `INSERT INTO moment_devices(
      id,participant_id,agreement_public_key,signing_public_key,state,created_at,activated_at
    ) VALUES(?,?,?,?,'active',?,?)`,
    )
    .run(
      fixture.ownerDeviceId,
      fixture.ownerParticipantId,
      "E".repeat(43),
      "F".repeat(43),
      nowSeconds,
      nowSeconds,
    );

  database
    .prepare(
      `INSERT INTO billing_transaction_lineages(
      original_transaction_id,billing_account_id,environment,subscription_group_id
    ) VALUES(?,?,'Sandbox','20999999')`,
    )
    .run(fixture.originalTransactionId, fixture.billingAccountId);
  database
    .prepare(
      `INSERT INTO billing_reconciliation_jobs(
      original_transaction_id,requested_at,not_before,request_generation,attempts,
      lease_token,lease_expires_at,updated_at
    ) VALUES(?,?,?,1,0,?,?,?)`,
    )
    .run(
      fixture.originalTransactionId,
      nowSeconds,
      nowSeconds,
      fixture.leaseToken,
      nowSeconds + 600,
      nowSeconds,
    );
  database
    .prepare(
      `INSERT INTO billing_subscription_authority_observations(
      observation_fingerprint,original_transaction_id,billing_account_id,environment,
      subscription_group_id,apple_status,transaction_id,product_id,expires_date_ms,
      revocation_date_ms,revocation_reason,is_upgraded,transaction_signed_date_ms,
      renewal_signed_date_ms,fetched_at_ms,ownership_type
    ) VALUES(?,?,?,'Sandbox','20999999',1,?,'jp.nekowidget.plus.monthly',?,
      NULL,NULL,0,?,?,?,'PURCHASED')`,
    )
    .run(
      fixture.observationFingerprint,
      fixture.originalTransactionId,
      fixture.billingAccountId,
      fixture.transactionId,
      accessUntilMilliseconds,
      nowMilliseconds,
      nowMilliseconds,
      nowMilliseconds,
    );
  database
    .prepare(
      `INSERT INTO billing_effective_entitlement_decisions(
      decision_id,observation_fingerprint,original_transaction_id,billing_account_id,
      environment,subscription_group_id,ownership_type,request_generation,lease_token,
      apple_status,transaction_id,product_id,expires_date_ms,revocation_date_ms,
      revocation_reason,is_upgraded,grace_period_expires_date_ms,source_fetched_at_ms,
      decision_status,grants_plus,access_until_ms,authority_stale_at_ms,evaluated_at_ms
    ) VALUES(?,?,?,?,'Sandbox','20999999','PURCHASED',1,?,1,?,
      'jp.nekowidget.plus.monthly',?,NULL,NULL,0,NULL,?,'active',1,?,?,?)`,
    )
    .run(
      fixture.decisionId,
      fixture.observationFingerprint,
      fixture.originalTransactionId,
      fixture.billingAccountId,
      fixture.leaseToken,
      fixture.transactionId,
      accessUntilMilliseconds,
      nowMilliseconds,
      accessUntilMilliseconds,
      accessUntilMilliseconds,
      nowMilliseconds,
    );
  database.exec(`INSERT INTO billing_effective_entitlement_current(
      original_transaction_id,billing_account_id,environment,subscription_group_id,
      decision_id,observation_fingerprint,ownership_type,request_generation,lease_token,
      apple_status,transaction_id,product_id,expires_date_ms,revocation_date_ms,
      revocation_reason,is_upgraded,grace_period_expires_date_ms,source_fetched_at_ms,
      materialized_status,materialized_grants_plus,access_until_ms,authority_stale_at_ms,
      evaluated_at_ms
    )
    SELECT original_transaction_id,billing_account_id,environment,subscription_group_id,
      decision_id,observation_fingerprint,ownership_type,request_generation,lease_token,
      apple_status,transaction_id,product_id,expires_date_ms,revocation_date_ms,
      revocation_reason,is_upgraded,grace_period_expires_date_ms,source_fetched_at_ms,
      decision_status,grants_plus,access_until_ms,authority_stale_at_ms,evaluated_at_ms
    FROM billing_effective_entitlement_decisions`);

  const membershipRevision = database
    .prepare("SELECT membership_revision FROM moment_spaces WHERE space_id=?")
    .get(fixture.spaceId).membership_revision;
  return { consentIssuedAt: nowSeconds, membershipRevision };
}

function sponsor(database, input) {
  database
    .prepare(
      `INSERT INTO billing_window_sponsorship_requests(
      client_request_id,request_hash,operation,billing_account_id,submitted_by_billing_key_id,
      window_lineage_id,expected_generation,expected_current_billing_account_id,
      consent_space_id,owner_participant_id,owner_device_id,consent_membership_revision,
      consent_issued_at,owner_consent_nonce_hash,owner_consent_hash,entitlement_decision_id,
      entitlement_request_generation,entitlement_evaluated_at_ms,resulting_generation
    )
    SELECT ?,?,'sponsor',?,?,?, ?,?, ?,?,?,?, ?,?,?,
      decision_id,request_generation,evaluated_at_ms,?
    FROM billing_effective_entitlement_current
    WHERE original_transaction_id=?`,
    )
    .run(
      input.requestId,
      input.requestHash,
      fixture.billingAccountId,
      fixture.billingKeyId,
      fixture.lineageId,
      input.expectedGeneration,
      input.expectedCurrentBillingAccountId,
      fixture.spaceId,
      fixture.ownerParticipantId,
      fixture.ownerDeviceId,
      input.membershipRevision,
      input.consentIssuedAt,
      "G".repeat(43),
      "H".repeat(43),
      input.expectedGeneration + 1,
      fixture.originalTransactionId,
    );
}

function ownerDetach(database, requestId, expectedGeneration) {
  const membershipRevision = database
    .prepare("SELECT membership_revision FROM moment_spaces WHERE space_id=?")
    .get(fixture.spaceId).membership_revision;
  database
    .prepare(
      `INSERT INTO billing_window_sponsorship_owner_detach_requests(
      client_request_id,request_hash,window_lineage_id,space_id,owner_participant_id,
      owner_device_id,membership_revision,expected_generation,expected_billing_account_id,
      resulting_generation
    ) VALUES(?,?,?,?,?,?,?,?,?,?)`,
    )
    .run(
      requestId,
      "I".repeat(43),
      fixture.lineageId,
      fixture.spaceId,
      fixture.ownerParticipantId,
      fixture.ownerDeviceId,
      membershipRevision,
      expectedGeneration,
      fixture.billingAccountId,
      expectedGeneration + 1,
    );
}

function payerUnsponsor(database, requestId, expectedGeneration) {
  database
    .prepare(
      `INSERT INTO billing_window_sponsorship_requests(
      client_request_id,request_hash,operation,billing_account_id,submitted_by_billing_key_id,
      window_lineage_id,expected_generation,expected_current_billing_account_id,
      resulting_generation
    ) VALUES(?,?,'unsponsor',?,?,?,?,?,?)`,
    )
    .run(
      requestId,
      "K".repeat(43),
      fixture.billingAccountId,
      fixture.billingKeyId,
      fixture.lineageId,
      expectedGeneration,
      fixture.billingAccountId,
      expectedGeneration + 1,
    );
}

function runSequence(database) {
  const { consentIssuedAt, membershipRevision } = seedReviewedFixture(database);
  const sponsorInput = (
    requestId,
    expectedGeneration,
    expectedCurrentBillingAccountId = null,
  ) => ({
    requestId,
    requestHash: "J".repeat(43),
    expectedGeneration,
    expectedCurrentBillingAccountId,
    consentIssuedAt,
    membershipRevision,
  });

  expectConstraint(
    () =>
      sponsor(
        database,
        sponsorInput("20000000-0000-4000-8000-000000000001", 0),
      ),
    "sponsorship runtime gate closed",
  );
  requireCondition(
    updateSponsorshipGates(database, 0, 1, 1) === 1,
    "opening gates lost CAS",
  );
  sponsor(database, sponsorInput("20000000-0000-4000-8000-000000000002", 0));

  requireCondition(
    updateSponsorshipGates(database, 0, 1, 0) === 0,
    "stale gate CAS succeeded",
  );
  requireCondition(
    updateSponsorshipGates(database, 1, 1, 0) === 1,
    "effective OFF lost CAS",
  );
  expectConstraint(
    () =>
      sponsor(
        database,
        sponsorInput(
          "20000000-0000-4000-8000-000000000003",
          1,
          fixture.billingAccountId,
        ),
      ),
    "sponsorship runtime gate closed",
  );

  payerUnsponsor(database, "20000000-0000-4000-8000-000000000004", 1);
  let state = database
    .prepare(
      `SELECT state,generation,billing_account_id
      FROM billing_window_sponsorships WHERE window_lineage_id=?`,
    )
    .get(fixture.lineageId);
  requireCondition(
    state?.state === "unsponsored" &&
      state.generation === 2 &&
      state.billing_account_id === null,
    "payer unsponsor did not preserve the effective-gate escape semantics",
  );

  requireCondition(
    updateSponsorshipGates(database, 2, 1, 1) === 1,
    "reopen lost CAS",
  );
  sponsor(database, sponsorInput("20000000-0000-4000-8000-000000000005", 2));
  requireCondition(
    updateSponsorshipGates(database, 3, 1, 0) === 1,
    "owner escape setup lost CAS",
  );
  ownerDetach(database, "20000000-0000-4000-8000-000000000006", 3);
  state = database
    .prepare(
      `SELECT state,generation,billing_account_id
      FROM billing_window_sponsorships WHERE window_lineage_id=?`,
    )
    .get(fixture.lineageId);
  requireCondition(
    state?.state === "unsponsored" &&
      state.generation === 4 &&
      state.billing_account_id === null,
    "owner detach did not preserve the effective-gate escape semantics",
  );

  requireCondition(
    updateSponsorshipGates(database, 4, 1, 1) === 1,
    "second reopen lost CAS",
  );
  sponsor(database, sponsorInput("20000000-0000-4000-8000-000000000007", 4));
  requireCondition(
    updateSponsorshipGates(database, 5, 0, 0) === 1,
    "broad OFF lost CAS",
  );
  expectConstraint(
    () => ownerDetach(database, "20000000-0000-4000-8000-000000000008", 5),
    "sponsorship runtime gate closed",
  );

  state = database
    .prepare(
      `SELECT state,generation FROM billing_window_sponsorships
      WHERE window_lineage_id=?`,
    )
    .get(fixture.lineageId);
  requireCondition(
    state?.state === "active" && state.generation === 5,
    "broad OFF changed sponsorship state",
  );
  requireCondition(
    updateSponsorshipGates(database, 6, 1, 0) === 1,
    "escape reopen lost CAS",
  );
  ownerDetach(database, "20000000-0000-4000-8000-000000000009", 5);
  requireCondition(
    updateSponsorshipGates(database, 7, 0, 0) === 1,
    "final broad OFF lost CAS",
  );

  const gate = database
    .prepare("SELECT * FROM billing_runtime_gate WHERE singleton=1")
    .get();
  requireCondition(
    databaseGateColumns.every((name) => gate[name] === 0),
    "local drill did not finish with every database gate OFF",
  );
  requireCondition(
    database.prepare("SELECT COUNT(*) AS count FROM moment_spaces").get()
      .count === 1,
    "sponsorship changes removed window data",
  );
  requireCondition(
    database
      .prepare(
        "SELECT COUNT(*) AS count FROM billing_window_sponsorship_owner_detach_requests",
      )
      .get().count === 2,
    "owner detach audit count changed",
  );
}

export function runBillingSponsorshipLocalDrill() {
  const resolvedTemporaryRoot = realpathSync(tmpdir());
  const temporaryDirectory = mkdtempSync(
    join(resolvedTemporaryRoot, "neko-billing-drill-"),
  );
  requireCondition(
    dirname(temporaryDirectory) === resolvedTemporaryRoot &&
      /^neko-billing-drill-[A-Za-z0-9_-]+$/u.test(basename(temporaryDirectory)),
    "local drill temporary directory escaped the system temporary root",
  );

  const database = new DatabaseSync(
    join(temporaryDirectory, "drill.sqlite"),
  );
  try {
    database.exec("PRAGMA foreign_keys = ON");
    const migrationsApplied = applyMigrations(database);
    verifyDefaultGates(database);
    runSequence(database);
    return Object.freeze({
      migrationsApplied,
      checksPassed: 12,
      identifiersEmitted: 0,
    });
  } finally {
    database.close();
    const deletionTarget = lstatSync(temporaryDirectory);
    requireCondition(
      deletionTarget.isDirectory() && !deletionTarget.isSymbolicLink(),
      "local drill refused an unsafe cleanup target",
    );
    rmSync(temporaryDirectory, { recursive: true, force: true });
  }
}

if (
  process.argv[1] &&
  resolve(process.argv[1]) === fileURLToPath(import.meta.url)
) {
  try {
    const result = runBillingSponsorshipLocalDrill();
    process.stdout.write(
      `billing sponsorship local drill: PASS (migrations=${result.migrationsApplied}, checks=${result.checksPassed}, identifiers=${result.identifiersEmitted})\n`,
    );
  } catch {
    process.stderr.write(
      "billing sponsorship local drill: FAIL (local invariant violation)\n",
    );
    process.exitCode = 1;
  }
}
