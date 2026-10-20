import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import type { Env } from "../src/env";

const db = (env as unknown as Env).DB;
const now = 1_792_454_400;
const id = () => crypto.randomUUID();
const sql = (text: string, ...values: (string | number | null | ArrayBuffer)[]) => db.prepare(text).bind(...values);
async function person() {
  const personId = id();
  await sql("INSERT INTO group_people VALUES (?, ?, 'active', ?)", personId, `identity-${personId}`, now).run();
  return personId;
}
async function device(personId: string) {
  const deviceId = id();
  await sql("INSERT INTO group_person_devices VALUES (?, ?, ?, ?, 'synthetic-authorization', 'active', ?, NULL)",
    deviceId, personId, `sign-${deviceId}`, `hpke-${deviceId}`, now).run();
  return deviceId;
}
async function member(windowId: string, personId: string, role = "member") {
  const participantId = id();
  await sql("INSERT INTO group_members VALUES (?, ?, ?, ?, 'active', 1, NULL, 'synthetic-ciphertext')",
    participantId, windowId, personId, role).run();
  return participantId;
}
async function window(ownerId?: string) {
  const owner = ownerId ?? await person();
  const windowId = id();
  await sql("INSERT INTO group_windows(space_id,owner_person_id,mode,created_at,updated_at) VALUES (?,?,'preparing',?,?)",
    windowId, owner, now, now).run();
  const participantId = await member(windowId, owner, "owner");
  const deviceId = await device(owner);
  await sql("INSERT INTO group_window_devices VALUES (?, ?, ?, 'active', 1, NULL)", windowId, deviceId, participantId).run();
  return { windowId, owner, deviceId, participantId };
}
async function statements(w: Awaited<ReturnType<typeof window>>, expected = 0, omitted = false) {
  const revision = expected + 1;
  const hash = `hash-${revision}`;
  const previousHash = expected === 0 ? "zero-hash" : `hash-${expected}`;
  const devices = await sql("SELECT device_id FROM group_window_devices WHERE space_id=? AND state='active'", w.windowId).all<{device_id: string}>();
  const result = [sql("INSERT INTO group_rosters VALUES (?, ?, ?, ?, ?, ?, ?, 'synthetic-signature', ?)",
    w.windowId, revision, previousHash, revision, new Uint8Array([1, 2, 3]).buffer, hash, w.deviceId, now)];
  if (!omitted) {
    for (const d of devices.results) {
      result.push(sql("INSERT INTO group_key_envelopes VALUES (?, ?, ?, ?, ?, 'synthetic-enc', 'synthetic-key', ?, 'synthetic-signature')",
        w.windowId, revision, d.device_id, revision, hash, w.deviceId));
    }
  }
  result.push(sql("INSERT INTO group_epoch_transitions VALUES (?, ?, ?, ?, ?, ?, 'request-hash', ?, ?)",
    id(), w.windowId, w.deviceId, expected, revision, revision, expected === 0 ? "create" : "rotate", now));
  return result;
}

describe("group membership additive D1 boundary (not signature verification)", () => {
  it("accepts six people; seventh insert and pending activation fail", async () => {
    const w = await window();
    for (let i = 0; i < 5; i++) await member(w.windowId, await person());
    const seventh = await person();
    await expect(member(w.windowId, seventh)).rejects.toThrow("group_member_limit");
    const pendingId = id();
    await sql("INSERT INTO group_members VALUES (?, ?, ?, 'member', 'pending', 1, NULL, 'cipher')", pendingId, w.windowId, seventh).run();
    await expect(sql("UPDATE group_members SET state='active' WHERE participant_id=?", pendingId).run()).rejects.toThrow("group_member_limit");
    expect((await sql("SELECT COUNT(*) n FROM group_members WHERE space_id=? AND state='active'", w.windowId).first<{n:number}>())?.n).toBe(6);
  });
  it("counts phones per person, blocks fourth, and does not reactivate revoked identities", async () => {
    const p = await person();
    const first = await device(p);
    await device(p); await device(p);
    await expect(device(p)).rejects.toThrow("group_device_limit");
    await sql("UPDATE group_person_devices SET state='revoked', revoked_at=? WHERE id=?", now, first).run();
    await device(p);
    await expect(sql("UPDATE group_person_devices SET state='active', revoked_at=NULL WHERE id=?", first).run()).rejects.toThrow("group_device_identity_immutable");
  });
  it("rejects a phone bound to someone else's participation", async () => {
    const w = await window();
    const otherDevice = await device(await person());
    await expect(sql("INSERT INTO group_window_devices VALUES (?, ?, ?, 'active', 1, NULL)",
      w.windowId, otherDevice, w.participantId).run()).rejects.toThrow("group_device_wrong_person");
  });
  it("limits total joined and owned windows together to five", async () => {
    const p = await person();
    for (let i = 0; i < 5; i++) {
      const w = await window();
      await member(w.windowId, p);
    }
    const sixth = await window();
    await expect(member(sixth.windowId, p)).rejects.toThrow("group_total_window_limit");
  });
  it("does not consume an invitation on the first application", async () => {
    const w = await window();
    const invitationId = id();
    await sql("INSERT INTO group_invitations VALUES (?, ?, ?, ?, ?, ?, NULL)",
      invitationId, w.windowId, id(), w.deviceId, now, now + 86400).run();
    for (let i = 0; i < 2; i++) {
      const p = await person(); const d = await device(p);
      await sql("INSERT INTO group_join_requests VALUES (?, ?, ?, ?, ?, 'signed', 'pending', ?, NULL)",
        id(), w.windowId, invitationId, p, d, now + 86400).run();
    }
    expect((await sql("SELECT COUNT(*) n FROM group_join_requests WHERE invitation_id=?", invitationId).first<{n:number}>())?.n).toBe(2);
    await expect(sql("INSERT INTO group_invitations VALUES (?, ?, ?, ?, ?, ?, NULL)",
      id(), w.windowId, id(), w.deviceId, now, now + 86401).run()).rejects.toThrow();
  });
  it("commits the roster/envelopes/current epoch together", async () => {
    const w = await window();
    await db.batch(await statements(w));
    expect(await sql("SELECT revision, key_epoch, mode FROM group_windows WHERE space_id=?", w.windowId).first())
      .toMatchObject({revision: 1, key_epoch: 1, mode: "active"});
  });
  it("rolls back a whole batch if even one envelope is missing", async () => {
    const w = await window();
    const mutation = sql("INSERT INTO group_mutations VALUES (?, ?, 'request', 'response', ?)", w.deviceId, id(), now + 172800);
    await expect(db.batch([mutation, ...await statements(w, 0, true)])).rejects.toThrow("group_envelope_set_mismatch");
    expect((await sql("SELECT revision FROM group_windows WHERE space_id=?", w.windowId).first<{revision:number}>())?.revision).toBe(0);
    expect((await sql("SELECT COUNT(*) n FROM group_rosters WHERE space_id=?", w.windowId).first<{n:number}>())?.n).toBe(0);
    expect((await sql("SELECT COUNT(*) n FROM group_mutations WHERE actor_device_id=?", w.deviceId).first<{n:number}>())?.n).toBe(0);
  });
  it("accepts one of two simultaneous transitions and keeps one head", async () => {
    const w = await window();
    const results = await Promise.allSettled([db.batch(await statements(w)), db.batch(await statements(w))]);
    expect(results.filter(r => r.status === "fulfilled")).toHaveLength(1);
    expect(results.filter(r => r.status === "rejected")).toHaveLength(1);
    expect((await sql("SELECT revision FROM group_windows WHERE space_id=?", w.windowId).first<{revision:number}>())?.revision).toBe(1);
  });
  it("rejects a stale CAS even if the new roster rows could be inserted", async () => {
    const w = await window(); await db.batch(await statements(w));
    const wrong = sql("INSERT INTO group_epoch_transitions VALUES (?, ?, ?, 0, 1, 1, 'hash', 'rotate', ?)", id(), w.windowId, w.deviceId, now);
    await expect(wrong.run()).rejects.toThrow("group_stale_revision_or_epoch");
  });
  it("preserves the owner's participation; removal is an explicit different operation", async () => {
    const w = await window();
    await expect(sql("UPDATE group_members SET state='left' WHERE participant_id=?", w.participantId).run()).rejects.toThrow("group_owner_cannot_leave");
  });
});
