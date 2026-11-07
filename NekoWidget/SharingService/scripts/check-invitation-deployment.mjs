import {mkdtemp,readFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';import {join} from 'node:path';
import {prepareInvitationAssets,invitationPaths} from './invitation-assets.mjs';
const root=await mkdtemp(join(tmpdir(),'neko-invitation-compare-'));
try{
 const output=join(root,'assets');await prepareInvitationAssets(output);
 for(const path of [...invitationPaths,'/.well-known/apple-app-site-association']){
  const expected=await readFile(join(output,path.slice(1)),'utf8');
  const response=await fetch('https://nekonomado.com'+path,{redirect:'manual',signal:AbortSignal.timeout(15000),headers:{'User-Agent':'neko-invitation-check/1.0'}});
  if(response.status!==200||await response.text()!==expected)throw Error('Published invitation differs from docs: '+path+'; deploy the generated assets (do not change AASA).');
  console.log('MATCH',path);
 }
}finally{await rm(root,{recursive:true,force:true});}
