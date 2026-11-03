import { sha256Base64url } from './encoding';
import { groupFields } from './group-protocol';

const fields = ['window','moment','senderPerson','senderParticipant','receiverPerson','receiverDevice'] as const;
type Field = typeof fields[number];
type Delivery = Record<Field,string>;
export type DeliveryMarker = Delivery & { generation:number; expiresAt:number };
const digest = (field:Field,id:string) => sha256Base64url(groupFields(['NW3.DELETED-DELIVERY.V1',field,id]));
export async function deliveryMarker(ids:Delivery, generation:number, acceptedAt:number, reportUntil:number|null):Promise<DeliveryMarker> {
  if (!Number.isSafeInteger(acceptedAt) || acceptedAt<=0 || !Number.isSafeInteger(acceptedAt+86400)
      || (reportUntil!==null && (!Number.isSafeInteger(reportUntil) || reportUntil<=0))
      || !Number.isSafeInteger(generation) || generation<1) throw new Error('Invalid deletion generation or expiry.');
  if (ids.receiverPerson===ids.senderPerson || fields.some(f=>!ids[f])) throw new Error('Invalid delivery.');
  const values=await Promise.all(fields.map(f=>digest(f,ids[f])));
  return {window:values[0]!,moment:values[1]!,senderPerson:values[2]!,senderParticipant:values[3]!,
    receiverPerson:values[4]!,receiverDevice:values[5]!,generation,expiresAt:Math.min(acceptedAt+86400,reportUntil??Infinity)};
}

// The caller must independently authenticate the receiver, check the live
// report-only grant, and supply the generation of the original deletion.
export async function matchesDelivery(marker:DeliveryMarker, ids:Delivery, generation:number, now:number):Promise<boolean> {
  if (!Number.isSafeInteger(now) || now<0 || generation!==marker.generation || now>=marker.expiresAt
      || ids.receiverPerson===ids.senderPerson) return false;
  const values=await Promise.all(fields.map(f=>digest(f,ids[f])));
  return fields.every((f,i)=>values[i]===marker[f]);
}

// Capture once at acceptance, before deleting moments. On recovery the caller
// projects the original journal contents, never a new scan of restored rows.
export async function captureDeletedDeliveries(db:D1Database,senderPerson:string,generation:number,acceptedAt:number):Promise<DeliveryMarker[]> {
  const rows=await db.prepare(`SELECT m.space_id AS window,m.id AS moment,sm.person_id AS senderPerson,
    sm.participant_id AS senderParticipant,c.person_id AS receiverPerson,c.device_id AS receiverDevice,
    a.expires_at AS reportUntil FROM group_moments m
    JOIN group_members sm ON sm.space_id=m.space_id AND sm.participant_id=m.sender_participant_id
    JOIN group_moment_deliveries d ON d.moment_id=m.id
    JOIN group_report_credentials c ON c.space_id=m.space_id AND c.device_id=d.device_id AND c.participant_id=d.participant_id
    LEFT JOIN group_report_access a ON a.space_id=c.space_id AND a.device_id=c.device_id
    WHERE sm.person_id=? AND sm.person_id<>c.person_id AND m.kind='photo' AND m.committed_at<=?
      AND d.acknowledged_at<=? AND d.state='acknowledged'
      AND (a.expires_at IS NULL OR a.expires_at>?)
    ORDER BY m.id,c.device_id`).bind(senderPerson,acceptedAt,acceptedAt,acceptedAt).all<Delivery & {reportUntil:number|null}>();
  return Promise.all(rows.results.map(row=>deliveryMarker(row,generation,acceptedAt,row.reportUntil)));
}

export function deletedDeliveryStatements(db:D1Database,markers:DeliveryMarker[],generation:number,acceptedAt:number):D1PreparedStatement[] {
  // These are the authoritative journal's generation and first accepted time,
  // not values from a replay request or a restored D1 row.
  if(!Number.isSafeInteger(generation) || generation<1 || !Number.isSafeInteger(acceptedAt) || acceptedAt<=0
    || !Number.isSafeInteger(acceptedAt+86400))throw new Error('Invalid deletion journal.');
  for(const marker of markers) {
    if(marker.generation!==generation || !Number.isSafeInteger(marker.expiresAt) || marker.expiresAt<=acceptedAt
      || marker.expiresAt>acceptedAt+86400 || fields.some(f=>typeof marker[f]!=='string' || !/^[A-Za-z0-9_-]{43}$/.test(marker[f])))
      throw new Error('Invalid deletion delivery marker.');
  }
  return markers.map(m=>db.prepare(`INSERT INTO group_deleted_deliveries SELECT ?,?,?,?,?,?,?,? WHERE ?>unixepoch()
    ON CONFLICT(window_digest,moment_digest,receiver_person_digest,receiver_device_digest) DO UPDATE SET
    sender_person_digest=excluded.sender_person_digest,sender_participant_digest=excluded.sender_participant_digest,
    generation=excluded.generation,expires_at=excluded.expires_at`)
    .bind(m.window,m.moment,m.senderPerson,m.senderParticipant,m.receiverPerson,m.receiverDevice,m.generation,m.expiresAt,m.expiresAt));
}

export async function deletedReportDelivery(db:D1Database,window:string,moment:string,receiverPerson:string,receiverDevice:string) {
  if(!await db.prepare("SELECT 1 FROM sqlite_master WHERE type='table' AND name='group_deleted_deliveries'").first())return null;
  const [w,m,r,d]=await Promise.all([digest('window',window),digest('moment',moment),digest('receiverPerson',receiverPerson),digest('receiverDevice',receiverDevice)]);
  const marker=await db.prepare(`SELECT window_digest AS window,moment_digest AS moment,sender_person_digest AS senderPerson,
    sender_participant_digest AS senderParticipant,receiver_person_digest AS receiverPerson,receiver_device_digest AS receiverDevice,
    generation,expires_at AS expiresAt FROM group_deleted_deliveries WHERE window_digest=? AND moment_digest=?
    AND receiver_person_digest=? AND receiver_device_digest=? AND expires_at>unixepoch()`).bind(w,m,r,d).first<DeliveryMarker>();
  if(!marker)return null;
  const reporter=await db.prepare('SELECT participant_id FROM group_report_credentials WHERE space_id=? AND person_id=? AND device_id=?')
    .bind(window,receiverPerson,receiverDevice).first<string>('participant_id');
  if(!reporter)return null;
  const members=await db.prepare('SELECT person_id,participant_id FROM group_members WHERE space_id=? AND person_id<>?')
    .bind(window,receiverPerson).all<{person_id:string;participant_id:string}>();
  for(const member of members.results) {
    const ids={window,moment,receiverPerson,receiverDevice,senderPerson:member.person_id,senderParticipant:member.participant_id};
    if(await matchesDelivery(marker,ids,marker.generation,Math.floor(Date.now()/1000))) {
      return {participant_id:reporter,sender_participant_id:member.participant_id,expiresAt:marker.expiresAt,
        authorize:(reportId:string)=>db.prepare('INSERT INTO group_deleted_delivery_commands VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)')
          .bind(reportId,window,moment,member.person_id,member.participant_id,receiverPerson,receiverDevice,
            w,m,marker.senderPerson,marker.senderParticipant,r,d,marker.generation)};
    }
  }
  return null;
}
