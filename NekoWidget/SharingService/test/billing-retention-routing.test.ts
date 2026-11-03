import { env } from 'cloudflare:workers';
import { expect, it, vi } from 'vitest';
import worker, { route } from '../src/index';
import * as scheduled from '../src/scheduled';
import * as moments from '../src/moments';
import * as family from '../src/family-records';
import * as relay from '../src/group-cleanup';
import * as operations from '../src/group-report-operations';
import type { Env } from '../src/env';

it('a missing independent billing fence rejects ordinary HTTP reads without invoking their handlers',async()=>{
  const unavailable={...env,ENVIRONMENT:'local',BILLING_TRANSACTION_RETENTION_REQUIRED:'YES',MEDIA:undefined} as unknown as Env;
  await expect(route(new Request('https://example.test/unrecognized'),unavailable)).rejects.toMatchObject({code:'billing_retention_unavailable'});
});

it('billing journal failure cannot postpone existing seven-day, family, or relay cleanup',async()=>{
  const moment=vi.spyOn(moments,'runMomentCleanup').mockResolvedValue(undefined);
  const familyCleanup=vi.spyOn(family,'runFamilyRecordCleanup').mockResolvedValue(undefined);
  const relayCleanup=vi.spyOn(relay,'runGroupRelayCleanup').mockResolvedValue(undefined);
  const reports=vi.spyOn(operations,'runGroupReportOperations').mockResolvedValue(undefined);
  const promises:Promise<unknown>[]=[];
  const context={waitUntil(p:Promise<unknown>){promises.push(p.catch(error=>error));},passThroughOnException(){}} as ExecutionContext;
  try {
    await worker.scheduled({cron:scheduled.MOMENT_CLEANUP_CRON,scheduledTime:Date.now(),noRetry(){}} as ScheduledController,
      {...env,ENVIRONMENT:'local',BILLING_TRANSACTION_RETENTION_REQUIRED:'YES'} as unknown as Env,context);
    const results=await Promise.all(promises);
    expect(results[0]).toMatchObject({code:'billing_retention_unavailable'});
    expect(moment).toHaveBeenCalledTimes(1);expect(familyCleanup).toHaveBeenCalledTimes(1);
    expect(relayCleanup).toHaveBeenCalledTimes(1);expect(reports).toHaveBeenCalledTimes(1);
    // In contrast, losing the common bucket also removes the independent
    // identity fence. No outbox work may read old reporting data in that case.
    promises.length=0;
    await worker.scheduled({cron:scheduled.MOMENT_CLEANUP_CRON,scheduledTime:Date.now(),noRetry(){}} as ScheduledController,
      {...env,ENVIRONMENT:'local',BILLING_TRANSACTION_RETENTION_REQUIRED:'YES',MEDIA:undefined} as unknown as Env,context);
    expect(await Promise.all(promises)).toContainEqual(expect.objectContaining({code:'deletion_recovery_required'}));
    expect(moment).toHaveBeenCalledTimes(2);expect(familyCleanup).toHaveBeenCalledTimes(2);
    expect(relayCleanup).toHaveBeenCalledTimes(2);expect(reports).toHaveBeenCalledTimes(1);
  } finally {vi.restoreAllMocks();}
});

it('restored active rights cannot bypass the independent snapshot fence via group or family early returns',async()=>{
  const e={...env,ENVIRONMENT:'local',BILLING_TRANSACTION_RETENTION_REQUIRED:'YES',
    GROUP_RUNTIME_ENABLED:'YES',MOMENT_RUNTIME_ENABLED:'YES',FAMILY_RECORD_RUNTIME_ENABLED:'YES',FAMILY_NOTEBOOK_API_RUNTIME_ENABLED:'YES'} as unknown as Env;
  await e.MEDIA!.put('__billing_retention/v1/control',JSON.stringify({version:1,deployment:'local',sequence:1}));
  expect(await e.DB.prepare('SELECT applied_sequence FROM billing_retention_checkpoint WHERE singleton=1').first()).toEqual({applied_sequence:0});
  for(const path of ['/v3/group-identities','/v3/group-windows','/v3/family-notebooks','/v2/family-records']) {
    await expect(route(new Request('https://example.test'+path),e)).rejects.toMatchObject({code:'billing_retention_recovery_required'});
  }
});
