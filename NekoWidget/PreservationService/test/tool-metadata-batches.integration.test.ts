import {expect,it,vi} from 'vitest';
import {randomToken,sha256} from '../src/contracts';
import {route,type Services} from '../src/index';
import {fixture,finish,db,base,encoder} from './tool-metadata-batch-fixture';

it('accepts a progressing metadata part that needs more than five seconds at the authenticated route',async()=>{
  const batchId=crypto.randomUUID(),partId=crypto.randomUUID(),token=randomToken();
  const bytes=new Uint8Array(512*1024).fill(32);
  const authorize=vi.fn(async()=>({ownerId:crypto.randomUUID(),sessionHash:'test',expiresAt:Date.now()+1000}));
  const stage=vi.fn(async()=>({status:'part-staged'}));
  vi.useFakeTimers({toFake:['setTimeout','clearTimeout','performance']});
  try {
    let stream!:ReadableStreamDefaultController<Uint8Array>;
    let started!:()=>void;
    const reading=new Promise<void>(resolve=>{started=resolve;});
    const body=new ReadableStream<Uint8Array>({start(controller){stream=controller;},pull(){started();}},
      {highWaterMark:0});
    const request=new Request(`https://preservation.test/v1/tool-metadata-batches/${batchId}/parts/${partId}`,{
      method:'PUT',headers:{authorization:`Bearer ${token}`,'content-type':'application/json'},body,
      duplex:'half',
    } as RequestInit);
    const services={
      auth:{requireToolMetadataBatchSession:authorize},archive:{stageMetadataBatch:stage},
    } as unknown as Services;
    const response=route(request,services);
    const staged=expect(response.then(value=>value.json())).resolves.toMatchObject({status:'part-staged'});
    const end=bytes.length/2;
    await Promise.race([reading,response]);
    await vi.advanceTimersByTimeAsync(3000);
    stream.enqueue(bytes.slice(0,end));
    await vi.advanceTimersByTimeAsync(3000);
    stream.enqueue(bytes.slice(end));
    stream.close();
    await staged;
    expect(authorize).toHaveBeenCalledWith(token,batchId);
    expect(stage).toHaveBeenCalledWith(token,batchId,partId,bytes);
  }finally{vi.useRealTimers();}
});
it('direct probe: stages three immutable parts, resumes after new instances, publishes one union and preserves head boundary',async()=>{
  const f=await fixture(),before=new Map([...f.objects].map(([key,value])=>[key,value.body.slice()]));
  const baseline=await db.prepare('SELECT count(*) n FROM pa_owner_recovery_versions WHERE owner_id=?').bind(f.session.ownerId).first<{n:number}>();
  await f.archive().beginMetadataBatch(f.session.token,f.manifest);
  await f.archive().stageMetadataBatch(f.session.token,f.batchId,f.parts[0]!.id,f.parts[0]!.body);
  await expect(f.auth.requireSession(f.session.token)).rejects.toThrow();
  await expect(f.archive().finishMetadataBatch(f.session.token,f.batchId)).rejects.toMatchObject({code:'TOOL_METADATA_BATCH_INCOMPLETE'});
  await f.archive().beginMetadataBatch(f.session.token,f.manifest);
  for(const part of f.parts)expect((await f.archive().stageMetadataBatch(f.session.token,f.batchId,part.id,part.body)).status).toBe('part-staged');
  expect(await finish(f)).toBeGreaterThan(1);
  await f.auth.requireSession(f.session.token);
  expect((await db.prepare('SELECT count(*) n FROM pa_owner_recovery_versions WHERE owner_id=?').bind(f.session.ownerId).first<{n:number}>())!.n).toBe(baseline!.n+1);
  const head=await db.prepare('SELECT count(*) n FROM pa_records WHERE owner_id=? AND record_id NOT IN (?,?,?)')
    .bind(f.session.ownerId,...f.parts.map(p=>p.id)).first<{n:number}>();expect(head!.n).toBe(0);
  for(const [key,value]of before)expect(f.objects.get(key)!.body).toEqual(value);
  const headId=crypto.randomUUID();
  await f.archive().put(f.session.token,headId,{document:{...base,formatVersion:1,text:JSON.stringify({kind:'app-records-v1',snapshotID:f.parts[2]!.id,indexHash:f.parts[2]!.document.toolBackup.sha256})},
    photoBase64:null,expectedRevision:null,consentVersion:'managed-preservation-v1'});
  expect((await f.archive().read(f.session.token,headId)).revision).toBe(1);
  expect((await db.prepare('SELECT count(*) n FROM pa_owner_delta_work WHERE owner_id=?').bind(f.session.ownerId).first<{n:number}>())!.n).toBe(0);
},60_000);

it('rejects changed manifest/body, foreign owner, head/photo/edit payload and expired session',async()=>{
  const f=await fixture();await f.archive().beginMetadataBatch(f.session.token,f.manifest);
  await expect(f.archive().beginMetadataBatch(f.session.token,{...f.manifest,items:[{...f.parts[0]!.descriptor,bodySHA256:'0'.repeat(64)}]})).rejects.toMatchObject({code:'TOOL_METADATA_BATCH_CHANGED'});
  await expect(f.archive().stageMetadataBatch(f.session.token,f.batchId,f.parts[0]!.id,encoder.encode('{}'))).rejects.toMatchObject({code:'INVALID_TOOL_METADATA_BATCH'});
  const other=await f.auth.establish({issuer:'https://appleid.apple.com',subject:crypto.randomUUID(),refreshToken:randomToken()});
  await expect(f.archive().stageMetadataBatch(other.token,f.batchId,f.parts[0]!.id,f.parts[0]!.body)).rejects.toThrow();
  for(const patch of [{expectedRevision:1},{photoBase64:'AA=='},{document:{...base,formatVersion:1}}]){
    const id=crypto.randomUUID(),batchId=crypto.randomUUID(),body=encoder.encode(JSON.stringify({...JSON.parse(new TextDecoder().decode(f.parts[0]!.body)),...patch}));
    await f.archive().beginMetadataBatch(f.session.token,{batchId,items:[{recordId:id,bodySHA256:await sha256(body)}]});
    await expect(f.archive().stageMetadataBatch(f.session.token,batchId,id,body)).rejects.toThrow();
  }
  f.advance();await expect(f.auth.requireToolMetadataBatchSession(f.session.token,f.batchId)).rejects.toThrow();
},60_000);
