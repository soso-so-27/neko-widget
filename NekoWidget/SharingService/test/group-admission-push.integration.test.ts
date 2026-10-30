import { describe,expect,it } from 'vitest';
import { plusOwner } from './group-billing-fixture';
import { randomBase64url } from '../src/encoding';
import { drainGroupAdmissionNotifications } from '../src/group-admission-push';
import { apply,call,create,db,invitation,ok,person,send,signed,testEnv,transition,type Person } from './group-fixture';
import type { Env } from '../src/env';
async function setup() {
  const owner=await plusOwner(),guest=await person(),w=await create(owner),invite=await invitation(owner,w);
  const join=await apply(guest,w,invite);ok(join.response,201);
  const keys=await crypto.subtle.generateKey({name:'ECDSA',namedCurve:'P-256'},true,['sign','verify']) as CryptoKeyPair;
  const raw=new Uint8Array(await crypto.subtle.exportKey('pkcs8',keys.privateKey));
  const settings:Env={...testEnv,GROUP_APNS_RUNTIME_ENABLED:'YES',APNS_RUNTIME_ENABLED:'YES',
    APNS_PROVIDER_CREDENTIAL_JSON:JSON.stringify({keyId:'A1B2C3D4E5',teamId:'Z9Y8X7W6V5',bundleId:'jp.nekowidget.app',environment:'production',
      privateKey:`-----BEGIN PRIVATE KEY-----\n${btoa(String.fromCharCode(...raw))}\n-----END PRIVATE KEY-----`}),
    APNS_TOKEN_KEYRING_JSON:JSON.stringify({current:'test',keys:{test:randomBase64url(32)}})};
  async function register(actor:Person,kind='join-push-subscription',token=randomBase64url(32)) {
    return send(await signed(actor,`/v3/group-windows/${w.windowId}/${kind}`,{operationId:crypto.randomUUID(),token,environment:'production'}),settings);
  }
  return {owner,guest,w,invite,join,settings,register};
}
const noNetwork:typeof fetch=async()=>{throw new Error('Unexpected APNs request');};
describe('group invitation admission notifications',()=>{
  it('stores the original verifiable challenge witness and permits only owner invitation lookup',async()=>{
    const {owner,guest,w,invite,join}=await setup();
    const pending=ok(await call(owner,`/v3/group-windows/${w.windowId}/join-requests/list`,{after:null,limit:50}));
    expect((pending.items as any[])[0].admissionProof).toMatchObject({operationId:expect.any(String),challengeId:expect.any(String),
      challenge:expect.any(String),inviteProof:expect.any(String),deviceSignature:expect.any(String)});
    const row=await db.prepare('SELECT invitation_id FROM group_join_requests WHERE id=?').bind(join.id).first<{invitation_id:string}>();
    const status=ok(await call(owner,`/v3/group-windows/${w.windowId}/invitations/status`,{invitationId:row!.invitation_id}));
    expect(status).toMatchObject({revokedAt:null,expiresAt:expect.any(Number),proofPublicKey:expect.any(String)});
    expect((await call(guest,`/v3/group-windows/${w.windowId}/invitations/status`,{invitationId:row!.invitation_id})).status).toBe(404);
  });
  it('delivers one generic request to the owner and approval to the correct entrant, including late registration',async()=>{
    const {owner,guest,w,join,settings,register}=await setup();ok(await register(owner,'push-subscription'));
    const sent:any[]=[];const transport:typeof fetch=async(_url,init)=>{sent.push(JSON.parse(init!.body as string));return new Response(null,{status:200});};
    expect((await drainGroupAdmissionNotifications(settings,undefined,transport)).accepted).toBe(1);
    expect(sent[0].neko).toEqual({v:3,kind:'join_requested',windowId:w.windowId,requestId:join.id});
    expect((await drainGroupAdmissionNotifications(settings,undefined,transport)).accepted).toBe(0);
    const outsider=await person();expect((await register(outsider)).status).toBe(404);
    const approved=await transition(owner,w,'admit',join.id,[...w.roster.members,join.member]);ok(approved.response);
    ok(await register(guest));
    expect((await drainGroupAdmissionNotifications(settings,undefined,transport)).accepted).toBe(1);
    expect(sent[1].neko.kind).toBe('join_approved');expect(JSON.stringify(sent)).not.toContain('encryptedDisplayName');
    ok(await register(guest));expect((await drainGroupAdmissionNotifications(settings,undefined,transport)).accepted).toBe(0);
  });
  it('pending subscription grants no membership, photo or key access and stores only encrypted tokens',async()=>{
    const {guest,w,register}=await setup(),token=randomBase64url(32);ok(await register(guest,'join-push-subscription',token));
    const row=await db.prepare('SELECT * FROM group_join_push_subscriptions WHERE space_id=? AND device_id=?').bind(w.windowId,guest.deviceId).first();
    expect(JSON.stringify(row)).not.toContain(token);
    expect((await call(guest,`/v3/group-windows/${w.windowId}/members/list`,{after:null,limit:50})).status).toBe(404);
    expect(await db.prepare('SELECT 1 FROM group_window_devices WHERE space_id=? AND device_id=?').bind(w.windowId,guest.deviceId).first()).toBeNull();
  });
  it.each(['cancel','revoke','gate','token','closed'] as const)('rechecks %s immediately before APNs',async(reason)=>{
    const {owner,guest,w,join,settings,register}=await setup();ok(await register(owner,'push-subscription'));
    const change=async()=>{
      if(reason==='cancel')ok(await call(guest,`/v3/group-windows/${w.windowId}/join-requests/${join.id}/cancel`,{operationId:crypto.randomUUID()}));
      if(reason==='revoke')await db.prepare('UPDATE group_invitations SET revoked_at=unixepoch() WHERE space_id=?').bind(w.windowId).run();
      if(reason==='gate')await db.prepare('UPDATE personal_staging_runtime_gate SET apns_enabled=0,generation=generation+1 WHERE singleton=1').run();
      if(reason==='token')ok(await register(owner,'push-subscription'));
      if(reason==='closed')await db.prepare("UPDATE group_windows SET mode='closed' WHERE space_id=?").bind(w.windowId).run();
    };
    try {expect((await drainGroupAdmissionNotifications(settings,undefined,noNetwork,{beforeSend:change})).skipped).toBe(1);}
    finally {if(reason==='gate')await db.prepare('UPDATE personal_staging_runtime_gate SET apns_enabled=1,generation=generation+1 WHERE singleton=1').run();}
  });
  it('runtime OFF sends nothing and preserves requests',async()=>{
    const {owner,w,join,settings,register}=await setup();ok(await register(owner,'push-subscription'));
    expect((await drainGroupAdmissionNotifications({...settings,GROUP_APNS_RUNTIME_ENABLED:'NO'},undefined,noNetwork)).leased).toBe(0);
    expect((await db.prepare('SELECT state FROM group_join_requests WHERE id=?').bind(join.id).first())?.state).toBe('pending');
  });
});
