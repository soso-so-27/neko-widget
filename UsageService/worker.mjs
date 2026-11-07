export const contexts = ['onboarding','widget-resume','monthly-summary','new-memo','create-window','continue-window','create-family','continue-family','preservation','settings'];
export const events = new Set(('onboarding_completed photo_access_granted cats_found widget_guide_opened album_work_opened seasonal_movie_opened nine_exported showcase_opened photo_favorited photo_memo_written related_photos_opened mado_opened mado_photo_sent mado_heart official_window_started cat_care_edited tool_care_handoff tool_vet_visit tool_lost_cat tool_evacuation mado_created mado_invite_shared mado_joined family_created family_invite_shared family_joined app_recommended plus_restored autosave_started').split(' ').concat(contexts.flatMap(c=>['plus_offer_shown.'+c,'plus_purchased.'+c])));
const DAY=86400000;
const object=x=>x!==null && typeof x==='object' && !Array.isArray(x);
export function validate(x, now=Date.now()) {
 if(!object(x)||x.schema!==1||typeof x.day!=='string'||!/^\d{4}-\d{2}-\d{2}$/.test(x.day))throw Error('invalid');
 const day=Date.parse(x.day+'T00:00:00Z'), today=Math.floor(now/DAY)*DAY;
 if(!Number.isFinite(day)||new Date(day).toISOString().slice(0,10)!==x.day||day<today-7*DAY||day>today+DAY)throw Error('invalid');
 if(typeof x.batch!=='string'||!(/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(x.batch)))throw Error('invalid');
 if(typeof x.app!=='string'||!/^\d{1,2}\.\d{1,2}(?:\.\d{1,2})? \([1-9]\d{0,5}\)$/.test(x.app)||typeof x.os!=='string'||!/^\d{1,2}$/.test(x.os))throw Error('invalid');
 if(!object(x.counts)||Object.keys(x.counts).length>100||!object(x.state))throw Error('invalid');
 const counts={};
 for(const [k,v] of Object.entries(x.counts)){if(!events.has(k))continue;if(!Number.isSafeInteger(v)||v<0||v>10000)throw Error('invalid');if(v>0)counts[k]=v;}
 const state={};
 for(const k of ['plus','widget','family']){if(typeof x.state[k]!=='boolean')throw Error('invalid');state[k]=String(x.state[k]);}
 for(const [k,allowed] of Object.entries({cats:['0','1','2','3+'],windows:['0','1-2','3+'],photoAccess:['full','limited','none']})){if(!allowed.includes(x.state[k]))throw Error('invalid');state[k]=x.state[k];}
 return {day:x.day,batch:x.batch.toLowerCase(),app:x.app,counts,state,expires:Math.min(day+8*DAY,now+7*DAY+23*3600000)};
}
export async function digest(secret,day,batch){
 const enc=new TextEncoder();const key=await crypto.subtle.importKey('raw',enc.encode(secret),{name:'HMAC',hash:'SHA-256'},false,['sign']);
 return [...new Uint8Array(await crypto.subtle.sign('HMAC',key,enc.encode('usage-v1\n'+day+'\n'+batch)))].map(b=>b.toString(16).padStart(2,'0')).join('');
}
const reply=status=>new Response(null,{status,headers:{'Cache-Control':'no-store'}});
async function boundedBody(request){
 if(Number(request.headers.get('content-length')||0)>16384)throw Error('invalid');
 const reader=request.body?.getReader();if(!reader)throw Error('invalid');let size=0;const chunks=[];
 while(true){const {done,value}=await reader.read();if(done)break;size+=value.length;if(size>16384){await reader.cancel();throw Error('invalid');}chunks.push(value);}
 const bytes=new Uint8Array(size);let off=0;for(const c of chunks){bytes.set(c,off);off+=c.length;}return JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(bytes));
}
export async function store(db,r,hash,now=Date.now()){
 const prior=await db.prepare('SELECT 1 FROM usage_dedup WHERE day=? AND digest=? AND expires>?').bind(r.day,hash,now).first();if(prior)return 204;
 const marker=crypto.randomUUID(),receivedDay=new Date(now).toISOString().slice(0,10);
 const statements=[db.prepare('DELETE FROM usage_dedup WHERE expires<=?').bind(now),
 db.prepare('INSERT OR IGNORE INTO usage_dedup(day,digest,marker,expires) SELECT ?,?,?,? WHERE COALESCE((SELECT accepted FROM usage_quota WHERE day=?),0)<5000').bind(r.day,hash,marker,r.expires,receivedDay)];
 const condition='EXISTS(SELECT 1 FROM usage_dedup WHERE day=? AND digest=? AND marker=?)';
 statements.push(db.prepare('INSERT INTO usage_quota(day,accepted) SELECT ?,1 WHERE '+condition+' ON CONFLICT(day) DO UPDATE SET accepted=accepted+1').bind(receivedDay,r.day,hash,marker));
 statements.push(db.prepare('INSERT INTO usage_days(day,app,devices) SELECT ?,?,1 WHERE '+condition+' ON CONFLICT(day,app) DO UPDATE SET devices=devices+1').bind(r.day,r.app,r.day,hash,marker));
 for(const [name,value] of Object.entries(r.counts))statements.push(db.prepare('INSERT INTO usage_events(day,app,name,total,devices) SELECT ?,?,?,?,1 WHERE '+condition+' ON CONFLICT(day,app,name) DO UPDATE SET total=total+excluded.total,devices=devices+1').bind(r.day,r.app,name,value,r.day,hash,marker));
 for(const [name,value] of Object.entries(r.state))statements.push(db.prepare('INSERT INTO usage_states(day,app,name,value,devices) SELECT ?,?,?,?,1 WHERE '+condition+' ON CONFLICT(day,app,name,value) DO UPDATE SET devices=devices+1').bind(r.day,r.app,name,value,r.day,hash,marker));
 statements.push(db.prepare('UPDATE usage_dedup SET marker=NULL WHERE day=? AND digest=? AND marker=?').bind(r.day,hash,marker));
 await db.batch(statements); // D1 batch is transactional; a failed statement rolls everything back.
 return await db.prepare('SELECT 1 FROM usage_dedup WHERE day=? AND digest=?').bind(r.day,hash).first()?204:429;
}
export default {
 async fetch(request,env){
  if(new URL(request.url).pathname!=='/v1/usage')return reply(404);
  if(request.method!=='POST')return reply(405);
  if(!env.HMAC_KEY||env.HMAC_KEY.length<43)return reply(503);
  // A constant key: neither IP nor User-Agent enters storage or limiter keys.
  if(!(await env.LIMIT.limit({key:'all-reports'})).success)return reply(429);
  let r;try{if(!request.headers.get('content-type')?.startsWith('application/json'))return reply(415);r=validate(await boundedBody(request));}catch{return reply(400);}
  try{return reply(await store(env.DB,r,await digest(env.HMAC_KEY,r.day,r.batch)));}catch{return reply(503);}
 },
 async scheduled(event,env){
  await env.DB.batch([env.DB.prepare('DELETE FROM usage_dedup WHERE expires<=?').bind(Date.now()),env.DB.prepare('DELETE FROM usage_quota WHERE day<?').bind(new Date(Date.now()-2*DAY).toISOString().slice(0,10))]);
 }
};
