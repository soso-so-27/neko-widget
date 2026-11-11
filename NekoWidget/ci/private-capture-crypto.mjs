// Authenticated, all-or-nothing transport for owner-supplied screenshot media.
// No key, plaintext, or decoded image is ever written to stdout.
import { createCipheriv, createDecipheriv, randomBytes } from 'node:crypto';
import { readFile, writeFile } from 'node:fs/promises';

const [operation, input, output] = process.argv.slice(2);
const encodedKey = process.env.NEKO_CAPTURE_KEY;
if (!/^[0-9a-f]{64}$/i.test(encodedKey ?? '') || !['seal', 'open'].includes(operation) || !input || !output) {
  throw new Error('Expected seal/open, input, output and a 256-bit transport key');
}
const key = Buffer.from(encodedKey, 'hex');
const header = Buffer.from('NEKOCAP1');
const bytes = await readFile(input);
let result;
if (operation === 'seal') {
  const nonce = randomBytes(12);
  const cipher = createCipheriv('aes-256-gcm', key, nonce);
  cipher.setAAD(header);
  result = Buffer.concat([header, nonce, cipher.update(bytes), cipher.final(), cipher.getAuthTag()]);
} else {
  if (bytes.length < 36 || !bytes.subarray(0, 8).equals(header)) throw new Error('Invalid encrypted capture');
  const decipher = createDecipheriv('aes-256-gcm', key, bytes.subarray(8, 20));
  decipher.setAAD(header);
  decipher.setAuthTag(bytes.subarray(-16));
  // Do not create the destination before authentication succeeds.
  result = Buffer.concat([decipher.update(bytes.subarray(20, -16)), decipher.final()]);
}
await writeFile(output, result, { flag: 'wx', mode: 0o600 });
key.fill(0);
