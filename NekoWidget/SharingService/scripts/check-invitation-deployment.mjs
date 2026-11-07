import {mkdtemp,readFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';import {join} from 'node:path';
import {prepareInvitationAssets,invitationPaths,policyPaths,policyFile} from './invitation-assets.mjs';
const root=await mkdtemp(join(tmpdir(),'neko-invitation-compare-'));
try{
 const output=join(root,'assets');await prepareInvitationAssets(output);
 for(const path of [...invitationPaths,'/.well-known/apple-app-site-association']){
  const expected=await readFile(join(output,path.slice(1)),'utf8');
  const response=await fetch('https://nekonomado.com'+path,{redirect:'manual',signal:AbortSignal.timeout(15000),headers:{'User-Agent':'neko-invitation-check/1.0'}});
  if(response.status!==200||await response.text()!==expected)throw Error('Published invitation differs from docs: '+path+'; deploy the generated assets (do not change AASA).');
  console.log('MATCH',path);
 }
 for(const path of policyPaths){
  const expected=await readFile(join(output,policyFile(path)),'utf8');
  for(const url of ['https://nekonomado.com'+path,'https://soso-so-27.github.io/neko-widget'+path]){
   const response=await fetch(url,{signal:AbortSignal.timeout(15000)});
   if(response.status!==200||(await response.text()).replace(/\r\n/g,'\n')!==expected)throw Error('Published policy differs from docs: '+url);
  }
  if(path!=='/'){
   const response=await fetch('https://nekonomado.com'+path.slice(0,-1),{signal:AbortSignal.timeout(15000)});
   if(response.status!==200||await response.text()!==expected||new URL(response.url).pathname!==path)throw Error('Slashless policy route differs: '+path);
  }
  console.log('MATCH policy and GitHub Pages',path);
 }
 const css=await fetch('https://nekonomado.com/assets/site.css');
 if(css.status!==200||await css.text()!==await readFile(join(output,'assets/site.css'),'utf8'))throw Error('Policy CSS differs');
}finally{await rm(root,{recursive:true,force:true});}
