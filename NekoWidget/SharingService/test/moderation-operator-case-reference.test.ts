import { describe, expect, it } from "vitest";

import {
  MODERATION_OPERATOR_CASE_REFERENCE_DOMAIN,
  MODERATION_OPERATOR_CASE_REFERENCE_FAILURE_CODE,
  MODERATION_OPERATOR_CASE_REFERENCE_PROTOCOL_VERSION,
  ModerationOperatorCaseReferenceError,
  deriveModerationOperatorCaseReference,
} from "../src/moderation-operator-case-reference";

const encoder = new TextEncoder();
const reportId = "AQIDBAUGBwgJCgsMDQ4PEA";
const secret = Uint8Array.from({ length: 32 }, (_value, index) => index + 1);

function canonicalFields(fields: readonly string[]): Uint8Array {
  const encoded = fields.map((field) => encoder.encode(field));
  const output = new Uint8Array(encoded.reduce(
    (total, field) => total + 2 + field.length,
    0,
  ));
  const view = new DataView(output.buffer);
  let offset = 0;
  for (const field of encoded) {
    view.setUint16(offset, field.length, false);
    offset += 2;
    output.set(field, offset);
    offset += field.length;
  }
  return output;
}

function hex(bytes: Uint8Array): string {
  return [...bytes].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

async function independentHmac(
  report: string,
  keyVersion: number,
  keyBytes = secret,
): Promise<string> {
  const copy = new Uint8Array(keyBytes);
  const key = await crypto.subtle.importKey(
    "raw",
    copy.buffer,
    { name: "HMAC", hash: "SHA-256", length: 256 },
    false,
    ["sign"],
  );
  const transcript = canonicalFields([
    "NW.MODERATION-OPERATOR.CASE-REFERENCE",
    "1",
    String(keyVersion),
    report,
  ]);
  const message = new Uint8Array(transcript);
  return hex(new Uint8Array(await crypto.subtle.sign("HMAC", key, message.buffer)));
}

async function fixedFailure(
  fields: unknown,
  ...keys: unknown[]
): Promise<void> {
  try {
    await deriveModerationOperatorCaseReference(
      fields,
      keys.length === 0 ? secret : keys[0],
    );
    throw new Error("expected derivation to fail");
  } catch (error) {
    expect(error).toBeInstanceOf(ModerationOperatorCaseReferenceError);
    expect(error).toMatchObject({
      code: MODERATION_OPERATOR_CASE_REFERENCE_FAILURE_CODE,
      message: MODERATION_OPERATOR_CASE_REFERENCE_FAILURE_CODE,
    });
    expect(JSON.stringify(error)).not.toContain(reportId);
  }
}

describe("version-bound moderation operator case references", () => {
  it("matches an independent WebCrypto HMAC-SHA256 derivation", async () => {
    const result = await deriveModerationOperatorCaseReference({
      reportId,
      caseReferenceHmacKeyVersion: 7,
    }, secret);

    expect(MODERATION_OPERATOR_CASE_REFERENCE_DOMAIN)
      .toBe("NW.MODERATION-OPERATOR.CASE-REFERENCE");
    expect(MODERATION_OPERATOR_CASE_REFERENCE_PROTOCOL_VERSION).toBe(1);
    expect(result).toEqual({
      caseReferenceHmacKeyVersion: 7,
      caseReferenceHmac: await independentHmac(reportId, 7),
    });
    expect(result.caseReferenceHmac).toMatch(/^[0-9a-f]{64}$/u);
    expect(Object.isFrozen(result)).toBe(true);
    expect(JSON.stringify(result)).not.toContain(reportId);
    expect(JSON.stringify(result)).not.toContain([...secret].join(","));
  });

  it("domain-separates different report IDs, key versions, and keys", async () => {
    const fields = { reportId, caseReferenceHmacKeyVersion: 7 };
    const differentReport = "ERITFBUWFxgZGhscHR4fIA";
    const differentSecret = new Uint8Array(32).fill(0xa5);
    const [baseline, changedReport, changedVersion, changedKey] = await Promise.all([
      deriveModerationOperatorCaseReference(fields, secret),
      deriveModerationOperatorCaseReference({ ...fields, reportId: differentReport }, secret),
      deriveModerationOperatorCaseReference({
        ...fields,
        caseReferenceHmacKeyVersion: 8,
      }, secret),
      deriveModerationOperatorCaseReference(fields, differentSecret),
    ]);
    expect(new Set([
      baseline.caseReferenceHmac,
      changedReport.caseReferenceHmac,
      changedVersion.caseReferenceHmac,
      changedKey.caseReferenceHmac,
    ])).toHaveLength(4);
    expect(changedVersion.caseReferenceHmacKeyVersion).toBe(8);
  });

  it("does not mutate the caller's secret bytes", async () => {
    const callerSecret = new Uint8Array(secret);
    const before = new Uint8Array(callerSecret);
    await deriveModerationOperatorCaseReference({
      reportId,
      caseReferenceHmacKeyVersion: 1,
    }, callerSecret);
    expect(callerSecret).toEqual(before);
  });

  it("rejects unknown, missing, inherited, symbol, hidden, and accessor fields", async () => {
    const valid = { reportId, caseReferenceHmacKeyVersion: 1 };
    await fixedFailure({ ...valid, extra: true });
    await fixedFailure({ reportId });
    await fixedFailure(Object.assign(Object.create({ inherited: true }), valid));
    await fixedFailure({ ...valid, [Symbol("hidden")]: true });

    const hidden = { ...valid };
    Object.defineProperty(hidden, "extra", { value: true, enumerable: false });
    await fixedFailure(hidden);

    const accessor: Record<string, unknown> = {
      caseReferenceHmacKeyVersion: 1,
    };
    Object.defineProperty(accessor, "reportId", {
      enumerable: true,
      get: () => reportId,
    });
    await fixedFailure(accessor);
  });

  it("rejects noncanonical, Unicode, wrong-length, and normalized report IDs", async () => {
    const candidates = [
      reportId.slice(0, -1),
      `${reportId}A`,
      `${reportId.slice(0, -1)}=`,
      `${reportId.slice(0, -1)}!`,
      `Ａ${reportId.slice(1)}`,
      `${reportId.slice(0, -1)}B`, // unused base64url tail bits are noncanonical
      reportId.normalize("NFD").replace("A", "A\u0301"),
    ];
    for (const candidate of candidates) {
      await fixedFailure({
        reportId: candidate,
        caseReferenceHmacKeyVersion: 1,
      });
    }
  });

  it("rejects invalid key versions and secret representations", async () => {
    for (const keyVersion of [0, -1, 1.5, Number.NaN, Number.MAX_SAFE_INTEGER,
      0x8000_0000, "1", 1n]) {
      await fixedFailure({ reportId, caseReferenceHmacKeyVersion: keyVersion });
    }
    for (const key of [undefined, null, secret.slice(0, 31), new Uint8Array(33),
      [...secret], secret.buffer, "secret"]) {
      await fixedFailure({ reportId, caseReferenceHmacKeyVersion: 1 }, key);
    }
  });
});
