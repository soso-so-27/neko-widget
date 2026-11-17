import {afterEach,expect,it,vi} from 'vitest';
import worker,{type Env} from '../src/index';
import {ServiceError} from '../src/contracts';
import {logPutRefusal} from '../src/put-refusal';
afterEach(()=>vi.restoreAllMocks());
const request=(method='PUT',path='/v1/records/private-record')=>new Request('https://private.invalid'+path+'?owner=private-owner',
 {method,headers:{authorization:'Bearer private-token'},...(method==='PUT'?{body:'private-photo-and-note'}:{})});
it('logs one fixed refusal at the real fetch boundary without parsing an upload',async()=>{
 const spy=vi.spyOn(console,'warn').mockImplementation(()=>{});
 const response=await worker.fetch(request(),{PRESERVATION_ENABLED:'NO'} as Env);
 expect(response.status).toBe(503);
 expect(spy.mock.calls).toEqual([[JSON.stringify({code:'PRESERVATION_DISABLED',stage:'runtime_gate',status:503})]]);
});
it('never records arbitrary codes, exception messages, names or prototypes',()=>{
 const spy=vi.spyOn(console,'warn').mockImplementation(()=>{});
 for(const error of [new Error('private-owner private-token'),new ServiceError('PRIVATE_PHOTO_CONTENT'),new ServiceError('constructor')])logPutRefusal(request(),error);
 expect(spy.mock.calls.map(c=>JSON.parse(c[0]))).toEqual([
  {code:'PRESERVATION_UNAVAILABLE',stage:'unclassified',status:503},
  {code:'PRESERVATION_UNAVAILABLE',stage:'unclassified',status:400},
  {code:'PRESERVATION_UNAVAILABLE',stage:'unclassified',status:400}]);
 expect(JSON.stringify(spy.mock.calls)).not.toMatch(/private|PRIVATE|constructor/u);
});
it('classifies JPEG validation without inventing a dimension failure the provider does not expose',()=>{
 const spy=vi.spyOn(console,'warn').mockImplementation(()=>{});
 logPutRefusal(request(),new ServiceError('INVALID_JPEG'));
 expect(spy.mock.calls).toEqual([[JSON.stringify({code:'INVALID_JPEG',stage:'jpeg_validation',status:400})]]);
});
it('logs neither other routes nor methods and logging failures do not affect control flow',()=>{
 const spy=vi.spyOn(console,'warn').mockImplementation(()=>{});
 logPutRefusal(request('GET'),new ServiceError('SESSION_INVALID',401));
 logPutRefusal(request('POST','/v1/auth/sessions'),new ServiceError('SESSION_INVALID',401));
 logPutRefusal(request('PUT','/unknown'),new Error('private'));
 expect(spy).not.toHaveBeenCalled();
 spy.mockImplementation(()=>{throw new Error('console unavailable');});
 expect(()=>logPutRefusal(request(),new ServiceError('INVALID_JPEG'))).not.toThrow();
});
