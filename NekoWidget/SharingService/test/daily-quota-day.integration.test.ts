import {describe,expect,it} from 'vitest';
import {plusOwner} from './group-billing-fixture';
import {create,db} from './group-fixture';
import {dailyQuotaDay} from '../src/daily-quota-day';

describe('daily quota migration boundaries',()=>{
  it('demonstrates why changing a populated UTC counter key in the middle of a JST day would reset quota',async()=>{
    const owner=await plusOwner(),w=await create(owner),participant=w.roster.members[0]!.participantId;
    const time=Date.parse('2026-11-04T01:00:00+09:00')/1000;
    const utc=Math.floor(time/86400),jst=Math.floor((time+32400)/86400);
    expect(jst).toBe(utc+1);
    await db.prepare('INSERT INTO group_heart_usage VALUES (?,?,?,30)').bind(w.windowId,participant,utc).run();
    expect((await db.prepare('SELECT used FROM group_heart_usage WHERE space_id=? AND participant_id=? AND day_key=?')
      .bind(w.windowId,participant,utc).first())?.used).toBe(30);
    expect(await db.prepare('SELECT used FROM group_heart_usage WHERE space_id=? AND participant_id=? AND day_key=?')
      .bind(w.windowId,participant,jst).first()).toBeNull();
  });
  it('keeps current counters until the next JST midnight, then never resets at JST 09:00',async()=>{
    const before=Date.parse('2026-11-04T01:00:00+09:00')/1000;
    const boundary=(Math.floor((before+32400)/86400)+1)*86400-32400;
    await db.prepare('UPDATE daily_quota_day_policy SET effective_at=?').bind(boundary).run();
    expect(await dailyQuotaDay({DB:db},before)).toBe(Math.floor(before/86400));
    expect(await dailyQuotaDay({DB:db},boundary-1)).toBe(Math.floor((boundary-1)/86400));
    expect(await dailyQuotaDay({DB:db},boundary)).toBe(Math.floor((boundary+32400)/86400));
    expect(await dailyQuotaDay({DB:db},boundary+9*3600)).toBe(await dailyQuotaDay({DB:db},boundary));
    expect(await dailyQuotaDay({DB:db},boundary+86400)).toBe(1+await dailyQuotaDay({DB:db},boundary));
    const row=await db.prepare('SELECT CAST((?+CASE WHEN ?>=effective_at THEN utc_offset_seconds ELSE 0 END)/86400 AS INTEGER) day FROM daily_quota_day_policy')
      .bind(boundary,boundary).first<{day:number}>();
    expect(row!.day).toBe(await dailyQuotaDay({DB:db},boundary));
  });
});
