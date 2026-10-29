import assert from 'node:assert/strict';
import { createHash, createPublicKey, verify, createDecipheriv, generateKeyPairSync, sign, createCipheriv } from 'node:crypto';

const bytes = value => Buffer.from(value, 'base64url');
const hash = value => createHash('sha256').update(value).digest();
function fields(values) {
  return Buffer.concat(values.map(value => {
    const data = Buffer.isBuffer(value) ? value : Buffer.from(String(value));
    assert.ok(data.length <= 65535);
    const size = Buffer.alloc(2); size.writeUInt16BE(data.length);
    return Buffer.concat([size, data]);
  }));
}
function signed(message, signature, key) {
  assert.ok(verify(null, message, createPublicKey({
    key: Buffer.concat([Buffer.from('302a300506032b6570032100', 'hex'), bytes(key)]), format: 'der', type: 'spki',
  }), bytes(signature)), 'Ed25519 signature');
}
export function verifyVector(vector) {
  const { packet, operation: op } = vector, r = packet.roster;
  const family = r.familyId.toLowerCase();
  const values = ['FNB1.ROSTER', family, r.epoch, bytes(r.previousHash), bytes(r.keyCommitment), r.members.length];
  const devices = new Map();
  for (const member of [...r.members].sort((a, b) => a.personId < b.personId ? -1 : 1)) {
    values.push(member.personId, bytes(member.identityPublicKey), member.devices.length);
    for (const d of [...member.devices].sort((a, b) => a.id < b.id ? -1 : 1)) {
      signed(fields(['NW3.DEVICE', family, member.personId, d.id, bytes(d.signingPublicKey), bytes(d.hpkePublicKey)]),
        d.personAuthorization, member.identityPublicKey);
      values.push(d.id, bytes(d.signingPublicKey), bytes(d.hpkePublicKey), bytes(d.personAuthorization));
      devices.set(d.id, { ...d, personId: member.personId });
    }
  }
  const canonical = fields(values), rosterHash = hash(canonical);
  assert.deepEqual(rosterHash, bytes(vector.hash));
  signed(fields(['FNB1.ROSTER.SIGN', canonical, packet.signerDeviceId]), packet.signature, devices.get(packet.signerDeviceId).signingPublicKey);
  assert.equal(op.familyId.toLowerCase(), family);
  assert.equal(op.keyEpoch, r.epoch);
  assert.deepEqual(bytes(op.rosterHash), rosterHash);
  assert.equal(devices.get(op.deviceId).personId, op.personId);
  const ciphertext = bytes(op.ciphertext);
  const aad = fields(['FNB1.OPERATION', family, r.epoch, rosterHash, op.operationId.toLowerCase(), op.personId, op.deviceId, ciphertext.length]);
  signed(fields(['FNB1.OPERATION.SIGN', aad, hash(ciphertext)]), op.signature, devices.get(op.deviceId).signingPublicKey);
  // Fixed public synthetic key from the native probe; never production.
  const key = Buffer.alloc(32, 1);
  assert.deepEqual(hash(key), bytes(r.keyCommitment));
  const decryptor = createDecipheriv('aes-256-gcm', key, ciphertext.subarray(0, 12));
  decryptor.setAAD(aad); decryptor.setAuthTag(ciphertext.subarray(-16));
  const plain = JSON.parse(Buffer.concat([decryptor.update(ciphertext.subarray(12, -16)), decryptor.final()]));
  assert.equal(plain.familyId.toLowerCase(), family);
  assert.equal(plain.version.operationId.toLowerCase(), op.operationId.toLowerCase());
  assert.equal(plain.version.deviceId, op.deviceId);
  assert.equal(plain.author.personId, op.personId);
  assert.equal(plain.value.text._0, '合成のねこ');
}

function selfTest() {
  const root = generateKeyPairSync('ed25519'), device = generateKeyPairSync('ed25519');
  const publicKey = pair => pair.publicKey.export({ format: 'der', type: 'spki' }).subarray(-32).toString('base64url');
  const signature = (data, pair) => sign(null, data, pair.privateKey).toString('base64url');
  const family = '11111111-1111-4111-8111-111111111111', personId = 'person-a', id = 'device-a';
  const d = { id, signingPublicKey: publicKey(device), hpkePublicKey: Buffer.alloc(32, 2).toString('base64url') };
  d.personAuthorization = signature(fields(['NW3.DEVICE', family, personId, id, bytes(d.signingPublicKey), bytes(d.hpkePublicKey)]), root);
  const r = { familyId: family, epoch: 1, previousHash: Buffer.alloc(32).toString('base64url'),
    keyCommitment: hash(Buffer.alloc(32, 1)).toString('base64url'), members: [{ personId, identityPublicKey: publicKey(root), devices: [d] }] };
  const canonical = fields(['FNB1.ROSTER', family, 1, bytes(r.previousHash), bytes(r.keyCommitment), 1,
    personId, bytes(r.members[0].identityPublicKey), 1, id, bytes(d.signingPublicKey), bytes(d.hpkePublicKey), bytes(d.personAuthorization)]);
  const rosterHash = hash(canonical), operationId = '22222222-2222-4222-8222-222222222222';
  const plain = Buffer.from(JSON.stringify({ familyId: family, version: { operationId, deviceId: id }, author: { personId }, value: { text: { _0: '合成のねこ' } } }));
  const aad = fields(['FNB1.OPERATION', family, 1, rosterHash, operationId, personId, id, plain.length + 28]);
  const nonce = Buffer.alloc(12, 4), encryptor = createCipheriv('aes-256-gcm', Buffer.alloc(32, 1), nonce); encryptor.setAAD(aad);
  const ciphertext = Buffer.concat([nonce, encryptor.update(plain), encryptor.final(), encryptor.getAuthTag()]);
  const vector = { packet: { roster: r, signerDeviceId: id, signature: signature(fields(['FNB1.ROSTER.SIGN', canonical, id]), device) },
    hash: rosterHash.toString('base64url'), operation: { familyId: family, keyEpoch: 1, rosterHash: rosterHash.toString('base64url'), operationId,
      personId, deviceId: id, ciphertext: ciphertext.toString('base64url'), signature: signature(fields(['FNB1.OPERATION.SIGN', aad, hash(ciphertext)]), device) } };
  verifyVector(vector);
  for (const field of ['signature', 'ciphertext', 'rosterHash']) {
    const bad = structuredClone(vector); bad.operation[field] = Buffer.alloc(bytes(bad.operation[field]).length).toString('base64url');
    assert.throws(() => verifyVector(bad));
  }
  const bad = structuredClone(vector); bad.packet.roster.familyId = '33333333-3333-4333-8333-333333333333';
  assert.throws(() => verifyVector(bad));
  console.log('Family notebook independent crypto verifier self-test passed');
}
if (process.argv.includes('--self-test')) selfTest();
else {
  let input = ''; for await (const chunk of process.stdin) input += chunk;
  verifyVector(JSON.parse(input));
  console.log('Family notebook native history, rotation, tamper and causal-frontier checks passed; independent Node signatures and AES-GCM passed');
}
