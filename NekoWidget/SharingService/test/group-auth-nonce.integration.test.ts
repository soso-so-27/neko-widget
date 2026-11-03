import {describe,expect,it} from 'vitest';
import {authenticateGroupRequest} from '../src/group-auth';
import {person,signed,send,testEnv,db} from './group-fixture';
import {randomBase64url} from '../src/encoding';

describe('group authentication claims the nonce before dispatch',()=>{
 it('admits exactly one of two concurrent valid requests',async()=>{
  const actor=await person(),nonce=randomBase64url(16),path='/v3/group-windows/list',body={after:null,limit:20};
  const requests=await Promise.all([signed(actor,path,body,nonce),signed(actor,path,body,nonce)]);
  const results=await Promise.allSettled(requests.map(request=>authenticateGroupRequest(request,testEnv)));
  expect(results.filter(result=>result.status==='fulfilled')).toHaveLength(1);
  const rejected=results.find(result=>result.status==='rejected') as PromiseRejectedResult;
  expect(rejected.reason).toMatchObject({status:401,code:'replay'});
  expect((await db.prepare('SELECT COUNT(*) AS n FROM group_request_nonces WHERE device_id=? AND nonce=?').bind(actor.deviceId,nonce).first<{n:number}>())?.n).toBe(1);
 });
 it('does not consume a nonce for a bad signature, but consumes authenticated handler failure',async()=>{
  const actor=await person(),nonce=randomBase64url(16),path='/v3/group-windows/list',body={unexpected:true};
  const bad=await signed(actor,path,body,nonce);bad.headers.set('neko-signature',randomBase64url(64));
  expect((await send(bad)).status).toBe(401);
  expect(await db.prepare('SELECT 1 FROM group_request_nonces WHERE device_id=? AND nonce=?').bind(actor.deviceId,nonce).first()).toBeNull();
  const rejected=await send(await signed(actor,path,body,nonce));expect(rejected.status).toBe(400);
  expect((await send(await signed(actor,path,body,nonce))).data.error.code).toBe('replay');
 });
 it('retains the claim when a later authorization transaction aborts',async()=>{
  const actor=await person(),nonce=randomBase64url(16),path='/v3/group-windows/list',body={after:null,limit:20};
  let batches=0;
  const failing=new Proxy(db,{get(target,key){
   if(key==='batch')return async(statements:D1PreparedStatement[])=>{batches++;return target.batch([...statements,target.prepare("SELECT json('synthetic rollback')")]);};
   const value=Reflect.get(target,key);return typeof value==='function'?value.bind(target):value;
  }});
  expect((await send(await signed(actor,path,body,nonce),{...testEnv,DB:failing})).status).toBe(500);
  expect(batches).toBe(1);
  expect((await send(await signed(actor,path,body,nonce))).data.error.code).toBe('replay');
 });

});
