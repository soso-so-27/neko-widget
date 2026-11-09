// Owner-approved 1109d fields only. No credentials or raw API results in output.
import {spawnSync} from 'node:child_process';
import {createPrivateKey,sign} from 'node:crypto';
import {readFileSync,mkdtempSync,mkdirSync,writeFileSync,readdirSync} from 'node:fs';
import {isDeepStrictEqual} from 'node:util';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
import {pathToFileURL} from 'node:url';
import {safeText,validationSummary} from './asc-readonly.mjs';

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
export function errorDetails(stdout,stderr,secrets=[]){
  const clean=value=>safeText(value,secrets).replace(/\b[A-Z0-9]{10}\b/g,'[ID]').replace(/eyJ[\w.-]+/g,'[token]');
  const found=[];
  function visit(value){
    if(typeof value==='string'){
      try{visit(JSON.parse(value));}catch{
        if(value.includes('PRIVATE KEY')) found.push({code:'CLI_ERROR',title:'[redacted]',detail:'[redacted credential diagnostic]'});
        else if(value.trim())found.push({code:'CLI_ERROR',title:'CLI diagnostic',detail:clean(value)});
      }
    }else if(Array.isArray(value))value.forEach(visit);
    else if(value&&typeof value==='object'){
      if(value.code||value.title||value.detail)found.push(Object.fromEntries(['code','title','detail'].map(k=>[k,clean(value[k]??'unavailable')])));
      for(const k of ['errors','error','cause'])if(value[k])visit(value[k]);
      for(const a of value.actions??[])if(a.error)visit(a.error);
    }
  }
  try{visit(JSON.parse(stdout));}catch{}
  if(stderr?.trim())visit(stderr);
  return found.slice(0,8);
}
export function runGroups(groups,report=console.log){
  const failed=[];
  for(const [name,action] of groups){
    try{action();report(JSON.stringify({group:name,status:'completed'}));}
    catch(e){
      // Only an ordinary API refusal is local. Unknown write impact, identity,
      // permissions, readback and age boundaries always stop every group.
      if(e.message!=='STOP_API')throw e;
      failed.push(name);report(JSON.stringify({group:name,status:'failed',reason:e.message}));
    }
  }
  return failed;
}
export function permissionFailure(text){
  return /\b(?:401|403)\b|\b(?:FORBIDDEN|NOT_AUTHORIZED|NOT_AUTHENTICATED|UNAUTHORIZED|AUTHENTICATION_ERROR|INSUFFICIENT_PERMISSIONS)(?:\b|_)/i.test(text);
}
function main(){
  const mode=process.argv[2]; if(!['--dry-run','--apply','--validate'].includes(mode)) throw Error('STOP_MODE');
  const env={...process.env,ASC_TELEMETRY_DISABLED:'1',DO_NOT_TRACK:'1'};
  const sensitive=[env.APP_STORE_CONNECT_KEY_ID,env.APP_STORE_CONNECT_ISSUER_ID,env.APP_STORE_CONNECT_PRIVATE_KEY_BASE64];
  function call(args,allowFindings=false){
    const r=spawnSync('asc',args,{env,encoding:'utf8',timeout:240000,maxBuffer:32*1024*1024});
    let obj;try{obj=JSON.parse(r.stdout);}catch{}
    if(r.error||!obj||(r.status!==0&&!(allowFindings&&Array.isArray(obj.checks)))){
      const all=(r.stderr??'')+(r.stdout??'');
      const permission=permissionFailure(all);
      const code=all.match(/\b(401|403|409|422|429|500|502|503)\b/)?.[1]??'unknown';
      console.log(JSON.stringify({operation:args.slice(0,2).join(' '),HTTP:code,permissionDenied:permission,
        fieldHints:['whatsNew','subtitle','description','keywords','promotionalText','supportUrl','notes','demoAccountRequired'].filter(f=>all.includes(f)),
        completedActions:obj?.actions?.map(a=>({scope:a.scope,status:a.status}))??[],errors:errorDetails(r.stdout,r.stderr,sensitive)}));
      throw Error(permission?'STOP_PERMISSION':'STOP_API');
    }
    return obj;
  }
  if(call(['telemetry','status']).enabled!==false) throw Error('STOP_TELEMETRY');
  const now=Math.floor(Date.now()/1000), b=x=>Buffer.from(JSON.stringify(x)).toString('base64url');
  const payload=b({alg:'ES256',kid:env.APP_STORE_CONNECT_KEY_ID,typ:'JWT'})+'.'+b({iss:env.APP_STORE_CONNECT_ISSUER_ID,iat:now,exp:now+1200,aud:'appstoreconnect-v1'});
  const key=createPrivateKey(Buffer.from(env.APP_STORE_CONNECT_PRIVATE_KEY_BASE64,'base64'));
  env.ASC_BEARER_TOKEN=payload+'.'+sign('sha256',Buffer.from(payload),{key,dsaEncoding:'ieee-p1363'}).toString('base64url');
  sensitive.push(env.ASC_BEARER_TOKEN);
  for(const k of Object.keys(env)) if(k.startsWith('APP_STORE_CONNECT_')||k.startsWith('OWNER_INTERNAL_')) delete env[k];
  const apps=call(['apps','list','--name','ねこのまど','--output','json']).data?.filter(a=>a.attributes?.name==='ねこのまど');
  if(apps?.length!==1)throw Error('STOP_IDENTITY');
  const app=apps[0].id;
  sensitive.push(app);
  if(mode==='--validate'){
    const report=call(['validate','--app',app,'--version','1.0','--output','json'],true);
    console.log('VALIDATION '+JSON.stringify(validationSummary(report,[app,process.env.APP_STORE_CONNECT_KEY_ID,process.env.APP_STORE_CONNECT_ISSUER_ID])));
    return;
  }
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
      let writeError;
      try{call(args);}catch(e){writeError=e;}
      // Inspect even partial failures before allowing a later group to write.
      const after=snapshot(scope);
      for(const file of new Set([...Object.keys(before),...Object.keys(after)])){
        const writable=files.includes(file)?Object.keys(JSON.parse(readFileSync(join(root,file),'utf8'))):[];
        for(const field of new Set([...Object.keys(before[file]??{}),...Object.keys(after[file]??{})])){
          if(!writable.includes(field)&&!isDeepStrictEqual(before[file]?.[field]??'',after[file]?.[field]??''))throw Error('STOP_SCOPE');
          if(writable.includes(field)&&!isDeepStrictEqual(before[file]?.[field],after[file]?.[field])
             &&!isDeepStrictEqual(after[file]?.[field],JSON.parse(readFileSync(join(root,file),'utf8'))[field]))throw Error('STOP_SCOPE');
        }
      }
      if(writeError)throw writeError;
      if(checkPlan(call([...args,'--dry-run']),expected(files)).length)throw Error('STOP_READBACK');
      console.log(JSON.stringify({applied:true,scope,probe,readbackMatches:true}));
    }
  }
  const groups=Object.entries(scopes).map(([scope,files])=>[scope,()=>{
    try{runScope(scope,files);}finally{
    if(scope==='age-rating' && mode==='--apply'){
      const rating=call(['apps','info','list','--app',app,'--output','json']);
      const codes=[...new Set((rating.data??[]).map(x=>x.attributes?.appStoreAgeRating).filter(x=>/^(FOUR|NINE|TWELVE|THIRTEEN|SIXTEEN|SEVENTEEN|EIGHTEEN)_PLUS$/.test(x??'')))];
      console.log(JSON.stringify({ageRatingCodes:codes}));
      if(codes.some(x=>['SEVENTEEN_PLUS','EIGHTEEN_PLUS'].includes(x)))throw Error('STOP_AGE_RATING');
    }
    }
  }]);
  groups.push(['content-rights',()=>{
  // Content-rights has no native dry-run flag: this wrapper plans that one field.
  const desired='DOES_NOT_USE_THIRD_PARTY_CONTENT';
  const currentApp=call(['apps','list','--name','ねこのまど','--output','json']).data?.find(a=>a.id===app);
  if(!currentApp)throw Error('STOP_IDENTITY');
  const oldRights=currentApp.attributes.contentRightsDeclaration;
  if(oldRights&&!['DOES_NOT_USE_THIRD_PARTY_CONTENT','USES_THIRD_PARTY_CONTENT'].includes(oldRights))throw Error('STOP_SCOPE');
  console.log(JSON.stringify({dryRun:true,scope:'app',field:'contentRightsDeclaration',from:oldRights??null,to:desired}));
  if(mode==='--apply' && oldRights!==desired){
    let writeError;
    try{call(['apps','update','--id',app,'--content-rights',desired,'--output','json']);}catch(e){writeError=e;}
    const after=call(['apps','list','--name','ねこのまど','--output','json']).data?.find(a=>a.id===app);
    if(!after)throw Error('STOP_IDENTITY');
    const beforeAttrs={...currentApp.attributes},afterAttrs={...after.attributes};
    delete beforeAttrs.contentRightsDeclaration;delete afterAttrs.contentRightsDeclaration;
    if(!isDeepStrictEqual(beforeAttrs,afterAttrs))throw Error('STOP_SCOPE');
    if(writeError)throw writeError;
    if(after.attributes.contentRightsDeclaration!==desired)throw Error('STOP_READBACK');
    console.log(JSON.stringify({applied:true,scope:'content-rights',readbackMatches:true}));
  }
  }]);
  groups.push(['plus-localization',()=>{
    const products=call(['subscriptions','list','--app',app,'--include','subscriptionLocalizations','--paginate','--output','json']);
    const matches=products.data?.filter(x=>x.attributes?.productId==='jp.nekowidget.plus.monthly');
    if(matches?.length!==1)throw Error('STOP_IDENTITY');
    const product=matches[0];sensitive.push(product.id);
    const ids=new Set(product.relationships?.subscriptionLocalizations?.data?.map(x=>x.id)??[]);
    const existing=products.included?.filter(x=>ids.has(x.id)&&x.attributes?.locale==='ja')??[];
    if(existing.length>1)throw Error('STOP_IDENTITY');
    if(existing[0]?.attributes?.name&&existing[0]?.attributes?.description){
      console.log(JSON.stringify({scope:'plus-localization',status:'existing-nonempty-preserved',productState:product.attributes?.state}));return;
    }
    const versions=call(['subscriptions','versions','list','--subscription-id',product.id,'--paginate','--output','json']).data??[];
    const editable=versions.filter(x=>['PREPARE_FOR_SUBMISSION','MISSING_METADATA'].includes(x.attributes?.state));
    if(editable.length!==1){console.log(JSON.stringify({scope:'plus-localization',code:'EDITABLE_VERSION_UNRESOLVED',count:editable.length}));throw Error('STOP_API');}
    const version=editable[0].id;sensitive.push(version);
    const read=()=>call(['subscriptions','versions','localizations','list','--version-id',version,'--paginate','--output','json']).data??[];
    const before=read(),ja=before.filter(x=>x.attributes?.locale==='ja');
    if(ja.length>1)throw Error('STOP_IDENTITY');
    const desired={name:'ねこのまど Plus',description:'毎日の新しい 1 枚、月の作品、まどと家族の手帳、保存'};
    const fields=Object.keys(desired).filter(k=>!ja[0]?.attributes?.[k]);
    console.log(JSON.stringify({dryRun:true,scope:'plus-localization',locale:'ja',fields}));
    if(mode!=='--apply'||!fields.length)return;
    const args=ja[0]?['subscriptions','versions','localizations','update','--id',ja[0].id]
      :['subscriptions','versions','localizations','create','--version-id',version,'--locale','ja'];
    if(ja[0])sensitive.push(ja[0].id);
    for(const field of fields)args.push('--'+field,desired[field]);
    let writeError;try{call([...args,'--output','json']);}catch(e){writeError=e;}
    const after=read(),afterJa=after.filter(x=>x.attributes?.locale==='ja');
    for(const old of before){
      const current=after.find(x=>x.id===old.id);if(!current)throw Error('STOP_SCOPE');
      const a={...old.attributes},b={...current.attributes};
      if(old===ja[0])for(const field of fields){delete a[field];delete b[field];}
      if(!isDeepStrictEqual(a,b))throw Error('STOP_SCOPE');
    }
    if(after.some(x=>!before.some(old=>old.id===x.id)&&x.attributes?.locale!=='ja')||afterJa.length>1)throw Error('STOP_SCOPE');
    if(writeError)throw writeError;
    if(afterJa.length!==1||fields.some(k=>afterJa[0].attributes[k]!==desired[k]))throw Error('STOP_READBACK');
    console.log(JSON.stringify({applied:true,scope:'plus-localization',readbackMatches:true}));
  }]);
  const failed=runGroups(groups);
  console.log(JSON.stringify({failedGroups:failed}));
  if(failed.length)process.exitCode=1;
}
if(process.argv[1]&&import.meta.url===pathToFileURL(process.argv[1]).href){
  try{main();}catch(e){console.error(/^STOP_[A-Z_]+$/.test(e.message)?e.message:'STOP_UNEXPECTED');process.exitCode=1;}
}
