import test from 'node:test';
import assert from 'node:assert/strict';
import { validateMetadata, validateNote, normalizeNote, nullableDate, copyPhotoBytes,
  nativeArchiveDocument, MAX_PHOTO_BYTES } from './record-contract.mjs';

const code = (expected) => (error) => error.code === expected;
const unknown = { capturedAt: null, writtenAt: null, updatedAt: null, catNames: [] };

test('native single-record document has exact public keys, explicit unknown dates and multiple cat names', () => {
  const result = nativeArchiveDocument({ note: '猫たち', photoBytes: Buffer.from('synthetic-only'), metadata: {
    ...unknown, capturedAt: '2023-03-02T14:00:00+09:00', catNames: ['むぎ', 'そら', 'むぎ'],
    owner: 'must-not-export', location: 'must-not-export', photoKitId: 'must-not-export',
  }, owner: 'private', revision: 99 });
  assert.deepEqual(JSON.parse(JSON.stringify(result)), {
    formatVersion: 1, text: '猫たち', capturedAt: '2023-03-02T05:00:00.000Z',
    writtenAt: null, updatedAt: null, catNames: ['むぎ', 'そら', 'むぎ'], photoFile: 'photo.jpg',
  });
});

test('text-only and photo-only are valid; no invented image for text-only and no empty records', () => {
  assert.deepEqual(nativeArchiveDocument({ note: 'メモだけ', photoBytes: null, metadata: unknown }),
    { formatVersion: 1, text: 'メモだけ', ...unknown, photoFile: null });
  assert.equal(nativeArchiveDocument({ note: '', photoBytes: Buffer.from('fixture'), metadata: unknown }).text, '');
  assert.throws(() => nativeArchiveDocument({ note: '\n ', photoBytes: null, metadata: unknown }), code('EMPTY_RECORD'));
  assert.throws(() => nativeArchiveDocument({ note: '\u0085\u2028\u3000', photoBytes: null, metadata: unknown }), code('EMPTY_RECORD'));
});

test('grapheme-based note limits preserve combined emoji and enforce both byte and character bounds', () => {
  assert.equal(normalizeNote(' \n 猫 \n '), '猫');
  assert.equal(normalizeNote('\u0085\u2028猫\u2029\u3000'), '猫');
  const family = '👨‍👩‍👧‍👦';
  assert.equal(validateNote(family.repeat(500)), family.repeat(500));
  assert.throws(() => validateNote(family.repeat(501)), code('INVALID_NOTE'));
  assert.throws(() => validateNote('a' + '\u0301'.repeat(40_000)), code('INVALID_NOTE'));
  assert.throws(() => normalizeNote(null), code('INVALID_NOTE'));
});

test('cat names are cloned, not collapsed, and enforce native count/byte bounds', () => {
  const input = { ...unknown, catNames: Array(100).fill('猫') };
  const normalized = validateMetadata(input);
  input.catNames[0] = 'changed';
  assert.equal(normalized.catNames[0], '猫');
  assert.throws(() => validateMetadata({ ...unknown, catNames: Array(101).fill('猫') }), code('INVALID_METADATA'));
  assert.throws(() => validateMetadata({ ...unknown, catNames: Array(1) }), code('INVALID_METADATA'));
  for (const name of ['', '猫'.repeat(201), 'a' + '\u0301'.repeat(401)]) {
    assert.throws(() => validateMetadata({ ...unknown, catNames: [name] }), code('INVALID_METADATA'));
  }
  assert.deepEqual(validateMetadata({ ...unknown, catNames: ['a\u0301'.repeat(200)] }).catNames, ['a\u0301'.repeat(200)]);
});

test('dates normalize to UTC, unknown stays null, invalid calendar dates do not silently roll forward', () => {
  assert.equal(nullableDate(null), null);
  assert.equal(nullableDate('2024-02-29T23:59:59+09:00'), '2024-02-29T14:59:59.000Z');
  assert.equal(nullableDate('0001-01-01T00:00:00Z'), '0001-01-01T00:00:00.000Z');
  for (const value of [undefined, '2023-02-29T00:00:00Z', '2026-04-31T00:00:00Z',
    '2026-01-01T24:00:00Z', '0000-01-01T00:00:00Z', '9999-12-31T23:59:59-01:00']) {
    assert.throws(() => nullableDate(value), code('INVALID_METADATA'));
  }
});

test('photo byte ceiling matches native 20 MiB, without claiming synthetic bytes are valid JPEG', () => {
  const input = Buffer.alloc(MAX_PHOTO_BYTES, 1);
  const copy = copyPhotoBytes(input);
  input[0] = 2;
  assert.equal(copy.length, MAX_PHOTO_BYTES);
  assert.equal(copy[0], 1);
  assert.equal(copyPhotoBytes(null), null);
  for (const value of [undefined, Buffer.alloc(0), Buffer.alloc(MAX_PHOTO_BYTES + 1)]) {
    assert.throws(() => copyPhotoBytes(value), code('INVALID_PHOTO_BYTES'));
  }
});
