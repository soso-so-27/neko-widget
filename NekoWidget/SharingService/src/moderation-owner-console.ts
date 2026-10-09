import { ownerAssertionPayload } from "./moderation-owner-browser";
/** Local owner UI. No case, identity, credential, key or image is embedded. */
export function localModerationOwnerConsole(): Response {
  const nonce = crypto.randomUUID().replaceAll("-", "");
  return new Response(`<!doctype html><html lang="ja"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>通報写真の確認｜ねこのまど</title><style nonce="${nonce}">
:root{font-family:system-ui,sans-serif;color:#19362e;background:#f3f5f1;color-scheme:light}*{box-sizing:border-box}body{margin:0}main{max-width:860px;margin:auto;padding:32px 24px 60px}h1{font-size:28px}h2{font-size:20px}p{line-height:1.7}a{color:#245b47}section{background:white;border:1px solid #d4dfd7;border-radius:16px;padding:24px;margin:24px 0}.note{background:#e5ede7;padding:16px 20px;border-radius:12px}.muted{color:#536b61}button{font:inherit;font-weight:600;min-height:46px;border-radius:10px;padding:12px 18px;border:1px solid #245b47;background:#245b47;color:white;cursor:pointer}button:disabled{opacity:.5;cursor:default}button:focus-visible,input:focus-visible{outline:3px solid #be742e;outline-offset:3px}#photo{display:block;max-width:100%;max-height:420px;margin:20px auto;border-radius:10px}#status{min-height:28px}label{display:block;line-height:1.7;margin:20px 0}input{width:20px;height:20px;vertical-align:middle;margin-right:8px}blockquote{border-left:3px solid #b5c7bb;padding-left:18px;margin:16px 0}#decision[hidden],#photo[hidden]{display:none}@media(max-width:560px){main{padding:24px 16px}section{padding:18px}button{width:100%}}
</style></head><body><main><a href="/operator/console">← 通報一覧へ</a><h1>通報写真の確認</h1>
<p class="note">写真を確認して共有表示への対応を決めます。確定した結果は、この通報をした人だけがアプリから確認できます。本人の元の写真やメモは削除しません。</p>
<p id="status" role="status" aria-live="polite">写真はまだ開いていません。</p><section><h2>写真を確認</h2><p class="muted">表示は最長60秒です。画面を離れた場合も写真を消します。</p><button id="open">認証して写真を開く</button><img id="photo" alt="通報された写真" hidden></section>
<section id="decision" hidden><h2>写真への対応</h2><label><input type="radio" name="action" value="hide" checked>共有表示を一時的に非表示にする</label><label><input type="radio" name="action" value="no_action">追加の対応は不要</label><h3>通報した人への返答</h3><blockquote id="reply">通報いただいた共有写真を一時的に非表示にしました。</blockquote><label><input type="checkbox" id="confirmed">写真を確認し、この対応と返答を確定します。</label><button id="finish" disabled>認証して対応と返答を確定</button></section>
<section id="release-section" hidden><h2>この通報による非表示を解除</h2><p>この通報に対する制限だけを解除します。他の通報による非表示、共有解除、ブロックや期限切れはそのままです。</p><blockquote>確認の結果、この通報による非表示を解除しました。他の制限や共有期限がある場合は表示されません。</blockquote><label><input type="checkbox" id="release-confirmed">この通報による非表示を解除し、結果を返答します。</label><button id="release" disabled>認証して非表示を解除</button><p class="muted">通報の保存期限が終了している場合は、返答を新しく作りません。</p></section>
</main><script nonce="${nonce}">
'use strict';
const ownerAssertionPayload=${ownerAssertionPayload.toString()};
const status=document.getElementById('status'),open=document.getElementById('open'),photo=document.getElementById('photo'),decision=document.getElementById('decision'),confirmed=document.getElementById('confirmed'),finish=document.getElementById('finish');
const route=/^\\/operator\\/owner\\/console\\/([0-9a-f]{64})\\/([1-9][0-9]{0,9})$/.exec(location.pathname);
const releaseSection=document.getElementById('release-section'),releaseConfirmed=document.getElementById('release-confirmed'),releaseButton=document.getElementById('release'),reply=document.getElementById('reply');
let resolution=null;
let busy=false,generation=0,controller=null,imageURL=null,receipt=null,source=null,timer=null,expiresAt=0;
const base=route?'/operator/owner/v1/cases/'+route[1]+'/'+route[2]:null;
const resolutionBase=route?'/operator/resolution/v1/cases/'+route[1]+'/'+route[2]:null;
function erase(){clearTimeout(timer);if(imageURL)URL.revokeObjectURL(imageURL);imageURL=null;photo.removeAttribute('src');photo.hidden=true;decision.hidden=true;confirmed.checked=false;receipt=null;source=null;expiresAt=0;finish.disabled=true}
function leave(){generation++;controller?.abort();erase();resolution=null;releaseSection.hidden=true;releaseConfirmed.checked=false;releaseButton.disabled=true;busy=false;open.disabled=!base;status.textContent='写真の表示を終了しました。必要ならもう一度認証してください。'}
document.addEventListener('visibilitychange',()=>{if(document.hidden)leave()});window.addEventListener('pagehide',leave);
function lock(value){busy=value;open.disabled=value||!base||resolution?.operation==='no_action';finish.disabled=value||!confirmed.checked||!receipt||Date.now()>=expiresAt||!resolution?.targetAvailable||resolution?.operation==='hide';releaseButton.disabled=value||!releaseConfirmed.checked||!resolution?.canRelease}
confirmed.addEventListener('change',()=>lock(busy));
releaseConfirmed.addEventListener('change',()=>lock(busy));
for(const radio of document.querySelectorAll('input[name=action]'))radio.addEventListener('change',()=>{confirmed.checked=false;reply.textContent=radio.value==='hide'?'通報いただいた共有写真を一時的に非表示にしました。':'通報いただいた内容を確認しました。今回は追加の対応は行いません。';lock(busy)});
function decode(value){if(typeof value!=='string'||!/^[A-Za-z0-9_-]{43}$/.test(value))throw Error('challenge');return Uint8Array.from(atob(value.replaceAll('-','+').replaceAll('_','/')+'='),c=>c.charCodeAt(0))}
function encode(value){return btoa(String.fromCharCode(...new Uint8Array(value))).replaceAll('+','-').replaceAll('/','_').replace(/=+$/,'')}
async function post(path,body){const response=await fetch(path,{method:'POST',credentials:'same-origin',redirect:'error',cache:'no-store',signal:AbortSignal.any([controller.signal,AbortSignal.timeout(65000)]),...(body===undefined?{}:{headers:{'Content-Type':'application/json'},body:JSON.stringify(body)})});if(!response.ok)throw Error('request');return response}
async function authorize(path,purpose,epoch){
 const challenge=await(await post(path)).json();if(epoch!==generation)throw Error('stale');
 if(challenge.caseReferenceHmac!==route[1]||(purpose==='content_read'?challenge.purpose!==purpose:challenge.operation!==purpose)||challenge.rpId!==location.hostname||challenge.userVerification!=='required'||!Number.isSafeInteger(challenge.expiresAt)||challenge.expiresAt*1000<=Date.now()||!/^[0-9a-f]{64}$/.test(challenge.sourceSHA256)||!/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(challenge.challengeId)||challenge.assertionPath!==path+'/assertions/'+challenge.challengeId)throw Error('challenge');
 if(purpose!=='content_read'&&(!/^[0-9a-f]{64}$/.test(challenge.bindingSHA256)||challenge.expectedRevision!==resolution?.revision))throw Error('revision');
 if((purpose==='hide'||purpose==='no_action')&&challenge.sourceSHA256!==source)throw Error('source');
 const credential=await navigator.credentials.get({publicKey:{challenge:decode(challenge.challenge),rpId:challenge.rpId,userVerification:'required',timeout:Math.min(60000,challenge.expiresAt*1000-Date.now())},signal:controller.signal});
 if(epoch!==generation||!credential||credential.type!=='public-key'||Date.now()>=challenge.expiresAt*1000)throw Error('stale');
 const proof=ownerAssertionPayload(credential);
 return {response:await post(challenge.assertionPath,proof),challenge};
}
async function loadState(epoch){const state=await(await post(resolutionBase+'/state')).json();if(epoch!==generation)throw Error('stale');if(state.caseReferenceHmac!==route[1]||!Number.isSafeInteger(state.revision)||state.revision<0||typeof state.targetAvailable!=='boolean'||typeof state.canRelease!=='boolean'||(state.canRelease&&!/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(state.restrictionEventId)))throw Error('state');resolution=state;releaseSection.hidden=!state.canRelease;releaseConfirmed.checked=false;return state}
open.addEventListener('click',async()=>{
 if(busy||!base)return;erase();lock(true);const epoch=++generation;controller?.abort();controller=new AbortController();status.textContent='本人認証と写真の有効性を確認しています…';
 try{await loadState(epoch);const result=await authorize(base+'/content-read','content_read',epoch);if(epoch!==generation)return;
 const response=result.response,id=response.headers.get('X-Moderation-Read-Receipt'),digest=response.headers.get('X-Moderation-Source-SHA256'),expiry=Number(response.headers.get('X-Moderation-Expires-At'))*1000;
 if(!/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(id??'')||digest!==result.challenge.sourceSHA256||response.headers.get('Content-Type')!=='image/jpeg'||!Number.isSafeInteger(expiry)||expiry<=Date.now()||expiry>Date.now()+60000)throw Error('response');
 expiresAt=expiry;timer=setTimeout(leave,Math.max(1,expiry-Date.now()));
 const blob=await response.blob();if(epoch!==generation)return;if(blob.size<4||blob.size>950244||Date.now()>=expiry)throw Error('image');
 imageURL=URL.createObjectURL(blob);photo.src=imageURL;await photo.decode();if(epoch!==generation)return;
 if(Date.now()>=expiry)throw Error('expired');receipt=id;source=digest;expiresAt=expiry;photo.hidden=false;decision.hidden=false;
 status.textContent='写真を確認し、必要な対応を選んでください。';
 }catch{if(epoch===generation){erase();status.textContent='写真を開けませんでした。認証・権限・期限を確認してください。失敗した操作は自動で再送しません。'}}finally{if(epoch===generation)lock(false)}
});
async function resolve(operation){
 if(busy||!resolution?.targetAvailable)return;if(operation==='release'){if(!releaseConfirmed.checked||!resolution.canRelease)return}else if(!receipt||!confirmed.checked||Date.now()>=expiresAt)return;
 const revision=resolution.revision,identity=operation==='release'?resolution.restrictionEventId:receipt;
 lock(true);const epoch=++generation;controller?.abort();controller=new AbortController();status.textContent='対応を認証して保存しています…';
 try{const result=await authorize(resolutionBase+'/'+operation+'/'+identity+'/'+revision,operation,epoch),value=await result.response.json();if(epoch!==generation)return;
 if(value.caseReferenceHmac!==route[1]||value.operation!==operation||value.revision!==revision+1||!['available_in_app','not_created_source_unavailable'].includes(value.reply)||value.recipientViewed!==false)throw Error('response');
 erase();releaseConfirmed.checked=false;await loadState(epoch);status.textContent=(operation==='release'?'この通報による非表示を解除しました。':'対応を保存しました。')+(value.reply==='available_in_app'?'通報した人がアプリで返答を確認できます。閲覧済みかは分かりません。':'通報の保存期限などにより返答は作られていません。')+(resolution.hidden&&operation==='release'?'別の通報による非表示は継続しています。':'');
 }catch{if(epoch===generation){erase();resolution=null;releaseSection.hidden=true;status.textContent='結果を確認できません。一覧へ戻って状態を確認してください。同じ操作は自動で再送しません。'}}finally{if(epoch===generation)lock(false)}
}
finish.addEventListener('click',()=>resolve(document.querySelector('input[name=action]:checked').value));releaseButton.addEventListener('click',()=>resolve('release'));
if(!base){open.disabled=true;status.textContent='通報一覧から写真を選び直してください。'}
else{const epoch=++generation;controller=new AbortController();lock(true);loadState(epoch).then(()=>{if(epoch===generation)status.textContent=resolution.canRelease?'この通報による非表示は継続中です。解除操作は下にあります。':resolution.targetAvailable?'写真を開いて確認してください。':'共有期限などにより、この写真への操作はできません。'}).catch(()=>{if(epoch===generation){resolution=null;status.textContent='対応状態を確認できません。一覧から開き直してください。'}}).finally(()=>{if(epoch===generation)lock(false)})}
</script></body></html>`, { headers: { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store",
    "Content-Security-Policy": `default-src 'none'; script-src 'nonce-${nonce}'; style-src 'nonce-${nonce}'; img-src blob:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'`,
    "Referrer-Policy": "no-referrer", "X-Content-Type-Options": "nosniff", "X-Frame-Options": "DENY" } });
}
