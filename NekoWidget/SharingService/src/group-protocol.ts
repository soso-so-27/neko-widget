import { base64urlDecode, base64urlEncode, sha256Base64url, verifyEd25519 } from "./encoding";
import { ApiError } from "./errors";

export interface GroupRosterDevice {
  id: string;
  signingPublicKey: string;
  hpkePublicKey: string;
  personAuthorization: string;
}
export interface GroupRosterMember {
  participantId: string;
  personId: string;
  identityPublicKey: string;
  role: "owner" | "member";
  devices: GroupRosterDevice[];
}
export interface GroupRoster {
  windowId: string;
  revision: number;
  keyEpoch: number;
  previousHash: string;
  ownerPersonId: string;
  members: GroupRosterMember[];
}
export interface SignedGroupRoster {
  roster: GroupRoster;
  signerDeviceId: string;
  signature: string;
}
export interface GroupKeyEnvelope {
  windowId: string;
  keyEpoch: number;
  rosterHash: string;
  deviceId: string;
  encapsulatedKey: string;
  ciphertext: string;
  signerDeviceId: string;
  signature: string;
}
export interface GroupTrustAnchor {
  windowId: string;
  ownerPersonId: string;
  ownerIdentityPublicKey: string;
}

const encoder = new TextEncoder();
function invalid(code = "invalid_roster"): never { throw new ApiError(400, code, "The group proof could not be verified."); }
function id(value: string): boolean { return typeof value === "string" && /^[A-Za-z0-9_-]{1,128}$/u.test(value); }
function unique(values: readonly string[]): boolean { return new Set(values).size === values.length; }
function sorted<T>(values: readonly T[], key: (value: T) => string): T[] {
  // IDs are restricted to ASCII, so localeCompare must not influence signing.
  return [...values].sort((a, b) => key(a) < key(b) ? -1 : key(a) > key(b) ? 1 : 0);
}
function safePositive(value: number): boolean { return Number.isSafeInteger(value) && value > 0; }
function exact(value: object, keys: readonly string[]): void {
  if (value === null || typeof value !== "object" || Array.isArray(value)) invalid();
  const actual = Object.keys(value);
  if (actual.length !== keys.length || actual.some(k => !keys.includes(k))) invalid();
}

/** Matches GroupCanonical.fields in the iPhone core. Binary fields stay raw. */
export function groupFields(fields: readonly (string | Uint8Array)[]): Uint8Array {
  const bytes = fields.map(f => typeof f === "string" ? encoder.encode(f) : f);
  if (bytes.some(b => b.byteLength > 65535)) invalid();
  const result = new Uint8Array(bytes.reduce((n, b) => n + b.byteLength + 2, 0));
  const view = new DataView(result.buffer);
  let offset = 0;
  for (const value of bytes) {
    view.setUint16(offset, value.byteLength, false); offset += 2;
    result.set(value, offset); offset += value.byteLength;
  }
  return result;
}
export function groupDeviceAuthorization(windowId: string, personId: string, device: GroupRosterDevice): Uint8Array {
  return groupFields(["NW3.DEVICE", windowId, personId, device.id,
    base64urlDecode(device.signingPublicKey, 32), base64urlDecode(device.hpkePublicKey, 32)]);
}

/** Performs structural checks before any quadratic/key operations. */
export function groupRosterBytes(roster: GroupRoster): Uint8Array {
  if (roster === null || typeof roster !== "object") invalid();
  exact(roster, ["windowId", "revision", "keyEpoch", "previousHash", "ownerPersonId", "members"]);
  if (!id(roster.windowId) || !id(roster.ownerPersonId) || !safePositive(roster.revision) || !safePositive(roster.keyEpoch)
      || !Array.isArray(roster.members) || roster.members.length < 1 || roster.members.length > 6) invalid();
  const members = roster.members;
  for (const m of members) {
    if (m === null || typeof m !== "object") invalid();
    exact(m, ["participantId", "personId", "identityPublicKey", "role", "devices"]);
    if (!id(m.participantId) || !id(m.personId) || !["owner", "member"].includes(m.role)
        || !Array.isArray(m.devices) || m.devices.length < 1 || m.devices.length > 3) invalid();
    base64urlDecode(m.identityPublicKey, 32);
    for (const d of m.devices) {
      if (d === null || typeof d !== "object") invalid();
      exact(d, ["id", "signingPublicKey", "hpkePublicKey", "personAuthorization"]);
      if (!id(d.id)) invalid();
      base64urlDecode(d.signingPublicKey, 32); base64urlDecode(d.hpkePublicKey, 32);
      base64urlDecode(d.personAuthorization, 64);
    }
  }
  const devices = members.flatMap(m => m.devices);
  if (!unique(members.map(m => m.participantId)) || !unique(members.map(m => m.personId))
      || !unique(members.map(m => m.identityPublicKey)) || !unique(devices.map(d => d.id))
      || !unique(devices.map(d => d.signingPublicKey)) || !unique(devices.map(d => d.hpkePublicKey))
      || members.filter(m => m.role === "owner").length !== 1
      || members.find(m => m.role === "owner")?.personId !== roster.ownerPersonId) invalid();
  const fields: (string | Uint8Array)[] = ["NW3.ROSTER", "3", roster.windowId, String(roster.revision),
    base64urlDecode(roster.previousHash, 32), String(roster.keyEpoch), roster.ownerPersonId, String(members.length)];
  for (const m of sorted(members, m => m.participantId)) {
    fields.push(m.participantId, m.personId, base64urlDecode(m.identityPublicKey, 32), m.role, String(m.devices.length));
    for (const d of sorted(m.devices, d => d.id)) {
      fields.push(d.id, base64urlDecode(d.signingPublicKey, 32), base64urlDecode(d.hpkePublicKey, 32),
        base64urlDecode(d.personAuthorization, 64));
    }
  }
  const bytes = groupFields(fields);
  if (bytes.byteLength > 65535) invalid();
  return bytes;
}

function membershipKeys(roster: GroupRoster): string {
  return JSON.stringify(sorted(roster.members, m => m.participantId).map(m => [m.participantId, m.personId,
    m.identityPublicKey, m.role, sorted(m.devices, d => d.id).map(d => [d.id, d.signingPublicKey, d.hpkePublicKey])]));
}

// No exported constructor: only the verifier creates this certificate.
const verified = Symbol("verified-group-roster");
export interface VerifiedGroupRoster {
  readonly [verified]: true;
  readonly packet: SignedGroupRoster;
  readonly bytes: Uint8Array;
  readonly hash: string;
}

function freezePacket<T>(value: T): T {
  if (value !== null && typeof value === "object") {
    for (const child of Object.values(value)) freezePacket(child);
    Object.freeze(value);
  }
  return value;
}

export async function verifyGroupRoster(packet: SignedGroupRoster, anchor: GroupTrustAnchor,
  previous?: VerifiedGroupRoster): Promise<VerifiedGroupRoster> {
  return verifyRoster(packet,anchor,previous,false);
}

async function verifyRoster(packet: SignedGroupRoster, anchor: GroupTrustAnchor,
  previous: VerifiedGroupRoster|undefined, trustedStoredHead:boolean): Promise<VerifiedGroupRoster> {
  exact(packet, ["roster", "signerDeviceId", "signature"]);
  const r = packet.roster;
  const bytes = groupRosterBytes(r);
  const owner = r.members.find(m => m.role === "owner")!;
  const signer = owner.devices.find(d => d.id === packet.signerDeviceId);
  if (r.windowId !== anchor.windowId || r.ownerPersonId !== anchor.ownerPersonId
      || owner.identityPublicKey !== anchor.ownerIdentityPublicKey || signer === undefined) invalid("invalid_signature");
  for (const m of r.members) {
    for (const d of m.devices) {
      if (!await verifyEd25519(m.identityPublicKey, d.personAuthorization, groupDeviceAuthorization(r.windowId, m.personId, d))) invalid("invalid_signature");
    }
  }
  if (previous !== undefined) {
    const old = previous.packet.roster;
    if (r.windowId !== old.windowId || r.revision <= old.revision || r.revision - old.revision !== 1
        || r.previousHash !== previous.hash || r.keyEpoch < old.keyEpoch || r.keyEpoch - old.keyEpoch > 1) invalid("stale_revision");
    const oldSigner = old.members.find(m => m.role === "owner")?.devices.find(d => d.id === signer.id);
    if (!oldSigner || oldSigner.signingPublicKey !== signer.signingPublicKey || oldSigner.hpkePublicKey !== signer.hpkePublicKey) invalid("invalid_signature");
    if (membershipKeys(old) !== membershipKeys(r) && r.keyEpoch === old.keyEpoch) invalid();
  } else if (!trustedStoredHead && (r.revision !== 1 || r.keyEpoch !== 1 || r.previousHash !== base64urlEncode(new Uint8Array(32)))) {
    invalid("stale_revision");
  }
  if (!await verifyEd25519(signer.signingPublicKey, packet.signature,
      groupFields(["NW3.ROSTER.SIGN", bytes, packet.signerDeviceId]))) invalid("invalid_signature");
  // Isolate the accepted object from later caller mutations.
  const copy = freezePacket(structuredClone(packet));
  return Object.freeze({ [verified]: true as const, packet: copy,
    get bytes() { return bytes.slice(); }, hash: await sha256Base64url(bytes) });
}

/** Only the relay's own atomic write path may create these rows. Client
 * requests cannot supply the stored hash/revision/root used here. Avoid
 * re-verifying the whole historical chain on every relay request. iPhones
 * still verify their pinned chain independently. */
export async function loadStoredGroupRoster(db:D1Database,windowId:string):Promise<VerifiedGroupRoster> {
  const row=await db.prepare(`SELECT p.packet_json,r.roster_hash,w.roster_hash AS current_hash,w.revision,w.key_epoch,
      w.owner_person_id,person.identity_public_key FROM group_windows w
      JOIN group_rosters r ON r.space_id=w.space_id AND r.revision=w.revision
      JOIN group_roster_packets p ON p.space_id=r.space_id AND p.revision=r.revision
      JOIN group_people person ON person.id=w.owner_person_id WHERE w.space_id=? AND w.mode='active'`)
    .bind(windowId).first<{packet_json:string;roster_hash:string;current_hash:string;revision:number;key_epoch:number;owner_person_id:string;identity_public_key:string}>();
  if(!row || row.packet_json.length>65536) throw new ApiError(503,"unavailable","The group state is unavailable.");
  let packet:SignedGroupRoster;
  try { packet=JSON.parse(row.packet_json) as SignedGroupRoster; }
  catch { throw new ApiError(503,"unavailable","The group state is unavailable."); }
  const result=await verifyRoster(packet,{windowId,ownerPersonId:row.owner_person_id,ownerIdentityPublicKey:row.identity_public_key},undefined,true);
  if(result.hash!==row.roster_hash || result.hash!==row.current_hash || packet.roster.revision!==row.revision || packet.roster.keyEpoch!==row.key_epoch)
    throw new ApiError(503,"unavailable","The group state is unavailable.");
  return result;
}

export async function verifyGroupEnvelopes(envelopes: readonly GroupKeyEnvelope[], roster: VerifiedGroupRoster): Promise<void> {
  const r = roster.packet.roster;
  const devices = r.members.flatMap(m => m.devices);
  if (!Array.isArray(envelopes) || envelopes.length !== devices.length
      || envelopes.some(e => e === null || typeof e !== "object")
      || !unique(envelopes.map(e => e.deviceId))) invalid("invalid_envelope");
  for (const e of envelopes) {
    exact(e, ["windowId", "keyEpoch", "rosterHash", "deviceId", "encapsulatedKey", "ciphertext", "signerDeviceId", "signature"]);
    const signer = r.members.find(m => m.role === "owner")?.devices.find(d => d.id === e.signerDeviceId);
    if (e.windowId !== r.windowId || e.keyEpoch !== r.keyEpoch || e.rosterHash !== roster.hash
        || !devices.some(d => d.id === e.deviceId) || !signer) invalid("invalid_envelope");
    const info = groupFields(["NW3.KEY", r.windowId, String(r.keyEpoch), base64urlDecode(roster.hash, 32), e.deviceId]);
    const signature = groupFields(["NW3.KEY.SIGN", info, base64urlDecode(e.encapsulatedKey, 32),
      base64urlDecode(e.ciphertext, 48), e.signerDeviceId]);
    if (!await verifyEd25519(signer.signingPublicKey, e.signature, signature)) invalid("invalid_signature");
  }
}
