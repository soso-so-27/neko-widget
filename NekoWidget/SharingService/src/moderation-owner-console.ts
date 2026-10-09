import { ownerAssertionPayload } from "./moderation-owner-browser";
/** Local owner UI. No case, identity, credential, key or image is embedded. */
export function localModerationOwnerConsole(): Response {
  const nonce = crypto.randomUUID().replaceAll("-", "");
  return new Response(`<!doctype html><html lang="ja"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>通報写真の確認｜ねこのまど</title><style nonce="${nonce}">
:root{font-family:system-ui,sans-serif;color:#19362e;background:#f3f5f1;color-scheme:light}*{box-sizing:border-box}body{margin:0}main{max-width:860px;margin:auto;padding:32px 24px 60px}h1{font-size:28px}h2{font-size:20px}p{line-height:1.7}a{color:#245b47}section{background:white;border:1px solid #d4dfd7;border-radius:16px;padding:24px;margin:24px 0}.note{background:#e5ede7;padding:16px 20px;border-radius:12px}.muted{color:#536b61}button{font:inherit;font-weight:600;min-height:46px;border-radius:10px;padding:12px 18px;border:1px solid #245b47;background:#245b47;color:white;cursor:pointer}button:disabled{opacity:.5;cursor:default}button:focus-visible,input:focus-visible{outline:3px solid #be742e;outline-offset:3px}#photo{display:block;max-width:100%;max-height:420px;margin:20px auto;border-radius:10px}#status{min-height:28px}label{display:block;line-height:1.7;margin:20px 0}input{width:20px;height:20px;vertical-align:middle;margin-right:8px}blockquote{border-left:3px solid #b5c7bb;padding-left:18px;margin:16px 0}#decision[hidden],#photo[hidden]{display:none}@media(max-width:560px){main{padding:24px 16px}section{padding:18px}button{width:100%}}
</style></head><body><main><a href="/operator/console">← 通報一覧へ</a><h1>通報写真の確認</h1>
<p class="note">本人認証で写真を開き、確認した内容に対する判断を保存します。このローカル検証版では返信案の保存まで行い、送信はしません。</p>
<p id="status" role="status" aria-live="polite">写真はまだ開いていません。</p><section><h2>写真を確認</h2><p class="muted">表示は最長60秒です。画面を離れた場合も写真を消します。</p><button id="open">認証して写真を開く</button><img id="photo" alt="通報された写真" hidden></section>
<section id="decision" hidden><h2>確認結果を保存</h2><p>対応が必要な場合は、ここでは確定せず一覧へ戻してください。</p><h3>通報した人への返信案</h3><blockquote>通報いただいた内容を確認しました。今回は追加の対応は行いません。</blockquote><label><input type="checkbox" id="confirmed">写真を確認し、追加の対応は不要と判断しました。</label><button id="finish" disabled>認証して対応不要を確定</button><p class="muted">保存先は、この通報を送った人に限定されます。まだ送信されません。</p></section>
</main><script nonce="${nonce}">
'use strict';
const ownerAssertionPayload=${ownerAssertionPayload.toString()};
const status=document.getElementById('status'),open=document.getElementById('open'),photo=document.getElementById('photo'),decision=document.getElementById('decision'),confirmed=document.getElementById('confirmed'),finish=document.getElementById('finish');
const route=/^\\/operator\\/owner\\/console\\/([0-9a-f]{64})\\/([1-9][0-9]{0,9})$/.exec(location.pathname);
let busy=false,generation=0,controller=null,imageURL=null,receipt=null,source=null,timer=null,expiresAt=0;
const base=route?'/operator/owner/v1/cases/'+route[1]+'/'+route[2]:null;
function erase(){clearTimeout(timer);if(imageURL)URL.revokeObjectURL(imageURL);imageURL=null;photo.removeAttribute('src');photo.hidden=true;decision.hidden=true;confirmed.checked=false;receipt=null;source=null;expiresAt=0;finish.disabled=true}
function leave(){generation++;controller?.abort();erase();busy=false;open.disabled=!base;status.textContent='写真の表示を終了しました。必要ならもう一度認証してください。'}
document.addEventListener('visibilitychange',()=>{if(document.hidden)leave()});window.addEventListener('pagehide',leave);
function lock(value){busy=value;open.disabled=value||!base;finish.disabled=value||!confirmed.checked||!receipt||Date.now()>=expiresAt}
confirmed.addEventListener('change',()=>lock(busy));
function decode(value){if(typeof value!=='string'||!/^[A-Za-z0-9_-]{43}$/.test(value))throw Error('challenge');return Uint8Array.from(atob(value.replaceAll('-','+').replaceAll('_','/')+'='),c=>c.charCodeAt(0))}
function encode(value){return btoa(String.fromCharCode(...new Uint8Array(value))).replaceAll('+','-').replaceAll('/','_').replace(/=+$/,'')}
async function post(path,body){const response=await fetch(path,{method:'POST',credentials:'same-origin',redirect:'error',cache:'no-store',signal:AbortSignal.any([controller.signal,AbortSignal.timeout(65000)]),...(body===undefined?{}:{headers:{'Content-Type':'application/json'},body:JSON.stringify(body)})});if(!response.ok)throw Error('request');return response}
async function authorize(path,purpose,epoch){
 const challenge=await(await post(path)).json();if(epoch!==generation)throw Error('stale');
 if(challenge.caseReferenceHmac!==route[1]||challenge.purpose!==purpose||challenge.rpId!==location.hostname||challenge.userVerification!=='required'||!Number.isSafeInteger(challenge.expiresAt)||challenge.expiresAt*1000<=Date.now()||!/^[0-9a-f]{64}$/.test(challenge.sourceSHA256)||!/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(challenge.challengeId)||challenge.assertionPath!==path+'/assertions/'+challenge.challengeId)throw Error('challenge');
 if(purpose==='decision'&&challenge.sourceSHA256!==source)throw Error('source');
 const credential=await navigator.credentials.get({publicKey:{challenge:decode(challenge.challenge),rpId:challenge.rpId,userVerification:'required',timeout:Math.min(60000,challenge.expiresAt*1000-Date.now())},signal:controller.signal});
 if(epoch!==generation||!credential||credential.type!=='public-key'||Date.now()>=challenge.expiresAt*1000)throw Error('stale');
 const proof=ownerAssertionPayload(credential);
 return {response:await post(challenge.assertionPath,proof),challenge};
}
open.addEventListener('click',async()=>{
 if(busy||!base)return;erase();lock(true);const epoch=++generation;controller?.abort();controller=new AbortController();status.textContent='本人認証と写真の有効性を確認しています…';
 try{const result=await authorize(base+'/content-read','content_read',epoch);if(epoch!==generation)return;
 const response=result.response,id=response.headers.get('X-Moderation-Read-Receipt'),digest=response.headers.get('X-Moderation-Source-SHA256'),expiry=Number(response.headers.get('X-Moderation-Expires-At'))*1000;
 if(!/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(id??'')||digest!==result.challenge.sourceSHA256||response.headers.get('Content-Type')!=='image/jpeg'||!Number.isSafeInteger(expiry)||expiry<=Date.now()||expiry>Date.now()+60000)throw Error('response');
 expiresAt=expiry;timer=setTimeout(leave,Math.max(1,expiry-Date.now()));
 const blob=await response.blob();if(epoch!==generation)return;if(blob.size<4||blob.size>950244||Date.now()>=expiry)throw Error('image');
 imageURL=URL.createObjectURL(blob);photo.src=imageURL;await photo.decode();if(epoch!==generation)return;
 if(Date.now()>=expiry)throw Error('expired');receipt=id;source=digest;expiresAt=expiry;photo.hidden=false;decision.hidden=false;
 status.textContent='写真を確認してください。対応不要と判断した場合だけ、下の確認結果を保存します。';
 }catch{if(epoch===generation){erase();status.textContent='写真を開けませんでした。認証・権限・期限を確認してください。失敗した操作は自動で再送しません。'}}finally{if(epoch===generation)lock(false)}
});
finish.addEventListener('click',async()=>{
 if(busy||!receipt||!confirmed.checked||Date.now()>=expiresAt)return;lock(true);const epoch=++generation;controller?.abort();controller=new AbortController();status.textContent='判断を認証して保存しています…';
 try{const result=await authorize(base+'/decisions/no-action/'+receipt,'decision',epoch);const value=await result.response.json();if(epoch!==generation)return;
 if(value.caseReferenceHmac!==route[1]||value.sourceSHA256!==source||value.outcome!=='no_action'||value.reply!=='draft_saved'||value.sent!==false)throw Error('response');
 erase();status.textContent='対応不要の判断と返信案を保存しました。返信はまだ送信されていません。';open.hidden=true;
 }catch{if(epoch===generation){erase();status.textContent='保存結果を確認できません。一覧へ戻って状態を確認してください。同じ署名は自動で再送しません。'}}finally{if(epoch===generation)lock(false)}
});
if(!base){open.disabled=true;status.textContent='通報一覧から写真を選び直してください。'}
</script></body></html>`, { headers: { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store",
    "Content-Security-Policy": `default-src 'none'; script-src 'nonce-${nonce}'; style-src 'nonce-${nonce}'; img-src blob:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'`,
    "Referrer-Policy": "no-referrer", "X-Content-Type-Options": "nosniff", "X-Frame-Options": "DENY" } });
}
