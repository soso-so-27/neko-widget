import { base64urlDecode, sha256Base64url, verifyEd25519 } from './encoding';
import { groupDeviceAuthorization, groupFields, type GroupRosterDevice } from './group-protocol';
import { ApiError } from './errors';
import { asObject, binaryField, exactKeys, integerField, stringField } from './validation';

export interface FamilyCryptoMember { personId: string; identityPublicKey: string; devices: GroupRosterDevice[] }
export interface FamilyCryptoRoster {
  familyId: string; epoch: number; previousHash: string; keyCommitment: string; members: FamilyCryptoMember[];
}
export interface SignedFamilyCryptoRoster { roster: FamilyCryptoRoster; signerDeviceId: string; signature: string }
export interface VerifiedFamilyCryptoRoster { packet: SignedFamilyCryptoRoster; hash: string }
export interface FamilyKeyEnvelope {
  familyId: string; keyEpoch: number; keyRosterHash: string; recipientRosterHash: string;
  recipientDeviceId: string; signerDeviceId: string; encapsulatedKey: string; ciphertext: string; signature: string;
}
export interface FamilyEncryptedOperation {
  familyId: string; keyEpoch: number; rosterHash: string; operationId: string; personId: string;
  deviceId: string; ciphertext: string; signature: string;
}
function invalid(): never { throw new ApiError(400, 'invalid_family_proof', 'The family proof could not be verified.'); }
function id(value: unknown): string {
  if (typeof value !== 'string' || !/^[A-Za-z0-9_-]{1,128}$/u.test(value)) invalid();
  return value;
}
// Swift's UUID Codable representation uses uppercase; signed transcripts use
// the lowercase canonical form on both platforms. HTTP path IDs stay lowercase.
export function familyUUID(value: unknown): string {
  if (typeof value !== 'string' || !/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/iu.test(value)) invalid();
  return value.toLowerCase();
}
function unique(values: string[]): void { if (new Set(values).size !== values.length) invalid(); }
function sorted<T>(values: T[], key: (value: T) => string): T[] {
  return [...values].sort((a, b) => key(a) < key(b) ? -1 : key(a) > key(b) ? 1 : 0);
}
export function familyDevice(roster: FamilyCryptoRoster, deviceId: string): { member: FamilyCryptoMember; device: GroupRosterDevice } | undefined {
  for (const member of roster.members) {
    const device = member.devices.find(d => d.id === deviceId);
    if (device) return { member, device };
  }
  return undefined;
}
export function familyRosterBytes(value: unknown): Uint8Array {
  const r = asObject(value);
  exactKeys(r, ['familyId', 'epoch', 'previousHash', 'keyCommitment', 'members']);
  const family = familyUUID(r.familyId), epoch = integerField(r, 'epoch', 1, 1_000_000_000);
  const previous = base64urlDecode(binaryField(r, 'previousHash', 32), 32);
  const commitment = base64urlDecode(binaryField(r, 'keyCommitment', 32), 32);
  if (epoch === 1 && previous.some(b => b !== 0)) invalid();
  if (!Array.isArray(r.members) || r.members.length < 1 || r.members.length > 64) invalid();
  const members = r.members as FamilyCryptoMember[];
  for (const value of members) {
    const m = asObject(value); exactKeys(m, ['personId', 'identityPublicKey', 'devices']);
    id(m.personId); binaryField(m, 'identityPublicKey', 32);
    if (!Array.isArray(m.devices) || m.devices.length < 1 || m.devices.length > 3) invalid();
    for (const value of m.devices) {
      const d = asObject(value); exactKeys(d, ['id', 'signingPublicKey', 'hpkePublicKey', 'personAuthorization']);
      id(d.id); binaryField(d, 'signingPublicKey', 32); binaryField(d, 'hpkePublicKey', 32); binaryField(d, 'personAuthorization', 64);
    }
  }
  unique(members.map(m => m.personId)); unique(members.map(m => m.identityPublicKey));
  const devices = members.flatMap(m => m.devices);
  unique(devices.map(d => d.id)); unique(devices.map(d => d.signingPublicKey)); unique(devices.map(d => d.hpkePublicKey));
  const fields: (string | Uint8Array)[] = ['FNB1.ROSTER', family, String(epoch), previous, commitment, String(members.length)];
  for (const m of sorted(members, m => m.personId)) {
    fields.push(m.personId, base64urlDecode(m.identityPublicKey, 32), String(m.devices.length));
    for (const d of sorted(m.devices, d => d.id)) {
      fields.push(d.id, base64urlDecode(d.signingPublicKey, 32), base64urlDecode(d.hpkePublicKey, 32), base64urlDecode(d.personAuthorization, 64));
    }
  }
  const result = groupFields(fields); if (result.length > 65535) invalid(); return result;
}
export async function verifyFamilyRoster(value: unknown, previous?: VerifiedFamilyCryptoRoster): Promise<VerifiedFamilyCryptoRoster> {
  const raw = asObject(value); exactKeys(raw, ['roster', 'signerDeviceId', 'signature']);
  id(raw.signerDeviceId); binaryField(raw, 'signature', 64);
  const bytes = familyRosterBytes(raw.roster), packet = raw as unknown as SignedFamilyCryptoRoster, r = packet.roster;
  const signer = familyDevice(r, packet.signerDeviceId); if (!signer) invalid();
  for (const m of r.members) for (const d of m.devices) {
    if (!await verifyEd25519(m.identityPublicKey, d.personAuthorization, groupDeviceAuthorization(familyUUID(r.familyId), m.personId, d))) invalid();
  }
  if (!await verifyEd25519(signer.device.signingPublicKey, packet.signature, groupFields(['FNB1.ROSTER.SIGN', bytes, packet.signerDeviceId]))) invalid();
  if (previous) {
    const old = previous.packet.roster, before = familyDevice(old, packet.signerDeviceId);
    if (familyUUID(r.familyId) !== familyUUID(old.familyId) || r.epoch !== old.epoch + 1 || r.previousHash !== previous.hash
      || r.keyCommitment === old.keyCommitment || !before || before.member.personId !== signer.member.personId
      || !sameDevice(before.device, signer.device)) invalid();
    for (const m of r.members) {
      const prior = old.members.find(p => p.personId === m.personId);
      if (prior && prior.identityPublicKey !== m.identityPublicKey) invalid();
      for (const d of m.devices) {
        const prior = familyDevice(old, d.id);
        if (prior && (prior.member.personId !== m.personId || !sameDevice(prior.device, d))) invalid();
      }
    }
  }
  return { packet, hash: await sha256Base64url(bytes) };
}
function sameDevice(a: GroupRosterDevice, b: GroupRosterDevice): boolean {
  return a.id === b.id && a.signingPublicKey === b.signingPublicKey && a.hpkePublicKey === b.hpkePublicKey && a.personAuthorization === b.personAuthorization;
}
// Callers must establish that source belongs to current's stored hash chain;
// individual signed rosters alone cannot establish history/fork continuity.
export async function verifyFamilyEnvelope(value: unknown, current: VerifiedFamilyCryptoRoster,
  source: VerifiedFamilyCryptoRoster): Promise<FamilyKeyEnvelope> {
  const raw = asObject(value);
  exactKeys(raw, ['familyId', 'keyEpoch', 'keyRosterHash', 'recipientRosterHash', 'recipientDeviceId', 'signerDeviceId', 'encapsulatedKey', 'ciphertext', 'signature']);
  const family = familyUUID(raw.familyId);
  const epoch = integerField(raw, 'keyEpoch', 1, 1_000_000_000);
  binaryField(raw, 'keyRosterHash', 32); binaryField(raw, 'recipientRosterHash', 32);
  binaryField(raw, 'encapsulatedKey', 32); binaryField(raw, 'ciphertext', 48); binaryField(raw, 'signature', 64);
  const recipient = familyDevice(current.packet.roster, id(raw.recipientDeviceId)), signer = familyDevice(current.packet.roster, id(raw.signerDeviceId));
  if (family !== familyUUID(current.packet.roster.familyId) || family !== familyUUID(source.packet.roster.familyId)
    || epoch !== source.packet.roster.epoch || raw.keyRosterHash !== source.hash || raw.recipientRosterHash !== current.hash || !recipient || !signer) invalid();
  const e = raw as unknown as FamilyKeyEnvelope;
  const info = groupFields(['FNB1.KEY', family, String(epoch), base64urlDecode(source.hash, 32), base64urlDecode(current.hash, 32), e.recipientDeviceId]);
  if (!await verifyEd25519(signer.device.signingPublicKey, e.signature,
    groupFields(['FNB1.KEY.SIGN', info, base64urlDecode(e.encapsulatedKey, 32), base64urlDecode(e.ciphertext, 48), e.signerDeviceId]))) invalid();
  return e;
}
export async function verifyFamilyOperation(value: unknown, roster: VerifiedFamilyCryptoRoster): Promise<FamilyEncryptedOperation> {
  const raw = asObject(value);
  exactKeys(raw, ['familyId', 'keyEpoch', 'rosterHash', 'operationId', 'personId', 'deviceId', 'ciphertext', 'signature']);
  const family = familyUUID(raw.familyId), operationId = familyUUID(raw.operationId), epoch = integerField(raw, 'keyEpoch', 1, 1_000_000_000);
  const personId = id(raw.personId), deviceId = id(raw.deviceId);
  binaryField(raw, 'rosterHash', 32); binaryField(raw, 'signature', 64);
  const ciphertext = base64urlDecode(stringField(raw, 'ciphertext'));
  if (ciphertext.length < 29 || ciphertext.length > 1_048_576) invalid();
  const signer = familyDevice(roster.packet.roster, deviceId);
  if (family !== familyUUID(roster.packet.roster.familyId) || epoch !== roster.packet.roster.epoch || raw.rosterHash !== roster.hash
    || signer?.member.personId !== personId) invalid();
  const aad = groupFields(['FNB1.OPERATION', family, String(epoch), base64urlDecode(roster.hash, 32), operationId, personId, deviceId, String(ciphertext.length)]);
  if (!await verifyEd25519(signer.device.signingPublicKey, stringField(raw, 'signature'),
    groupFields(['FNB1.OPERATION.SIGN', aad, base64urlDecode(await sha256Base64url(ciphertext), 32)]))) invalid();
  return raw as unknown as FamilyEncryptedOperation;
}
