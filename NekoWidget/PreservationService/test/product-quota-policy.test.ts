import { expect, it } from 'vitest';
import { pendingProductQuota, productQuotaPolicy } from '../src/product-quota-policy';

it('keeps approved decimal limits separate from implementation record counts', () => {
  const policy = productQuotaPolicy();
  expect(policy.version).toBe(2);
  expect(policy.plus).toEqual({ limitBytes: 3_000_000_000, maximumRecords: 3000, includesAppleFamily: false });
  expect(policy.trial).toEqual({ limitBytes: 250_000_000, maximumRecords: 3000, durationDays: 14 });
  expect(policy.recordUnit).toBe('visible-records-v1');
  expect(policy.familyParticipationRequiresPersonalStoragePurchase).toBe(false);
  expect(pendingProductQuota({})).toMatchObject({ configurationStatus: 'valid', usage: null,
    accountingStatus: 'not_available', enforcementStatus: 'not_enabled' });
});

it('allows capacity expansion by settings and rejects lossy or malformed limits', () => {
  expect(productQuotaPolicy({ PRODUCT_PLUS_BYTES: '5000000000', PRODUCT_TRIAL_BYTES: '500000000',
    PRODUCT_VISIBLE_RECORDS: '10000' }).plus).toMatchObject({ limitBytes: 5_000_000_000, maximumRecords: 10_000 });
  for (const value of ['', '0', '-1', '3GB', '3e9', '3.5', ' 3000', '03000', '9007199254740992']) {
    expect(() => productQuotaPolicy({ PRODUCT_PLUS_BYTES: value })).toThrow('PRODUCT_QUOTA_NOT_CONFIGURED');
    expect(() => productQuotaPolicy({ PRODUCT_VISIBLE_RECORDS: value })).toThrow('PRODUCT_QUOTA_NOT_CONFIGURED');
  }
  expect(() => productQuotaPolicy({ PRODUCT_TRIAL_BYTES: '3000000001' })).toThrow('PRODUCT_QUOTA_NOT_CONFIGURED');
  expect(pendingProductQuota({ PRODUCT_VISIBLE_RECORDS: 'invalid' })).toMatchObject({
    policy: null, configurationStatus: 'invalid', usage: null, enforcementStatus: 'not_enabled' });
});
