import { base64urlDecode, sha256Base64url, verifyEd25519 } from "./encoding";
import { ApiError } from "./errors";
import { groupDeviceAuthorization, groupFields, groupRosterBytes,
  type GroupRoster, type GroupRosterDevice, type VerifiedGroupRoster } from "./group-protocol";

/** P1 validates a proposal only. No route, issuance, D1 write or capability. */
export const groupRecoveryIssuanceEnabled = false;
export interface GroupRecoveryClaim {
  version: number;
  environment: "production" | "staging";
  windowId: string;
  personId: string;
  participantId: string;
  recoveryGeneration: number;
  previousRevision: number;
  previousHash: string;
  nextHash: string;
  newDevice: GroupRosterDevice;
  replacedDeviceIds: string[];
  operationId: string;
  challenge: string;
  issuedAt: number;
  expiresAt: number;
}
export interface GroupRecoveryProof {
  claim: GroupRecoveryClaim;
  rootSignature: string;
  deviceSignature: string;
}
/** Supplied by the atomic ledger adapter, NEVER decoded from the proposal.
 * A successful proof is not a substitute for CAS/challenge consumption at
 * issuance. P3 must repeat this validation inside that atomic operation. */
export interface GroupRecoveryLedger {
  environment: "production" | "staging";
  windowId: string;
  personId: string;
  participantId: string;
  identityPublicKey: string;
  revision: number;
  hash: string;
  recoveryGeneration: number;
  state: "active" | "closed" | "deleted" | "left" | "removed" | "root-revoked";
  newDeviceWasRevoked: boolean;
  challenge: { value: string; operationId: string; issuedAt: number; expiresAt: number; consumed: boolean };
}
function fail(code = "invalid_recovery_proof"): never {
  throw new ApiError(code === "CLIENT_UPGRADE_REQUIRED" ? 426 : 400, code, "Recovery proof unavailable or invalid.");
};
function exact(value: object, names: string[]) {
  if (!value || typeof value !== "object" || Array.isArray(value)
      || Object.keys(value).length !== names.length || Object.keys(value).some(n => !names.includes(n))) fail();
}
const id = (s: string) => typeof s === "string" && /^[A-Za-z0-9_-]{1,128}$/u.test(s);
const positive = (n: number) => Number.isSafeInteger(n) && n > 0;
export function groupRecoveryClaimBytes(c: GroupRecoveryClaim): Uint8Array {
  exact(c, ["version", "environment", "windowId", "personId", "participantId", "recoveryGeneration",
    "previousRevision", "previousHash", "nextHash", "newDevice", "replacedDeviceIds", "operationId", "challenge", "issuedAt", "expiresAt"]);
  if (!positive(c.version)) fail();
  if (c.version !== 1) fail("CLIENT_UPGRADE_REQUIRED");
  if (!["production", "staging"].includes(c.environment) || ![c.windowId, c.personId, c.participantId, c.operationId].every(id)
      || !positive(c.recoveryGeneration) || !positive(c.previousRevision) || !positive(c.issuedAt)
      || !positive(c.expiresAt) || c.expiresAt <= c.issuedAt || c.expiresAt - c.issuedAt > 300
      || !Array.isArray(c.replacedDeviceIds) || c.replacedDeviceIds.length > 3
      || !c.replacedDeviceIds.every(id) || new Set(c.replacedDeviceIds).size !== c.replacedDeviceIds.length) fail();
  exact(c.newDevice, ["id", "signingPublicKey", "hpkePublicKey", "personAuthorization"]);
  if (!id(c.newDevice.id) || c.replacedDeviceIds.includes(c.newDevice.id)) fail();
  return groupFields(["NW3.RECOVER_DEVICE.V1", c.environment, c.windowId, c.personId, c.participantId,
    String(c.recoveryGeneration), String(c.previousRevision), base64urlDecode(c.previousHash, 32),
    base64urlDecode(c.nextHash, 32), c.newDevice.id, base64urlDecode(c.newDevice.signingPublicKey, 32),
    base64urlDecode(c.newDevice.hpkePublicKey, 32), base64urlDecode(c.newDevice.personAuthorization, 64),
    String(c.replacedDeviceIds.length), ...[...c.replacedDeviceIds].sort(), c.operationId,
    base64urlDecode(c.challenge, 32), String(c.issuedAt), String(c.expiresAt)]);
}
export function groupRecoverySignatureBytes(c: GroupRecoveryClaim, signer: "root" | "device"): Uint8Array {
  if (signer !== "root" && signer !== "device") fail();
  return groupFields([signer === "root" ? "NW3.RECOVER_DEVICE.ROOT.V1" : "NW3.RECOVER_DEVICE.DEVICE.V1", groupRecoveryClaimBytes(c)]);
}
function deviceKey(d: GroupRosterDevice): string {
  return JSON.stringify([d.id, d.signingPublicKey, d.hpkePublicKey, d.personAuthorization]);
}
function memberKey(m: GroupRoster["members"][number]): string {
  return JSON.stringify([m.participantId, m.personId, m.identityPublicKey, m.role, m.devices.map(deviceKey).sort()]);
}
/** Returns no VerifiedGroupRoster and cannot authorize reads/writes/decryption. */
export async function validateGroupRecoveryProof(proof: GroupRecoveryProof, previous: VerifiedGroupRoster,
  next: GroupRoster, ledger: GroupRecoveryLedger, now: number): Promise<void> {
  exact(proof, ["claim", "rootSignature", "deviceSignature"]);
  const c = proof.claim;
  groupRecoveryClaimBytes(c);
  const old = previous.packet.roster;
  const oldHash = await sha256Base64url(groupRosterBytes(old));
  const nextHash = await sha256Base64url(groupRosterBytes(next));
  if (!positive(now) || now < c.issuedAt || now >= c.expiresAt || ledger.state !== "active"
      || ledger.newDeviceWasRevoked !== false || ledger.challenge.consumed !== false
      || ledger.environment !== c.environment || ledger.windowId !== c.windowId
      || ledger.personId !== c.personId || ledger.participantId !== c.participantId
      || ledger.recoveryGeneration !== c.recoveryGeneration || ledger.revision !== c.previousRevision
      || ledger.hash !== c.previousHash || ledger.challenge.value !== c.challenge
      || ledger.challenge.operationId !== c.operationId || ledger.challenge.issuedAt !== c.issuedAt
      || ledger.challenge.expiresAt !== c.expiresAt) fail("stale_recovery_state");
  if (old.windowId !== c.windowId || old.revision !== c.previousRevision || previous.hash !== oldHash
      || oldHash !== c.previousHash || nextHash !== c.nextHash || next.previousHash !== oldHash
      || next.windowId !== old.windowId || next.ownerPersonId !== old.ownerPersonId
      || next.revision - old.revision !== 1 || next.keyEpoch - old.keyEpoch !== 1
      || next.members.length !== old.members.length) fail();
  const owner = old.members.find(m => m.personId === c.personId && m.participantId === c.participantId);
  const recovered = next.members.find(m => m.personId === c.personId && m.participantId === c.participantId);
  if (!owner || !recovered || owner.identityPublicKey !== ledger.identityPublicKey
      || recovered.identityPublicKey !== owner.identityPublicKey || recovered.role !== owner.role) fail();
  if (old.members.flatMap(m => m.devices).some(d => d.id === c.newDevice.id
      || d.signingPublicKey === c.newDevice.signingPublicKey || d.hpkePublicKey === c.newDevice.hpkePublicKey)
      || c.replacedDeviceIds.some(d => !owner.devices.some(v => v.id === d))) fail();
  const expected = [...owner.devices.filter(d => !c.replacedDeviceIds.includes(d.id)), c.newDevice].map(deviceKey).sort();
  if (JSON.stringify(recovered.devices.map(deviceKey).sort()) !== JSON.stringify(expected)) fail();
  for (const m of old.members.filter(m => m.personId !== c.personId)) {
    const other = next.members.find(n => n.personId === m.personId);
    if (!other || memberKey(other) !== memberKey(m)) fail();
  }
  for (const m of next.members) for (const d of m.devices) {
    if (!await verifyEd25519(m.identityPublicKey, d.personAuthorization, groupDeviceAuthorization(next.windowId, m.personId, d))) fail();
  }
  if (!await verifyEd25519(owner.identityPublicKey, proof.rootSignature, groupRecoverySignatureBytes(c, "root"))
      || !await verifyEd25519(c.newDevice.signingPublicKey, proof.deviceSignature, groupRecoverySignatureBytes(c, "device"))) fail("invalid_signature");
}
