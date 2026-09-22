import sharp from 'sharp';

// Synthetic pixels, generated locally. No user photos/network fixtures.
export async function jpeg({ width = 24, height = 16, progressive = false, grey = false, orientation } = {}) {
  const raw = Buffer.alloc(width * height * 3);
  for (let at = 0; at < raw.length; at++) raw[at] = (at * 37 + (at >> 8) * 13) % 256;
  let image = sharp(raw, { raw: { width, height, channels: 3 } });
  if (grey) image = image.toColourspace('b-w');
  if (orientation !== undefined) image = image.withMetadata({ orientation });
  return image.jpeg({ progressive, quality: 92 }).toBuffer();
}

export function segment(marker, payload) {
  const header = Buffer.from([0xff, marker, 0, 0]);
  header.writeUInt16BE(payload.length + 2, 2);
  return Buffer.concat([header, payload]);
}
export const inject = (photo, extra) => Buffer.concat([photo.subarray(0, 2), extra, photo.subarray(2)]);

export function changeDimensions(photo, width, height) {
  const copy = Buffer.from(photo);
  for (let at = 2; at < copy.length - 8; at++) {
    if (copy[at] === 0xff && [0xc0, 0xc1, 0xc2].includes(copy[at + 1])) {
      copy.writeUInt16BE(height, at + 5); copy.writeUInt16BE(width, at + 7);
      return copy;
    }
  }
  throw new Error('fixture SOF not found');
}

export function truncateEntropy(photo) {
  const at = photo.indexOf(Buffer.from([0xff, 0xda]));
  const end = at + 2 + photo.readUInt16BE(at + 2);
  return Buffer.concat([photo.subarray(0, end + 1), Buffer.from([0xff, 0xd9])]);
}

export const request = (photo, options = {}) => new Request('https://preservation-internal/images/validate-jpeg', {
  method: 'POST', headers: { 'content-type': 'application/json' },
  body: JSON.stringify({ photoBase64: photo.toString('base64') }), ...options,
});
