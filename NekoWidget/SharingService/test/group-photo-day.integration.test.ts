import {describe,expect,it} from 'vitest';
import {plusOwner} from './group-billing-fixture';
import {create,db} from './group-fixture';
import {randomBase64url} from '../src/encoding';

async function fixture() {
  const owner=await plusOwner(),window=await create(owner);
  const policy=await db.prepare('SELECT * FROM group_photo_day_policy').first<{effective_at:number;utc_offset_seconds:number}>();
  // Future synthetic transition lets real D1 expiry checks remain enabled.
  const boundary=policy!.effective_at+86400;
  await db.prepare('UPDATE group_photo_day_policy SET effective_at=?').bind(boundary).run();
  async function reserve(time:number,expires=time+1800) {
    const id=randomBase64url(16),client=randomBase64url(16);
    await db.prepare(`INSERT INTO group_moments VALUES (?,?,?,?,?,?,?,?,?,?,?,'photo','reserved',?,?,?,NULL,?,?,NULL)`)
      .bind(id,window.windowId,client,window.roster.members[0]!.participantId,owner.deviceId,
        window.roster.keyEpoch,window.roster.revision,window.hash,48,randomBase64url(32),randomBase64url(64),
        `groups/v3/${window.windowId}/${id}/${randomBase64url(32)}`,time,expires,time+30*86400,expires+600).run();
    return id;
  }
  async function commit(id:string,time:number) {
    await db.batch([
      db.prepare("UPDATE group_moments SET state='uploaded' WHERE id=?").bind(id),
      db.prepare("UPDATE group_moments SET state='committed',committed_at=? WHERE id=?").bind(time,id),
    ]);
  }
  return {boundary,reserve,commit};
}

describe('group photo product day: next JST midnight cutover',()=>{
  it('schedules the next Japan midnight, never the middle of the current day',async()=>{
    const row=await db.prepare('SELECT * FROM group_photo_day_policy').first<{effective_at:number;utc_offset_seconds:number}>();
    const now=Math.floor(Date.now()/1000);
    expect(row!.utc_offset_seconds).toBe(9*3600);
    expect(row!.effective_at).toBe((Math.floor((now+9*3600)/86400)+1)*86400-9*3600);
    expect(row!.effective_at).toBeGreaterThan(now);
  });
  it('keeps the previous UTC rule until cutover, then allows five and does not reset at 09:00 JST',async()=>{
    const f=await fixture();
    for(let i=0;i<5;i++)await f.commit(await f.reserve(f.boundary-60),f.boundary-60);
    await expect(f.reserve(f.boundary-1)).rejects.toThrow('group_photo_daily_limit');
    for(let i=0;i<5;i++)await f.commit(await f.reserve(f.boundary),f.boundary);
    await expect(f.reserve(f.boundary)).rejects.toThrow('group_photo_daily_limit');
    await expect(f.reserve(f.boundary+9*3600)).rejects.toThrow('group_photo_daily_limit');
    await f.reserve(f.boundary+86400);
  });
  it('counts live pre-midnight reservations on the new day without double-charging their commit',async()=>{
    const f=await fixture(),pending=[];
    for(let i=0;i<4;i++)pending.push(await f.reserve(f.boundary-10));
    pending.push(await f.reserve(f.boundary));
    await expect(f.reserve(f.boundary)).rejects.toThrow('group_photo_daily_limit');
    for(const id of pending)await f.commit(id,f.boundary+1);
    await expect(f.reserve(f.boundary+2)).rejects.toThrow('group_photo_daily_limit');
    // Idempotent same-state updates cannot consume a second slot.
    await db.prepare("UPDATE group_moments SET state='committed' WHERE id=?").bind(pending[0]).run();
    for(let i=0;i<5;i++)await f.reserve(f.boundary+86400);
  });
  it('releases an expired carried reservation instead of blocking all five slots',async()=>{
    const f=await fixture();await f.reserve(f.boundary-10,f.boundary+20);
    for(let i=0;i<5;i++)await f.reserve(f.boundary+21);
    await expect(f.reserve(f.boundary+21)).rejects.toThrow('group_photo_daily_limit');
  });
  it('serializes six simultaneous reservations into exactly five accepted slots',async()=>{
    const f=await fixture();
    const results=await Promise.allSettled(Array.from({length:6},()=>f.reserve(f.boundary)));
    expect(results.filter(r=>r.status==='fulfilled')).toHaveLength(5);
    expect(results.filter(r=>r.status==='rejected')).toHaveLength(1);
  });
});
