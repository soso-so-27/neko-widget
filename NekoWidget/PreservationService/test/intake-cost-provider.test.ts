import { expect, it } from 'vitest';
import { collectCosts, type CostFetch } from '../src/intake-cost-provider';
const now=Date.parse('2026-11-04T06:00:00Z'),day=86400000;
const config={COST_AWS_ACCOUNT_ID:'123456789012',COST_AWS_ACCESS_KEY_ID:'synthetic',COST_AWS_SECRET_ACCESS_KEY:'synthetic',
  COST_CLOUDFLARE_ACCOUNT_ID:'a'.repeat(32),COST_CLOUDFLARE_TOKEN:'synthetic'};
const end=Math.floor(now/day)*day;
const periods=()=>Array.from({length:30},(_,i)=>({TimePeriod:{Start:new Date(end-(30-i)*day).toISOString().slice(0,10),End:new Date(end-(29-i)*day).toISOString().slice(0,10)},
  Estimated:true,Groups:[{Keys:['Amazon Simple Storage Service'],Metrics:{UnblendedCost:{Amount:'0.01',Unit:'USD'}}}]}));
const cf=()=>({success:true,errors:[],messages:[],result:[{BillingAccountId:config.COST_CLOUDFLARE_ACCOUNT_ID,BillingCurrency:'USD',
  ChargeCategory:'Usage',ServiceName:'Workers Standard',SubscriptionId:'test-subscription',BillingPeriodStart:'2026-11-01T00:00:00Z',
  ChargePeriodStart:'2026-11-01T00:00:00Z',ChargePeriodEnd:'2026-11-04T00:00:00Z',ContractedCost:0.01}]});
it('uses account-scoped 30-day AWS data and the Cloudflare billing cycle, exactly one call each',async()=>{
 let aws=0,cloudflare=0;
 const fetcher:CostFetch=async(input,init)=>{
  if(String(input).includes('ce.us-east-1.amazonaws.com')){
   aws++;const body=JSON.parse(String(init?.body));expect(body.Filter.And[0].Dimensions.Values).toEqual([config.COST_AWS_ACCOUNT_ID]);
   expect(body.Filter.And[1].Not.Dimensions.Values).toEqual(['Credit','Refund']);expect(body.NextPageToken).toBeUndefined();
   expect(init?.redirect).toBe('manual');return Response.json({ResultsByTime:periods()});
  }
  cloudflare++;expect(String(input)).toBe(`https://api.cloudflare.com/client/v4/accounts/${config.COST_CLOUDFLARE_ACCOUNT_ID}/billable-usage`);
  return Response.json(cf());
 };
 const result=await collectCosts(config,()=>now,fetcher);
 expect(aws).toBe(1);expect(cloudflare).toBe(1);expect(result.awsPages).toBe(1);expect(result.awsMonthlyUsd).toBeCloseTo(0.31);
 expect(result.cloudflareMonthlyUsd).toBeCloseTo(0.01*31/3);
});
it('two pages finish normally; a third page is rejected without fetching it',async()=>{
 for(const overflow of [false,true]){
  let aws=0;
  const fetcher:CostFetch=async(input)=>{
   if(!String(input).includes('amazonaws.com'))return Response.json(cf());
   aws++;return Response.json({ResultsByTime:periods().slice(aws===1?0:15,aws===1?15:30),
    ...(aws===1?{NextPageToken:'second'}:overflow?{NextPageToken:'third'}:{})});
  };
  if(overflow)await expect(collectCosts(config,()=>now,fetcher)).rejects.toThrow();
  else expect((await collectCosts(config,()=>now,fetcher)).awsPages).toBe(2);
  expect(aws).toBe(2);
 }
});
it('rejects unavailable, incomplete, duplicate, negative, and wrong-currency AWS evidence without retries',async()=>{
 for(const kind of ['http','incomplete','duplicate','negative','currency']){
  let calls=0;
  await expect(collectCosts(config,()=>now,async()=>{
   calls++;if(kind==='http')return new Response(null,{status:503});
   const rows=periods();if(kind==='incomplete')rows.pop();if(kind==='duplicate')rows.push(rows[0]!);
   if(kind==='negative')rows[0]!.Groups[0]!.Metrics.UnblendedCost.Amount='-1';
   if(kind==='currency')rows[0]!.Groups[0]!.Metrics.UnblendedCost.Unit='JPY';
   return Response.json({ResultsByTime:rows});
  })).rejects.toThrow();expect(calls).toBe(1);
 }
});
it('never interprets forbidden, empty, foreign-account, stale or future Cloudflare usage as zero',async()=>{
 for(const kind of ['http','empty','foreign','stale','future','currency','notice','duplicate']){
  const fetcher:CostFetch=async(input)=>{
   if(String(input).includes('amazonaws.com'))return Response.json({ResultsByTime:periods()});
   if(kind==='http')return new Response(null,{status:403});
   const data=cf();if(kind==='empty')data.result=[];
   if(kind==='duplicate')data.result.push({...data.result[0]!});
   if(kind==='foreign')data.result[0]!.BillingAccountId='b'.repeat(32);
   if(kind==='stale')data.result[0]!.ChargePeriodEnd='2026-11-02T00:00:00Z';
   if(kind==='future')data.result[0]!.ChargePeriodEnd='2026-11-05T00:00:00Z';
   if(kind==='currency')data.result[0]!.BillingCurrency='JPY';
   if(kind==='notice')(data.messages as any[]).push({message:'partial'});
   return Response.json(data);
  };
  await expect(collectCosts(config,()=>now,fetcher)).rejects.toThrow();
 }
});
it('missing credentials make no provider requests',async()=>{
 let calls=0;await expect(collectCosts({},()=>now,async()=>{calls++;throw Error();})).rejects.toThrow();expect(calls).toBe(0);
});
