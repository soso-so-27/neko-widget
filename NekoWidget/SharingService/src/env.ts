export interface Env {
  DB: D1Database;
  MEDIA?: R2Bucket;
  MODERATION_MEDIA?: R2Bucket;
  CREATE_RATE_LIMITER?: RateLimit;
  INVITE_RATE_LIMITER?: RateLimit;
  MEMBER_RATE_LIMITER?: RateLimit;
  ENVIRONMENT: string;
  /// Exact, server-side operational switch for normal v2 moment traffic.
  /// Report ingestion is controlled separately; blocks and cleanup remain
  /// available when this is disabled.
  MOMENT_RUNTIME_ENABLED?: string;
  /// Exact, independent server-side switch for accepting new moderation
  /// report reservations, ciphertext uploads and commits. Report cleanup,
  /// retention and deletion remain available when this is disabled.
  REPORT_INGESTION_RUNTIME_ENABLED?: string;
  /// Exact, independent server-side operational switch for paw reactions.
  REACTION_RUNTIME_ENABLED?: string;
  /// Exact, independent server-side switch for encrypted private-window names.
  WINDOW_NAME_RUNTIME_ENABLED?: string;
  /// Exact, independent switch for APNs registration and dispatch. Secrets
  /// alone never enable push traffic.
  APNS_RUNTIME_ENABLED?: string;
  /// Secret JSON containing keyId, teamId, bundleId, environment and the
  /// PKCS#8 .p8 private key. Never place this value in Wrangler vars.
  APNS_PROVIDER_CREDENTIAL_JSON?: string;
  /// Secret JSON AES-GCM keyring used to encrypt opaque APNs device tokens.
  APNS_TOKEN_KEYRING_JSON?: string;
  /// Exact, server-side operational switch for the retired v1 daily-sharing
  /// transport. Pairing and revocation remain available when this is disabled.
  LEGACY_SHARING_RUNTIME_ENABLED?: string;
  INVITATION_TTL_SECONDS: string;
  CHALLENGE_TTL_SECONDS: string;
  PENDING_TTL_SECONDS: string;
  IDEMPOTENCY_TTL_SECONDS: string;
  SPACE_INACTIVITY_TTL_SECONDS: string;
}

export function momentRuntimeEnabled(
  env: Pick<Env, "MOMENT_RUNTIME_ENABLED">,
): boolean {
  return env.MOMENT_RUNTIME_ENABLED === "YES";
}

export function reportIngestionRuntimeEnabled(
  env: Pick<Env, "REPORT_INGESTION_RUNTIME_ENABLED">,
): boolean {
  return env.REPORT_INGESTION_RUNTIME_ENABLED === "YES";
}

export function reactionRuntimeEnabled(
  env: Pick<Env, "REACTION_RUNTIME_ENABLED">,
): boolean {
  return env.REACTION_RUNTIME_ENABLED === "YES";
}

export function windowNameRuntimeEnabled(
  env: Pick<Env, "WINDOW_NAME_RUNTIME_ENABLED">,
): boolean {
  return env.WINDOW_NAME_RUNTIME_ENABLED === "YES";
}

export function apnsRuntimeEnabled(
  env: Pick<Env, "APNS_RUNTIME_ENABLED">,
): boolean {
  return env.APNS_RUNTIME_ENABLED === "YES";
}

export function legacySharingRuntimeEnabled(
  env: Pick<Env, "LEGACY_SHARING_RUNTIME_ENABLED">,
): boolean {
  return env.LEGACY_SHARING_RUNTIME_ENABLED === "YES";
}

export function positiveIntegerSetting(value: string, fallback: number): number {
  const parsed = Number(value);
  return Number.isSafeInteger(parsed) && parsed > 0 ? parsed : fallback;
}
