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
