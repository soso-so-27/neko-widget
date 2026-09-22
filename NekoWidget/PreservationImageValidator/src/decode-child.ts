import sharp from 'sharp';
import { inspectJPEG } from './jpeg-envelope.js';
import { MAX_PIXELS } from './limits.js';
import { isInvalidJPEGError } from './decode-error.js';

// This runs in a disposable process. Do not import it in the serving process.
sharp.cache(false);
sharp.concurrency(1);
sharp.block({ operation: ['VipsForeignLoad'] });
sharp.unblock({ operation: ['VipsForeignLoadJpeg'] });

process.once('message', async (message: unknown) => {
  let result: { valid: boolean } | { unavailable: true };
  try {
    if (!(message instanceof Uint8Array)) throw new Error('invalid IPC');
    const frame = inspectJPEG(message);
    if (!frame) result = { valid: false };
    else {
      const input = sharp(message, { failOn: 'warning', limitInputPixels: MAX_PIXELS,
        limitInputChannels: 4, sequentialRead: true });
      // metadata() alone does not read entropy-coded image data. Force ALL pixels.
      const { data, info } = await input.toColourspace('srgb').removeAlpha()
        .raw({ depth: 'uchar' }).timeout({ seconds: 4 }).toBuffer({ resolveWithObject: true });
      result = { valid: info.width === frame.width && info.height === frame.height
        && info.channels === 3 && data.length === frame.width * frame.height * 3 };
      data.fill(0);
    }
  } catch (error) {
    result = isInvalidJPEGError(error) ? { valid: false } : { unavailable: true };
  }
  // No image bytes, metadata, native error messages, secrets, or disk writes.
  if (process.send) process.send(result, undefined, undefined, () => process.disconnect());
});
