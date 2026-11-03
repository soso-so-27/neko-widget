import type { Env } from './env';
import { ApiError } from './errors';
import { readPersonIdentityFence } from './group-identity-fence';
import { GROUP_RELAY_KEY } from './group-cleanup';

export interface IdentityErasureClaim {
  personId: string;
  requestId: string;
  acceptedAt: number;
}

async function requireMatchingFence(env:Env, claim:IdentityErasureClaim):Promise<void> {
  if (!env.MEDIA) throw new ApiError(503,'unavailable','The deletion could not be verified.');
  const fence = await readPersonIdentityFence(env.MEDIA, claim.personId);
  if (!fence || fence.requestId !== claim.requestId || fence.acceptedAt !== claim.acceptedAt) {
    throw new ApiError(503,'unavailable','The deletion could not be verified.');
  }
}

// A single internal phase. The API/receipt must never treat credential
// revocation as proof that photos, reports or all dependent data were erased.
export async function eraseGroupIdentityCredentials(env: Env, claim: IdentityErasureClaim): Promise<void> {
  await requireMatchingFence(env,claim);
  const db = env.DB;
  const person = claim.personId;
  const devices = 'SELECT id FROM group_person_devices WHERE person_id=?';
  const byDevice = (sql: string) => db.prepare(sql).bind(person);
  const revokeTokens = (table: 'group_push_subscriptions' | 'group_join_push_subscriptions') => byDevice(`
    UPDATE ${table} SET generation=generation+1,expires_at=0,token_ciphertext='',token_nonce='',token_digest=''
    WHERE device_id IN (${devices}) AND (expires_at<>0 OR token_ciphertext<>'' OR token_nonce<>'' OR token_digest<>'')`);

  // Keep FK identities used by other participants' signed history. The
  // replacements are unique invalid public keys (':' is not base64url).
  // All deletes, revocations and removal of the command commit together.
  await db.batch([
    // A restored snapshot can predate registration. Rebuild only the opaque
    // revoked FK identity that matches the independent fence.
    db.prepare("INSERT INTO group_people VALUES (?,'deleted:'||?,'revoked',?) ON CONFLICT(id) DO NOTHING")
      .bind(person,person,claim.acceptedAt),
    db.prepare('INSERT INTO group_identity_erasure_commands VALUES (?,?,?)')
      .bind(person,claim.requestId,claim.acceptedAt),
    db.prepare(`UPDATE group_person_devices SET state='revoked',revoked_at=COALESCE(revoked_at,?),
      signing_public_key='deleted:'||id,hpke_public_key='deleted:'||id,authorization='' WHERE person_id=?`)
      .bind(claim.acceptedAt,person),
    db.prepare("UPDATE group_people SET state='revoked',identity_public_key='deleted:'||id WHERE id=?").bind(person),
    byDevice(`DELETE FROM group_report_access WHERE device_id IN (${devices})`),
    byDevice(`DELETE FROM group_challenges WHERE device_key_hash IN (${devices})`),
    byDevice(`DELETE FROM group_identity_registrations WHERE device_id IN (${devices})`),
    byDevice(`DELETE FROM group_request_nonces WHERE device_id IN (${devices})`),
    byDevice(`DELETE FROM group_mutations WHERE actor_device_id IN (${devices})`),
    byDevice(`DELETE FROM group_notification_deliveries WHERE device_id IN (${devices})`),
    byDevice(`DELETE FROM group_admission_deliveries WHERE device_id IN (${devices})`),
    revokeTokens('group_push_subscriptions'),
    revokeTokens('group_join_push_subscriptions'),
    byDevice(`DELETE FROM group_key_envelopes WHERE device_id IN (${devices})`),
    byDevice(`DELETE FROM family_notebook_crypto_envelopes WHERE recipient_device_id IN (${devices})`),
    db.prepare('DELETE FROM family_notebook_crypto_devices WHERE person_id=?').bind(person),
    db.prepare('DELETE FROM group_identity_erasure_commands WHERE person_id=? AND request_id=?').bind(person,claim.requestId),
  ]);
}

export interface IdentityErasurePhoto {
  momentId: string;
  windowId: string;
  objectKey: string;
}

// Page the initial journal before erasing rows: the coordinator needs these
// exact keys to protect against late uploads and restoration of an older D1.
async function readIdentityPhotoPage(db:D1Database, personId:string, after:string, limit:number):Promise<IdentityErasurePhoto[]> {
  if (!Number.isSafeInteger(limit) || limit<1 || limit>32) throw new Error('Invalid deletion page size.');
  const rows=await db.prepare(`SELECT m.id AS momentId,m.space_id AS windowId,m.object_key AS objectKey,
    m.ciphertext_sha256 AS hash,sm.person_id AS sender,sm.space_id AS memberWindow,sd.person_id AS deviceOwner
    FROM group_moments m JOIN group_members sm ON sm.participant_id=m.sender_participant_id
    JOIN group_person_devices sd ON sd.id=m.sender_device_id
    WHERE (sm.person_id=? OR sd.person_id=?) AND m.id>? ORDER BY m.id LIMIT ?`)
    .bind(personId,personId,after,limit).all<IdentityErasurePhoto & {hash:string;sender:string;memberWindow:string;deviceOwner:string}>();
  return rows.results.map(({momentId,windowId,objectKey,hash,sender,memberWindow,deviceOwner})=>{
    if(sender!==personId || deviceOwner!==sender || memberWindow!==windowId || !GROUP_RELAY_KEY.test(objectKey) || objectKey!==`groups/v3/${windowId}/${momentId}/${hash}`)
      throw new ApiError(503,'unavailable','The deletion target could not be verified.');
    return {momentId,windowId,objectKey};
  });
}

export async function prepareIdentityErasurePhotos(env:Pick<Env,'DB'>,personId:string):Promise<IdentityErasurePhoto[]> {
  if(!/^[A-Za-z0-9_-]{43}$/u.test(personId))throw new Error('Invalid deletion subject.');
  const inventory:IdentityErasurePhoto[]=[];
  let after='';
  for(;;){
    const page=await readIdentityPhotoPage(env.DB,personId,after,32);
    inventory.push(...page);
    if(page.length<32)return inventory;
    after=page[page.length-1]!.momentId;
  }
}

export async function listIdentityErasurePhotos(env:Env,claim:IdentityErasureClaim,after='',limit=8):Promise<IdentityErasurePhoto[]> {
  await requireMatchingFence(env,claim);
  return readIdentityPhotoPage(env.DB,claim.personId,after,limit);
}

function ownershipStatements(db:D1Database,claim:IdentityErasureClaim):D1PreparedStatement[] {
  const p=claim.personId, at=claim.acceptedAt;
  const devices='SELECT id FROM group_person_devices WHERE person_id=?';
  const participants='SELECT participant_id FROM group_members WHERE person_id=?';
  const owned='SELECT space_id FROM group_windows WHERE owner_person_id=?';
  const invites=`SELECT id FROM group_invitations WHERE created_by_device_id IN (${devices})`;
  const families='SELECT id FROM family_notebook_invitations WHERE creator_person_id=?';
  const one=(sql:string)=>db.prepare(sql).bind(p);
  const closedToken=(table:'group_push_subscriptions'|'group_join_push_subscriptions')=>one(`UPDATE ${table}
    SET generation=generation+1,expires_at=0,token_ciphertext='',token_nonce='',token_digest=''
    WHERE space_id IN (${owned}) AND (expires_at<>0 OR token_ciphertext<>'' OR token_nonce<>'' OR token_digest<>'')`);
  return [
    db.prepare('INSERT INTO group_identity_erasure_commands VALUES (?,?,?)').bind(p,claim.requestId,at),
    // The deletion claim authorizes the closure. Never forge an owner-signed
    // normal close receipt or change old signed rosters/packets.
    db.prepare("UPDATE group_windows SET mode='closed',updated_at=MAX(updated_at,?) WHERE owner_person_id=? AND mode<>'closed'").bind(at,p),
    db.prepare(`UPDATE group_windows SET rotation_required=1,updated_at=MAX(updated_at,?) WHERE mode='active' AND space_id IN
      (SELECT space_id FROM group_members WHERE person_id=? AND state='active')`).bind(at,p),
    one(`UPDATE group_members SET state='left',left_revision=(SELECT revision+1 FROM group_windows w WHERE w.space_id=group_members.space_id)
      WHERE space_id IN (${owned}) AND state='active'`),
    one(`UPDATE group_window_devices SET state='revoked',removed_revision=(SELECT revision+1 FROM group_windows w WHERE w.space_id=group_window_devices.space_id)
      WHERE space_id IN (${owned}) AND state='active'`),
    one(`UPDATE group_members SET state='left',left_revision=(SELECT revision+1 FROM group_windows w WHERE w.space_id=group_members.space_id)
      WHERE person_id=? AND state IN ('active','pending')`),
    one(`UPDATE group_window_devices SET state='revoked',removed_revision=(SELECT revision+1 FROM group_windows w WHERE w.space_id=group_window_devices.space_id)
      WHERE participant_id IN (${participants}) AND state='active'`),
    one("UPDATE group_members SET display_name_ciphertext='' WHERE person_id=?"),
    one(`UPDATE group_join_requests SET state='cancelled' WHERE state='pending' AND space_id IN (${owned})`),
    db.prepare(`UPDATE group_invitations SET revoked_at=COALESCE(revoked_at,?) WHERE space_id IN (${owned})`).bind(at,p),
    one(`UPDATE group_join_requests SET state='cancelled' WHERE state='pending' AND invitation_id IN (${invites})`),
    db.prepare(`DELETE FROM group_admission_deliveries WHERE EXISTS(SELECT 1 FROM group_join_requests j
      WHERE (j.person_id=? OR j.space_id IN (${owned})) AND event_id IN(j.id||'-requested',j.id||'-approved'))`).bind(p,p),
    one(`DELETE FROM group_join_requests WHERE person_id=?`), // proof row cascades
    one(`DELETE FROM group_challenges WHERE invitation_id IN (${invites})`),
    db.prepare(`UPDATE group_invitations SET proof_public_key='deleted:'||id,revoked_at=COALESCE(revoked_at,?)
      WHERE created_by_device_id IN (${devices})`).bind(at,p),
    one(`DELETE FROM group_invitations WHERE created_by_device_id IN (${devices})
      AND NOT EXISTS(SELECT 1 FROM group_join_requests j WHERE j.invitation_id=group_invitations.id)`),
    closedToken('group_push_subscriptions'),closedToken('group_join_push_subscriptions'),
    one(`DELETE FROM group_window_metadata WHERE space_id IN (${owned})`),
    one(`DELETE FROM group_window_names WHERE space_id IN (${owned})`),
    ...['group_key_envelopes','group_roster_packets','group_rosters'].map(t=>one(`DELETE FROM ${t} WHERE space_id IN
      (SELECT space_id FROM group_closed_roster_cleanup_due WHERE space_id IN (${owned}))`)),
    one(`DELETE FROM group_window_closures WHERE actor_device_id IN (${devices})`),
    one(`DELETE FROM group_epoch_transitions WHERE actor_device_id IN (${devices})`),
    one(`DELETE FROM group_moment_hearts WHERE participant_id IN (${participants})`),
    one(`DELETE FROM group_heart_usage WHERE participant_id IN (${participants})`),
    db.prepare(`DELETE FROM group_participant_blocks WHERE blocker_id IN (${participants}) OR blocked_id IN (${participants})`).bind(p,p),
    one(`DELETE FROM group_moment_deliveries WHERE device_id IN (${devices})`),
    one(`DELETE FROM group_notification_events WHERE actor_participant_id IN (${participants})`),
    // Expire closed-window pushes even for other recipients, as normal close does.
    one(`DELETE FROM group_notification_deliveries WHERE event_id IN (SELECT id FROM group_notification_events WHERE space_id IN (${owned}))`),
    // The old two-person migration's acknowledgements belong to distinct roles.
    one(`UPDATE group_migrations SET owner_ack=NULL WHERE space_id IN (${owned})`),
    db.prepare(`SELECT json(CASE WHEN EXISTS(SELECT 1 FROM group_migrations g JOIN group_windows w ON w.space_id=g.space_id
      JOIN group_legacy_bindings l ON l.space_id=g.space_id WHERE g.peer_ack IS NOT NULL AND l.person_id=? AND w.owner_person_id<>l.person_id
      AND EXISTS(SELECT 1 FROM group_legacy_bindings other WHERE other.space_id=g.space_id AND other.person_id NOT IN(w.owner_person_id,l.person_id)))
      THEN 'ambiguous_legacy_peer' ELSE 'true' END)`).bind(p),
    db.prepare(`UPDATE group_migrations SET peer_ack=NULL WHERE space_id IN
      (SELECT l.space_id FROM group_legacy_bindings l JOIN group_windows w ON w.space_id=l.space_id WHERE l.person_id=? AND w.owner_person_id<>?)`).bind(p,p),
    one('DELETE FROM group_legacy_bindings WHERE person_id=?'),
    one('DELETE FROM group_report_daily_usage WHERE person_id=?'),
    one('DELETE FROM group_billing_connections WHERE person_id=?'),
    // Leave active families. Only the deleting payer/nominee is cleared; no
    // other person inherits payment authority. Advance the generation once.
    one(`UPDATE family_notebook_members SET state='left',left_generation=(SELECT generation+1 FROM family_notebook_spaces f WHERE f.id=family_notebook_members.family_id)
      WHERE person_id=? AND state='active' AND family_id IN (SELECT id FROM family_notebook_spaces WHERE state='active')`),
    db.prepare(`UPDATE family_notebook_spaces SET generation=generation+1,updated_at=MAX(updated_at,?),
      payer_absent_since_generation=CASE WHEN payer_person_id=? THEN generation+1 ELSE payer_absent_since_generation END,
      payer_person_id=CASE WHEN payer_person_id=? THEN NULL ELSE payer_person_id END,
      nominated_person_id=CASE WHEN nominated_person_id=? THEN NULL ELSE nominated_person_id END
      WHERE state='active' AND EXISTS(SELECT 1 FROM family_notebook_members m WHERE m.family_id=family_notebook_spaces.id
        AND m.person_id=? AND m.state='left' AND m.left_generation=family_notebook_spaces.generation+1)`).bind(at,p,p,p,p),
    one('DELETE FROM family_notebook_handover_current WHERE nominee_person_id=?'),
    one(`DELETE FROM family_notebook_invitation_checks WHERE invitation_id IN (${families})`),
    one(`UPDATE family_notebook_join_requests SET state='cancelled' WHERE state='pending' AND invitation_id IN (${families})`),
    one('DELETE FROM family_notebook_join_requests WHERE person_id=?'),
    one("UPDATE family_notebook_invitations SET state='revoked',proof_public_key='deleted:'||id,encrypted_preview='' WHERE creator_person_id=?"),
    one('DELETE FROM family_notebook_invitations WHERE creator_person_id=? AND NOT EXISTS(SELECT 1 FROM family_notebook_join_requests j WHERE j.invitation_id=family_notebook_invitations.id)'),
    one(`INSERT INTO group_erased_family_dissolutions SELECT e.family_id,e.resulting_generation,e.recorded_at FROM family_notebook_governance_events e
      JOIN family_notebook_spaces f ON f.id=e.family_id WHERE e.actor_person_id=? AND e.action='dissolve' AND f.state='closed' AND f.generation=e.resulting_generation
      ON CONFLICT(family_id) DO NOTHING`),
    one('DELETE FROM family_notebook_governance_events WHERE actor_person_id=?'),
    one('DELETE FROM family_notebook_admission_events WHERE actor_person_id=?'),
    one('DELETE FROM family_notebook_payer_events WHERE actor_person_id=?'),
    one('DELETE FROM family_notebook_crypto_receipts WHERE actor_person_id=?'),
    one('DELETE FROM family_notebook_members WHERE person_id=?'),
    // Transient check rows normally disappear in their writer's own batch.
    ...['group_creation_policy_checks','group_creation_environment_checks','group_window_creation_checks'].map(t=>one(`DELETE FROM ${t} WHERE owner_person_id=?`)),
    ...['family_notebook_access_checks','family_notebook_crypto_checks','family_notebook_crypto_environment_checks','group_billing_connection_checks'].map(t=>one(`DELETE FROM ${t} WHERE person_id=?`)),
    ...['group_authorization_checks','group_report_checks','group_media_access_checks'].map(t=>one(`DELETE FROM ${t} WHERE device_id IN (${devices})`)),
    ...['group_delivery_environment_checks','group_delivery_policy_checks'].map(t=>one(`DELETE FROM ${t} WHERE space_id IN (${owned})`)),
    db.prepare('DELETE FROM group_moderation_checks WHERE sender_person_id=? OR actor_person_id=?').bind(p,p),
    db.prepare('DELETE FROM group_identity_erasure_commands WHERE person_id=? AND request_id=?').bind(p,claim.requestId),
  ];
}

// Invoke only after the coordinator has durably captured deliveries/object
// keys and processed identifiable reports. This method never emits a receipt.
// Each call performs at most eight photo+caption deletions; callers may resume
// immediately or schedule another slice without extending any deadline.
export async function eraseGroupIdentityData(env:Env, claim:IdentityErasureClaim):Promise<{morePhotos:boolean}> {
  const photos=await listIdentityErasurePhotos(env,claim);
  if(photos.length){
    const keys=photos.flatMap(p=>[p.objectKey,p.objectKey+'.caption']);
    await env.MEDIA!.delete(keys);
    if((await Promise.all(keys.map(k=>env.MEDIA!.head(k)))).some(Boolean))
      throw new ApiError(503,'unavailable','The deletion target could not be verified.');
    const statements=photos.flatMap(p=>[
      env.DB.prepare('DELETE FROM group_media_access_checks WHERE moment_id=?').bind(p.momentId),
      env.DB.prepare(`DELETE FROM group_moments WHERE id=? AND space_id=? AND object_key=? AND sender_participant_id IN
        (SELECT participant_id FROM group_members WHERE person_id=?)`).bind(p.momentId,p.windowId,p.objectKey,claim.personId),
      env.DB.prepare('DELETE FROM group_object_deletions WHERE moment_id=? AND object_key=?').bind(p.momentId,p.objectKey),
    ]);
    const windows=[...new Set(photos.map(p=>p.windowId))];
    for(const table of ['group_key_envelopes','group_roster_packets','group_rosters']){
      statements.push(env.DB.prepare(`DELETE FROM ${table} WHERE space_id IN (SELECT space_id FROM group_closed_roster_cleanup_due
        WHERE space_id IN (${windows.map(()=>'?').join(',')}))`).bind(...windows));
    }
    await env.DB.batch(statements);
    if(photos.length===8)return {morePhotos:true};
  }
  await eraseGroupIdentityCredentials(env,claim);
  await env.DB.batch(ownershipStatements(env.DB,claim));
  if(!await identityErasureDataIsClear(env.DB,claim.personId))throw new ApiError(503,'unavailable','The deletion could not be verified.');
  return {morePhotos:false};
}

// Positive readback of this phase only. Report/fence/receipt and late-write
// checks are separate obligations of the coordinator.
export async function identityErasureDataIsClear(db:D1Database,personId:string):Promise<boolean> {
  const residual=[
    "SELECT 1 FROM group_person_devices WHERE person_id=p.id AND (state<>'revoked' OR signing_public_key<>'deleted:'||id OR hpke_public_key<>'deleted:'||id OR authorization<>'')",
    'SELECT 1 FROM group_moments m WHERE m.sender_participant_id IN (SELECT participant_id FROM members) OR m.sender_device_id IN (SELECT id FROM devices)',
    "SELECT 1 FROM group_members WHERE person_id=p.id AND (state IN ('active','pending') OR display_name_ciphertext<>'')",
    "SELECT 1 FROM group_windows WHERE owner_person_id=p.id AND mode<>'closed'",
    "SELECT 1 FROM group_window_devices WHERE state='active' AND (participant_id IN (SELECT participant_id FROM members) OR space_id IN (SELECT space_id FROM owned))",
    ...['group_report_access','group_request_nonces','group_identity_registrations','group_key_envelopes','group_notification_deliveries','group_admission_deliveries','group_moment_deliveries']
      .map(t=>`SELECT 1 FROM ${t} WHERE device_id IN (SELECT id FROM devices)`),
    ...['group_push_subscriptions','group_join_push_subscriptions'].map(t=>`SELECT 1 FROM ${t} WHERE (device_id IN (SELECT id FROM devices) OR space_id IN (SELECT space_id FROM owned))
      AND (expires_at<>0 OR token_ciphertext<>'' OR token_nonce<>'' OR token_digest<>'')`),
    ...['group_join_requests','group_legacy_bindings','group_report_daily_usage','group_billing_connections','family_notebook_members','family_notebook_crypto_devices','family_notebook_join_requests']
      .map(t=>`SELECT 1 FROM ${t} WHERE person_id=p.id`),
    ...['family_notebook_crypto_receipts','family_notebook_governance_events','family_notebook_admission_events','family_notebook_payer_events'].map(t=>`SELECT 1 FROM ${t} WHERE actor_person_id=p.id`),
    'SELECT 1 FROM group_moment_hearts WHERE participant_id IN (SELECT participant_id FROM members)',
    'SELECT 1 FROM group_heart_usage WHERE participant_id IN (SELECT participant_id FROM members)',
    'SELECT 1 FROM group_notification_events WHERE actor_participant_id IN (SELECT participant_id FROM members)',
    'SELECT 1 FROM group_mutations WHERE actor_device_id IN (SELECT id FROM devices)',
    'SELECT 1 FROM group_challenges WHERE device_key_hash IN (SELECT id FROM devices)',
    "SELECT 1 FROM group_invitations WHERE created_by_device_id IN (SELECT id FROM devices) AND (revoked_at IS NULL OR proof_public_key<>'deleted:'||id)",
    "SELECT 1 FROM family_notebook_invitations WHERE creator_person_id=p.id AND (state<>'revoked' OR proof_public_key<>'deleted:'||id OR encrypted_preview<>'')",
    'SELECT 1 FROM family_notebook_spaces WHERE payer_person_id=p.id OR nominated_person_id=p.id',
    'SELECT 1 FROM family_notebook_handover_current WHERE nominee_person_id=p.id',
    'SELECT 1 FROM family_notebook_crypto_envelopes WHERE recipient_device_id IN (SELECT id FROM devices)',
    'SELECT 1 FROM group_identity_erasure_commands WHERE person_id=p.id',
  ];
  const row=await db.prepare(`WITH subject AS (SELECT ? AS id),devices AS (SELECT id FROM group_person_devices WHERE person_id=(SELECT id FROM subject)),
    members AS (SELECT participant_id FROM group_members WHERE person_id=(SELECT id FROM subject)),owned AS (SELECT space_id FROM group_windows WHERE owner_person_id=(SELECT id FROM subject))
    SELECT 1 AS clear FROM subject p JOIN group_people g ON g.id=p.id WHERE g.state='revoked' AND g.identity_public_key='deleted:'||g.id
    AND ${residual.map(sql=>`NOT EXISTS(${sql})`).join(' AND ')}`).bind(personId).first();
  return row!==null;
}
