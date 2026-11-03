import { describe,expect,it } from 'vitest';
import { deliveryMarker,matchesDelivery } from '../src/group-deleted-delivery';
import { db,testEnv,person,create,ok,invitation,apply,transition } from './group-fixture';
import { plusOwner } from './group-billing-fixture';
describe('A1 hash-only delivery before connecting the report route',()=>{
  it('resolves the original FK in the same window without putting raw values in the marker', async()=>{
    const owner=await plusOwner(),guest=await person(); let w=await create(owner);
    const join=await apply(guest,w,await invitation(owner,w));
    const joined=await transition(owner,w,'admit',join.id,[...w.roster.members,join.member]);ok(joined.response);w=joined.next;
    const sender=w.roster.members.find(m=>m.personId===owner.id)!;
    const ids={window:w.windowId,moment:'synthetic-delivered-id',senderPerson:owner.id,senderParticipant:sender.participantId,receiverPerson:guest.id,receiverDevice:guest.deviceId};
    const at=Math.floor(Date.now()/1000), end=at+21;
    const m=await deliveryMarker(ids,1,at,end);
    expect(Object.keys(m).sort()).toEqual([...Object.keys(ids),'generation','expiresAt'].sort());
    for(const value of Object.values(ids))expect(JSON.stringify(m)).not.toContain(value);
    expect((await deliveryMarker(ids,1,at,null)).expiresAt).toBe(at+86400);
    expect(m.expiresAt).toBe(end);
    const refs=(await db.prepare('SELECT participant_id,person_id FROM group_members WHERE space_id=?').bind(w.windowId)
      .all<{participant_id:string;person_id:string}>()).results;
    const matches=await Promise.all(refs.map(row=>matchesDelivery(m,{...ids,senderParticipant:row.participant_id,senderPerson:row.person_id},1,end-1)));
    expect(refs.filter((_,i)=>matches[i]).map(r=>r.participant_id)).toEqual([sender.participantId]);
    const fk=(await db.prepare('PRAGMA foreign_key_list(group_reports)').all<{from:string;table:string;to:string}>()).results;
    expect(fk).toEqual(expect.arrayContaining([expect.objectContaining({from:'accused_participant_id',table:'group_members',to:'participant_id'})]));
    for(const key of Object.keys(ids) as (keyof typeof ids)[])expect(await matchesDelivery(m,{...ids,[key]:'different'},1,end-1)).toBe(false);
    expect(await matchesDelivery(m,ids,2,end-1)).toBe(false);
    expect(await matchesDelivery(m,ids,1,end)).toBe(false);
    // Replay an older D1 view: the authoritative R2 marker keeps its original
    // expiry; a later request must not replace it with a new 24-hour interval.
    const key='synthetic-a1/'+crypto.randomUUID(),storage=testEnv.MEDIA!;
    expect(await storage.put(key,JSON.stringify(m),{onlyIf:{etagDoesNotMatch:'*'}})).not.toBeNull();
    expect(await storage.put(key,JSON.stringify(await deliveryMarker(ids,2,end+1,null)),{onlyIf:{etagDoesNotMatch:'*'}})).toBeNull();
    const restored=await (await storage.get(key))!.json<typeof m>();
    expect(restored).toEqual(m);
    expect(await matchesDelivery(restored,ids,1,end+1)).toBe(false);
  });
});
