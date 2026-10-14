import { ServiceError, sha256, type ArchiveDocument, type ToolBackupPart } from './contracts';
import { validateDocument, decodePhoto, toolIndexRecordIDs } from './documents';
import type { PilotStorageAccess } from './pilot-control';

const paused = () => new ServiceError('PILOT_WRITES_PAUSED', 503);
const day = 86_400_000;
export const TRIAL_DOCUMENT_ALLOWANCE = 2048;
export const TRIAL_INDEX_ALLOWANCE = 256 * 1024;
interface Grant {
  owner_id: string; owner_epoch: number; enabled: number; starts_at: number; ends_at: number;
  reviewed_at: number; valid_until: number; cost_evidence_sha256: string; review_revision: number;
  snapshot_id: string | null; byte_limit: number; attempt_limit: number; record_limit: number;
  attempts: number; admitted_bytes: number; completed_at: number | null; slot_generation: number;
}
interface Piece {
  record_id: string; snapshot_id: string; kind: string; path: string; part: number; part_count: number;
  payload_sha256: string; input_fingerprint: string; content_bytes: number; committed: number;
}
export interface ToolTrialAdmission {
  grant: Grant; recordId: string; document: ArchiveDocument; photo: Uint8Array | null;
  photoSHA256: string | null; fingerprint: string;
  indexSlotGeneration: number | null;
}
const eligible = `enabled=1 AND starts_at<=? AND ends_at>? AND reviewed_at<=? AND reviewed_at>?
  AND valid_until>? AND EXISTS(SELECT 1 FROM pa_owners o WHERE o.owner_id=pa_tool_owner_trials.owner_id
    AND o.epoch=pa_tool_owner_trials.owner_epoch AND o.disabled=0 AND o.purge_fence_id IS NULL)
  AND NOT EXISTS(SELECT 1 FROM pa_owner_deletion_requests d WHERE d.owner_id=pa_tool_owner_trials.owner_id)
  AND NOT EXISTS(SELECT 1 FROM pa_membership_links l WHERE l.owner_id=pa_tool_owner_trials.owner_id)`;
const length = (value: string) => value.length / 4 * 3 - (value.endsWith('==') ? 2 : value.endsWith('=') ? 1 : 0);
const manifests=new Set(['CareHandoff/plan.json','EvacuationPreparation/plan.json','VeterinaryVisits/state.json',
  'ShowcasePhotos/selected.json','LostCatDrafts/drafts.json','CatPreparedness/records.json']);
const partKeys = ['snapshotId','kind','path','part','count','sha256','payload'] as const;
function orderedPart(part: ToolBackupPart, keys: readonly (keyof ToolBackupPart)[]): ToolBackupPart {
  return Object.fromEntries(keys.map(key=>[key,part[key]])) as unknown as ToolBackupPart;
}
function* keyOrders(keys: readonly (keyof ToolBackupPart)[]): Generator<(keyof ToolBackupPart)[]> {
  if (!keys.length) { yield []; return; }
  for (let n=0;n<keys.length;n++) {
    for (const tail of keyOrders([...keys.slice(0,n),...keys.slice(n+1)])) yield [keys[n]!,...tail];
  }
}
/** Original slots fingerprinted JSON member order, which JSONEncoder need not
 * preserve on retry. Match the original digest, never replace immutable debt.
 * Only photos have an empty payload and a <=2048-byte document envelope; do not
 * multiply large JSON/index payloads by the 7! legacy orders. */
async function legacyPhotoFingerprint(old: Piece, document: ArchiveDocument, photoSHA256: string | null,
  contentBytes: number): Promise<string | null> {
  const part=document.toolBackup!;
  if (part.kind!=='photo' || part.payload!=='' || old.snapshot_id!==part.snapshotId
    || old.kind!==part.kind || old.path!==part.path || old.part!==part.part || old.part_count!==part.count
    || old.payload_sha256!==part.sha256 || old.content_bytes!==contentBytes) return null;
  for (const keys of keyOrders(partKeys)) {
    const candidate=await sha256(JSON.stringify({document:{...document,toolBackup:orderedPart(part,keys)},photoSHA256}));
    if (candidate===old.input_fingerprint) return candidate;
  }
  return null;
}

/** Empty until a separately reviewed operator grant targets an existing owner.
 * All counters are lifetime debits. No signing, photo or provider call issues a grant. */
export class ToolOwnerTrial {
  constructor(private readonly db: D1Database, private readonly now: () => number) {}
  private times(): number[] {
    const now = this.now();
    if (!Number.isSafeInteger(now) || now < 0 || now >= 253_402_300_800_000) throw paused();
    return [now, now, now, now - day, now];
  }
  async hasAnyGrant(): Promise<boolean> {
    return !!await this.db.prepare('SELECT 1 FROM pa_tool_owner_trials LIMIT 1').first();
  }
  async grant(owner: string): Promise<Grant | null> {
    return this.db.prepare('SELECT * FROM pa_tool_owner_trials WHERE owner_id=?').bind(owner).first<Grant>();
  }
  async allowed(owner: string): Promise<{ expiresAt: number } | null> {
    const value = await this.db.prepare(`SELECT ends_at,valid_until FROM pa_tool_owner_trials
      WHERE owner_id=? AND ${eligible} AND attempts<attempt_limit
      AND admitted_bytes+?<=byte_limit`).bind(owner, ...this.times(), TRIAL_DOCUMENT_ALLOWANCE)
      .first<{ ends_at: number; valid_until: number }>();
    return value ? { expiresAt: Math.min(value.ends_at, value.valid_until) } : null;
  }
  /** IP-denied authenticated PUTs consume an attempt and a document reservation
   * without reading a rejected body or binding a snapshot. */
  async deniedAttempt(owner: string): Promise<void> {
    const grant = await this.debitAttempt(owner);
    if (!grant) return;
    await this.debitBytes(grant, TRIAL_DOCUMENT_ALLOWANCE);
  }
  private async debitAttempt(owner: string): Promise<Grant | null> {
    if (!await this.grant(owner)) return null;
    const value = await this.db.prepare(`UPDATE pa_tool_owner_trials SET attempts=attempts+1
      WHERE owner_id=? AND ${eligible} AND attempts<attempt_limit RETURNING *`)
      .bind(owner, ...this.times()).first<Grant>();
    if (!value) throw paused();
    return value;
  }
  private async debitBytes(grant: Grant, amount: number): Promise<Grant> {
    if (!Number.isSafeInteger(amount) || amount<1 || amount>20*1024*1024) throw paused();
    const value = await this.db.prepare(`UPDATE pa_tool_owner_trials SET admitted_bytes=admitted_bytes+?
      WHERE owner_id=? AND review_revision=? AND ${eligible} AND admitted_bytes<=byte_limit-? RETURNING *`)
      .bind(amount, grant.owner_id, grant.review_revision, ...this.times(), amount).first<Grant>();
    if (!value) throw paused();
    return value;
  }
  async admit(owner: string, id: string, input: unknown): Promise<ToolTrialAdmission | null> {
    let grant = await this.debitAttempt(owner);
    if (!grant) return null;
    // Every attempted body burns at least one document allowance, including malformed input.
    grant = await this.debitBytes(grant, TRIAL_DOCUMENT_ALLOWANCE);
    if (!input || typeof input!=='object' || Array.isArray(input)) throw paused();
    const request=input as Record<string, unknown>;
    if (Object.keys(request).some(k=>!['document','photoBase64','expectedRevision','consentVersion'].includes(k))
      || request.expectedRevision!==null || request.consentVersion!=='managed-preservation-v1') throw paused();
    const document=validateDocument(request.document), part=document.toolBackup;
    if (document.formatVersion!==3 || !part) throw paused();
    if (part.kind==='json' && !manifests.has(part.path)) throw paused();
    if (part.kind==='photo' && !/^[A-Za-z]+\/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.jpg$/i.test(part.path)) throw paused();
    const { payload: _payload, ...tag }=part;
    if (new TextEncoder().encode(JSON.stringify({...document,toolBackup:tag})).length>TRIAL_DOCUMENT_ALLOWANCE) throw paused();
    const encoded=request.photoBase64;
    if (part.kind==='photo' && (typeof encoded!=='string' || encoded.length%4!==0
      || !/^[A-Za-z0-9+/]+={0,2}$/.test(encoded))) throw paused();
    if (part.kind!=='photo' && encoded!==null) throw paused();
    const contentBytes=part.kind==='photo' ? length(encoded as string) : length(part.payload);
    grant=await this.debitBytes(grant,contentBytes);
    // Hashes/decoding are local and bounded; all KMS/S3/JPEG work stays after admission.
    const photo=decodePhoto(encoded), photoSHA256=photo===null ? null : await sha256(photo);
    if ((photo===null)!==(document.photoFile===null)) throw paused();
    const payloadSHA=photoSHA256 ?? await sha256(Uint8Array.from(atob(part.payload),c=>c.charCodeAt(0)));
    if (payloadSHA!==part.sha256 || (part.kind==='index' ? id!==part.snapshotId : id===part.snapshotId)) throw paused();
    // Stable for all newly admitted pieces, independent of JSON object order.
    let fingerprint=await sha256(JSON.stringify({document:{...document,toolBackup:orderedPart(part,partKeys)},photoSHA256}));
    const old=await this.db.prepare('SELECT * FROM pa_tool_trial_records WHERE owner_id=? AND record_id=?')
      .bind(owner,id).first<Piece>();
    if (old && old.input_fingerprint!==fingerprint) {
      const original=await sha256(JSON.stringify({document,photoSHA256}));
      const compatible=old.input_fingerprint===original ? original
        : await legacyPhotoFingerprint(old,document,photoSHA256,contentBytes);
      if (!compatible) throw paused();
      fingerprint=compatible;
    }
    if (!old && await this.db.prepare('SELECT 1 FROM pa_records WHERE owner_id=? AND record_id=?').bind(owner,id).first()) throw paused();
    const indexGeneration=part.kind==='index' ? await this.checkIndex(owner,part) : null;
    if (grant.completed_at!==null && (!old || old.committed!==1)) throw paused();
    // First correct part binds the backup ID, NOT the URL's separate record ID.
    const results=await this.db.batch([
      this.db.prepare(`UPDATE pa_tool_owner_trials SET snapshot_id=COALESCE(snapshot_id,?)
        WHERE owner_id=? AND review_revision=? AND ${eligible}
        AND (snapshot_id IS NULL OR snapshot_id=?) AND (?=1 OR completed_at IS NULL)
        AND (? IS NULL OR slot_generation=?) RETURNING *`)
        .bind(part.snapshotId,owner,grant.review_revision,...this.times(),part.snapshotId,old?.committed===1 ? 1 : 0,
          indexGeneration,indexGeneration),
      this.db.prepare(`INSERT INTO pa_tool_trial_records(owner_id,record_id,snapshot_id,kind,path,part,part_count,
        payload_sha256,input_fingerprint,content_bytes)
        SELECT ?,?,?,?,?,?,?,?,?,? WHERE changes()=1 AND NOT EXISTS
          (SELECT 1 FROM pa_tool_trial_records WHERE owner_id=? AND record_id=?)`)
        .bind(owner,id,part.snapshotId,part.kind,part.path,part.part,part.count,part.sha256,fingerprint,contentBytes,owner,id),
    ]);
    const bound=results[0]?.results[0] as unknown as Grant | undefined;
    if (!bound) throw paused();
    const piece=await this.db.prepare('SELECT input_fingerprint FROM pa_tool_trial_records WHERE owner_id=? AND record_id=?')
      .bind(owner,id).first<{input_fingerprint:string}>();
    if (piece?.input_fingerprint!==fingerprint) throw paused();
    return {grant:bound,recordId:id,document,photo,photoSHA256,fingerprint,
      indexSlotGeneration:indexGeneration===null ? null : indexGeneration+(old ? 0 : 1)};
  }
  private async checkIndex(owner: string, part: ToolBackupPart): Promise<number> {
    const ids=toolIndexRecordIDs(part);
    const state=await this.db.batch([
      this.db.prepare('SELECT slot_generation FROM pa_tool_owner_trials WHERE owner_id=?').bind(owner),
      this.db.prepare(`SELECT * FROM pa_tool_trial_records WHERE owner_id=? AND kind!='index'`).bind(owner),
    ]);
    const generation=(state[0]?.results[0] as {slot_generation:number}|undefined)?.slot_generation;
    const pieces=state[1]?.results as unknown as Piece[];
    if (!Number.isSafeInteger(generation)) throw paused();
    if (!pieces.length || pieces.length!==ids.length || pieces.some(p=>p.snapshot_id!==part.snapshotId
      || p.committed!==1 || !ids.includes(p.record_id))) throw paused();
    const index=JSON.parse(atob(part.payload)) as {files:{path:string;bytes:number;sha256:string;records:string[]}[]};
    for (const file of index.files) {
      let sum=0;
      for (const [offset,record] of file.records.entries()) {
        const piece=pieces.find(p=>p.record_id===record.toLowerCase());
        if (!piece || piece.path!==file.path || piece.part!==offset || piece.part_count!==file.records.length
          || piece.kind!==(file.path.endsWith('.jpg')?'photo':'json')) throw paused();
        if (file.records.length===1 && file.sha256!==piece.payload_sha256) throw paused();
        sum+=piece.content_bytes;
      }
      if (sum!==file.bytes) throw paused();
    }
    return generation!;
  }
  fence(admission: ToolTrialAdmission): {sql:string;bindings:(string|number)[]} {
    return {sql:`EXISTS(SELECT 1 FROM pa_tool_owner_trials WHERE owner_id=? AND review_revision=?
      AND snapshot_id=? AND completed_at IS NULL AND ${eligible}
      AND (?<0 OR slot_generation=?)) AND EXISTS(SELECT 1 FROM pa_tool_trial_records
      WHERE owner_id=? AND record_id=? AND input_fingerprint=?)`,
      bindings:[admission.grant.owner_id,admission.grant.review_revision,admission.grant.snapshot_id!,...this.times(),
        admission.indexSlotGeneration??-1,admission.indexSlotGeneration??-1,
        admission.grant.owner_id,admission.recordId,admission.fingerprint]};
  }
  committed(admission: ToolTrialAdmission, operation: string): D1PreparedStatement[] {
    const owner=admission.grant.owner_id,id=admission.recordId;
    return [this.db.prepare(`UPDATE pa_tool_trial_records SET committed=1 WHERE owner_id=? AND record_id=?
      AND EXISTS(SELECT 1 FROM pa_records WHERE owner_id=? AND record_id=? AND initial_operation=?)`)
      .bind(owner,id,owner,id,operation),
      ...(admission.document.toolBackup!.kind==='index' ? [this.db.prepare(`UPDATE pa_tool_owner_trials
        SET completed_at=? WHERE owner_id=? AND completed_at IS NULL AND EXISTS
        (SELECT 1 FROM pa_tool_trial_records WHERE owner_id=? AND record_id=? AND committed=1)`)
        .bind(this.now(),owner,owner,id)] : [])];
  }
  async usage(owner:string):Promise<{remainingBytes:number;remainingRecords:number}|null> {
    const grant=await this.grant(owner);
    if (!grant) return null;
    if (!await this.allowed(owner) || grant.completed_at!==null) return {remainingBytes:0,remainingRecords:0};
    const row=await this.db.prepare(`SELECT count(*) AS committed FROM pa_tool_trial_records
      WHERE owner_id=? AND committed=1`).bind(owner).first<{committed:number}>();
    const remainingRecords=grant.record_limit-(row?.committed??0);
    // Current app prechecks source bytes but excludes index/document envelopes.
    return {remainingBytes:Math.max(0,grant.byte_limit-grant.admitted_bytes
      -remainingRecords*TRIAL_DOCUMENT_ALLOWANCE-TRIAL_INDEX_ALLOWANCE),remainingRecords};
  }
}

export function trialPilotAccess(trial: ToolOwnerTrial, pilot: PilotStorageAccess): PilotStorageAccess {
  return {allowed:async owner=>await trial.grant(owner) ? trial.allowed(owner) : pilot.allowed(owner),
    // Storage adds the admitted trial's exact fence separately; legacy pilot stays unchanged.
    fence:owner=>pilot.fence(owner)};
}
export function trialOwnerAdmission(trial: ToolOwnerTrial, admission: {
  createOwner(owner:string,identity:string,at:number):Promise<void>;
}) {
  return {createOwner:async (owner:string,identity:string,at:number)=> {
    if (await trial.hasAnyGrant()) throw paused();
    await admission.createOwner(owner,identity,at);
  }};
}
