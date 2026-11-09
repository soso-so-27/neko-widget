// Owner-approved 1109d fields only. No credentials or raw API results in output.
import {spawnSync} from 'node:child_process';
import {createPrivateKey,sign} from 'node:crypto';
import {readFileSync,mkdtempSync,mkdirSync,writeFileSync,readdirSync} from 'node:fs';
import {isDeepStrictEqual} from 'node:util';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
import {pathToFileURL} from 'node:url';

const root=resolve('NekoWidget/ci/asc-metadata-1109d');
const scopes={localizations:['app-info/ja.json','version/1.0/ja.json'],categories:['categories.json'],'age-rating':['age-rating.json'],'review-information':['review-information.json']};
function expected(files){
  return files.flatMap(file=>Object.entries(JSON.parse(readFileSync(join(root,file),'utf8'))).map(([field,value])=>({
    scope:file.startsWith('app-info/')?'app-info':file.startsWith('version/')?'version':file.replace('.json',''),
    locale:file.includes('/')?'ja':'',field,value:String(value),version:file.startsWith('version/')?'1.0':undefined,
  })));
}
export function checkPlan(plan,allowed){
  if(!plan.dryRun || !Array.isArray(plan.adds) || !Array.isArray(plan.updates) || (plan.deletes?.length??0)) throw Error('STOP_SCOPE');
  const changes=[...plan.adds,...plan.updates];
  for(const c of changes){
    if(!allowed.some(a=>a.scope===c.scope && a.field===c.field && (c.locale??'')===a.locale && (!a.version||c.version===a.version) && c.to===a.value)) throw Error('STOP_SCOPE');
  }
  return changes.map(c=>({scope:c.scope,field:c.field,locale:c.locale||undefined}));
}
function main(){
  const mode=process.argv[2]; if(!['--dry-run','--apply'].includes(mode)) throw Error('STOP_MODE');
  const env={...process.env,ASC_TELEMETRY_DISABLED:'1',DO_NOT_TRACK:'1'};
  function call(args){
    const r=spawnSync('asc',args,{env,encoding:'utf8',timeout:240000,maxBuffer:32*1024*1024});
    let obj;try{obj=JSON.parse(r.stdout);}catch{}
    if(r.error||r.status!==0||!obj){
      const all=(r.stderr??'')+(r.stdout??'');
      const permission=/\b(401|403|FORBIDDEN|NOT_AUTHORIZED)\b/i.test(all);
      const code=all.match(/\b(401|403|409|422|429|500|502|503)\b/)?.[1]??'unknown';
      console.log(JSON.stringify({operation:args.slice(0,2).join(' '),HTTP:code,permissionDenied:permission,
        fieldHints:['whatsNew','subtitle','description','keywords','promotionalText','supportUrl','notes','demoAccountRequired'].filter(f=>all.includes(f)),
        completedActions:obj?.actions?.map(a=>({scope:a.scope,status:a.status}))??[]}));
      throw Error(permission?'STOP_PERMISSION':'STOP_API');
    }
    return obj;
  }
  if(call(['telemetry','status']).enabled!==false) throw Error('STOP_TELEMETRY');
  const now=Math.floor(Date.now()/1000), b=x=>Buffer.from(JSON.stringify(x)).toString('base64url');
  const payload=b({alg:'ES256',kid:env.APP_STORE_CONNECT_KEY_ID,typ:'JWT'})+'.'+b({iss:env.APP_STORE_CONNECT_ISSUER_ID,iat:now,exp:now+1200,aud:'appstoreconnect-v1'});
  const key=createPrivateKey(Buffer.from(env.APP_STORE_CONNECT_PRIVATE_KEY_BASE64,'base64'));
  env.ASC_BEARER_TOKEN=payload+'.'+sign('sha256',Buffer.from(payload),{key,dsaEncoding:'ieee-p1363'}).toString('base64url');
  for(const k of Object.keys(env)) if(k.startsWith('APP_STORE_CONNECT_')||k.startsWith('OWNER_INTERNAL_')) delete env[k];
  const apps=call(['apps','list','--name','ねこのまど','--output','json']).data?.filter(a=>a.attributes?.name==='ねこのまど');
  if(apps?.length!==1)throw Error('STOP_IDENTITY');
  const app=apps[0].id;
  function snapshot(scope){
    const dir=mkdtempSync(join(tmpdir(),'asc-before-after-'));
    call(['metadata','pull','--app',app,'--version','1.0','--platform','IOS','--dir',dir,'--include',scope,'--output','json']);
    const values={};
    function walk(path,prefix=''){
      for(const e of readdirSync(path,{withFileTypes:true})){
        const name=prefix+e.name;
        if(e.isDirectory())walk(join(path,e.name),name+'/');
        else if(name.endsWith('.json'))values[name]=JSON.parse(readFileSync(join(path,e.name),'utf8'));
      }
    }
    walk(dir);return values;
  }
  function runScope(scope,files,probe=false){
    const dir=mkdtempSync(join(tmpdir(),'asc-approved-'));
    for(const file of files){const dest=join(dir,file);mkdirSync(resolve(dest,'..'),{recursive:true});writeFileSync(dest,readFileSync(join(root,file)),{mode:0o600});}
    const args=['metadata','apply','--app',app,'--version','1.0','--platform','IOS','--dir',dir,'--include',scope,'--output','json'];
    const plan=call([...args,'--dry-run']);
    const changes=checkPlan(plan,expected(files));
    console.log(JSON.stringify({dryRun:true,scope,probe,changes}));
    if(mode==='--apply'&&changes.length){
      const before=snapshot(scope);
      if(scope==='localizations'&&before['version/1.0/ja.json']?.marketingUrl)throw Error('STOP_SCOPE');
      call(args);
      if(checkPlan(call([...args,'--dry-run']),expected(files)).length)throw Error('STOP_READBACK');
      const after=snapshot(scope);
      for(const file of new Set([...Object.keys(before),...Object.keys(after)])){
        const writable=files.includes(file)?Object.keys(JSON.parse(readFileSync(join(root,file),'utf8'))):[];
        for(const field of new Set([...Object.keys(before[file]??{}),...Object.keys(after[file]??{})])){
          if(!writable.includes(field)&&!isDeepStrictEqual(before[file]?.[field]??'',after[file]?.[field]??''))throw Error('STOP_SCOPE');
        }
      }
      console.log(JSON.stringify({applied:true,scope,probe,readbackMatches:true}));
    }
  }
  // Probe one explicitly approved field before any multi-field operation.
  runScope('localizations',['app-info/ja.json'],true);
  for(const [scope,files] of Object.entries(scopes)){
    runScope(scope,files);
    if(scope==='age-rating' && mode==='--apply'){
      const rating=call(['apps','info','list','--app',app,'--output','json']);
      const codes=[...new Set((rating.data??[]).map(x=>x.attributes?.appStoreAgeRating).filter(x=>/^(FOUR|NINE|TWELVE|THIRTEEN|SIXTEEN|SEVENTEEN|EIGHTEEN)_PLUS$/.test(x??'')))];
      console.log(JSON.stringify({ageRatingCodes:codes}));
      if(codes.some(x=>['SEVENTEEN_PLUS','EIGHTEEN_PLUS'].includes(x)))throw Error('STOP_AGE_RATING');
    }
  }
  // Content-rights has no native dry-run flag: this wrapper plans that one field.
  const desired='DOES_NOT_USE_THIRD_PARTY_CONTENT';
  const currentApp=call(['apps','list','--name','ねこのまど','--output','json']).data?.find(a=>a.id===app);
  if(!currentApp)throw Error('STOP_IDENTITY');
  const oldRights=currentApp.attributes.contentRightsDeclaration;
  if(oldRights&&!['DOES_NOT_USE_THIRD_PARTY_CONTENT','USES_THIRD_PARTY_CONTENT'].includes(oldRights))throw Error('STOP_SCOPE');
  console.log(JSON.stringify({dryRun:true,scope:'app',field:'contentRightsDeclaration',from:oldRights??null,to:desired}));
  if(mode==='--apply' && oldRights!==desired){
    call(['apps','update','--id',app,'--content-rights',desired,'--output','json']);
    const after=call(['apps','list','--name','ねこのまど','--output','json']).data?.find(a=>a.id===app);
    if(after?.attributes?.contentRightsDeclaration!==desired)throw Error('STOP_READBACK');
    const beforeAttrs={...currentApp.attributes},afterAttrs={...after.attributes};
    delete beforeAttrs.contentRightsDeclaration;delete afterAttrs.contentRightsDeclaration;
    if(!isDeepStrictEqual(beforeAttrs,afterAttrs))throw Error('STOP_SCOPE');
    console.log(JSON.stringify({applied:true,scope:'content-rights',readbackMatches:true}));
  }
}
if(process.argv[1]&&import.meta.url===pathToFileURL(process.argv[1]).href){
  try{main();}catch(e){console.error(/^STOP_[A-Z_]+$/.test(e.message)?e.message:'STOP_UNEXPECTED');process.exitCode=1;}
}
