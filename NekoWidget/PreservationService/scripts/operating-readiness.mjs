// Local advisory only. No credentials, network, notifications or deletion.
import { readFile } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';

// Aggregate local evidence only: never include a bearer token or owner identity.
// A closed shape keeps an unrecognized transition from silently being ignored.
function explicitExportAuthorization(bulk, fresh) {
  const count = value => Number.isSafeInteger(value) && value >= 0;
  const shape = (value, fields) => value !== null && typeof value === 'object' && !Array.isArray(value)
    && Object.keys(value).length === fields.length && fields.every(key => Object.hasOwn(value, key));
  const opaque = value => typeof value === 'string' && /^[A-Za-z0-9][A-Za-z0-9_-]{7,63}(?![\s\S])/.test(value);
  const segments = bulk.sessionSegments;
  if (bulk.authorizationRenewed !== true || bulk.silentAuthorizationRenewed !== false
    || bulk.expiredSessionStopsAndCleans !== true || bulk.cancellationStopsAndCleans !== true
    || bulk.reauthenticationFailureStopsAndCleans !== true
    || !count(bulk.inventoryGeneration) || !count(bulk.recordCount) || bulk.recordCount < 1
    || !count(bulk.totalPages) || bulk.totalPages < 1 || bulk.totalPages > bulk.recordCount
    || !Array.isArray(segments) || segments.length < 2 || segments.length > bulk.totalPages + 1) return false;
  const seen = new Set(); let previous;
  for (let index = 0; index < segments.length; index++) {
    const segment = segments[index];
    if (!shape(segment, ['sessionEvidenceId', 'issuedAt', 'expiresAt', 'startedAt', 'completedAt',
      'completedPagesBefore', 'completedPagesAfter', 'inventoryGeneration', 'reauthentication'])
      || !opaque(segment.sessionEvidenceId) || seen.has(segment.sessionEvidenceId)
      || !count(segment.issuedAt) || !count(segment.expiresAt)
      || segment.expiresAt <= segment.issuedAt || segment.expiresAt - segment.issuedAt > 900_000
      || !fresh(segment.startedAt) || !fresh(segment.completedAt)
      || segment.issuedAt > segment.startedAt || segment.startedAt >= segment.completedAt
      || segment.completedAt >= segment.expiresAt || segment.completedAt > bulk.completedAt
      || segment.inventoryGeneration !== bulk.inventoryGeneration
      || !count(segment.completedPagesBefore) || !count(segment.completedPagesAfter)
      || segment.completedPagesAfter > bulk.totalPages
      || segment.completedPagesBefore > segment.completedPagesAfter
      || (index < segments.length - 1 && segment.completedPagesBefore === segment.completedPagesAfter)) return false;
    if (!previous) {
      if (segment.startedAt !== bulk.startedAt || segment.expiresAt !== bulk.originalSessionExpiresAt
        || segment.completedPagesBefore !== 0 || segment.reauthentication !== null) return false;
    } else {
      const reauth = segment.reauthentication;
      if (segment.completedPagesBefore !== previous.completedPagesAfter
        || !shape(reauth, ['previousSessionEvidenceId', 'requestedAt', 'confirmedAt', 'verifiedAt',
          'userInitiated', 'appleIdentityConfirmed', 'sameOwner', 'newToken', 'newEpoch',
          'inventoryUnchanged', 'pageBoundary'])
        || reauth.previousSessionEvidenceId !== previous.sessionEvidenceId
        || !['userInitiated', 'appleIdentityConfirmed', 'sameOwner', 'newToken', 'newEpoch',
          'inventoryUnchanged', 'pageBoundary'].every(key => reauth[key] === true)
        || !fresh(reauth.requestedAt) || !fresh(reauth.confirmedAt) || !fresh(reauth.verifiedAt)
        || reauth.requestedAt < previous.completedAt || reauth.requestedAt > segment.issuedAt
        || segment.issuedAt > reauth.confirmedAt || reauth.confirmedAt > reauth.verifiedAt
        || reauth.verifiedAt > segment.startedAt) return false;
    }
    seen.add(segment.sessionEvidenceId); previous = segment;
  }
  const final = bulk.finalAuthorizationCheck;
  return previous.completedPagesAfter === bulk.totalPages
    && shape(final, ['sessionEvidenceId', 'verifiedAt', 'sameOwner', 'sessionCurrent', 'inventoryUnchanged', 'beforeSharing'])
    && final.sessionEvidenceId === previous.sessionEvidenceId && fresh(final.verifiedAt)
    && final.verifiedAt >= previous.completedAt && final.verifiedAt <= bulk.completedAt
    && bulk.completedAt < previous.expiresAt
    && ['sameOwner', 'sessionCurrent', 'inventoryUnchanged', 'beforeSharing'].every(key => final[key] === true);
}

export function reviewOperatingEvidence(evidence, plan, now = Date.now()) {
  const blockers = [];
  const positive = value => Number.isSafeInteger(value) && value > 0;
  const validPlan = [plan?.archive?.reviewLifetimeHours, plan?.maximumParticipants,
    plan?.archive?.globalActiveBytesLimit, plan?.currency?.warningForecastYen,
    plan?.currency?.pauseNewIntakeForecastYen].every(positive)
    && plan.currency.warningForecastYen < plan.currency.pauseNewIntakeForecastYen;
  if (!validPlan || !Number.isSafeInteger(now) || now < 0) return {
    version: 1, advisoryOnly: true, remoteStateChanged: false, newIntakeReviewReady: false,
    blockers: ['invalid-review-plan-or-clock'], noticePermission: false, permanentDeletionPermission: false };
  const fresh = value => Number.isSafeInteger(value) && value <= now
    && value >= now - plan.archive.reviewLifetimeHours * 3_600_000;
  const count = value => Number.isSafeInteger(value) && value >= 0;
  if (evidence?.version !== 1) blockers.push('unsupported-evidence');
  if (!fresh(evidence?.observedAt)) blockers.push('stale-or-missing-observation');
  const usage = evidence?.usage;
  if (!usage || !['activeOwners', 'retainedOwners', 'primaryBytes', 'recoveryBytesIncludingVersions']
    .every(key => count(usage[key]))) blockers.push('incomplete-usage');
  else {
    if (usage.activeOwners + usage.retainedOwners >= plan.maximumParticipants) blockers.push('no-participant-slot');
    if (usage.primaryBytes >= plan.archive.globalActiveBytesLimit) blockers.push('no-storage-slot');
    if (usage.recoveryBytesIncludingVersions < usage.primaryBytes) blockers.push('incomplete-recovery-accounting');
  }
  const cost = evidence?.cost;
  if (!cost || !fresh(cost.confirmedAt) || !count(cost.forecastMonthlyYen)
    || cost.includesRetainedOwnersAndHistoricalVersions !== true
    || cost.includesOperationsComputeKmsAndNotices !== true) blockers.push('incomplete-cost-review');
  else if (cost.forecastMonthlyYen >= plan.currency.pauseNewIntakeForecastYen) blockers.push('intake-budget-threshold');
  const sandbox = evidence?.sandbox;
  if (!sandbox || !fresh(sandbox.confirmedAt) || !['purchase', 'purchaseSheetCancel', 'cancelBeforeExpiry', 'restore', 'expiry',
    'preservationAccess'].every(key => sandbox[key] === true)) blockers.push('sandbox-device-check-incomplete');
  if (evidence?.capacityMatchesDeployedConfiguration !== true) blockers.push('deployed-capacity-unconfirmed');
  return { version: 1, advisoryOnly: true, remoteStateChanged: false,
    newIntakeReviewReady: blockers.length === 0, blockers,
    costWarning: count(cost?.forecastMonthlyYen) && cost.forecastMonthlyYen >= plan.currency.warningForecastYen,
    retention: { calendarMonths: 12, minimumDaysAfterDeliveredFinalNotice: 30,
      freshPrivateBillingRequired: true, unknownPausesDeadline: true },
    noticePermission: false, permanentDeletionPermission: false };
}

/** Public sales claims need concrete deployed limits, not the pilot's boolean
 * capacity attestation. This is advisory evidence review; it never applies a
 * configuration, approves a promise, renews intake, or changes retained data.
 */
export function reviewPublicPreservationOffer(evidence, offer, plan, now = Date.now()) {
  const operating = reviewOperatingEvidence(evidence, plan, now);
  const blockers = [...operating.blockers];
  const positive = value => Number.isSafeInteger(value) && value > 0;
  const count = value => Number.isSafeInteger(value) && value >= 0;
  const fresh = value => positive(plan?.archive?.reviewLifetimeHours)
    && plan.archive.reviewLifetimeHours <= 24 && Number.isSafeInteger(now) && now >= 0
    && Number.isSafeInteger(value) && value <= now
    && value > now - plan.archive.reviewLifetimeHours * 3_600_000;
  const validOffer = offer?.version === 1
    && [offer.ownerQuotaBytes, offer.maximumRecordsPerOwner, offer.maximumOwners].every(positive)
    && Number.isSafeInteger(offer.ownerQuotaBytes * offer.maximumOwners);
  if (!validOffer) blockers.push('invalid-public-offer');
  if (offer?.approval?.status !== 'approved' || typeof offer?.approval?.evidenceReference !== 'string'
    || !offer.approval.evidenceReference.trim()) blockers.push('public-offer-not-approved');
  // Keep the agreed currency boundaries. A candidate cannot increase them by
  // passing a different local plan; prices and paid cloud usage still need review.
  if (plan?.currency?.warningForecastYen !== 1800 || plan?.currency?.pauseNewIntakeForecastYen !== 2200
    || plan?.currency?.monthlyTargetYen !== 3000) blockers.push('cost-boundaries-changed');
  if (!validOffer || offer.ownerQuotaBytes !== plan?.archive?.ownerQuotaBytes
    || offer.maximumRecordsPerOwner !== plan?.archive?.maximumRecordsPerOwner
    || offer.maximumOwners !== plan?.maximumParticipants) blockers.push('offer-exceeds-reviewed-plan');
  const configuration = evidence?.configuration;
  if (!configuration || !fresh(configuration.confirmedAt)
    || configuration.ownerQuotaBytes !== offer?.ownerQuotaBytes
    || configuration.maximumRecordsPerOwner !== offer?.maximumRecordsPerOwner
    || configuration.maximumOwners !== offer?.maximumOwners
    || configuration.globalActiveBytesLimit !== plan?.archive?.globalActiveBytesLimit
    || configuration.mode !== 'general') blockers.push('public-deployed-limits-unconfirmed');
  if (configuration?.requestLimiterScope !== 'owner'
    || configuration?.requestLimiterConsistency !== 'global-atomic'
    || configuration?.requestLimiterWindow !== 'fixed-utc-minute'
    || !positive(plan?.additionalControlsRequired?.perParticipantRequestsPerMinute)
    || configuration?.perParticipantRequestsPerMinute !== plan.additionalControlsRequired.perParticipantRequestsPerMinute) {
    blockers.push('participant-request-limit-unconfirmed');
  }
  // Quota enforcement must not make the promised full export impossible.
  // A one-record access check cannot prove compatibility at the sold capacity.
  const bulk = evidence?.bulkExport;
  if (!validOffer || !bulk || !fresh(bulk.confirmedAt)
    || bulk.recordCount !== offer.maximumRecordsPerOwner
    || bulk.requestsPerMinute !== configuration?.perParticipantRequestsPerMinute
    || bulk.window !== configuration?.requestLimiterWindow
    || bulk.completed !== true || bulk.archiveConsistent !== true
    || bulk.cancellationStopsRequests !== true || bulk.sessionChangeStopsRequests !== true
    || typeof bulk.appBuild !== 'string' || !bulk.appBuild.trim()
    || typeof bulk.evidenceReference !== 'string' || !bulk.evidenceReference.trim()) {
    blockers.push('full-export-with-request-limit-unconfirmed');
  }
  // Count-only fixtures do not exercise the bytes sold. Use the server's quota
  // accounting (metadata and photo), not compressed ZIP or base64 wire bytes.
  if (!validOffer || !positive(bulk?.sourceQuotaBytes)
    || bulk.sourceQuotaBytes !== offer.ownerQuotaBytes) {
    blockers.push('full-export-byte-volume-unconfirmed');
  }
  // Keep the original path intact. Only a complete, explicit page-boundary
  // authorization chain can qualify a run spanning more than one session.
  const timeline = bulk && fresh(bulk.startedAt) && fresh(bulk.completedAt)
    && bulk.startedAt < bulk.completedAt && bulk.completedAt <= bulk.confirmedAt;
  if (bulk?.authorizationMode === 'explicit-reauthentication') {
    if (!timeline || !explicitExportAuthorization(bulk, fresh)) blockers.push('full-export-reauthentication-unconfirmed');
  } else if (bulk?.authorizationMode === undefined || bulk.authorizationMode === 'single-session') {
    if (!timeline || !Number.isSafeInteger(bulk.originalSessionExpiresAt)
      || bulk.completedAt >= bulk.originalSessionExpiresAt
      || bulk.originalSessionExpiresAt - bulk.startedAt > 15 * 60_000
      || bulk.authorizationRenewed !== false || bulk.expiredSessionStopsAndCleans !== true
      || bulk.sessionSegments !== undefined || bulk.finalAuthorizationCheck !== undefined
      || (bulk.silentAuthorizationRenewed !== undefined && bulk.silentAuthorizationRenewed !== false)) {
      blockers.push('full-export-original-session-unconfirmed');
    }
  } else {
    blockers.push('full-export-authorization-mode-unconfirmed');
  }
  if (!validOffer || !positive(plan?.archive?.globalActiveBytesLimit)
    || plan.archive.globalActiveBytesLimit < offer.ownerQuotaBytes * offer.maximumOwners) {
    blockers.push('sales-capacity-not-reserved');
  }
  const usage = evidence?.usage;
  if (!count(usage?.allocatedQuotaBytes) || !count(usage?.reservedQuotaBytes)
    || !Number.isSafeInteger(usage.allocatedQuotaBytes + usage.reservedQuotaBytes)) {
    blockers.push('quota-reservations-unaccounted');
  } else if (plan?.archive?.globalActiveBytesLimit - usage.allocatedQuotaBytes - usage.reservedQuotaBytes < offer?.ownerQuotaBytes) {
    blockers.push('no-quota-slot');
  }
  const intake = evidence?.intake;
  const expected = {
    maximumOwners: plan?.maximumParticipants,
    dailyNewIntakeAttempts: plan?.archive?.dailyNewIntakeAttempts,
    monthlyNewIntakeAttempts: plan?.archive?.monthlyNewIntakeAttempts,
    monthlyNewIntakeBytes: plan?.archive?.monthlyNewIntakeBytes,
    dailyMutationAttempts: plan?.additionalControlsRequired?.dailyMutationAttemptsIncludingEditsAndRetries,
    monthlyMutationAttempts: plan?.additionalControlsRequired?.monthlyMutationAttemptsIncludingEditsAndRetries,
  };
  if (!intake || intake.enabled !== true || !fresh(intake.reviewedAt)
    || !Number.isSafeInteger(intake.validUntil) || intake.validUntil <= now
    || intake.validUntil > intake.reviewedAt + 86_400_000
    || intake.pauseForecastYen !== 2200 || !count(intake.forecastMonthlyYen)
    || intake.forecastMonthlyYen !== evidence?.cost?.forecastMonthlyYen
    || intake.forecastMonthlyYen >= 2200
    || !Object.entries(expected).every(([key, value]) => positive(value) && intake[key] === value)) {
    blockers.push('general-intake-controls-unconfirmed');
  }
  // Matching a plan is insufficient if it cannot admit the capacity it sells.
  // These are explicitly approved calendar quota allocations, NOT elapsed days
  // or a promise that unused allowance is reserved for one particular owner.
  const sizing = offer?.initialFill;
  let initialFill = null;
  if (!validOffer || !sizing || sizing.basis !== 'calendar-quota-allocations'
    || !positive(sizing.monthlyAllocations) || !positive(sizing.dailyAllocations)
    || !count(sizing.newAttemptReserve) || !count(sizing.editAttemptReserve)) {
    blockers.push('initial-fill-plan-missing');
  } else {
    const records = offer.maximumRecordsPerOwner * offer.maximumOwners;
    const newAttempts = records + sizing.newAttemptReserve;
    const mutations = newAttempts + sizing.editAttemptReserve;
    // storage.ts estimates photo bytes + 512KiB + 8192 before validating a
    // new PUT. Base64 padding can overestimate the photo by two bytes. Failed
    // admissions consume budget; reserve each retry at the maximum 20MiB.
    const bytes = offer.ownerQuotaBytes * offer.maximumOwners + records * 532482
      + sizing.newAttemptReserve * (20 * 1024 * 1024 + 532480);
    const capacity = [
      [intake?.monthlyNewIntakeAttempts, sizing.monthlyAllocations, newAttempts],
      [intake?.monthlyMutationAttempts, sizing.monthlyAllocations, mutations],
      [intake?.monthlyNewIntakeBytes, sizing.monthlyAllocations, bytes],
      [intake?.dailyNewIntakeAttempts, sizing.dailyAllocations, newAttempts],
      [intake?.dailyMutationAttempts, sizing.dailyAllocations, mutations],
    ];
    if (![records, newAttempts, mutations, bytes].every(positive)
      || !capacity.every(([limit, allocations]) => positive(limit) && positive(limit * allocations))) {
      blockers.push('invalid-initial-fill-arithmetic');
    } else {
      initialFill = { newAttempts, mutationAttempts: mutations, conservativeAdmissionBytes: bytes,
        monthlyAllocations: sizing.monthlyAllocations, dailyAllocations: sizing.dailyAllocations,
        elapsedCompletionDeadlineGuaranteed: false };
      if (capacity.some(([limit, allocations, required]) => limit * allocations < required)) {
        blockers.push('initial-fill-exceeds-intake-budget');
      }
    }
  }
  // A free account's expiry is a service stop, not merely a price adjustment.
  // The billing observation must refer to the account actually holding the
  // recovery data. A paid plan alone does not prove future operating funding.
  const aws = evidence?.awsAccount;
  if (!aws || !fresh(aws.confirmedAt) || !/^[0-9]{12}$/u.test(configuration?.recoveryAwsAccountId ?? '')
    || aws.accountId !== configuration.recoveryAwsAccountId || aws.planType !== 'PAID'
    || aws.planStatus !== 'ACTIVE' || aws.planExpirationAt !== null
    || typeof aws.approvalEvidenceReference !== 'string' || !aws.approvalEvidenceReference.trim()) {
    blockers.push('aws-account-continuity-unconfirmed');
  }
  const funding = evidence?.retentionFunding;
  if (!funding || !fresh(funding.reviewedAt) || funding.calendarMonths !== 12
    || !count(funding.minimumDaysAfterDeliveredFinalNotice) || funding.minimumDaysAfterDeliveredFinalNotice < 30
    || funding.includesRetainedOwnersAndHistoricalVersions !== true
    || funding.coversUnknownStatusAndUndeliveredNoticeExtension !== true
    || typeof funding.evidenceReference !== 'string' || !funding.evidenceReference.trim()) {
    blockers.push('retention-funding-unconfirmed');
  }
  return { ...operating, publicOfferReviewReady: blockers.length === 0,
    newIntakeReviewReady: blockers.length === 0, blockers: [...new Set(blockers)],
    initialFill, salesApprovalPermission: false, deployPermission: false };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  if (![3, 5].includes(process.argv.length) || (process.argv.length === 5 && process.argv[3] !== '--public-offer'))
    throw new Error('Usage: node scripts/operating-readiness.mjs <aggregate-evidence.json> [--public-offer <offer.json>]');
  const plan = JSON.parse(await readFile(new URL('../operations/pilot-plan.json', import.meta.url), 'utf8'));
  const evidence = JSON.parse(await readFile(process.argv[2], 'utf8'));
  const offer = process.argv.length === 5 ? JSON.parse(await readFile(process.argv[4], 'utf8')) : null;
  const report = process.argv.length === 5 ? reviewPublicPreservationOffer(evidence, offer, plan)
    : reviewOperatingEvidence(evidence, plan);
  console.log(JSON.stringify(report, null, 2));
  if (!report.newIntakeReviewReady) process.exitCode = 1;
}
