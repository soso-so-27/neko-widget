import { readBoundedBody } from './bounded-body';
import { ServiceError } from './contracts';

// Preserve the existing key-custody plaintext limit, including after expansion.
export const MAX_OWNER_SNAPSHOT_BYTES = 21 * 1024 * 1024;
const magic = new Uint8Array([78, 75, 90, 49]); // NKZ1
const headerBytes = 8; // magic + unsigned big-endian uncompressed length
// Workerd emits 4 KiB gzip output chunks: a valid 21 MiB body needs 5376.
// Network callers of readBoundedBody keep their original 4096-chunk bound.
const maximumCodecChunks = 8192;
const unavailable = () => new ServiceError('OWNER_RECOVERY_UNAVAILABLE', 503);
function validSize(bytes: Uint8Array): void {
  if (!bytes.length || bytes.length > MAX_OWNER_SNAPSHOT_BYTES) throw unavailable();
}

/** Only owner metadata uses this codec, BEFORE the existing authenticated seal.
 * Small/incompressible snapshots retain the legacy JSON representation. */
export async function compressOwnerSnapshot(bytes: Uint8Array): Promise<Uint8Array> {
  validSize(bytes);
  if (bytes.length < 4096) return bytes;
  try {
    const gzip = await readBoundedBody(new Blob([bytes.slice()]).stream()
      .pipeThrough(new CompressionStream('gzip')), MAX_OWNER_SNAPSHOT_BYTES + 65_536,
      unavailable, undefined, unavailable, maximumCodecChunks);
    if (gzip.length + headerBytes >= bytes.length * 0.9) return bytes;
    const framed = new Uint8Array(headerBytes + gzip.length);
    framed.set(magic);
    new DataView(framed.buffer).setUint32(4, bytes.length, false);
    framed.set(gzip, headerBytes);
    return framed;
  } catch { throw unavailable(); }
}

/** Call ONLY after owner/purpose-bound authentication succeeds. Read both
 * formats regardless of the write gate; corrupt/unknown frames never fall back. */
export async function openOwnerSnapshot(bytes: Uint8Array): Promise<Uint8Array> {
  validSize(bytes);
  if (!magic.subarray(0, 3).every((byte, i) => bytes[i] === byte)) return bytes;
  if (bytes.length <= headerBytes || !magic.every((byte, i) => bytes[i] === byte)) throw unavailable();
  const declared = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength).getUint32(4, false);
  if (!declared || declared > MAX_OWNER_SNAPSHOT_BYTES) throw unavailable();
  try {
    // Bound expansion while streaming, not after allocating an unbounded body.
    const opened = await readBoundedBody(new Blob([bytes.slice(headerBytes)]).stream()
      .pipeThrough(new DecompressionStream('gzip')), declared,
      unavailable, undefined, unavailable, maximumCodecChunks);
    if (opened.length !== declared) throw unavailable();
    return opened;
  } catch { throw unavailable(); }
}
