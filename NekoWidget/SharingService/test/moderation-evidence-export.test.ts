import { describe, expect, it } from "vitest";
import {
  buildModerationEvidenceChain,
  canonicalModerationEvidenceBytes,
  createSignedModerationEvidenceExport,
  type ModerationEvidenceReplayGuard,
  type ModerationEvidenceVerifier,
  verifySignedModerationEvidenceExport,
  webCryptoEd25519EvidenceSigner,
  webCryptoEd25519EvidenceVerifier,
} from "../src/moderation-evidence-export";

const caseReferenceHmac = "1".repeat(64);
const firstActorHmac = "2".repeat(64);
const secondActorHmac = "3".repeat(64);
const firstArtifact = "a".repeat(64);
const secondArtifact = "b".repeat(64);
const thirdArtifact = "c".repeat(64);
const keyID = "moderation-evidence-test-v1";

const eventIDs = [
  "11111111-1111-4111-8111-111111111111",
  "22222222-2222-4222-8222-222222222222",
  "33333333-3333-4333-8333-333333333333",
] as const;
const actionIDs = [
  "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
  "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
  "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
] as const;

class MemoryReplayGuard implements ModerationEvidenceReplayGuard {
  readonly exports = new Set<string>();
  readonly events = new Set<string>();

  async consume(exportID: string, incomingEventIDs: readonly string[]): Promise<boolean> {
    if (this.exports.has(exportID)
        || incomingEventIDs.some((eventID) => this.events.has(eventID))) {
      return false;
    }
    this.exports.add(exportID);
    for (const eventID of incomingEventIDs) this.events.add(eventID);
    return true;
  }
}

async function keys(): Promise<{
  signer: ReturnType<typeof webCryptoEd25519EvidenceSigner>;
  verifier: ModerationEvidenceVerifier;
}> {
  const pair = await crypto.subtle.generateKey(
    { name: "Ed25519" },
    false,
    ["sign", "verify"],
  ) as CryptoKeyPair;
  return {
    signer: webCryptoEd25519EvidenceSigner(keyID, pair.privateKey),
    verifier: webCryptoEd25519EvidenceVerifier(keyID, pair.publicKey),
  };
}

async function fixture(): Promise<{
  bytes: Uint8Array;
  signer: ReturnType<typeof webCryptoEd25519EvidenceSigner>;
  verifier: ModerationEvidenceVerifier;
}> {
  const pair = await keys();
  const events = await buildModerationEvidenceChain([
    {
      eventID: eventIDs[0],
      actionID: actionIDs[0],
      actionType: "review_start",
      caseReferenceHmac,
      actorSubjectHmacKeyVersion: 1,
      actorSubjectHmac: firstActorHmac,
      occurredAt: 1_800_000_000,
      artifactSHA256: firstArtifact,
    },
    {
      eventID: eventIDs[1],
      actionID: actionIDs[1],
      actionType: "content_delete",
      caseReferenceHmac,
      actorSubjectHmacKeyVersion: 1,
      actorSubjectHmac: firstActorHmac,
      occurredAt: 1_800_000_001,
      artifactSHA256: secondArtifact,
    },
    {
      eventID: eventIDs[2],
      actionID: actionIDs[2],
      actionType: "evidence_export",
      caseReferenceHmac,
      actorSubjectHmacKeyVersion: 2,
      actorSubjectHmac: secondActorHmac,
      occurredAt: 1_800_000_002,
      artifactSHA256: thirdArtifact,
    },
  ]);
  const bytes = await createSignedModerationEvidenceExport({
    exportID: "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
    actionID: actionIDs[2],
    actorSubjectHmacKeyVersion: 2,
    actorSubjectHmac: secondActorHmac,
    generatedAt: 1_800_000_003,
    caseReferenceHmac,
    events,
  }, pair.signer);
  return { bytes, ...pair };
}

function parse(bytes: Uint8Array): Record<string, any> {
  return JSON.parse(new TextDecoder().decode(bytes)) as Record<string, any>;
}

function resolver(verifier: ModerationEvidenceVerifier) {
  return async (requestedKeyID: string): Promise<ModerationEvidenceVerifier | null> => (
    requestedKeyID === verifier.keyID ? verifier : null
  );
}

describe("signed moderation evidence export foundation", () => {
  it("binds the case, action, actor pseudonym, time, artifact and previous digest", async () => {
    const item = await fixture();
    const guard = new MemoryReplayGuard();
    const verified = await verifySignedModerationEvidenceExport(
      item.bytes,
      resolver(item.verifier),
      guard,
    );

    expect(verified.export.eventCount).toBe(3);
    expect(verified.export).toMatchObject({
      actionID: actionIDs[2],
      actorSubjectHmacKeyVersion: 2,
      actorSubjectHmac: secondActorHmac,
    });
    expect(verified.export.events.map(({ event }) => ({
      action: event.actionType,
      actorKeyVersion: event.actorSubjectHmacKeyVersion,
      actor: event.actorSubjectHmac,
      artifact: event.artifactSHA256,
      caseReference: event.caseReferenceHmac,
      occurredAt: event.occurredAt,
      previous: event.previousEventSHA256,
    }))).toEqual([
      expect.objectContaining({
        action: "review_start",
        actorKeyVersion: 1,
        actor: firstActorHmac,
        artifact: firstArtifact,
        caseReference: caseReferenceHmac,
        occurredAt: 1_800_000_000,
        previous: "0".repeat(64),
      }),
      expect.objectContaining({
        action: "content_delete",
        previous: verified.export.events[0]?.eventSHA256,
      }),
      expect.objectContaining({
        action: "evidence_export",
        actorKeyVersion: 2,
        actor: secondActorHmac,
        previous: verified.export.events[1]?.eventSHA256,
      }),
    ]);
    expect(verified.export.chainHeadSHA256).toBe(
      verified.export.events[2]?.eventSHA256,
    );
  });

  it("binds the export itself to the final evidence-export action and actor alias", async () => {
    const item = await fixture();
    for (const mutate of [
      (object: Record<string, any>) => { object.export.actionID = actionIDs[1]; },
      (object: Record<string, any>) => {
        object.export.actorSubjectHmacKeyVersion = 1;
      },
      (object: Record<string, any>) => {
        object.export.actorSubjectHmac = firstActorHmac;
      },
    ]) {
      const object = parse(item.bytes);
      mutate(object);
      await expect(verifySignedModerationEvidenceExport(
        canonicalModerationEvidenceBytes(object),
        resolver(item.verifier),
        new MemoryReplayGuard(),
      )).rejects.toMatchObject({ code: "export_action_mismatch" });
    }
  });

  it("rejects tampering with every security-bound event field", async () => {
    const item = await fixture();
    const mutations: Array<{
      mutate(object: Record<string, any>): void;
      code: string;
    }> = [
      {
        mutate(object) { object.export.events[1].event.actionType = "review_decision"; },
        code: "event_digest_mismatch",
      },
      {
        mutate(object) {
          object.export.events[1].event.actorSubjectHmacKeyVersion = 2;
        },
        code: "event_digest_mismatch",
      },
      {
        mutate(object) { object.export.events[1].event.actorSubjectHmac = "4".repeat(64); },
        code: "event_digest_mismatch",
      },
      {
        mutate(object) { object.export.events[1].event.occurredAt += 1; },
        code: "event_digest_mismatch",
      },
      {
        mutate(object) { object.export.events[1].event.artifactSHA256 = "d".repeat(64); },
        code: "event_digest_mismatch",
      },
      {
        mutate(object) { object.export.events[1].event.previousEventSHA256 = "e".repeat(64); },
        code: "broken_event_chain",
      },
      {
        mutate(object) { object.export.events[1].event.caseReferenceHmac = "f".repeat(64); },
        code: "case_reference_mismatch",
      },
    ];

    for (const mutation of mutations) {
      const object = parse(item.bytes);
      mutation.mutate(object);
      await expect(verifySignedModerationEvidenceExport(
        canonicalModerationEvidenceBytes(object),
        resolver(item.verifier),
        new MemoryReplayGuard(),
      )).rejects.toMatchObject({ code: mutation.code });
    }
  });

  it("rejects a missing event and a reordered event chain", async () => {
    const item = await fixture();
    const missing = parse(item.bytes);
    missing.export.events.splice(1, 1);
    missing.export.eventCount = 2;

    await expect(verifySignedModerationEvidenceExport(
      canonicalModerationEvidenceBytes(missing),
      resolver(item.verifier),
      new MemoryReplayGuard(),
    )).rejects.toMatchObject({ code: "noncontiguous_sequence" });

    const reordered = parse(item.bytes);
    [reordered.export.events[0], reordered.export.events[1]] = [
      reordered.export.events[1],
      reordered.export.events[0],
    ];
    await expect(verifySignedModerationEvidenceExport(
      canonicalModerationEvidenceBytes(reordered),
      resolver(item.verifier),
      new MemoryReplayGuard(),
    )).rejects.toMatchObject({ code: "noncontiguous_sequence" });
  });

  it("rejects whole-export digest and Ed25519 signature tampering", async () => {
    const item = await fixture();
    const digestTamper = parse(item.bytes);
    digestTamper.exportSHA256 = "f".repeat(64);
    await expect(verifySignedModerationEvidenceExport(
      canonicalModerationEvidenceBytes(digestTamper),
      resolver(item.verifier),
      new MemoryReplayGuard(),
    )).rejects.toMatchObject({ code: "export_digest_mismatch" });

    const signatureTamper = parse(item.bytes);
    signatureTamper.signature = `${signatureTamper.signature[0] === "A" ? "B" : "A"}${
      signatureTamper.signature.slice(1)
    }`;
    await expect(verifySignedModerationEvidenceExport(
      canonicalModerationEvidenceBytes(signatureTamper),
      resolver(item.verifier),
      new MemoryReplayGuard(),
    )).rejects.toMatchObject({ code: "signature_verification_failed" });
  });

  it("requires an externally trusted key and atomically rejects replay", async () => {
    const item = await fixture();
    const guard = new MemoryReplayGuard();

    await expect(verifySignedModerationEvidenceExport(
      item.bytes,
      async () => null,
      guard,
    )).rejects.toMatchObject({ code: "untrusted_signing_key" });
    expect(guard.exports.size).toBe(0);

    await verifySignedModerationEvidenceExport(
      item.bytes,
      resolver(item.verifier),
      guard,
    );
    await expect(verifySignedModerationEvidenceExport(
      item.bytes,
      resolver(item.verifier),
      guard,
    )).rejects.toMatchObject({ code: "replayed_export" });
  });

  it("rejects duplicate event/action IDs before an export can be signed", async () => {
    const duplicateEvent = {
      eventID: eventIDs[0],
      actionID: actionIDs[0],
      actionType: "review_start" as const,
      caseReferenceHmac,
      actorSubjectHmacKeyVersion: 1,
      actorSubjectHmac: firstActorHmac,
      occurredAt: 1_800_000_000,
      artifactSHA256: firstArtifact,
    };
    await expect(buildModerationEvidenceChain([
      duplicateEvent,
      { ...duplicateEvent, actionID: actionIDs[1], occurredAt: 1_800_000_001 },
    ])).rejects.toMatchObject({ code: "replayed_event_id" });

    await expect(buildModerationEvidenceChain([
      duplicateEvent,
      { ...duplicateEvent, eventID: eventIDs[1], occurredAt: 1_800_000_001 },
    ])).rejects.toMatchObject({ code: "replayed_action_id" });
  });

  it("accepts only strict canonical JSON with exact fields", async () => {
    const item = await fixture();
    const object = parse(item.bytes);
    const pretty = new TextEncoder().encode(JSON.stringify(object, null, 2));
    await expect(verifySignedModerationEvidenceExport(
      pretty,
      resolver(item.verifier),
      new MemoryReplayGuard(),
    )).rejects.toMatchObject({ code: "noncanonical_export_json" });

    object.unexpected = true;
    await expect(verifySignedModerationEvidenceExport(
      canonicalModerationEvidenceBytes(object),
      resolver(item.verifier),
      new MemoryReplayGuard(),
    )).rejects.toMatchObject({ code: "invalid_fields" });
  });

  it("rejects deeply nested unknown JSON before recursive canonicalization", async () => {
    const nested = `${"[".repeat(5_000)}0${"]".repeat(5_000)}`;
    const bytes = new TextEncoder().encode(`{"unexpected":${nested}}`);
    await expect(verifySignedModerationEvidenceExport(
      bytes,
      async () => null,
      new MemoryReplayGuard(),
    )).rejects.toMatchObject({ code: "invalid_fields" });
  });

  it("rejects an extractable signing key", async () => {
    const pair = await crypto.subtle.generateKey(
      { name: "Ed25519" },
      true,
      ["sign", "verify"],
    ) as CryptoKeyPair;
    expect(() => webCryptoEd25519EvidenceSigner(
      keyID,
      pair.privateKey,
    )).toThrowError(expect.objectContaining({ code: "invalid_ed25519_key" }));
  });
});
