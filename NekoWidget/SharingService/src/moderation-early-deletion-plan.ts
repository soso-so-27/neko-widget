/**
 * Pure policy gate for deleting the separately encrypted moderation copy.
 *
 * This module deliberately has no D1/R2 dependencies. A caller must obtain a
 * transactionally consistent snapshot and must execute the returned phases
 * with compare-and-swap writes. It never authorizes deletion of the shared
 * moment ciphertext in MEDIA.
 */

export type ModerationReportState =
  | "reserved"
  | "uploaded"
  | "committed"
  | "expired"
  | "deleted";

export type ModerationReviewState = "unreviewed" | "in_review" | "decided";

export type ModerationDecisionOutcome =
  | "no_action"
  | "warning"
  | "block"
  | "account_removal"
  | "safety_or_legal_escalation";

export type ModerationHoldDisposition = "clear" | "active" | "unknown";
export type ContentDeleteAuthorization = "missing" | "approved";
export type EarlyDeletionIntentState = "none" | "pending" | "completed";
export type ModerationObjectObservation = "unknown" | "present" | "absent";

export interface ModerationEarlyDeletionSnapshot {
  readonly nowEpochSeconds: number;
  readonly contentExpiresAt: number;
  readonly reportState: ModerationReportState;
  readonly reviewState: ModerationReviewState;
  readonly outcome: ModerationDecisionOutcome | null;
  readonly legalHold: ModerationHoldDisposition;
  readonly appealHold: ModerationHoldDisposition;
  readonly contentDeleteAuthorization: ContentDeleteAuthorization;
  readonly authorizationLedgerRecorded: boolean;
  readonly deletionIntentState: EarlyDeletionIntentState;
  readonly objectObservation: ModerationObjectObservation;
}

export type ModerationEarlyDeletionBlockReason =
  | "invalid_snapshot"
  | "legal_hold_active"
  | "legal_hold_unknown"
  | "appeal_hold_active"
  | "appeal_hold_unknown"
  | "report_not_committed"
  | "review_not_decided"
  | "decision_missing"
  | "safety_or_legal_escalation"
  | "content_delete_not_approved"
  | "orphaned_ledger_event"
  | "inconsistent_intent_state"
  | "pending_intent_without_ledger";

interface ModerationDeletionTarget {
  /** The separately encrypted report copy in MODERATION_MEDIA. */
  readonly target: "moderation_report_ciphertext";
  /** A case decision must never delete the normal shared moment in MEDIA. */
  readonly sharedMomentCiphertext: "preserve";
}

export type ModerationEarlyDeletionPlan =
  | ({
      readonly kind: "blocked";
      readonly reason: ModerationEarlyDeletionBlockReason;
    } & ModerationDeletionTarget)
  | ({
      /** The hard retention deadline owns this object; do not extend it. */
      readonly kind: "retention_cleanup_due";
    } & ModerationDeletionTarget)
  | ({
      /** Atomically append the 0014 authorization event, create the intent,
       * and CAS the report from committed to expired before touching R2. */
      readonly kind: "prepare_intent";
    } & ModerationDeletionTarget)
  | ({
      /** Re-read/HEAD the R2 object before deciding the next retry phase. */
      readonly kind: "inspect_object";
    } & ModerationDeletionTarget)
  | ({
      /** Issue the idempotent R2 delete; keep the D1 intent pending on error. */
      readonly kind: "delete_object";
    } & ModerationDeletionTarget)
  | ({
      /** R2 absence is verified; atomically finalize D1/tombstone evidence. */
      readonly kind: "finalize_metadata";
    } & ModerationDeletionTarget)
  | ({
      readonly kind: "already_deleted";
    } & ModerationDeletionTarget);

const target: ModerationDeletionTarget = {
  target: "moderation_report_ciphertext",
  sharedMomentCiphertext: "preserve",
};

function blocked(reason: ModerationEarlyDeletionBlockReason): ModerationEarlyDeletionPlan {
  return { kind: "blocked", reason, ...target };
}

function isValidEpochSeconds(value: number): boolean {
  return Number.isSafeInteger(value) && value >= 0;
}

/**
 * Selects the next safe phase. Hold state is intentionally three-valued:
 * callers that cannot prove the absence of a hold receive no delete plan.
 */
export function planModerationEarlyDeletion(
  snapshot: Readonly<ModerationEarlyDeletionSnapshot>,
): ModerationEarlyDeletionPlan {
  if (!isValidEpochSeconds(snapshot.nowEpochSeconds)
      || !isValidEpochSeconds(snapshot.contentExpiresAt)) {
    return blocked("invalid_snapshot");
  }

  if (snapshot.reportState === "deleted") {
    return { kind: "already_deleted", ...target };
  }

  if (snapshot.legalHold === "active") return blocked("legal_hold_active");
  if (snapshot.legalHold === "unknown") return blocked("legal_hold_unknown");
  if (snapshot.appealHold === "active") return blocked("appeal_hold_active");
  if (snapshot.appealHold === "unknown") return blocked("appeal_hold_unknown");

  // Early deletion must never extend or replace the existing hard TTL path.
  if (snapshot.nowEpochSeconds >= snapshot.contentExpiresAt) {
    return { kind: "retention_cleanup_due", ...target };
  }

  if (snapshot.reportState === "expired") {
    if (snapshot.deletionIntentState !== "pending") {
      return blocked("inconsistent_intent_state");
    }
    if (!snapshot.authorizationLedgerRecorded) {
      return blocked("pending_intent_without_ledger");
    }
    if (snapshot.objectObservation === "unknown") {
      return { kind: "inspect_object", ...target };
    }
    if (snapshot.objectObservation === "present") {
      return { kind: "delete_object", ...target };
    }
    return { kind: "finalize_metadata", ...target };
  }

  if (snapshot.reportState !== "committed") {
    return blocked("report_not_committed");
  }
  if (snapshot.deletionIntentState !== "none") {
    return blocked("inconsistent_intent_state");
  }
  if (snapshot.authorizationLedgerRecorded) {
    return blocked("orphaned_ledger_event");
  }
  if (snapshot.reviewState !== "decided") {
    return blocked("review_not_decided");
  }
  if (snapshot.outcome === null) {
    return blocked("decision_missing");
  }
  if (snapshot.outcome === "safety_or_legal_escalation") {
    return blocked("safety_or_legal_escalation");
  }
  if (snapshot.contentDeleteAuthorization !== "approved") {
    return blocked("content_delete_not_approved");
  }

  return { kind: "prepare_intent", ...target };
}
