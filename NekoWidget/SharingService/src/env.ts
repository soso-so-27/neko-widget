export interface Env {
  DB: D1Database;
  MEDIA?: R2Bucket;
  CREATE_RATE_LIMITER?: RateLimit;
  INVITE_RATE_LIMITER?: RateLimit;
  MEMBER_RATE_LIMITER?: RateLimit;
  ENVIRONMENT: string;
  INVITATION_TTL_SECONDS: string;
  CHALLENGE_TTL_SECONDS: string;
  PENDING_TTL_SECONDS: string;
  IDEMPOTENCY_TTL_SECONDS: string;
  SPACE_INACTIVITY_TTL_SECONDS: string;
}

export function positiveIntegerSetting(value: string, fallback: number): number {
  const parsed = Number(value);
  return Number.isSafeInteger(parsed) && parsed > 0 ? parsed : fallback;
}
