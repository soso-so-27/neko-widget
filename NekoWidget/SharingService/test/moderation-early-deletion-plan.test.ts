import { describe, expect, it } from "vitest";
import {
  planModerationEarlyDeletion,
  type ModerationEarlyDeletionSnapshot,
} from "../src/moderation-early-deletion-plan";

function eligible(
  overrides: Partial<ModerationEarlyDeletionSnapshot> = {},
): ModerationEarlyDeletionSnapshot {
  return {
    nowEpochSeconds: 1_800_000_000,
    contentExpiresAt: 1_800_003_600,
    reportState: "committed",
    reviewState: "decided",
    outcome: "block",
    legalHold: "clear",
    appealHold: "clear",
    contentDeleteAuthorization: "approved",
    authorizationLedgerRecorded: false,
    deletionIntentState: "none",
    objectObservation: "unknown",
    ...overrides,
  };
}

describe("planModerationEarlyDeletion", () => {
  it("prepares only the separate moderation copy and preserves the shared moment", () => {
    expect(planModerationEarlyDeletion(eligible())).toEqual({
      kind: "prepare_intent",
      target: "moderation_report_ciphertext",
      sharedMomentCiphertext: "preserve",
    });
  });

  it.each([
    ["unreviewed", null],
    ["in_review", null],
  ] as const)("blocks review state %s", (reviewState, outcome) => {
    expect(planModerationEarlyDeletion(eligible({ reviewState, outcome }))).toMatchObject({
      kind: "blocked",
      reason: "review_not_decided",
    });
  });

  it("blocks legal escalation even when generic hold flags are clear", () => {
    expect(planModerationEarlyDeletion(eligible({
      outcome: "safety_or_legal_escalation",
    }))).toMatchObject({
      kind: "blocked",
      reason: "safety_or_legal_escalation",
    });
  });

  it.each([
    ["legalHold", "unknown", "legal_hold_unknown"],
    ["legalHold", "active", "legal_hold_active"],
    ["appealHold", "unknown", "appeal_hold_unknown"],
    ["appealHold", "active", "appeal_hold_active"],
  ] as const)("fails closed for %s=%s", (field, value, reason) => {
    expect(planModerationEarlyDeletion(eligible({ [field]: value }))).toMatchObject({
      kind: "blocked",
      reason,
    });
  });

  it("does not let early deletion extend the hard retention deadline", () => {
    expect(planModerationEarlyDeletion(eligible({
      nowEpochSeconds: 1_800_003_600,
    }))).toMatchObject({ kind: "retention_cleanup_due" });
  });

  it("requires distinct content-delete approval", () => {
    expect(planModerationEarlyDeletion(eligible({
      contentDeleteAuthorization: "missing",
    }))).toMatchObject({
      kind: "blocked",
      reason: "content_delete_not_approved",
    });
  });

  it.each([
    ["unknown", "inspect_object"],
    ["present", "delete_object"],
    ["absent", "finalize_metadata"],
  ] as const)("continues a durable pending intent when R2 is %s", (objectObservation, kind) => {
    expect(planModerationEarlyDeletion(eligible({
      reportState: "expired",
      deletionIntentState: "pending",
      authorizationLedgerRecorded: true,
      objectObservation,
    }))).toMatchObject({ kind });
  });

  it("rejects a pending destructive intent without its 0014 ledger authorization", () => {
    expect(planModerationEarlyDeletion(eligible({
      reportState: "expired",
      deletionIntentState: "pending",
      authorizationLedgerRecorded: false,
      objectObservation: "present",
    }))).toMatchObject({
      kind: "blocked",
      reason: "pending_intent_without_ledger",
    });
  });

  it("rejects split-brain ledger and intent state", () => {
    expect(planModerationEarlyDeletion(eligible({
      authorizationLedgerRecorded: true,
    }))).toMatchObject({
      kind: "blocked",
      reason: "orphaned_ledger_event",
    });
  });

  it("treats an already deleted report as idempotently complete", () => {
    expect(planModerationEarlyDeletion(eligible({
      reportState: "deleted",
      deletionIntentState: "completed",
      authorizationLedgerRecorded: true,
      objectObservation: "absent",
    }))).toMatchObject({ kind: "already_deleted" });
  });

  it("rejects malformed timestamps instead of guessing", () => {
    expect(planModerationEarlyDeletion(eligible({ nowEpochSeconds: Number.NaN }))).toMatchObject({
      kind: "blocked",
      reason: "invalid_snapshot",
    });
  });
});
