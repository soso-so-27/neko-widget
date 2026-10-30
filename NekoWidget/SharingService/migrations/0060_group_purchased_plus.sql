-- 1.0 does not grant Plus through Apple Family Sharing. No user records are removed.
DROP VIEW group_verified_plus_people;
CREATE VIEW group_verified_plus_people AS
SELECT DISTINCT link.person_id,authority.environment
FROM group_billing_connections link
JOIN billing_effective_entitlement_current authority ON authority.billing_account_id=link.billing_account_id
JOIN billing_runtime_gate gate ON gate.singleton=1
WHERE gate.effective_entitlement_enabled=1
    AND authority.ownership_type ='PURCHASED'
    AND authority.product_id='jp.nekowidget.plus.monthly'
    AND authority.apple_status IN (1,4)
    AND authority.revocation_date_ms IS NULL AND authority.revocation_reason IS NULL AND authority.is_upgraded=0
    AND (CASE WHEN authority.apple_status=4 THEN authority.grace_period_expires_date_ms ELSE authority.expires_date_ms END)>CAST(unixepoch('subsec')*1000 AS INTEGER)
    AND authority.authority_stale_at_ms>CAST(unixepoch('subsec')*1000 AS INTEGER);

