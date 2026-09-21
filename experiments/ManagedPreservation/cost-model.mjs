// Offline planning only. No app imports, network, credentials, or deployment.
import { pathToFileURL } from 'node:url';

export const PRICE_SOURCE = 'https://developers.cloudflare.com/r2/pricing/';
export const PRICE_CHECKED_ON = '2026-09-22';
export const RATES = Object.freeze({ storageGBMonthUSD: 0.015, classAMillionUSD: 4.5, classBMillionUSD: 0.36 });

const EXCLUSIONS = Object.freeze([
  'Workers, D1, authentication and key recovery',
  'Monitoring, support, payment fees, acquisition, tax and exchange rates',
  'Other storage providers and their operations/transfer charges',
  'Videos, originals and any copies not represented by copyMultiplier/overheadRatio',
  'Cost of running restores/deletions unless included in the supplied request totals',
]);

function nonnegative(name, value, integer = false) {
  if (!Number.isFinite(value) || value < 0 || value > Number.MAX_SAFE_INTEGER || (integer && !Number.isSafeInteger(value))) {
    throw new TypeError(`${name} must be a non-negative ${integer ? 'safe integer' : 'finite number'}`);
  }
}

/**
 * A constant-inventory, 30-day R2 Standard scenario, NOT a forecast or full cost.
 * MB/GB are decimal. Request counts are account-wide totals, INCLUDING copies,
 * edits, retries, imports, restores and deletions where applicable.
 * copyMultiplier models equally sized R2 Standard copies for arithmetic only;
 * it does not prove that backups are independent or recoverable.
 */
export function estimateR2(input) {
  if (!input || typeof input !== 'object' || Array.isArray(input)) throw new TypeError('An input object is required');
  const fields = ['payingAccounts', 'retainedNonPayingAccounts', 'photosPerAccount', 'averagePhotoMB',
    'copyMultiplier', 'overheadRatio', 'monthlyClassA', 'monthlyClassB', 'applyAccountFreeTier'];
  for (const key of Object.keys(input)) if (!fields.includes(key)) throw new TypeError(`Unknown input: ${key}`);
  for (const key of fields.filter(key => key !== 'applyAccountFreeTier')) {
    nonnegative(key, input[key], ['payingAccounts', 'retainedNonPayingAccounts', 'photosPerAccount', 'monthlyClassA', 'monthlyClassB'].includes(key));
  }
  if (input.copyMultiplier < 1) throw new RangeError('copyMultiplier must include at least the primary copy');
  if (typeof input.applyAccountFreeTier !== 'boolean') throw new TypeError('applyAccountFreeTier must be explicit');
  if (input.photosPerAccount > 0 && input.averagePhotoMB === 0) throw new RangeError('Photos must have a positive size');

  const storedAccounts = input.payingAccounts + input.retainedNonPayingAccounts;
  nonnegative('storedAccounts', storedAccounts, true);
  const primaryPhotoGB = storedAccounts * input.photosPerAccount * input.averagePhotoMB / 1000;
  const modeledGBMonth = primaryPhotoGB * (1 + input.overheadRatio) * input.copyMultiplier;
  nonnegative('modeledGBMonth', modeledGBMonth);
  const free = input.applyAccountFreeTier ? { gb: 10, a: 1_000_000, b: 10_000_000 } : { gb: 0, a: 0, b: 0 };
  const billableGBMonth = Math.ceil(Math.max(0, modeledGBMonth - free.gb));
  const billableClassAMillions = Math.ceil(Math.max(0, input.monthlyClassA - free.a) / 1_000_000);
  const billableClassBMillions = Math.ceil(Math.max(0, input.monthlyClassB - free.b) / 1_000_000);
  const storageUSD = billableGBMonth * RATES.storageGBMonthUSD;
  const operationsUSD = billableClassAMillions * RATES.classAMillionUSD + billableClassBMillions * RATES.classBMillionUSD;
  const modeledR2USD = storageUSD + operationsUSD;
  const round = value => Math.round(value * 1e6) / 1e6;
  return {
    assumptions: { ...input }, source: PRICE_SOURCE, priceCheckedOn: PRICE_CHECKED_ON,
    storedAccounts, primaryPhotoGB, modeledGBMonth,
    billableGBMonth, billableClassAMillions, billableClassBMillions,
    storageUSD: round(storageUSD), operationsUSD: round(operationsUSD), modeledR2USD: round(modeledR2USD),
    modeledR2USDPerPayingAccount: input.payingAccounts === 0 ? null : round(modeledR2USD / input.payingAccounts),
    exclusions: [...EXCLUSIONS],
    warning: 'Illustrative storage arithmetic only; not measured usage, a quota promise, profit or recovery proof.',
  };
}

export const BASELINE = Object.freeze({
  payingAccounts: 1000, retainedNonPayingAccounts: 0, photosPerAccount: 10000,
  averagePhotoMB: 1, copyMultiplier: 1, overheadRatio: 0,
  monthlyClassA: 30000, monthlyClassB: 930000, applyAccountFreeTier: false,
});

export function illustrativeScenarios() {
  return [
    ['Primary copies only', { ...BASELINE }],
    ['Copies + derivatives, same 1,000 paying accounts', { ...BASELINE, copyMultiplier: 2, overheadRatio: 0.15, monthlyClassA: 60000 }],
    ['Plus 1,000 retained non-paying accounts', { ...BASELINE, retainedNonPayingAccounts: 1000, copyMultiplier: 2, overheadRatio: 0.15, monthlyClassA: 60000, monthlyClassB: 1860000 }],
    ['Plus 5,000 retained non-paying accounts', { ...BASELINE, retainedNonPayingAccounts: 5000, copyMultiplier: 2, overheadRatio: 0.15, monthlyClassA: 60000, monthlyClassB: 5580000 }],
  ].map(([name, assumptions]) => ({ name, ...estimateR2(assumptions) }));
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    if (process.argv.length > 3) throw new Error('Pass at most one JSON object; no file or network access is supported');
    const result = process.argv[2] ? estimateR2(JSON.parse(process.argv[2])) : illustrativeScenarios();
    console.log(JSON.stringify(result, null, 2));
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
