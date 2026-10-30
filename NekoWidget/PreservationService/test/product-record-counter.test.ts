import {expect,it} from 'vitest';
import {productRecordCounter} from '../src/product-record-counter';
function count(tool:string,json:string,step=7){
  const counter=productRecordCounter(tool),bytes=new TextEncoder().encode(json);
  for(let at=0;at<bytes.length;at+=step)counter.write(bytes.slice(at,at+step));
  return counter.finish();
}
it('streams UTF-8 and escaped strings across boundaries and counts visible containers, including old arrays',()=>{
  expect(count('PhotoMemoryNotes',JSON.stringify({schemaVersion:4,notes:{a:{text:'ねこ🐈\\\"'},b:{text:'two'}}}))).toBe(2);
  expect(count('PhotoMemoryNotes','{"notes":{}}')).toBe(0);
  expect(count('PhotoMemoryNotes','{"futureNotes":{}}')).toBeNull();
  expect(count('PhotoMemoryNotes','{"schemaVersion":999,"notes":{}}')).toBeNull();
  expect(count('PhotoMemoryNotes','{"notes":{"a":1,"a":2}}')).toBe(1);
  expect(count('VeterinaryVisits','{"schema":1,"visits":[{"entries":[1,2]},{}]}')).toBe(2);
  expect(count('CareHandoff','{"cats":[{},{}],"contact":"x"}')).toBe(2);
  expect(count('ShowcasePhotos','[{},{}]')).toBe(2);
  expect(count('ShowcasePhotos','{"entries":[{},{}],"scopes":{}}')).toBe(2);
  expect(count('LostCatDrafts','{"a":{},"b":{}}')).toBe(2);
  expect(count('CatIdentity','{"schemaVersion":1,"profiles":[{},{}]}')).toBe(0);
});
it('does not turn corrupt or ambiguous JSON into a completed count',()=>{
  for(const text of ['{"notes":','{"notes":{}}{}','{"notes":{},"notes":{}}']){
    expect(()=>count('PhotoMemoryNotes',text)).toThrow();
  }
  expect(()=>count('PhotoMemoryNotes','{"notes":{"a":'+ '['.repeat(65))).toThrow();
});
it('counts care rows and notebook stable records, not revisions, ACKs or removed children',()=>{
  const cat={catID:'cat',weights:[{id:'w'},{id:'deleted',deletedAt:'today'}],medications:[],vaccinations:[],meals:[]};
  expect(count('CatCare',JSON.stringify({schemaVersion:1,cats:[cat,{...cat,catID:'removed-cat',deletedAt:'today'}]}))).toBe(2);
  const target=(collection:string,recordID?:string,field:string|null='text',parentRecordID?:string)=>({target:{familyCatID:'cat',collection,recordID,field,parentRecordID}});
  const operations=[target('cat',undefined,'name'),target('cat',undefined,'name'),target('weight','w'),target('weight','w'),
    target('visit','v'),target('visitEntry','entry','text','v'),target('visit','v',null),
    target('handoff','h'),target('handoffMeal','meal','food','h'),target('handoffMeal','meal',null,'h')];
  const manifest={version:1,copies:[{id:'copy',state:{schemaVersion:1,operations,outboxIDs:['op'],acknowledgements:[{}]}}]};
  expect(count('FamilyNotebook',JSON.stringify(manifest))).toBe(3);
  manifest.copies[0]!.state.operations.push(target('cat',undefined,null));
  expect(count('FamilyNotebook',JSON.stringify(manifest))).toBe(0);
  expect(count('FamilyNotebook','{"version":1,"copies":[]}')).toBe(0);
  expect(count('FamilyNotebook','{"version":2,"copies":[]}')).toBeNull();
  expect(count('FamilyNotebook','{"version":1,"copies":[{"id":"copy","state":{"schemaVersion":3,"operations":[]}}]}')).toBeNull();
});
