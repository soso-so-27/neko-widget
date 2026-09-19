import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { route } from "../src/index";
import { base64urlEncode, sha256Base64url } from "../src/encoding";
import { signedRequestTranscript } from "../src/protocol";
import type { Env } from "../src/env";
import { runFamilyRecordCleanup } from "../src/family-records";

const enabled = { ...env, FAMILY_RECORD_RUNTIME_ENABLED: "YES" } as Env;
const random = (length = 16): string => base64urlEncode(crypto.getRandomValues(new Uint8Array(length)));
interface Member { id: string; keys: CryptoKeyPair; }
async function seed() {
  const now = Math.floor(Date.now() / 1000), space = random();
  const members: Member[] = [];
  await enabled.DB.prepare(`INSERT INTO spaces(id,creation_request_id,protocol_version,
    daily_boundary_minute_utc,state,created_at,last_activity_at,metadata_expires_at)
    VALUES (?,?,1,0,'active',?,?,?)`).bind(space, crypto.randomUUID(), now, now, now + 2592000).run();
  for (const role of ["owner", "invitee"]) {
    const keys = await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"]) as CryptoKeyPair;
    const id = random(), signing = base64urlEncode(new Uint8Array(await crypto.subtle.exportKey("raw", keys.publicKey)));
    await enabled.DB.prepare(`INSERT INTO members(id,space_id,role,participant_id,agreement_public_key,
      signing_public_key,state,created_at,activated_at) VALUES (?,?,?,?,?,?,'active',?,?)`)
      .bind(id, space, role, random(), random(32), signing, now, now).run();
    members.push({ id, keys });
  }
  return { space, owner: members[0]!, peer: members[1]! };
}
async function request(member: Member, path = "/v2/family-records", body?: unknown, environment = enabled) {
  const method = body === undefined ? "GET" : "PUT";
  const encoded = body === undefined ? new Uint8Array() : new TextEncoder().encode(JSON.stringify(body));
  const timestamp = Math.floor(Date.now() / 1000), nonce = random();
  const transcript = signedRequestTranscript({ memberId: member.id, timestamp, nonce, method,
    pathname: path, bodySHA256: await sha256Base64url(encoded) });
  const signature = base64urlEncode(new Uint8Array(await crypto.subtle.sign("Ed25519", member.keys.privateKey, new Uint8Array(transcript).buffer)));
  return route(new Request(`https://sharing.invalid${path}`, { method,
    headers: { "content-type": "application/json", "CF-Connecting-IP": "192.0.2.88",
      "Neko-Protocol-Version": "1", "Neko-Member-ID": member.id, "Neko-Timestamp": String(timestamp),
      "Neko-Nonce": nonce, "Neko-Signature": signature },
    body: body === undefined ? null : new TextDecoder().decode(encoded) }), environment);
}
function mutation(entryID: string, kind: "photo" | "words", expectedRevision = 0, ciphertext: string | null = random(100)) {
  return { entryID, kind, expectedRevision, operationID: crypto.randomUUID(), ciphertext };
}
type Catalog = { records: { id: string; authorID: string; state: string; ciphertext: string | null; revision: number }[] };

describe("independent family record catalog", () => {
  it("requires the exact independent gate before authentication", async () => {
    for (const value of [undefined, "NO", "true", "yes"]) {
      const disabled = { ...enabled };
      if (value === undefined) delete disabled.FAMILY_RECORD_RUNTIME_ENABLED;
      else disabled.FAMILY_RECORD_RUNTIME_ENABLED = value;
      await expect(route(new Request("https://sharing.invalid/v2/family-records"), disabled))
        .rejects.toMatchObject({ code: "family_record_runtime_disabled" });
    }
  });
  it("restores both authors from the current catalog and withdraws only the author's selected record", async () => {
    const { owner, peer } = await seed();
    const photo = crypto.randomUUID(), words = crypto.randomUUID();
    const add = mutation(photo, "photo");
    await request(owner, `/v2/family-records/${photo}`, add);
    await request(owner, `/v2/family-records/${photo}`, add); // same operation, fresh auth nonce
    const contribution = mutation(photo, "words");
    await request(peer, `/v2/family-records/${words}`, contribution);
    const catalog = await (await request(peer)).json<Catalog>();
    expect(catalog.records).toHaveLength(2);
    expect(catalog.records.find(r => r.id === words)?.authorID).toBe(peer.id);
    await expect(request(owner, `/v2/family-records/${words}`, mutation(photo, "words", 1, null)))
      .rejects.toMatchObject({ code: "family_record_conflict" });
    await request(owner, `/v2/family-records/${photo}`, mutation(photo, "photo", 1, null));
    const restored = await (await request(peer)).json<Catalog>();
    expect(restored.records.find(r => r.id === photo)?.state).toBe("withdrawn");
    expect(restored.records.find(r => r.id === words)?.ciphertext).toBe(contribution.ciphertext);
    await expect(request(peer, `/v2/family-records/${photo}/photo`)).rejects.toMatchObject({ status: 404 });
    await runFamilyRecordCleanup(enabled);
    const removals = await enabled.DB.prepare("SELECT COUNT(*) AS n FROM family_record_object_deletions").first<{ n: number }>();
    expect(removals?.n).toBe(0);
    // Stale creation snapshots cannot reactivate a withdrawn photo.
    await expect(request(owner, `/v2/family-records/${photo}`, add)).rejects.toMatchObject({ status: 409 });
  });
  it("keeps conflicts and operation reuse fail-closed without duplicating content", async () => {
    const { owner } = await seed(), photo = crypto.randomUUID(), words = crypto.randomUUID();
    await request(owner, `/v2/family-records/${photo}`, mutation(photo, "photo"));
    await request(owner, `/v2/family-records/${words}`, mutation(photo, "words"));
    const edit = mutation(photo, "words", 1);
    await request(owner, `/v2/family-records/${words}`, edit);
    await request(owner, `/v2/family-records/${words}`, edit);
    await expect(request(owner, `/v2/family-records/${words}`, { ...edit, ciphertext: random(100) }))
      .rejects.toMatchObject({ status: 409 });
    await expect(request(owner, `/v2/family-records/${words}`, mutation(photo, "words", 1)))
      .rejects.toMatchObject({ status: 409 });
    expect((await (await request(owner)).json<Catalog>()).records.find(r => r.id === words)?.revision).toBe(2);
  });
  it("denies ended membership, cross-space reads, and an old successful write replay", async () => {
    const { space, owner, peer } = await seed(), outsider = (await seed()).owner;
    const photo = crypto.randomUUID(), add = mutation(photo, "photo");
    await request(owner, `/v2/family-records/${photo}`, add);
    await expect(request(outsider, `/v2/family-records/${photo}/photo`)).rejects.toMatchObject({ status: 404 });
    await enabled.DB.prepare("UPDATE members SET state='revoked' WHERE id=?").bind(owner.id).run();
    await expect(request(owner)).rejects.toMatchObject({ status: 410 });
    await expect(request(owner, `/v2/family-records/${photo}`, add)).rejects.toMatchObject({ status: 410 });
    expect((await (await request(peer)).json<Catalog>()).records).toHaveLength(1);
    await enabled.DB.prepare("UPDATE spaces SET state='revoked' WHERE id=?").bind(space).run();
    await expect(request(peer)).rejects.toMatchObject({ status: 401 });
    expect(await enabled.DB.prepare("SELECT COUNT(*) AS n FROM family_records WHERE space_id=?").bind(space).first())
      .toEqual({ n: 1 });
  });
  it("rechecks participant blocks before read and prior-success replay", async () => {
    const { space, owner, peer } = await seed(), photo = crypto.randomUUID(), add = mutation(photo, "photo");
    await request(owner, `/v2/family-records/${photo}`, add);
    await enabled.DB.prepare(`INSERT INTO moment_blocks
      SELECT ?,a.id,b.id,'active',2,unixepoch() FROM moment_participants a,moment_participants b
      WHERE a.legacy_member_id=? AND b.legacy_member_id=?`).bind(space, owner.id, peer.id).run();
    await expect(request(owner, `/v2/family-records/${photo}`, add))
      .rejects.toMatchObject({ code: "family_record_access_revoked" });
    await expect(request(peer)).rejects.toMatchObject({ code: "family_record_access_revoked" });
    await expect(request(peer, `/v2/family-records/${photo}/photo`))
      .rejects.toMatchObject({ code: "family_record_access_revoked" });
  });
});
