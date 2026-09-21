// TEST CHILD PROCESS ONLY. No Apple/KMS/network calls; no real photos or credentials.
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { randomBytes, createHash } from 'node:crypto';
import { OfflineArchive } from './archive.mjs';
import { OfflineIdentityVerifier } from './identity.mjs';
import { createSyntheticIdentity } from './synthetic-identity.mjs';
import { sealKeyBundle, openKeyBundle } from './key-bundle.mjs';

const digest = (bytes) => createHash('sha256').update(bytes).digest('hex');
const scope = 'synthetic-neko-recovery';
const wrappingKeyId = 'synthetic-root';
let archive;
try {
  const chunks = [];
  let length = 0;
  for await (const chunk of process.stdin) {
    length += chunk.length;
    if (length > 4096) throw new Error('Invalid fixture input');
    chunks.push(chunk);
  }
  const input = JSON.parse(Buffer.concat(chunks).toString('utf8'));
  if (input.syntheticOnly !== true || !['seed', 'restore'].includes(input.mode)) throw new Error('Synthetic only');
  if (readFileSync(join(input.folder, 'SYNTHETIC_ONLY'), 'utf8') !== 'neko-offline-test') throw new Error('Invalid fixture directory');
  const wrappingKey = input.wrappingKey ? Buffer.from(input.wrappingKey, 'base64url') : undefined;
  const bundlePath = join(input.folder, 'keys.jwe');
  const provider = await createSyntheticIdentity();
  const identity = new OfflineIdentityVerifier(provider);
  const session = await provider.login(identity, { sub: input.otherOwner ? 'synthetic-other' : 'synthetic-owner' });
  let keyring;
  if (input.mode === 'seed') {
    // Data key exists only inside this child. Parent receives only encrypted bundle and hashes.
    keyring = { keys: new Map([['synthetic-data-key', randomBytes(32)]]), activeKeyId: 'synthetic-data-key' };
    const sealed = await sealKeyBundle({ ...keyring, wrappingKey, wrappingKeyId, scope });
    writeFileSync(bundlePath, sealed, { flag: 'wx', mode: 0o600 });
  } else {
    keyring = await openKeyBundle({ jwe: readFileSync(bundlePath, 'utf8'), wrappingKey, wrappingKeyId, expectedScope: scope });
  }
  archive = new OfflineArchive({ databasePath: join(input.folder, 'archive.sqlite'), initialize: input.mode === 'seed',
    identity, ...keyring, newSaveAccess: () => ({ entitlement: input.mode === 'seed' ? 'active' : 'expired',
      consentVersion: input.mode === 'seed' ? 'offline-explicit-v1' : null }) });
  if (input.mode === 'seed') {
    await archive.preserve(session, { recordId: 'synthetic-photo', photoBytes: Buffer.from('synthetic-photo-byte-fixture'),
      note: '合成記録：ひざで寝た日', metadata: { capturedAt: '2023-03-02T14:00:00+09:00', recordedAt: null, catName: '合成の猫' } });
  }
  // Also try an explicit record read: an outsider must not present an empty export as recovered.
  await archive.read(session, 'synthetic-photo');
  const summaries = [];
  for await (const record of archive.exportRecords(session)) summaries.push({
    photoHash: digest(record.photoBytes), noteHash: digest(record.noteText), metadata: record.manifest,
  });
  archive.close(); archive = undefined;
  process.stdout.write(JSON.stringify({ ok: true, pid: process.pid, records: summaries }));
} catch (error) {
  if (archive) archive.close();
  // Never log secrets, raw tokens, crypto errors, or full input, even for the test harness.
  const safe = ['WRAPPING_KEY_UNAVAILABLE', 'KEY_BUNDLE_UNREADABLE', 'ARCHIVE_DATABASE_UNAVAILABLE',
    'ARCHIVE_KEY_UNAVAILABLE', 'ARCHIVE_INTEGRITY_FAILED', 'RECORD_NOT_FOUND', 'ENOENT'];
  process.stdout.write(JSON.stringify({ ok: false, code: safe.includes(error.code) ? error.code : 'FIXTURE_FAILED' }));
  process.exitCode = 1;
}
