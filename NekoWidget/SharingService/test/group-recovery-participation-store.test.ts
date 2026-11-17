import {it,expect} from 'vitest';
import {plusOwner} from './group-billing-fixture';
import {create,person,invitation,apply,transition,ok,sign,db,packet,testEnv,signed,send} from './group-fixture';
import {participationBytes,type ParticipationBoundary} from '../src/group-recovery-participation';
it('atomically records a new admission, carries it forward, and refuses historical backfill',async()=>{
 const owner=await plusOwner(),p=await person(),w=await create(owner),join=await apply(p,w,await invitation(owner,w));ok(join.response,201);
 const roster={...w.roster,revision:2,keyEpoch:2,previousHash:w.hash,members:[...w.roster.members,join.member]};
 const data=await packet(owner,roster),{hash,...wire}=data;
 const unsigned:Omit<ParticipationBoundary,'signature'>={environment:'staging',windowId:w.windowId,personId:p.id,participantId:join.member.participantId,
  admissionRevision:2,rosterHash:hash,signerDeviceId:owner.deviceId};
 const make=async(u:typeof unsigned)=>({...u,signature:await sign(owner.signing.privateKey,participationBytes(u))});
 const body={operationId:crypto.randomUUID(),expectedRevision:1,kind:'admit',targetId:join.id,...wire,participationProofs:[await make(unsigned)]};
 const env={...testEnv,ENVIRONMENT:'staging',GROUP_RECOVERY_CATALOG_ENABLED:'YES',MEMBER_RATE_LIMITER:{limit:async()=>({success:true})}};
 ok(await send(await signed(owner,`/v3/group-windows/${w.windowId}/join-requests/${join.id}/approve`,body),env));
 expect(await db.prepare('SELECT roster_hash FROM group_recovery_participation WHERE window_id=?').bind(w.windowId).first()).toEqual({roster_hash:hash});
 const nextRoster={...roster,revision:3,keyEpoch:3,previousHash:hash};
 const next=await packet(owner,nextRoster),{hash:nextHash,...nextWire}=next;
 const rotate={operationId:crypto.randomUUID(),expectedRevision:2,kind:'rotate',targetId:w.windowId,...nextWire,
  participationProofs:[await make({...unsigned,rosterHash:nextHash})]};
 ok(await send(await signed(owner,`/v3/group-windows/${w.windowId}/rotate`,rotate),env));
 // Existing owner has no boundary proof: do not invent revision one from D1.
 const fourth={...nextRoster,revision:4,keyEpoch:4,previousHash:nextHash},four=await packet(owner,fourth),{hash:fourHash,...fourWire}=four;
 const backfill={...unsigned,personId:owner.id,participantId:w.roster.members[0]!.participantId,admissionRevision:1,rosterHash:fourHash};
 const rejected=await send(await signed(owner,`/v3/group-windows/${w.windowId}/rotate`,{
  operationId:crypto.randomUUID(),expectedRevision:3,kind:'rotate',targetId:w.windowId,...fourWire,participationProofs:[await make(backfill)]}),env);
 expect(rejected.data.error.code).toBe('invalid_participation');
 expect(await db.prepare('SELECT revision FROM group_windows WHERE space_id=?').bind(w.windowId).first()).toEqual({revision:3});
});
