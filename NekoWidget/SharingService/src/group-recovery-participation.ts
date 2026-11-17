import { base64urlDecode, verifyEd25519 } from './encoding';
import { ApiError } from './errors';
import { groupFields, type VerifiedGroupRoster } from './group-protocol';
import { asObject, binaryField, exactKeys, integerField, stringField } from './validation';

/** Detached owner attestation. The current roster hash prevents an attestation
 * from an earlier admission from being replayed after leave/re-admission.
 * Absence means unknown, never revision one. */
export interface ParticipationBoundary {
  environment: 'production' | 'staging';
  windowId: string;
  personId: string;
  participantId: string;
  admissionRevision: number;
  rosterHash: string;
  signerDeviceId: string;
  signature: string;
}
const verifiedParticipation = Symbol('verified-participation');
export interface VerifiedParticipation extends ParticipationBoundary { readonly [verifiedParticipation]: true }
export function participationBytes(p: Omit<ParticipationBoundary, 'signature'>): Uint8Array {
  const o = asObject(p);
  exactKeys(o, ['environment','windowId','personId','participantId','admissionRevision','rosterHash','signerDeviceId']);
  if (!['production','staging'].includes(p.environment)) throw new ApiError(400,'invalid_participation','Invalid participation proof.');
  integerField(o, 'admissionRevision', 1, Number.MAX_SAFE_INTEGER);
  for (const name of ['windowId','personId','participantId','signerDeviceId']) {
    if (!/^[A-Za-z0-9_-]{1,128}$/u.test(stringField(o,name))) throw new ApiError(400,'invalid_participation','Invalid participation proof.');
  }
  return groupFields(['NW3.RECOVERY.PARTICIPATION.V1', p.environment, p.windowId,
    p.personId, p.participantId, String(p.admissionRevision),
    base64urlDecode(binaryField(o,'rosterHash',32),32), p.signerDeviceId]);
}
/** head MUST have been verified against the locally pinned owner/root. Neither
 * a server joined_revision nor an unverified JSON roster is accepted here. */
export async function verifyParticipation(value: unknown, head: VerifiedGroupRoster,
  environment: 'production'|'staging', personId: string): Promise<VerifiedParticipation | null> {
  if (value === null || value === undefined) return null;
  try {
    const raw=asObject(value);
    exactKeys(raw,['environment','windowId','personId','participantId','admissionRevision','rosterHash','signerDeviceId','signature']);
    const signature=binaryField(raw,'signature',64);
    const {signature: _signature,...unsigned}=raw;
    const p=unsigned as unknown as Omit<ParticipationBoundary,'signature'>;
    const message=participationBytes(p), roster=head.packet.roster;
    const member=roster.members.find(m=>m.personId===personId);
    const signer=roster.members.find(m=>m.role==='owner')?.devices.find(d=>d.id===p.signerDeviceId);
    if (!member || !signer || p.environment!==environment || p.windowId!==roster.windowId || p.personId!==personId
      || p.participantId!==member.participantId || p.rosterHash!==head.hash || p.admissionRevision>roster.revision
      || !await verifyEd25519(signer.signingPublicKey,signature,message)) return null;
    return Object.freeze({...p,signature,[verifiedParticipation]:true as const});
  } catch { return null; }
}

/** Historical roster is independently chain-verified. Being the same person
 * today is insufficient: both the current admission and that epoch must match. */
export function participationAllowsEpoch(proof: VerifiedParticipation, current: VerifiedGroupRoster,
  epoch: VerifiedGroupRoster): boolean {
  const r=epoch.packet.roster;
  return proof.rosterHash===current.hash && proof.windowId===current.packet.roster.windowId
    && r.windowId===proof.windowId && r.revision>=proof.admissionRevision && r.revision<=current.packet.roster.revision
    && r.members.some(m=>m.personId===proof.personId && m.participantId===proof.participantId);
}
