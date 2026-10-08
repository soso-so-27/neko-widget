import { Buffer } from 'node:buffer';
import { describe, expect, it } from 'vitest';
import { decodePhoto, MAX_PHOTO_BYTES } from '../src/documents';

describe('strict photo base64 decoding', () => {
  it('preserves bytes across block boundaries and all final padding lengths', () => {
    for (const size of [1, 2, 3, 6143, 6144, 6145, 12287, 12288, 12289]) {
      const photo = Buffer.alloc(size);
      for (let i = 0; i < size; i++) photo[i] = (i * 37 + (i >> 8) * 13) % 256;
      expect(decodePhoto(photo.toString('base64'))).toEqual(new Uint8Array(photo));
    }
    expect(decodePhoto(null)).toBeNull();
  });

  it('rejects noncanonical padding bits, whitespace, alphabet and misplaced padding', () => {
    for (const invalid of ['', 'A', 'AAA', '====', 'AA=A', 'A===', 'AA==AAAA',
      'AB==', 'AAB=', 'AA-_', 'AA==\n', ' AA==', 'AA==\0', 'ＡＡ==', 17, undefined,
      'A'.repeat(8191) + '=AAAA', 'A'.repeat(8192) + 'AB==', 'A'.repeat(8192) + 'AAB=']) {
      expect(() => decodePhoto(invalid)).toThrowError(expect.objectContaining({ code: 'INVALID_RECORD' }));
    }
  });

  it('accepts the exact existing20MiB limit and rejects one extra decoded byte', async () => {
    const photo = Buffer.alloc(MAX_PHOTO_BYTES);
    for (let i = 0; i < photo.length; i++) photo[i] = (i * 37 + (i >> 8) * 13) % 256;
    const decoded = decodePhoto(photo.toString('base64'))!;
    expect(decoded.byteLength).toBe(MAX_PHOTO_BYTES);
    const digest = (bytes: Uint8Array) => crypto.subtle.digest('SHA-256', bytes as BufferSource);
    expect(new Uint8Array(await digest(decoded))).toEqual(new Uint8Array(await digest(photo)));
    //20MiB+1 has the same encoded character count; checking that count alone is insufficient.
    const larger = Buffer.alloc(MAX_PHOTO_BYTES + 1).toString('base64');
    expect(larger.length).toBe(photo.toString('base64').length);
    expect(() => decodePhoto(larger)).toThrowError(expect.objectContaining({ code: 'INVALID_RECORD' }));
  });
});
