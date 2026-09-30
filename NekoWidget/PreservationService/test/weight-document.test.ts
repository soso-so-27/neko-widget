import { expect, it } from 'vitest';
import { validateDocument } from '../src/documents';

const base = { formatVersion: 1, text: '記録', capturedAt: null, writtenAt: null,
  updatedAt: null, catNames: ['むぎ'], photoFile: null };

it('keeps legacy document shape and accepts explicit portable measurements without local identity', () => {
  expect(validateDocument(base)).toEqual(base);
  const next = { ...base, formatVersion: 2, text: '', weight: { grams: 4200, measuredOn: '2026-09-29', catName: 'むぎ' } };
  expect(validateDocument(next)).toEqual(next);
  expect(validateDocument({ ...next, weight: { grams: 4200, measuredOn: null, catName: null } }).weight?.measuredOn).toBeNull();
  expect(() => validateDocument({ ...next, weight: { ...next.weight, catID: 'private-id' } })).toThrow();
  expect(() => validateDocument({ ...next, formatVersion: 1 })).toThrow();
});

it('rejects invalid measurements and dates and never converts an invalid day into a nearby day', () => {
  for (const grams of [0, -1, 100001, 4200.5, '4200', Infinity]) {
    expect(() => validateDocument({ ...base, formatVersion: 2, weight: { grams, measuredOn: null, catName: null } })).toThrow();
  }
  for (const measuredOn of ['2026-02-29', '2026-09-31', '0000-01-01', '2026-09-29T00:00:00Z']) {
    expect(() => validateDocument({ ...base, formatVersion: 2, weight: { grams: 4200, measuredOn, catName: null } })).toThrow();
  }
});
