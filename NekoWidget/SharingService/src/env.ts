export interface Env {
  DB: D1Database;
  MEDIA?: R2Bucket;
  MODERATION_MEDIA?: R2Bucket;
  CREATE_RATE_LIMITER?: RateLimit;
  INVITE_RATE_LIMITER?: RateLimit;
  MEMBER_RATE_LIMITER?: RateLimit;
  ENVIRONMENT: string;
  /// Exact, server-side operational switch for normal v2 moment traffic.
  /// Reports, blocks and cleanup remain available when this is disabled.
  MOMENT_RUNTIME_ENABLED?: string;
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

export function legacySharingRuntimeEnabled(
  env: Pick<Env, "LEGACY_SHARING_RUNTIME_ENABLED">,
): boolean {
  return env.LEGACY_SHARING_RUNTIME_ENABLED === "YES";
}

export function positiveIntegerSetting(value: string, fallback: number): number {
  const parsed = Number(value);
  return Number.isSafeInteger(parsed) && parsed > 0 ? parsed : fallback;
}
