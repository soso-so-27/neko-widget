import { describe, expect, it } from "vitest";
import vector from "../../ci/fixtures/group-roster-v3.json";
import { base64urlDecode, base64urlEncode } from "../src/encoding";
import { groupDeviceAuthorization, groupFields, groupRosterBytes, verifyGroupEnvelopes, verifyGroupRoster,
  type GroupKeyEnvelope, type GroupRoster, type GroupRosterMember, type SignedGroupRoster } from "../src/group-protocol";

async function key() {
  const pair = await crypto.subtle.generateKey({name: "Ed25519"}, true, ["sign", "verify"]) as CryptoKeyPair;
  return { privateKey: pair.privateKey,
    publicKey: base64urlEncode(new Uint8Array(await crypto.subtle.exportKey("raw", pair.publicKey))) };
}
async function sign(privateKey: CryptoKey, message: Uint8Array) {
  return base64urlEncode(new Uint8Array(await crypto.subtle.sign("Ed25519", privateKey, message.slice().buffer)));
}
async function person(personId: string, role: "owner" | "member" = "member", phoneCount = 1, windowId = "room-one") {
  const identity = await key();
  const deviceKeys: Awaited<ReturnType<typeof key>>[] = [];
  const member: GroupRosterMember = {participantId: `${personId}-participant`, personId, identityPublicKey: identity.publicKey, role, devices: []};
  for (let i = 0; i < phoneCount; i++) {
    const device = await key(); deviceKeys.push(device);
    const value = {id: `${personId}-phone-${i}`, signingPublicKey: device.publicKey,
      hpkePublicKey: base64urlEncode(crypto.getRandomValues(new Uint8Array(32))), personAuthorization: ""};
    value.personAuthorization = await sign(identity.privateKey, groupDeviceAuthorization(windowId, personId, value));
    member.devices.push(value);
  }
  return {member, identity, deviceKeys};
}
async function packet(roster: GroupRoster, privateKey: CryptoKey, signerDeviceId: string): Promise<SignedGroupRoster> {
  return {roster, signerDeviceId, signature: await sign(privateKey,
    groupFields(["NW3.ROSTER.SIGN", groupRosterBytes(roster), signerDeviceId]))};
}
async function fixture() {
  const owner = await person("a", "owner"); const bob = await person("b"); const cat = await person("c");
  const roster: GroupRoster = {windowId: "room-one", revision: 1, keyEpoch: 1,
    previousHash: base64urlEncode(new Uint8Array(32)), ownerPersonId: "a", members: [owner.member, bob.member, cat.member]};
  const anchor = {windowId: "room-one", ownerPersonId: "a", ownerIdentityPublicKey: owner.identity.publicKey};
  const signed = await packet(roster, owner.deviceKeys[0]!.privateKey, owner.member.devices[0]!.id);
  return {owner, bob, cat, roster, anchor, signed};
}

describe("group protocol signatures and canonical wire boundary", () => {
  it("accepts the same public interoperability vector as CryptoKit", async () => {
    const verified = await verifyGroupRoster(vector.packet as SignedGroupRoster, vector.anchor);
    expect(verified.hash).toBe(vector.canonicalSHA256);
  });
  it("uses raw binary with big-endian lengths", () => {
    expect([...groupFields(["a", new Uint8Array([0, 255])])]).toEqual([0, 1, 97, 0, 2, 0, 255]);
  });
  it("validates a pinned three-person roster and isolates it from later mutation", async () => {
    const f = await fixture(); const verified = await verifyGroupRoster(f.signed, f.anchor);
    expect(verified.packet.roster.members).toHaveLength(3);
    f.signed.roster.members[0]!.personId = "changed";
    expect(verified.packet.roster.members[0]!.personId).toBe("a");
    const bytes = verified.bytes; bytes.fill(0);
    expect(verified.bytes.some(n => n !== 0)).toBe(true);
    expect(() => { verified.packet.roster.members[0]!.personId = "other"; }).toThrow();
  });
  it("rejects wrong roots, forged owner role, and unknown fields", async () => {
    const f = await fixture();
    await expect(verifyGroupRoster(f.signed, {...f.anchor, ownerIdentityPublicKey: f.bob.identity.publicKey})).rejects.toMatchObject({code:"invalid_signature"});
    const forged = await packet(f.roster, f.bob.deviceKeys[0]!.privateKey, f.bob.member.devices[0]!.id);
    await expect(verifyGroupRoster(forged, f.anchor)).rejects.toMatchObject({code:"invalid_signature"});
    const extra = {...f.signed, notificationLabel: "should-never-be-accepted"};
    await expect(verifyGroupRoster(extra, f.anchor)).rejects.toMatchObject({code:"invalid_roster"});
  });
  it("does not depend on member array order", async () => {
    const f = await fixture();
    const bytes = groupRosterBytes(f.roster);
    expect(groupRosterBytes({...f.roster, members:[...f.roster.members].reverse()})).toEqual(bytes);
    const one = await verifyGroupRoster(f.signed, f.anchor);
    const next = {...f.roster, revision:2, previousHash:one.hash, members:[...f.roster.members].reverse()};
    const signed = await packet(next, f.owner.deviceKeys[0]!.privateKey, f.owner.member.devices[0]!.id);
    expect((await verifyGroupRoster(signed, f.anchor, one)).packet.roster.keyEpoch).toBe(1);
  });
  it("requires key rotation for a membership change and a continuous chain", async () => {
    const f = await fixture(); const one = await verifyGroupRoster(f.signed, f.anchor);
    const next = {...f.roster, revision:2, previousHash:one.hash, members:[f.owner.member, f.cat.member]};
    await expect(verifyGroupRoster(await packet(next, f.owner.deviceKeys[0]!.privateKey, f.owner.member.devices[0]!.id), f.anchor, one)).rejects.toMatchObject({code:"invalid_roster"});
    const updated = {...next, keyEpoch:2};
    const signed = await packet(updated, f.owner.deviceKeys[0]!.privateKey, f.owner.member.devices[0]!.id);
    const two = await verifyGroupRoster(signed, f.anchor, one);
    await expect(verifyGroupRoster(f.signed, f.anchor, two)).rejects.toMatchObject({code:"stale_revision"});
    await expect(verifyGroupRoster(signed, f.anchor)).rejects.toMatchObject({code:"stale_revision"});
  });
  it("allows six people/eighteen phones; rejects duplicates and excess", async () => {
    const people = await Promise.all([person("a", "owner", 3), ...["b", "c", "d", "e", "f"].map(p=>person(p, "member", 3))]);
    const roster: GroupRoster = {windowId:"room-one", revision:1, keyEpoch:1,
      previousHash:base64urlEncode(new Uint8Array(32)), ownerPersonId:"a", members:people.map(p=>p.member)};
    expect(groupRosterBytes(roster).byteLength).toBeLessThan(65536);
    const seventh = await person("g");
    expect(()=>groupRosterBytes({...roster,members:[...roster.members,seventh.member]})).toThrow();
    const four = await person("h","member",4);
    expect(()=>groupRosterBytes({...roster,members:[people[0]!.member,four.member]})).toThrow();
    expect(()=>groupRosterBytes({...roster,members:[people[0]!.member,people[1]!.member,people[1]!.member]})).toThrow();
  });
  it("rejects a person certificate copied from another window", async () => {
    const f = await fixture();
    const other = {...f.roster,windowId:"other-room"};
    const signed = await packet(other,f.owner.deviceKeys[0]!.privateKey,f.owner.member.devices[0]!.id);
    await expect(verifyGroupRoster(signed,{...f.anchor,windowId:"other-room"})).rejects.toMatchObject({code:"invalid_signature"});
  });
  it("requires the exact complete signed envelope set without excluded devices", async () => {
    const f = await fixture(); const roster = await verifyGroupRoster(f.signed,f.anchor);
    const signerDeviceId = f.owner.member.devices[0]!.id;
    const envelopes: GroupKeyEnvelope[] = [];
    for (const device of f.roster.members.flatMap(m=>m.devices)) {
      const encapsulatedKey = base64urlEncode(crypto.getRandomValues(new Uint8Array(32)));
      const ciphertext = base64urlEncode(crypto.getRandomValues(new Uint8Array(48)));
      const info = groupFields(["NW3.KEY",f.roster.windowId,"1",base64urlDecode(roster.hash,32),device.id]);
      const signature = await sign(f.owner.deviceKeys[0]!.privateKey,
        groupFields(["NW3.KEY.SIGN",info,base64urlDecode(encapsulatedKey,32),base64urlDecode(ciphertext,48),signerDeviceId]));
      envelopes.push({windowId:f.roster.windowId,keyEpoch:1,rosterHash:roster.hash,deviceId:device.id,encapsulatedKey,ciphertext,signerDeviceId,signature});
    }
    await expect(verifyGroupEnvelopes(envelopes,roster)).resolves.toBeUndefined();
    await expect(verifyGroupEnvelopes(envelopes.slice(1),roster)).rejects.toMatchObject({code:"invalid_envelope"});
    await expect(verifyGroupEnvelopes([envelopes[0]!,envelopes[0]!,envelopes[2]!],roster)).rejects.toMatchObject({code:"invalid_envelope"});
    const wrong = {...envelopes[1]!,deviceId:"excluded-device"};
    await expect(verifyGroupEnvelopes([envelopes[0]!,wrong,envelopes[2]!],roster)).rejects.toMatchObject({code:"invalid_envelope"});
    const altered = {...envelopes[1]!,ciphertext:base64urlEncode(new Uint8Array(48))};
    await expect(verifyGroupEnvelopes([envelopes[0]!,altered,envelopes[2]!],roster)).rejects.toMatchObject({code:"invalid_signature"});
  });
});
