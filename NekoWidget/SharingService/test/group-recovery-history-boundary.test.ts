import {it,expect} from 'vitest';
import {plusOwner} from './group-billing-fixture';
import {create,person,invitation,apply,transition,ok,call,sign,db} from './group-fixture';
import {groupFields,groupRosterBytes} from '../src/group-protocol';
it('observes re-admission without a signed-roster absence',async()=>{
 const owner=await plusOwner(),p=await person(),w=await create(owner),invite=await invitation(owner,w),join=await apply(p,w,invite);ok(join.response,201);
 const admitted=await transition(owner,w,'admit',join.id,[...w.roster.members,join.member]);ok(admitted.response);
 const before=admitted.next,op=crypto.randomUUID();
 ok(await call(p,`/v3/group-windows/${w.windowId}/leave`,{operationId:op,expectedRevision:2,selfSignature:await sign(p.signing.privateKey,groupFields(['NW3.LEAVE',w.windowId,join.member.participantId,'2',op]))}));
 expect(await db.prepare('SELECT revision FROM group_windows WHERE space_id=?').bind(w.windowId).first()).toEqual({revision:2});
 const again=await apply(p,before,await invitation(owner,before));ok(again.response,201);
 const sameMember={...again.member,participantId:join.member.participantId};
 const rejoined=await transition(owner,before,'admit',again.id,[before.roster.members[0]!,sameMember]);ok(rejoined.response);
 expect(sameMember).toEqual(join.member);
 const rotationOnly={...before.roster,revision:3,keyEpoch:3,previousHash:before.hash};
 expect(groupRosterBytes(rejoined.next.roster)).toEqual(groupRosterBytes(rotationOnly));
 expect(await db.prepare('SELECT joined_revision FROM group_members WHERE participant_id=?').bind(join.member.participantId).first()).toEqual({joined_revision:3});
 console.log('P5 boundary: rejoin signed roster equals uninterrupted rotation; joined_revision differs only in server ledger');
});
