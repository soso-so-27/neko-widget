// Synthetic 0061 fixture. Keep its old-schema inserts fixed so migration tests exercise upgrade, not fresh schema.
export const fixture = Object.freeze({
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

export function seedReviewedFixture(database) {
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

export function sponsor(database, input) {
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
