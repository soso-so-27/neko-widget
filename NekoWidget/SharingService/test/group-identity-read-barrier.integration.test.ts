import {describe,it,expect} from 'vitest';
import {checkedDeletionRead} from '../src/group-identity-read-barrier';
import {testEnv,db} from './group-fixture';

describe('A1 independent restore boundary, synthetic before routing',()=>{
  it('withholds a third person’s response across old snapshots, missing control, or concurrent acceptance',async()=>{
    const store=testEnv.MEDIA!, key='group-identity-deletions/v1/control';
    const genesis={sequence:0,requestId:''}, tip={sequence:1,requestId:crypto.randomUUID()};
    const apply=(t:{sequence:number;requestId:string})=>db.prepare('INSERT OR REPLACE INTO group_identity_deletion_checkpoint VALUES (1,?,?)').bind(t.sequence,t.requestId).run();
    await apply(genesis);
    const read=()=>checkedDeletionRead(db,store,async()=>'other family data');
    await expect(read()).rejects.toMatchObject({status:503});
    await store.put(key,JSON.stringify(genesis));expect(await read()).toBe('other family data');
    await expect(checkedDeletionRead(db,store,async()=>{
      await store.put(key,JSON.stringify(tip));return 'stale subject data';
    })).rejects.toMatchObject({status:503});
    await expect(read()).rejects.toMatchObject({status:503});
    await apply(tip);expect(await read()).toBe('other family data');
    await apply(genesis);await expect(read()).rejects.toMatchObject({status:503});
    await apply({...tip,requestId:crypto.randomUUID()});await expect(read()).rejects.toMatchObject({status:503});
  });
});
