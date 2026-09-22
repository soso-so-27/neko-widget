import { MAX_MARKERS, MAX_PHOTO_BYTES, MAX_PIXELS, MAX_SCANS, MAX_SIDE } from './limits.js';

export interface JPEGFrame { width: number; height: number; components: number }

// A bounded framing check, NOT a pixel decoder. Full decoding is still mandatory.
// Rejects additional pictures/MPF and trailing data even if libjpeg accepts frame 1.
export function inspectJPEG(bytes: Uint8Array): JPEGFrame | null {
  if (bytes.length < 4 || bytes.length > MAX_PHOTO_BYTES || bytes[0] !== 0xff || bytes[1] !== 0xd8) return null;
  let at = 2, scans = 0, markers = 0;
  let entropy = false;
  let frame: JPEGFrame | null = null;
  while (at < bytes.length) {
    if (entropy) {
      while (at < bytes.length && bytes[at] !== 0xff) at++;
      if (at >= bytes.length) return null;
    } else if (bytes[at] !== 0xff) return null;
    while (bytes[at] === 0xff) at++;
    const marker = bytes[at++];
    if (marker === undefined) return null;
    if (entropy && (marker === 0 || (marker >= 0xd0 && marker <= 0xd7))) continue;
    entropy = false;
    if (++markers > MAX_MARKERS) return null;
    if (marker === 0xd9) return frame && scans > 0 && at === bytes.length ? frame : null;
    // Baseline/extended sequential/progressive Huffman-coded, single 8-bit frame.
    const isFrame = marker === 0xc0 || marker === 0xc1 || marker === 0xc2;
    const isMetadata = marker >= 0xe0 && marker <= 0xef || marker === 0xfe;
    if (!isFrame && !isMetadata && ![0xc4, 0xdb, 0xdd, 0xda].includes(marker)) return null;
    if (at + 2 > bytes.length) return null;
    const length = bytes[at]! * 256 + bytes[at + 1]!;
    const end = at + length;
    if (length < 2 || end > bytes.length) return null;
    const start = at + 2;
    if (marker === 0xe2 && length >= 6 && bytes[start] === 0x4d && bytes[start + 1] === 0x50
      && bytes[start + 2] === 0x46 && bytes[start + 3] === 0) return null;
    if (isFrame) {
      if (frame || length < 8 || bytes[start] !== 8) return null;
      const height = bytes[start + 1]! * 256 + bytes[start + 2]!;
      const width = bytes[start + 3]! * 256 + bytes[start + 4]!;
      const components = bytes[start + 5]!;
      if (![1, 3, 4].includes(components) || length !== 8 + 3 * components
        || !width || !height || width > MAX_SIDE || height > MAX_SIDE || width * height > MAX_PIXELS) return null;
      frame = { width, height, components };
    }
    if (marker === 0xda) {
      if (!frame || ++scans > MAX_SCANS || length < 6) return null;
      const components = bytes[start]!;
      if (!components || components > frame.components || length !== 6 + 2 * components) return null;
      entropy = true;
    }
    at = end;
  }
  return null;
}
