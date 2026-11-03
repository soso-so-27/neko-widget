import {describe,it,expect} from 'vitest';
import {acceptIdentityFence,lookupIdentityFence,personIsFenced} from '../src/group-identity-fence';
import {randomBase64url} from '../src/encoding';
import {testEnv,db,person} from './group-fixture';
describe('A1 independent fence and receipt primitive, before routing',()=>{
  it('recovers a lost fence write, binds the receipt and never restarts the deletion clock',async()=>{
    const p=await person(),q=await person(),bucket=testEnv.MEDIA!,id=crypto.randomUUID(),receipt=randomBase64url(32),requestHash=randomBase64url(32),now=12345;
    const lost=new Proxy(bucket,{get(b,k){if(k==='put')return async(key:string,v:string,opts:R2PutOptions)=>{
      if(key.includes('/people/'))throw Error('synthetic interruption');return b.put(key,v,opts);
    }; const x=Reflect.get(b,k);return typeof x==='function'?x.bind(b):x;}});
    await expect(acceptIdentityFence(lost,p.id,id,receipt,requestHash,now)).rejects.toThrow('synthetic interruption');
    await expect(lookupIdentityFence(bucket,id,randomBase64url(32))).rejects.toMatchObject({status:404});
    expect(await personIsFenced(bucket,p.id)).toBe(false);
    expect(await lookupIdentityFence(bucket,id,receipt)).toMatchObject({requestId:id,acceptedAt:now,state:'processing',completedAt:null});
    expect(await personIsFenced(bucket,p.id)).toBe(true);expect(await personIsFenced(bucket,q.id)).toBe(false);
    expect((await acceptIdentityFence(bucket,p.id,id,receipt,requestHash,now+86400)).acceptedAt).toBe(now);
    await expect(acceptIdentityFence(bucket,p.id,id,randomBase64url(32),requestHash,now)).rejects.toMatchObject({status:409});
    await expect(acceptIdentityFence(bucket,q.id,id,receipt,requestHash,now)).rejects.toMatchObject({status:409});
    await expect(acceptIdentityFence(bucket,p.id,id,receipt,randomBase64url(32),now)).rejects.toMatchObject({status:409});
    const locator=await (await bucket.get('group-identity-deletions/v1/requests/'+id))!.text();
    expect(locator).not.toContain(receipt);expect(locator).not.toContain(p.id);
    expect(await db.prepare('SELECT state FROM group_people WHERE id=?').bind(p.id).first('state')).toBe('active');
    // As in a restored D1 snapshot, this row is active. The independent R2
    // check still denies the subject. This is not a test of all public routes.
    expect(await personIsFenced(bucket,p.id)).toBe(true);
  });
});