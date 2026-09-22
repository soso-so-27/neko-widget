import assert from 'node:assert/strict';
import { test } from 'node:test';
import { isInvalidJPEGError } from '../dist/decode-error.js';

test('only known libjpeg corruption diagnostics count as invalid input', () => {
  assert.equal(isInvalidJPEGError(new Error('VipsJpeg: Corrupt JPEG data: premature end of data segment')), true);
  assert.equal(isInvalidJPEGError(new Error('VipsJpeg: Invalid JPEG file structure: missing SOS marker')), true);
  for (const error of [new Error('EIO'), new Error('out of memory'), new Error('timeout'),
    new Error('VipsJpeg: unknown library failure'), new Error('invalid IPC'),
    new Error('VipsJpeg: Corrupt JPEG data: test\nEIO'),
    new TypeError('VipsJpeg: Corrupt JPEG data: test'), 'VipsJpeg: Corrupt JPEG data: test', null]) {
    assert.equal(isInvalidJPEGError(error), false);
  }
});
