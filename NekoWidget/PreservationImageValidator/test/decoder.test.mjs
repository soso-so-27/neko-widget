import assert from 'node:assert/strict';
import { test } from 'node:test';
import sharp from 'sharp';
import { createHash } from 'node:crypto';
import { validateJPEG } from '../dist/decoder.js';
import { inspectJPEG } from '../dist/jpeg-envelope.js';
import { DECODE_TIMEOUT_MS, MAX_PHOTO_BYTES } from '../dist/limits.js';
import { jpeg, segment, inject, changeDimensions, truncateEntropy } from './fixtures.mjs';

for (const options of [{}, { progressive: true }, { grey: true }, { orientation: 1 }, { orientation: 6 }]) {
  test(`fully decodes a single JPEG without altering it ${JSON.stringify(options)}`, async () => {
    const photo = await jpeg(options);
    const digest = createHash('sha256').update(photo).digest('hex');
    assert.equal(await validateJPEG(photo), true);
    assert.equal(createHash('sha256').update(photo).digest('hex'), digest);
  });
}

test('ICC/EXIF and marker-like bytes inside a comment remain a single picture', async () => {
  const photo = await jpeg({ orientation: 1 });
  const thumbnailBytes = Buffer.from([0xff, 0xd8, 0xff, 0xd9]);
  // Marker-like bytes inside a length-delimited comment are not stream markers.
  assert.equal(await validateJPEG(inject(photo, segment(0xfe, thumbnailBytes))), true);
});

test('metadata-readable but entropy-truncated photo is rejected by real full decode', async () => {
  const broken = truncateEntropy(await jpeg());
  assert.ok(inspectJPEG(broken), 'framing by itself would mistakenly accept this photo');
  assert.equal((await sharp(broken).metadata()).format, 'jpeg');
  assert.equal(await validateJPEG(broken), false);
});

test('rejects spoofed types, missing EOI, appended data, multiple JPEGs and MPF', async () => {
  const photo = await jpeg();
  const png = await sharp({ create: { width: 2, height: 2, channels: 3, background: 'red' } }).png().toBuffer();
  const values = [Buffer.from('<svg/>'), png, Buffer.from([0xff, 0xd8, 0xff, 0xd9]),
    photo.subarray(0, -2), Buffer.concat([photo, Buffer.from('trailing')]),
    Buffer.concat([photo, photo]), inject(photo, segment(0xe2, Buffer.from('MPF\0bad', 'binary'))),
    Buffer.concat([Buffer.from([0xff, 0xd8, 0xff, 0xe1, 0xff, 0xff]), photo.subarray(2)]),
  ];
  for (const value of values) assert.equal(await validateJPEG(value), false);
});

test('enforces encoded bytes, side and pixel bounds before native allocation', async () => {
  const photo = await jpeg();
  assert.equal(await validateJPEG(Buffer.alloc(MAX_PHOTO_BYTES + 1)), false);
  for (const [width, height] of [[4097, 1], [1, 4097], [65535, 65535], [0, 1], [1, 0]]) {
    assert.equal(await validateJPEG(changeDimensions(photo, width, height)), false);
  }
});

test('accepts the actual 4096 by 4096 client limit, not only small fixture thumbnails', async () => {
  // Flat generated image avoids spending time compressing random 16MP test data.
  const photo = await sharp({ create: { width: 4096, height: 4096, channels: 3, background: '#667788' } })
    .jpeg().toBuffer();
  assert.equal(await validateJPEG(photo), true);
});

test('cancelled decode reports unavailability and waits for child termination', async () => {
  const photo = await jpeg();
  const controller = new AbortController();
  const result = validateJPEG(photo, controller.signal);
  controller.abort();
  await assert.rejects(result, /DEPENDENCY_UNAVAILABLE/);
  await assert.rejects(validateJPEG(photo, controller.signal), /DEPENDENCY_UNAVAILABLE/);
  assert.equal(await validateJPEG(photo), true, 'next attempt remains usable');
});

test('hard deadline terminates native process instead of only abandoning its promise', async (t) => {
  const photo = await jpeg();
  t.mock.timers.enable({ apis: ['setTimeout'] });
  const result = validateJPEG(photo);
  t.mock.timers.tick(DECODE_TIMEOUT_MS);
  await assert.rejects(result, /DEPENDENCY_UNAVAILABLE/);
  t.mock.timers.reset();
});
