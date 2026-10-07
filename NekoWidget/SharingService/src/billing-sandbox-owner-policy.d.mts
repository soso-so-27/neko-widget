export interface OwnerAdmissionPolicy {
  readonly version: 1;
  readonly bootstrapClientRequestId: string;
  readonly initialPublicKeySHA256: string;
  readonly startsAtMs: number;
  readonly expiresAtMs: number;
}
export function parseOwnerAdmission(text: unknown, now?: number, allowExpired?: boolean): OwnerAdmissionPolicy;
