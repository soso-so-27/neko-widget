import { ServiceError } from './contracts';

// Values, not a pattern: provider/user strings can never become log fields.
const stages: Readonly<Record<string,string>> = Object.freeze({
  INVALID_JPEG:'jpeg_validation', PHOTO_TOO_LARGE:'photo_size', REQUEST_TOO_LARGE:'request_size',
  INVALID_PHOTO:'photo_format', INVALID_RECORD:'record_validation', INVALID_RECORD_ID:'record_validation',
  INVALID_REQUEST:'request_validation', INVALID_REVISION:'revision', REVISION_CONFLICT:'revision',
  RECORD_DELETED:'revision', RECORD_NOT_FOUND:'revision',
  SESSION_INVALID:'session', SESSION_EXPIRED:'session', INVALID_DEVICE_PROOF:'signature',
  INVALID_BILLING_PROOF:'signature', REQUEST_IDENTITY_UNCONFIRMED:'request_identity',
  PRESERVATION_DISABLED:'runtime_gate', PRESERVATION_INTAKE_PAUSED:'intake',
  RATE_LIMITED:'rate_limit', OWNER_REQUEST_RATE_LIMITED:'rate_limit',
  PRESERVATION_NOT_CONFIGURED:'configuration', RECOVERY_POLICY_INACTIVE:'recovery_policy',
  OWNER_RECOVERY_PENDING:'recovery_copy', OWNER_RECOVERY_UNAVAILABLE:'recovery_copy',
  OWNER_DELETION_REQUESTED:'owner_deletion', QUOTA_EXCEEDED:'quota',
  PRESERVATION_UNAVAILABLE:'unclassified', CLIENT_UPGRADE_REQUIRED:'client_version',
  ACCESS_UNCONFIRMED:'membership', NEW_SAVE_REQUIRES_MEMBERSHIP:'membership',
  PRESERVATION_CONSENT_REQUIRED:'consent', OWNER_REVOCATION_NOT_CONFIGURED:'configuration',
  OWNER_REQUEST_LIMIT_UNAVAILABLE:'rate_limit', ARCHIVE_CAPACITY_REACHED:'quota',
  ARCHIVE_TOO_LARGE:'quota', PRODUCT_QUOTA_ACCOUNTING_UNAVAILABLE:'quota',
  ARCHIVE_ACCOUNTING_UNAVAILABLE:'quota', ARCHIVE_CHANGED:'revision',
  ARCHIVE_STORAGE_UNAVAILABLE:'storage', ARCHIVE_INTEGRITY_FAILED:'integrity',
  ARCHIVE_PHOTO_UNAVAILABLE:'storage', PHOTO_REPLACEMENT_REQUIRES_NEW_RECORD:'photo_replacement',
  RECOVERY_COPY_UNAVAILABLE:'recovery_copy', RECOVERY_PENDING:'recovery_copy',
  RECOVERY_RECORD_UNAVAILABLE:'recovery_copy', TOOL_METADATA_BATCH_NOT_FOUND:'metadata_batch',
  TOOL_PART_REFERENCED:'metadata_batch', TOOL_SNAPSHOT_ABANDONED:'metadata_batch',
});
export function preservationPutPath(request:Request):boolean {
  if(request.method!=='PUT')return false;
  const path=new URL(request.url).pathname;
  return /^\/v1\/records\/[^/]+$/u.test(path)
    || /^\/v1\/tool-metadata-batches\/[^/]+\/parts\/[^/]+$/u.test(path);
}
export function logPutRefusal(request:Request,error:unknown):void {
  if(!preservationPutPath(request))return;
  const code=error instanceof ServiceError && Object.hasOwn(stages,error.code)?error.code:'PRESERVATION_UNAVAILABLE';
  const status=error instanceof ServiceError && Number.isInteger(error.status) && error.status>=400 && error.status<=599 ? error.status:503;
  // Exactly one console call at the fetch boundary. Never pass the exception,
  // URL, owner, record, headers, request or body to a logger.
  try { console.warn(JSON.stringify({code,stage:stages[code],status})); } catch { /* Logging cannot change the response. */ }
}
