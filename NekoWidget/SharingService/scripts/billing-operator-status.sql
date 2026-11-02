-- Read-only 0062+ ledger snapshot. This query does not authorize service access.
-- No account, transaction, notification, cursor, token, or key leaves the query.
WITH clock AS (SELECT CAST(unixepoch('subsec') * 1000 AS INTEGER) AS now_ms),
stores(environment) AS (VALUES ('Production'), ('Sandbox')),
unknown_legacy_pages AS (
  SELECT page.generation, page.page_index
  FROM billing_apple_notification_history_page_commits_legacy_0061 page
  WHERE NOT EXISTS (
    SELECT 1 FROM billing_apple_notification_history_recovery_legacy_0061 original
    WHERE original.generation = page.generation AND original.store_environment IS NOT NULL
  )
)
SELECT json_object(
  'schemaVersion', 1,
  'capturedAtMs', clock.now_ms,
  'gate', json((SELECT json_object(
    'generation', generation,
    'effectiveEntitlement', effective_entitlement_enabled,
    'reconciliation', subscription_reconciliation_enabled,
    'historyRecovery', apple_notification_history_recovery_enabled
  ) FROM billing_runtime_gate WHERE singleton = 1)),
  'environments', json((SELECT json_group_array(json_object(
    'environment', stores.environment,
    'history', json((SELECT json_object(
      'state', state, 'generation', generation, 'pages', committed_page_count,
      'records', committed_record_count, 'attempts', attempts,
      'notBefore', not_before, 'completedAt', completed_at, 'errorCode', last_error_code
    ) FROM billing_apple_notification_history_recovery recovery WHERE recovery.environment = stores.environment)),
    'reconciliation', json((SELECT json_object(
      'pending', COUNT(*),
      'leased', COALESCE(SUM(lease_token IS NOT NULL AND lease_expires_at > clock.now_ms / 1000), 0),
      'ready', COALESCE(SUM((lease_token IS NULL OR lease_expires_at <= clock.now_ms / 1000) AND not_before <= clock.now_ms / 1000), 0),
      'retryWait', COALESCE(SUM((lease_token IS NULL OR lease_expires_at <= clock.now_ms / 1000) AND not_before > clock.now_ms / 1000), 0),
      'withErrors', COALESCE(SUM(last_error_code IS NOT NULL), 0)
    ) FROM billing_reconciliation_jobs jobs WHERE jobs.environment = stores.environment)),
    'entitlement', json((SELECT json_object(
      'lineages', COUNT(*),
      'freshPlusAccounts', COUNT(DISTINCT CASE WHEN
        ownership_type = 'PURCHASED' AND product_id = 'jp.nekowidget.plus.monthly'
        AND apple_status IN (1, 4) AND revocation_date_ms IS NULL AND revocation_reason IS NULL
        AND is_upgraded = 0
        AND (CASE WHEN apple_status = 4 THEN grace_period_expires_date_ms ELSE expires_date_ms END) > clock.now_ms
        AND authority_stale_at_ms > clock.now_ms THEN billing_account_id END),
      'staleAuthorityLineages', COALESCE(SUM(authority_stale_at_ms <= clock.now_ms), 0),
      'expiredAccessLineages', COALESCE(SUM((CASE WHEN apple_status = 4 THEN grace_period_expires_date_ms ELSE expires_date_ms END) <= clock.now_ms), 0),
      'lastObservationAtMs', MAX(source_fetched_at_ms)
    ) FROM billing_effective_entitlement_current authority WHERE authority.environment = stores.environment))
  )) FROM stores)),
  'unknownLegacy', json_object(
    'pages', (SELECT COUNT(*) FROM unknown_legacy_pages),
    'records', (SELECT COUNT(*) FROM billing_apple_notification_history_page_records_legacy_0061 record
      JOIN unknown_legacy_pages page ON page.generation = record.generation AND page.page_index = record.page_index)
  )
) AS snapshot FROM clock;
