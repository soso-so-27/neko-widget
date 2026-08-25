import { ApiError, errorResponse, jsonResponse } from "./errors";
import {
  legacySharingRuntimeEnabled,
  momentRuntimeEnabled,
  reactionRuntimeEnabled,
  windowNameRuntimeEnabled,
  type Env,
} from "./env";
import {
  approveEnrollment,
  cancelEnrollment,
  completeEnrollment,
  createChallenge,
  createSpace,
  getPending,
  getStatus,
  redeemInvitation,
  revokeSpace,
} from "./handlers";
import {
  approveDeviceRecovery,
  claimDeviceRecovery,
  completeDeviceRecovery,
  createDeviceRecovery,
  getDeviceRecoveryDescriptor,
  getDeviceRecoveryStatus,
  getSponsorDeviceRecoveryStatus,
  getPendingDeviceRecoveries,
} from "./device-recovery";
import { rejectQuery } from "./http";
import {
  acknowledgeMoment,
  blockParticipant,
  commitMoment,
  commitMomentReport,
  downloadMomentCiphertext,
  getMomentChanges,
  runMomentCleanup,
  reserveMoment,
  reserveMomentReport,
  uploadMomentCiphertext,
  uploadMomentReportCiphertext,
} from "./moments";
import { getReactionChanges, recordPawReaction } from "./reactions";
import { MOMENT_CLEANUP_CRON, runLegacyScheduledCleanup } from "./scheduled";
import {
  commitGeneration,
  downloadManifest,
  downloadMedia,
  getCurrent,
  getGeneration,
  getSources,
  prepareGeneration,
  registerDescriptors,
  reserveGeneration,
  uploadManifest,
  uploadMedia,
} from "./sharing";
import { getWindowName, putWindowName } from "./window-name";

export async function route(request: Request, env: Env): Promise<Response> {
  const url = new URL(request.url);
  rejectQuery(url);
  const { pathname } = url;

  if (request.method === "GET" && pathname === "/health") {
    return jsonResponse({ status: "ok", protocolVersion: 1 });
  }
  if (pathname === "/v1/sharing" || pathname.startsWith("/v1/sharing/")) {
    if (!legacySharingRuntimeEnabled(env)) {
      throw new ApiError(
        503,
        "legacy_sharing_runtime_disabled",
        "Legacy daily sharing is unavailable.",
      );
    }
  }
  if (request.method === "POST" && pathname === "/v1/spaces") {
    return createSpace(request, env);
  }

  const challengeMatch = pathname.match(/^\/v1\/invitations\/([^/]+)\/challenges$/u);
  if (request.method === "POST" && challengeMatch?.[1] !== undefined) {
    return createChallenge(request, env, challengeMatch[1]);
  }
  const enrollmentMatch = pathname.match(/^\/v1\/invitations\/([^/]+)\/enrollments$/u);
  if (request.method === "POST" && enrollmentMatch?.[1] !== undefined) {
    return redeemInvitation(request, env, enrollmentMatch[1]);
  }
  if (request.method === "GET" && pathname === "/v1/pairing/pending") {
    return getPending(request, env);
  }
  if (request.method === "GET" && pathname === "/v1/pairing/status") {
    return getStatus(request, env);
  }
  const approveMatch = pathname.match(/^\/v1\/pairing\/enrollments\/([^/]+)\/approve$/u);
  if (request.method === "POST" && approveMatch?.[1] !== undefined) {
    return approveEnrollment(request, env, approveMatch[1]);
  }
  const completeMatch = pathname.match(/^\/v1\/pairing\/enrollments\/([^/]+)\/complete$/u);
  if (request.method === "POST" && completeMatch?.[1] !== undefined) {
    return completeEnrollment(request, env, completeMatch[1]);
  }
  const cancelMatch = pathname.match(/^\/v1\/pairing\/enrollments\/([^/]+)\/cancel$/u);
  if (request.method === "POST" && cancelMatch?.[1] !== undefined) {
    return cancelEnrollment(request, env, cancelMatch[1]);
  }
  if (request.method === "POST" && pathname === "/v1/pairing/revoke") {
    return revokeSpace(request, env);
  }
  if (request.method === "POST" && pathname === "/v2/device-recoveries") {
    return createDeviceRecovery(request, env);
  }
  if (request.method === "GET" && pathname === "/v2/device-recoveries/pending") {
    return getPendingDeviceRecoveries(request, env);
  }
  const recoveryDescriptorMatch = pathname.match(
    /^\/v2\/device-recoveries\/([^/]+)\/descriptor$/u,
  );
  if (request.method === "GET" && recoveryDescriptorMatch?.[1] !== undefined) {
    return getDeviceRecoveryDescriptor(request, env, recoveryDescriptorMatch[1]);
  }
  const recoveryClaimMatch = pathname.match(
    /^\/v2\/device-recoveries\/([^/]+)\/claim$/u,
  );
  if (request.method === "POST" && recoveryClaimMatch?.[1] !== undefined) {
    return claimDeviceRecovery(request, env, recoveryClaimMatch[1]);
  }
  const recoveryApproveMatch = pathname.match(
    /^\/v2\/device-recoveries\/([^/]+)\/approve$/u,
  );
  if (request.method === "POST" && recoveryApproveMatch?.[1] !== undefined) {
    return approveDeviceRecovery(request, env, recoveryApproveMatch[1]);
  }
  const recoveryStatusMatch = pathname.match(
    /^\/v2\/device-recoveries\/([^/]+)\/status$/u,
  );
  if (request.method === "GET" && recoveryStatusMatch?.[1] !== undefined) {
    return getDeviceRecoveryStatus(request, env, recoveryStatusMatch[1]);
  }
  const recoverySponsorStatusMatch = pathname.match(
    /^\/v2\/device-recoveries\/([^/]+)\/sponsor-status$/u,
  );
  if (request.method === "GET" && recoverySponsorStatusMatch?.[1] !== undefined) {
    return getSponsorDeviceRecoveryStatus(request, env, recoverySponsorStatusMatch[1]);
  }
  const recoveryCompleteMatch = pathname.match(
    /^\/v2\/device-recoveries\/([^/]+)\/complete$/u,
  );
  if (request.method === "POST" && recoveryCompleteMatch?.[1] !== undefined) {
    return completeDeviceRecovery(request, env, recoveryCompleteMatch[1]);
  }
  const pawReactionMatch = pathname.match(/^\/v2\/moments\/([^/]+)\/reactions$/u);
  if (
    (pawReactionMatch?.[1] !== undefined
      || pathname === "/v2/reactions/changes"
      || pathname.startsWith("/v2/reactions/changes/"))
    && !reactionRuntimeEnabled(env)
  ) {
    throw new ApiError(
      503,
      "reaction_runtime_disabled",
      "Photo reactions are temporarily unavailable.",
    );
  }
  if (
    (pathname === "/v2/moments" || pathname.startsWith("/v2/moments/"))
    && pawReactionMatch?.[1] === undefined
  ) {
    if (!momentRuntimeEnabled(env)) {
      throw new ApiError(
        503,
        "moment_runtime_disabled",
        "Moment sharing is temporarily unavailable.",
      );
    }
  }
  if (request.method === "POST" && pathname === "/v2/moments/reservations") {
    return reserveMoment(request, env);
  }
  if (pathname === "/v2/window-name" && !windowNameRuntimeEnabled(env)) {
    throw new ApiError(
      503,
      "window_name_runtime_disabled",
      "Private window name sync is temporarily unavailable.",
    );
  }
  if (request.method === "GET" && pathname === "/v2/window-name") {
    return getWindowName(request, env);
  }
  if (request.method === "PUT" && pathname === "/v2/window-name") {
    return putWindowName(request, env);
  }
  if (request.method === "GET" && pathname === "/v2/moments/changes") {
    return getMomentChanges(request, env);
  }
  if (request.method === "GET" && pathname === "/v2/reactions/changes") {
    return getReactionChanges(request, env);
  }
  const reactionChangesMatch = pathname.match(/^\/v2\/reactions\/changes\/([^/]+)$/u);
  if (request.method === "GET" && reactionChangesMatch?.[1] !== undefined) {
    return getReactionChanges(request, env, reactionChangesMatch[1]);
  }
  const momentChangesMatch = pathname.match(/^\/v2\/moments\/changes\/([^/]+)$/u);
  if (request.method === "GET" && momentChangesMatch?.[1] !== undefined) {
    return getMomentChanges(request, env, momentChangesMatch[1]);
  }
  const momentCiphertextMatch = pathname.match(/^\/v2\/moments\/([^/]+)\/ciphertext$/u);
  if (request.method === "PUT" && momentCiphertextMatch?.[1] !== undefined) {
    return uploadMomentCiphertext(request, env, momentCiphertextMatch[1]);
  }
  if (request.method === "GET" && momentCiphertextMatch?.[1] !== undefined) {
    return downloadMomentCiphertext(request, env, momentCiphertextMatch[1]);
  }
  const momentCommitMatch = pathname.match(/^\/v2\/moments\/([^/]+)\/commit$/u);
  if (request.method === "POST" && momentCommitMatch?.[1] !== undefined) {
    return commitMoment(request, env, momentCommitMatch[1]);
  }
  const momentAckMatch = pathname.match(/^\/v2\/moments\/([^/]+)\/ack$/u);
  if (request.method === "POST" && momentAckMatch?.[1] !== undefined) {
    return acknowledgeMoment(request, env, momentAckMatch[1]);
  }
  if (request.method === "POST" && pawReactionMatch?.[1] !== undefined) {
    return recordPawReaction(request, env, pawReactionMatch[1]);
  }
  const participantBlockMatch = pathname.match(/^\/v2\/participants\/([^/]+)\/block$/u);
  if (request.method === "POST" && participantBlockMatch?.[1] !== undefined) {
    return blockParticipant(request, env, participantBlockMatch[1]);
  }
  if (request.method === "POST" && pathname === "/v2/reports/reservations") {
    return reserveMomentReport(request, env);
  }
  const reportCiphertextMatch = pathname.match(/^\/v2\/reports\/([^/]+)\/ciphertext$/u);
  if (request.method === "PUT" && reportCiphertextMatch?.[1] !== undefined) {
    return uploadMomentReportCiphertext(request, env, reportCiphertextMatch[1]);
  }
  const reportCommitMatch = pathname.match(/^\/v2\/reports\/([^/]+)\/commit$/u);
  if (request.method === "POST" && reportCommitMatch?.[1] !== undefined) {
    return commitMomentReport(request, env, reportCommitMatch[1]);
  }
  if (request.method === "POST" && pathname === "/v1/sharing/generations/reserve") {
    return reserveGeneration(request, env);
  }
  const descriptorMatch = pathname.match(/^\/v1\/sharing\/generations\/([^/]+)\/descriptors$/u);
  if (request.method === "POST" && descriptorMatch?.[1] !== undefined) {
    return registerDescriptors(request, env, descriptorMatch[1]);
  }
  const mediaMatch = pathname.match(/^\/v1\/sharing\/generations\/([^/]+)\/media\/([^/]+)$/u);
  if (request.method === "PUT" && mediaMatch?.[1] !== undefined && mediaMatch[2] !== undefined) {
    return uploadMedia(request, env, mediaMatch[1], mediaMatch[2]);
  }
  const prepareMatch = pathname.match(/^\/v1\/sharing\/generations\/([^/]+)\/prepare$/u);
  if (request.method === "POST" && prepareMatch?.[1] !== undefined) {
    return prepareGeneration(request, env, prepareMatch[1]);
  }
  const manifestUploadMatch = pathname.match(
    /^\/v1\/sharing\/generations\/([^/]+)\/prepares\/([^/]+)\/manifest$/u,
  );
  if (
    request.method === "PUT" &&
    manifestUploadMatch?.[1] !== undefined &&
    manifestUploadMatch[2] !== undefined
  ) {
    return uploadManifest(request, env, manifestUploadMatch[1], manifestUploadMatch[2]);
  }
  const commitMatch = pathname.match(/^\/v1\/sharing\/generations\/([^/]+)\/commit$/u);
  if (request.method === "POST" && commitMatch?.[1] !== undefined) {
    return commitGeneration(request, env, commitMatch[1]);
  }
  if (request.method === "GET" && pathname === "/v1/sharing/sources") {
    return getSources(request, env);
  }
  const currentMatch = pathname.match(/^\/v1\/sharing\/sources\/([^/]+)\/current$/u);
  if (request.method === "GET" && currentMatch?.[1] !== undefined) {
    return getCurrent(request, env, currentMatch[1]);
  }
  const manifestDownloadMatch = pathname.match(/^\/v1\/sharing\/generations\/([^/]+)\/manifest$/u);
  if (request.method === "GET" && manifestDownloadMatch?.[1] !== undefined) {
    return downloadManifest(request, env, manifestDownloadMatch[1]);
  }
  if (request.method === "GET" && mediaMatch?.[1] !== undefined && mediaMatch[2] !== undefined) {
    return downloadMedia(request, env, mediaMatch[1], mediaMatch[2]);
  }
  const generationMatch = pathname.match(/^\/v1\/sharing\/generations\/([^/]+)$/u);
  if (request.method === "GET" && generationMatch?.[1] !== undefined) {
    return getGeneration(request, env, generationMatch[1]);
  }
  throw new ApiError(404, "not_found", "The endpoint was not found.");
}

export default {
  async fetch(request, env): Promise<Response> {
    try {
      return await route(request, env);
    } catch (error) {
      return errorResponse(error);
    }
  },
  async scheduled(controller, env, ctx): Promise<void> {
    ctx.waitUntil(
      controller.cron === MOMENT_CLEANUP_CRON
        ? runMomentCleanup(env)
        : runLegacyScheduledCleanup(env),
    );
  },
} satisfies ExportedHandler<Env>;
