// Owner-approved 1109d fields only. No credentials or raw API results in output.
import {spawnSync} from 'node:child_process';
import {createHash,createPrivateKey,sign} from 'node:crypto';
import {readFileSync,mkdtempSync,mkdirSync,writeFileSync,readdirSync} from 'node:fs';
import {isDeepStrictEqual} from 'node:util';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
import {pathToFileURL} from 'node:url';
import {safeText,validationSummary} from './asc-readonly.mjs';

const root=resolve('NekoWidget/ci/asc-metadata-1109d');
const scopes={localizations:['app-info/ja.json','version/1.0/ja.json'],categories:['categories.json'],'age-rating':['age-rating.json'],'review-information':['review-information.json']};
function expected(files,fields,directory){
  return files.flatMap(file=>Object.entries(JSON.parse(readFileSync(join(directory,file),'utf8'))).filter(([field])=>!fields||fields.includes(field)).map(([field,value])=>({
    scope:file.startsWith('app-info/')?'app-info':file.startsWith('version/')?'version':file.replace('.json',''),
    locale:file.includes('/')?'ja':'',field,value:String(value),version:file.startsWith('version/')?'1.0':undefined,
  })));
}
export function seasonalMovieAppMetadata(current,desired){
  if(typeof current?.description!=='string'||typeof current.keywords!=='string')throw Error('STOP_SCOPE');
  const movieSentence='季節のムービーもあります。';
  const movieBenefit='・月の作品、季節のムービー';
  let description=current.description;
  if(description!==desired.description){
    if(description.split(movieSentence).length!==2||description.split(movieBenefit).length!==2)throw Error('STOP_SCOPE');
    description=description.replace(movieSentence,'').replace(movieBenefit,'・月の作品、1年の作品');
    if(description!==desired.description)throw Error('STOP_SCOPE');
  }
  if(description.includes('ムービー'))throw Error('STOP_SCOPE');

  const tokens=current.keywords.split(',');
  const movieCount=tokens.filter(token=>token.trim()==='ムービー').length;
  const missingCatCount=tokens.filter(token=>token.trim()==='迷子').length;
  if(movieCount>1||missingCatCount>1||(!movieCount&&!missingCatCount))throw Error('STOP_SCOPE');
  const keywords=missingCatCount
    ? tokens.filter(token=>token.trim()!=='ムービー').join(',')
    : tokens.map(token=>token.trim()==='ムービー'?token.replace('ムービー','迷子'):token).join(',');
  return {description,keywords};
}
export function approvedDescriptionUpdate(current,desired){
  if(typeof current!=='string'||typeof desired!=='string')return false;
  if(current===desired)return true;
  // 1115c: owner approved exactly the three #1007 description edits.
  const reviewEdits=[["・写真とひとことは、まどの人だけが開ける鍵で暗号化して届けます。運営者は中身を読めません。", "・写真とひとことは、まどの人だけが開ける鍵で暗号化して届けます。運営者は中身を読めません。通報された写真だけは、確認用の画像を運営者が確かめます。"], ["・届ける前と表示する前に、iPhone の中で不適切な内容でないかを確かめます。困ったときは、通報やブロックができます。", "・iPhone の「センシティブな内容の警告」がオンのときは、届ける前と表示する前に、iPhone の中で確かめます。困ったときは、通報やブロックができます。"], ["Plus は 14 日間無料で試せます。お試しが終わると、月額 980 円（税込）で自動で更新されます。更新の 24 時間前までに解約すれば、料金はかかりません。解約は iPhone の「設定」→ Apple アカウント →「サブスクリプション」からできます。やめても、写真・まど・メモ・手帳の記録は消えません。Apple のファミリー共有には対応していません。", "Plus は 14 日間無料で試せます。お試しが終わると、月額 980 円（税込）で自動で更新されます。更新の 24 時間前までに解約すれば、料金はかかりません。解約は iPhone の「設定」→ Apple アカウント →「サブスクリプション」からできます。やめても、この iPhone の写真・メモ・まどの写真・手帳の記録は消えません。自動保存のコピーは、やめてから 12 か月後に消えます。Apple のファミリー共有には対応していません。"]];
  if(reviewEdits.every(([before])=>current.split(before).length===2)
      && reviewEdits.reduce((text,[before,after])=>text.replace(before,after),current)===desired)return true;
  // 1113d: remove exactly the former paid photo-memo bullet, and nothing else.
  const memo='・写真に新しいメモを書く\n';
  if(current.split(memo).length===2 && current.replace(memo,'')===desired)return true;
  const paragraph='季節のムービーもあります。',storage='（3GB・記録 3,000 件まで）';
  if(current.split(paragraph).length!==2||current.split(storage).length!==2)return false;
  return current.replace(paragraph,paragraph+'作品を開くのは Plus です（14 日間無料）。')
    .replace(storage,'（3GB・記録 3,000 件まで。お試し中は 250MB）')===desired;
}
// 1123: owner approved exactly these store-copy edits (description, promotional text, keywords, review notes).
// 1123n — keywords merged with the 7 words found in ASC (minus ホーム画面, which repeats the subtitle), entered manually by Codex.
// The previous text, verbatim, and the SHA-256 of the approved new text.
export const storeCopy1123Previous={"description":"ねこのまどは、iPhone の写真から猫の写真を見つけて、アルバムとホーム画面のウィジェットに出すアプリです。\n\n■ 探さなくても、猫の写真がそろう\n写真へのアクセスを許可すると、iPhone の中の猫の写真を見つけて並べます。猫かどうかの見分けは iPhone の中で行います。元の写真を動かしたり、消したりはしません。\n\n■ ホーム画面で、ふと目が合う\nウィジェットを置くと、猫の写真がホーム画面に出ます。新しい 1 枚は、くもったまどで届きます。札をタップすると晴れて、その日の 1 枚に会えます。毎日ちがう 1 枚に入れ替わります。\n\n■ 毎月 1 日に、先月の作品が届く\nその月の猫の写真から、本のように開ける「月の作品」をつくります。12 月には 1 年の作品も届きます。作品を開くのは Plus です（14 日間無料）。\n\n■ みんなのまどで、家族や猫友に届ける\n名前を付けたまどを作って、家族や猫友を招待します（1 つのまどに 6 人まで）。写真に短いひとことを添えて届けると、相手のホーム画面のウィジェットにも出せます。ハートで「見たよ」を返せます。\n・招待した人だけのまどです。公開のタイムライン、検索、フォローはありません。\n・写真とひとことは、まどの人だけが開ける鍵で暗号化して届けます。運営者は中身を読めません。通報された写真だけは、確認用の画像を運営者が確かめます。\n・iPhone の「センシティブな内容の警告」がオンのときは、届ける前と表示する前に、iPhone の中で確かめます。困ったときは、通報やブロックができます。\n\n■ のわのまど\nねこのまどの黒猫「のわ」の写真が、毎日 1 枚届きます。だれでも無料で受け取れます。\n\n■ 家族の手帳\n猫のごはん、薬、病院、預けるときのことを、家族で一緒に書けます。だれが書いても、家族みんなの iPhone に同じ記録がそろいます。中身は家族だけが開ける鍵で暗号化して届けます。\n\n■ 暮らしのツール（無料）\n猫の写真と「この子のこと」から、暮らしで使うものをつくれます。\n・写真を見せる：自慢の 9 枚を、人に見せたりスライドショーにしたり\n・病院で見せる：気付いたことと写真・動画・体重を、先生に見せる 1 画面に\n・預けるとき：お世話のお願いと毎日のチェック表を、PDF や文で渡せる\n・迷子のとき：チラシと SNS 用の画像、連絡したところの記録\n・避難に備える：持ち出すものと期限、見直しの時期のお知らせ、「いま避難する」画面\n\n■ ねこのまど Plus\n・月の作品、1年の作品\n・まどを作って、家族と写真を届け合う\n・家族の手帳を作る\n・猫のこと・メモ・ツールの記録を保存して、新しい iPhone に戻せる（3GB・記録 3,000 件まで。お試し中は 250MB）\n\n招待されてまどや家族の手帳に入る人は、無料です。\n\nPlus は 14 日間無料で試せます。お試しが終わると、月額 980 円（税込）で自動で更新されます。更新の 24 時間前までに解約すれば、料金はかかりません。解約は iPhone の「設定」→ Apple アカウント →「サブスクリプション」からできます。やめても、この iPhone の写真・メモ・まどの写真・手帳の記録は消えません。自動保存のコピーは、やめてから 12 か月後に消えます。Apple のファミリー共有には対応していません。\n\nプライバシーポリシー：https://nekonomado.com/privacy/ \n利用規約：https://www.apple.com/legal/internet-services/itunes/dev/stdeula/\n\niOS 17.1 以降の iPhone で使えます。","keywords":"ねこ,ネコ,ペット,愛猫,アルバム,写真整理,ウィジェット,迷子,家族,共有,お世話,記録,病院,メモ,黒猫,多頭飼い,見守り","promotionalText":"iPhone の中の猫の写真を見つけて、アルバムとホーム画面に。毎月 1 日には、先月の猫の作品が届きます。家族とは「みんなのまど」で写真を届け合い、「家族の手帳」でお世話の記録を一緒に書けます。","notes":"ねこのまどは、iPhone の写真から猫の写真を見つけて、アルバムとウィジェットに出すアプリです。\n\n1. 写真へのアクセスは「フルアクセス」をおすすめします。端末に猫の写真が無いと、アルバムと作品は空になります。\n\n2. Plus（jp.nekowidget.plus.monthly、月額、14 日間の無料お試し）は Sandbox の購入で試せます。審査用のコードや特別な入口はありません。購入画面は「設定」→「Plusについて」です。\n\n3. みんなのまど（招待した人と写真を届け合う機能）は、Plus でまどを作り、招待リンクを 2 台目の端末で開くと試せます。1 台でも、作る・届ける・ウィジェットまでは確認できます。写真とひとことはエンドツーエンド暗号化で届けます。写真アプリの共有シートの「ねこのまど」からも、まどに届けられます。\n\n4. 不適切な写真への対応（みんなのまど）\n・公開の場はありません。招待した人だけ（1 つのまどに 6 人まで）で、公開のタイムライン・検索・フォローはありません。\n・届けられるのは 1 人 1 日 5 枚までです。\n・まどを作るとき・参加するときに、コミュニティ基準への同意を求めます。\n・まどの写真を開いた画面の「…」から「この写真を通報」と「○○さんをブロック」ができます。通報した写真はすぐに見えなくなり、通報番号を表示します。ブロックもすぐに効きます。\n・通報とブロックは、ほかの人が届けた写真にだけ出ます。1 台では見られないため、2 台で操作した動画を添付します。\n・通報は運営者が原則 48 時間以内に確認を始めます（コミュニティ基準 https://nekonomado.com/community/ ）。\n・届ける前と表示する前の iPhone の中での確かめは、iPhone の「センシティブな内容の警告」がオンのときに行い、センシティブな写真は届けず、表示もしません。オフのときは確かめずに届けるため、上の招待制・枚数の上限・同意・通報・ブロックで対応します。\n・家族の手帳では、家族の書き込みを長押しして「この書き込みを表示しない」と「運営に知らせる」（お問い合わせへの案内）が選べます。\n\n5. 削除：「設定」のいちばん下の「アカウントとデータを消す」から。まどと家族の手帳は「まどと家族の手帳のデータを消す」、自動保存は「自動保存のアカウント」。Plus の解約は App Store のサブスクリプションからです。\n\n6. 「病院で見せる」で写真や動画を撮ると、写真アプリに保存します。動画を撮るときだけマイクを使います。\n\n連絡先：support@nekonomado.com"};
export const storeCopy1123Approved={"description":"7d27bc45e6f876f2c297001bfb334545d1826a3092e1deb1d82eda0708a22870","keywords":"b8928f5fe80bcf5a0067bbe95e5730ffd872a109ffb14018ac2346ea781ba7c1","promotionalText":"611b7dd84d794cb56f177e9a03d29ade6fbaaef7e900d4a280b37f1791ae186f","notes":"63031e04a82cfd611ccbe34bf7d7996f29a8f8ba9b0871ae871709dcb8aff6b2"};
const sha256=text=>createHash('sha256').update(text,'utf8').digest('hex');
export function pickFields(values,fields){
  return Object.fromEntries(fields.map(field=>[field,values?.[field]]));
}
// Each field moves only from its exact previous text to its exact approved
// text (or is already there). Any other current value, or any field outside
// the four, stops.
export function approvedStoreCopy1123(current,desired){
  if(!current||!desired||typeof current!=='object'||typeof desired!=='object')return false;
  const fields=Object.keys(desired);
  if(!fields.length||fields.some(field=>!Object.hasOwn(storeCopy1123Previous,field)))return false;
  if(Object.keys(current).some(field=>!fields.includes(field)))return false;
  return fields.every(field=>typeof desired[field]==='string'&&sha256(desired[field])===storeCopy1123Approved[field]
    &&(current[field]===storeCopy1123Previous[field]||current[field]===desired[field]));
}
// 1123v: PR #1235 renamed the button 「猫友を招く」 to 「招待する」. Only the review
// notes move, from exactly the store-copy-1123 approved notes to exactly this text.
export const reviewNotes1123vPrevious=storeCopy1123Approved.notes;
export const reviewNotes1123vApproved='8a44b2a67ff2bd4fe6db182564b167ca9dcf9dd38ff9ef8cad8ac344fd5c1123';
export function approvedReviewNotes1123v(current,desired){
  if(!current||!desired||typeof current!=='object'||typeof desired!=='object')return false;
  if(Object.keys(desired).join()!=='notes'||Object.keys(current).some(field=>field!=='notes'))return false;
  if(typeof desired.notes!=='string'||sha256(desired.notes)!==reviewNotes1123vApproved)return false;
  return typeof current.notes==='string'&&(sha256(current.notes)===reviewNotes1123vPrevious||current.notes===desired.notes);
}
const freePhotoHeading='■ ホーム画面で、ふと目が合う\n';
const plusHeading='■ ねこのまど Plus\n';
const paidDailyLine='・毎日、新しい 1 枚がホーム画面に\n';
const freeDailyLine='毎日ちがう 1 枚に入れ替わります。';
const dailyPlusDescription='月の作品、まど、家族の手帳、メモ、保存';
export function approvedDailyPhotoAppDescription(current,desired){
  if(typeof current!=='string'||typeof desired!=='string')return false;
  if(current===desired)return true;
  const paragraphs=current.split('\n\n');
  const home=paragraphs.map((p,i)=>p.startsWith(freePhotoHeading)?i:-1).filter(i=>i>=0);
  const plus=paragraphs.map((p,i)=>p.startsWith(plusHeading)?i:-1).filter(i=>i>=0);
  if(home.length!==1||plus.length!==1||paragraphs[plus[0]].split(paidDailyLine).length!==2)return false;
  if(!paragraphs[home[0]].includes(freeDailyLine))paragraphs[home[0]]+=freeDailyLine;
  paragraphs[plus[0]]=paragraphs[plus[0]].replace(paidDailyLine,'');
  return paragraphs.join('\n\n')===desired;
}
export function dailyPlusDescriptionChange(current){
  if(current===dailyPlusDescription)return null;
  if(typeof current!=='string'||!current.replace(/\s/gu,'').includes('毎日の新しい1枚'))throw Error('STOP_SCOPE');
  return dailyPlusDescription;
}
function oldDailyPhotoCopy(value){
  if(typeof value!=='string')return false;
  return /毎日の新しい1枚|毎日、新しい1枚がホーム画面に|毎日の入れ替わりはPlus|毎日新しい1枚に入れ替わるのはPlus|最後の1枚のまま|最初の1枚がそのまま/u.test(value.replace(/\s/gu,''));
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
  const selection=process.env.ASC_METADATA_SCOPE||'approved-groups';
  if(!['approved-groups','version-description','daily-photo-app-description','daily-photo-plus-description','seasonal-movie-app-metadata','store-copy-1123','review-notes-1123v','age-rating'].includes(selection))throw Error('STOP_SCOPE');
  if(selection==='age-rating'&&mode==='--apply')throw Error('STOP_SCOPE');
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
  function runScope(scope,files,probe=false,fields,checkBefore,approvedOverrides={}){
    const dir=mkdtempSync(join(tmpdir(),'asc-approved-'));
    for(const file of files){const dest=join(dir,file);mkdirSync(resolve(dest,'..'),{recursive:true});
      const value={...JSON.parse(readFileSync(join(root,file),'utf8')),...approvedOverrides[file]};
      writeFileSync(dest,JSON.stringify(Object.fromEntries(Object.entries(value).filter(([field])=>!fields||fields.includes(field)))),{mode:0o600});}
    const args=['metadata','apply','--app',app,'--version','1.0','--platform','IOS','--dir',dir,'--include',scope,'--output','json'];
    const plan=call([...args,'--dry-run']);
    const allowed=expected(files,fields,dir);
    const changes=checkPlan(plan,allowed);
    console.log(JSON.stringify({dryRun:true,scope,probe,changes}));
    if(mode==='--apply'&&changes.length){
      const before=snapshot(scope);
      if(scope==='localizations'&&before['version/1.0/ja.json']?.marketingUrl)throw Error('STOP_SCOPE');
      if(checkBefore&&!checkBefore(before))throw Error('STOP_SCOPE');
      let writeError;
      try{call(args);}catch(e){writeError=e;}
      // Inspect even partial failures before allowing a later group to write.
      const after=snapshot(scope);
      for(const file of new Set([...Object.keys(before),...Object.keys(after)])){
        const writable=files.includes(file)?Object.keys(JSON.parse(readFileSync(join(root,file),'utf8'))).filter(field=>!fields||fields.includes(field)):[];
        for(const field of new Set([...Object.keys(before[file]??{}),...Object.keys(after[file]??{})])){
          if(!writable.includes(field)&&!isDeepStrictEqual(before[file]?.[field]??'',after[file]?.[field]??''))throw Error('STOP_SCOPE');
          if(writable.includes(field)&&!isDeepStrictEqual(before[file]?.[field],after[file]?.[field])
               &&!isDeepStrictEqual(after[file]?.[field],JSON.parse(readFileSync(join(dir,file),'utf8'))[field]))throw Error('STOP_SCOPE');
        }
      }
      if(writeError)throw writeError;
      if(checkPlan(call([...args,'--dry-run']),allowed).length)throw Error('STOP_READBACK');
      console.log(JSON.stringify({applied:true,scope,probe,readbackMatches:true}));
    }
  }
  if(selection==='age-rating'){
    runScope('age-rating',scopes['age-rating']);
    return;
  }
  if(selection==='store-copy-1123'){
    // Both groups are checked before either writes.
    const groups=[['localizations','version/1.0/ja.json',['description','keywords','promotionalText']],
      ['review-information','review-information.json',['notes']]].map(([scope,file,fields])=>{
      const desired=pickFields(JSON.parse(readFileSync(join(root,file),'utf8')),fields);
      if(!approvedStoreCopy1123(pickFields(snapshot(scope)[file],fields),desired))throw Error('STOP_SCOPE');
      return [scope,file,fields,desired];
    });
    for(const [scope,file,fields,desired] of groups)
      runScope(scope,[file],false,fields,before=>approvedStoreCopy1123(pickFields(before[file],fields),desired));
    return;
  }
  if(selection==='review-notes-1123v'){
    const file='review-information.json',fields=['notes'];
    const desired=pickFields(JSON.parse(readFileSync(join(root,file),'utf8')),fields);
    if(!approvedReviewNotes1123v(pickFields(snapshot('review-information')[file],fields),desired))throw Error('STOP_SCOPE');
    runScope('review-information',[file],false,fields,before=>approvedReviewNotes1123v(pickFields(before[file],fields),desired));
    return;
  }
  if(selection==='seasonal-movie-app-metadata'){
    const file='version/1.0/ja.json';
    const desired=JSON.parse(readFileSync(join(root,file),'utf8'));
    const approved=seasonalMovieAppMetadata(snapshot('localizations')[file],desired);
    runScope('localizations',[file],false,['description','keywords'],
      before=>isDeepStrictEqual(seasonalMovieAppMetadata(before[file],desired),approved),{[file]:approved});
    return;
  }
  if(selection==='version-description'||selection==='daily-photo-app-description'){
    const file='version/1.0/ja.json';
    const localizations=snapshot('localizations');
    const current=localizations[file]?.description;
    const desired=JSON.parse(readFileSync(join(root,file),'utf8')).description;
    const approved=selection==='version-description'?approvedDescriptionUpdate:approvedDailyPhotoAppDescription;
    if(selection==='daily-photo-app-description')for(const [location,values] of Object.entries(localizations)){
      for(const [field,value] of Object.entries(values))if((location!==file||field!=='description')&&oldDailyPhotoCopy(value))
        console.log(JSON.stringify({outOfScope:true,scope:selection,location,field}));
    }
    if(!approved(current,desired))throw Error('STOP_SCOPE');
    runScope('localizations',[file],false,['description'],before=>approved(before[file]?.description,desired));
    return;
  }
  if(selection==='daily-photo-plus-description'){
    const productID='jp.nekowidget.plus.monthly';
    const matches=call(['subscriptions','list','--app',app,'--paginate','--output','json']).data?.filter(x=>x.attributes?.productId===productID);
    if(matches?.length!==1)throw Error('STOP_IDENTITY');
    const subscription=matches[0].id;sensitive.push(subscription);
    const drafts=(call(['subscriptions','versions','list','--subscription-id',subscription,'--paginate','--output','json']).data??[])
      .filter(x=>['PREPARE_FOR_SUBMISSION','MISSING_METADATA'].includes(x.attributes?.state));
    if(drafts.length!==1){console.log(JSON.stringify({scope:selection,editableVersionCount:drafts.length}));throw Error('STOP_API');}
    const version=drafts[0].id;sensitive.push(version);
    function read(){
      const rows=(call(['subscriptions','versions','localizations','list','--version-id',version,'--paginate','--output','json']).data??[])
        .sort((a,b)=>a.id.localeCompare(b.id));
      const japanese=rows.filter(x=>x.attributes?.locale==='ja');
      if(japanese.length!==1)throw Error('STOP_IDENTITY');
      return {rows,target:japanese[0]};
    }
    const before=read(),id=before.target.id;sensitive.push(id);
    const next=dailyPlusDescriptionChange(before.target.attributes.description);
    console.log(JSON.stringify({dryRun:true,scope:selection,productID,locale:'ja',fields:next===null?[]:['description'],description:next??dailyPlusDescription}));
    for(const row of before.rows){
      if(row.id!==id&&oldDailyPhotoCopy(row.attributes?.description))
        console.log(JSON.stringify({outOfScope:true,scope:selection,locale:row.attributes.locale,field:'description'}));
    }
    if(mode==='--apply'&&next!==null){
      if([ ...next ].length>55)throw Error('STOP_SCOPE');
      let writeError;
      try{call(['subscriptions','versions','localizations','update','--id',id,'--description',next,'--output','json']);}
      catch(e){writeError=e;}
      const after=read();
      if(after.target.id!==id)throw Error('STOP_SCOPE');
      const comparable=rows=>rows.map(({id:rowID,attributes})=>({id:rowID,attributes:Object.fromEntries(Object.entries(attributes).filter(([key])=>rowID!==id||key!=='description'))}));
      if(!isDeepStrictEqual(comparable(before.rows),comparable(after.rows)))throw Error('STOP_SCOPE');
      if(after.target.attributes.description!==next){if(writeError)throw writeError;throw Error('STOP_READBACK');}
      console.log(JSON.stringify({applied:true,scope:selection,readbackMatches:true}));
    }
    return;
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
  const readApp=()=>{
    const value=call(['apps','view','--id',app,'--fields','name,bundleId,sku,primaryLocale,contentRightsDeclaration,accessibilityUrl,subscriptionStatusUrl,subscriptionStatusUrlVersion,subscriptionStatusUrlForSandbox,subscriptionStatusUrlVersionForSandbox','--output','json']).data;
    if(value?.id!==app)throw Error('STOP_IDENTITY');
    return value;
  };
  const currentApp=readApp();
  const oldRights=currentApp.attributes.contentRightsDeclaration;
  if(oldRights&&!['DOES_NOT_USE_THIRD_PARTY_CONTENT','USES_THIRD_PARTY_CONTENT'].includes(oldRights))throw Error('STOP_SCOPE');
  console.log(JSON.stringify({dryRun:true,scope:'app',field:'contentRightsDeclaration',from:oldRights??null,to:desired}));
  if(mode==='--apply' && oldRights!==desired){
    let writeError;
    try{call(['apps','update','--id',app,'--content-rights',desired,'--output','json']);}catch(e){writeError=e;}
    const after=readApp();
    const beforeAttrs={...currentApp.attributes},afterAttrs={...after.attributes};
    delete beforeAttrs.contentRightsDeclaration;delete afterAttrs.contentRightsDeclaration;
    if(!isDeepStrictEqual(beforeAttrs,afterAttrs))throw Error('STOP_SCOPE');
    if(writeError)throw writeError;
    if(after.attributes.contentRightsDeclaration!==desired)throw Error('STOP_READBACK');
    console.log(JSON.stringify({applied:true,scope:'content-rights',readbackMatches:true}));
  }
  }]);
  groups.push(['plus-localization',()=>{
    const products=call(['subscriptions','list','--app',app,'--paginate','--output','json']);
    const matches=products.data?.filter(x=>x.attributes?.productId==='jp.nekowidget.plus.monthly');
    if(matches?.length!==1)throw Error('STOP_IDENTITY');
    sensitive.push(matches[0].id);
    const detail=call(['subscriptions','view','--id',matches[0].id,'--include','subscriptionLocalizations','--output','json']);
    const product=detail.data;
    if(product?.id!==matches[0].id||product.attributes?.productId!=='jp.nekowidget.plus.monthly')throw Error('STOP_IDENTITY');
    const ids=new Set(product.relationships?.subscriptionLocalizations?.data?.map(x=>x.id)??[]);
    const existing=detail.included?.filter(x=>ids.has(x.id)&&x.attributes?.locale==='ja')??[];
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
