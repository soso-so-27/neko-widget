import { ServiceError } from './contracts';

/** Product limits are not the storage engine's physical-row safety limits.
 * Raising these settings never edits, expires or deletes existing content. */
export interface ProductQuotaSettings {
  PRODUCT_PLUS_BYTES?: string;
  PRODUCT_TRIAL_BYTES?: string;
  PRODUCT_VISIBLE_RECORDS?: string;
  PRODUCT_QUOTA_ENFORCEMENT?: string;
}

function setting(value: string | undefined, initial: number): number {
  if (value === undefined) return initial;
  if (!/^[1-9][0-9]*$/u.test(value)) throw new ServiceError('PRODUCT_QUOTA_NOT_CONFIGURED', 503);
  const result = Number(value);
  if (!Number.isSafeInteger(result)) throw new ServiceError('PRODUCT_QUOTA_NOT_CONFIGURED', 503);
  return result;
}

export function productQuotaPolicy(settings: ProductQuotaSettings = {}) {
  if (settings.PRODUCT_QUOTA_ENFORCEMENT !== undefined && !['true','false'].includes(settings.PRODUCT_QUOTA_ENFORCEMENT)) {
    throw new ServiceError('PRODUCT_QUOTA_NOT_CONFIGURED',503);
  }
  const plusBytes = setting(settings.PRODUCT_PLUS_BYTES, 3_000_000_000);
  const trialBytes = setting(settings.PRODUCT_TRIAL_BYTES, 250_000_000);
  const visibleRecords = setting(settings.PRODUCT_VISIBLE_RECORDS, 3_000);
  if (trialBytes > plusBytes) throw new ServiceError('PRODUCT_QUOTA_NOT_CONFIGURED', 503);
  return {
    version: 1 as const,
    byteUnit: 'decimal' as const,
    recordUnit: 'visible-records-v1' as const,
    plus: { limitBytes: plusBytes, maximumRecords: visibleRecords, includesAppleFamily: true as const },
    trial: { limitBytes: trialBytes, maximumRecords: visibleRecords, durationDays: 14 as const },
    familyParticipationRequiresPersonalStoragePurchase: false as const,
  };
}

export type ProductQuotaPolicy = ReturnType<typeof productQuotaPolicy>;

/** Never relabel encrypted fragments, indexes or retained history as visible
 * records. Publication/accounting migration must land before a ready result. */
export function pendingProductQuota(settings: ProductQuotaSettings) {
  let policy: ProductQuotaPolicy | null = null;
  try { policy = productQuotaPolicy(settings); }
  catch (error) {
    if (!(error instanceof ServiceError) || error.code !== 'PRODUCT_QUOTA_NOT_CONFIGURED') throw error;
  }
  // A bad future-product setting must not block legacy reads or exports.
  return { policy, configurationStatus: policy ? 'valid' as const : 'invalid' as const,
    accountingStatus: 'not_available' as const,
    enforcementStatus: 'not_enabled' as const, usage: null };
}
