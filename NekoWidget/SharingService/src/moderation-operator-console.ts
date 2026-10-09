/** Local integration console only. No embedded identity, evidence or token.
 * All data and operations use the authenticated triage route. No new grant,
 * decision, disclosure, notification or production route is introduced here.
 */
export function localModerationConsole(): Response {
  const nonce = crypto.randomUUID().replaceAll("-", "");
  return new Response(`<!doctype html><html lang="ja"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>通報の確認｜ねこのまど</title>
<style nonce="${nonce}">
:root{font-family:system-ui,sans-serif;color:#19362e;background:#f3f5f1;color-scheme:light}
*{box-sizing:border-box}body{margin:0}main{max-width:1040px;margin:auto;padding:36px 24px 72px}
header{display:flex;align-items:center;justify-content:space-between;gap:20px;margin-bottom:30px}
h1{font-size:30px;letter-spacing:.03em;margin:6px 0}h2{font-size:18px;margin:0 0 12px}p{line-height:1.7}
.eyebrow{font-size:13px;letter-spacing:.12em;color:#546a62}.note{padding:18px 22px;background:#e5ede7;border-radius:12px}
.muted{color:#536b61;font-size:14px}.case{background:white;border:1px solid #d4dfd7;border-radius:16px;padding:22px;margin:16px 0}
.row{display:flex;justify-content:space-between;align-items:flex-start;gap:20px}.label{font-size:13px;padding:4px 10px;border-radius:20px;background:#e9efe9;white-space:nowrap}
.urgent{color:#8b371c;background:#fff0df}.ref{font-family:monospace;overflow-wrap:anywhere}.action{margin-top:12px}
button{font:inherit;font-weight:600;border-radius:10px;padding:12px 18px;border:1px solid #b5c7bb;background:white;color:#214e3e;cursor:pointer;min-height:46px}
button.primary{background:#245b47;color:white;border-color:#245b47}button:disabled{opacity:.55;cursor:default}
button:focus-visible{outline:3px solid #be742e;outline-offset:3px}#status{min-height:24px;margin:20px 0;line-height:1.7}
details{margin:14px 0}summary{cursor:pointer}#more{color:#87451e}footer{margin-top:32px;border-top:1px solid #d4dfd7;padding-top:18px}
@media(max-width:560px){main{padding:24px 16px 48px}header{align-items:flex-start}h1{font-size:25px}.row{display:block}.label{display:inline-block;margin-bottom:12px}.case{padding:18px}button{width:100%}header button{width:auto}}
</style></head><body><main>
<header><div><div class="eyebrow">ねこのまど / 運営用</div><h1>通報の確認</h1></div><button id="refresh">一覧を更新</button></header>
<div class="note"><strong>ローカル検証版</strong><p>受付状況とAIの補助結果を確認できます。本人に限定した写真の確認と「対応不要」の判断・返信案保存へ進めます。返信送信や非表示処理は行いません。</p></div>
<p id="status" role="status" aria-live="polite">認証と通報一覧を確認しています…</p>
<div id="cases" aria-label="通報一覧"></div><p id="more"></p><button id="next" hidden>次の20件</button>
<footer class="muted">AIは判断の補助です。未処理・失敗した通報も確認対象に残ります。表示順は確認期限順です。</footer>
</main><script nonce="${nonce}">
"use strict";
const list=document.getElementById('cases'), status=document.getElementById('status'), more=document.getElementById('more'), refresh=document.getElementById('refresh'), next=document.getElementById('next');
let busy=false, generation=0, controller=null, nextPage=null;
const reasons={not_requested:'AI補助は未実施',pending:'AI処理の確認待ち',advisory_ready:'AI補助結果あり・本人の確認が必要',child_safety_hold:'専門的な確認が必要・AIへ送信していません',safety_route_unreviewed:'送信前の確認待ち・AIへ送信していません',provider_unavailable:'AIとの通信に失敗・本人の確認待ち',provider_timeout:'AIの応答待ちが終了・本人の確認待ち',provider_invalid:'AIの応答を利用できません・本人の確認待ち',stale_evidence:'証拠が更新されています・再確認が必要'};
function el(tag,text,className){const e=document.createElement(tag);if(text!==undefined)e.textContent=text;if(className)e.className=className;return e}
function clear(){list.replaceChildren();more.textContent='';next.hidden=true;nextPage=null}
function lock(value){busy=value;refresh.disabled=value;next.disabled=value;for(const b of list.querySelectorAll('button'))b.disabled=value}
function expired(){generation++;controller?.abort();clear();lock(false);status.textContent='画面を離れたため表示を消しました。一覧を更新して再確認してください。'}
document.addEventListener('visibilitychange',()=>{if(document.hidden)expired()});window.addEventListener('pagehide',expired);
function failure(error){clear();status.textContent=error?.name==='NotAllowedError'?'署名は完了していません。一覧を更新して状態を確認してください。':error?.status===401||error?.status===403?'認証または権限を確認できません。運営用のログインを確認してください。':'結果を確認できません。一覧を更新してください。同じ署名は自動で再送しません。'}
async function api(path,body){
  const result=await fetch(path,{method:'POST',credentials:'same-origin',redirect:'error',cache:'no-store',signal:AbortSignal.any([controller.signal,AbortSignal.timeout(15000)]),...(body===undefined?{}:{headers:{'Content-Type':'application/json'},body:JSON.stringify(body)})});
  if(!result.ok){const error=new Error('request_failed');error.status=result.status;throw error}return result.json();
}
function decode(value){if(typeof value!=='string'||!/^[A-Za-z0-9_-]{43}$/.test(value))throw Error('challenge');return Uint8Array.from(atob(value.replaceAll('-','+').replaceAll('_','/')+'='),c=>c.charCodeAt(0))}
function encode(value){return btoa(String.fromCharCode(...new Uint8Array(value))).replaceAll('+','-').replaceAll('/','_').replace(/=+$/,'')}
async function begin(item){
  if(busy)return;lock(true);const epoch=++generation;controller=new AbortController();
  const path='/operator/v1/cases/'+item.caseReferenceHmac+'/review-start';
  try{
    status.textContent='確認開始の署名を準備しています…';
    const challenge=await api(path);
    if(epoch!==generation)return;
    if(challenge.rpId!==location.hostname||challenge.userVerification!=='required'||!Number.isSafeInteger(challenge.expiresAt)||challenge.expiresAt*1000<=Date.now()||challenge.expiresAt*1000>Date.now()+300000||typeof challenge.challengeId!=='string'||!/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(challenge.challengeId)||challenge.assertionPath!==path+'/assertions/'+challenge.challengeId)throw Error('challenge');
    if(!window.PublicKeyCredential||!navigator.credentials)throw Error('authenticator_unavailable');
    status.textContent='登録済みの認証器で確認開始を署名してください。';
    const credential=await navigator.credentials.get({publicKey:{challenge:decode(challenge.challenge),rpId:challenge.rpId,userVerification:'required',timeout:Math.min(60000,challenge.expiresAt*1000-Date.now())},signal:controller.signal});
    if(epoch!==generation)return;
    if(!credential||credential.type!=='public-key')throw Error('credential');
    const proof={id:credential.id,rawId:encode(credential.rawId),type:credential.type,clientExtensionResults:credential.getClientExtensionResults(),response:{clientDataJSON:encode(credential.response.clientDataJSON),authenticatorData:encode(credential.response.authenticatorData),signature:encode(credential.response.signature)}};
    if(credential.authenticatorAttachment)proof.authenticatorAttachment=credential.authenticatorAttachment;
    const result=await api(challenge.assertionPath,proof);
    if(epoch!==generation)return;
    if(result.caseReferenceHmac!==item.caseReferenceHmac||result.reviewState!=='in_review')throw Error('result');
    await load('確認開始を記録しました。最終判断や返答はまだ行っていません。');
  }catch(error){if(epoch===generation)failure(error)}finally{if(epoch===generation)lock(false)}
}
function render(item){
  if(!/^[0-9a-f]{64}$/.test(item.caseReferenceHmac)||!['unreviewed','in_review'].includes(item.reviewState)||!Number.isSafeInteger(item.reviewDueAt)||![0,1].includes(item.evidenceAvailable)||![0,1].includes(item.pendingFinalization)||![0,1].includes(item.slaExceeded)||!Object.hasOwn(reasons,item.advisoryReason)||!['preserve','raise'].includes(item.advisoryPriority))throw Error('response');
  const card=el('section',undefined,'case'),row=el('div',undefined,'row');
  row.append(el('h2','通報 '+item.caseReferenceHmac.slice(0,8)),el('span',item.pendingFinalization?'記録の確定待ち':item.reviewState==='in_review'?'確認中':'未確認','label'));card.append(row);
  card.append(el('p','確認期限：'+new Date(item.reviewDueAt*1000).toLocaleString('ja-JP'),item.slaExceeded?'urgent':'muted'));
  card.append(el('p',reasons[item.advisoryReason],item.advisoryPriority==='raise'?'urgent':undefined));
  if(!item.evidenceAvailable)card.append(el('p','有効な証拠を確認できません。期限切れ・削除・未準備の可能性があります。','muted'));
  const details=el('details');details.append(el('summary','照合番号を表示'),el('p',item.caseReferenceHmac,'ref'));card.append(details);
  if(item.reviewState==='unreviewed'&&!item.pendingFinalization){const button=el('button','確認開始を署名する','primary action');button.addEventListener('click',()=>begin(item));card.append(button)}
  if((item.evidenceAvailable||item.restrictionActive)&&Number.isInteger(item.caseReferenceHmacKeyVersion)&&item.caseReferenceHmacKeyVersion>0&&item.caseReferenceHmacKeyVersion<=2147483647){const link=el('a',item.restrictionActive?'非表示への対応を確認する':'写真を確認する','action');link.href='/operator/owner/console/'+item.caseReferenceHmac+'/'+item.caseReferenceHmacKeyVersion;const paragraph=el('p');paragraph.append(link);card.append(paragraph)}
  list.append(card);
}
async function load(message,after=''){
  const epoch=++generation;controller?.abort();controller=new AbortController();clear();lock(true);status.textContent='通報一覧を確認しています…';
  try{const data=await api('/operator/v1/cases/read'+after);if(epoch!==generation)return;
    if(!Array.isArray(data.cases)||data.cases.length>20||typeof data.hasMore!=='boolean'||(data.hasMore&&data.cases.length===0)||!Number.isSafeInteger(data.unboundCases)||data.unboundCases<0)throw Error('response');
    data.cases.forEach(render);status.textContent=message??(data.cases.length?'確認期限が近い通報から表示しています。':'表示できる未完了の通報はありません。');
    more.textContent=(data.hasMore?'さらに通報があります。 ':'')+(data.unboundCases?'照合番号の準備待ち：'+data.unboundCases+'件。未処理として残っています。':'');
    if(data.hasMore){const last=data.cases.at(-1);nextPage='/'+last.reviewDueAt+'/'+last.caseReferenceHmac;next.hidden=false}
  }catch(error){if(epoch===generation)failure(error)}finally{if(epoch===generation)lock(false)}
}
refresh.addEventListener('click',()=>{if(!busy)void load()});next.addEventListener('click',()=>{if(!busy&&nextPage)void load(undefined,nextPage)});void load();
</script></body></html>`, {headers: {
    "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store",
    "Content-Security-Policy": `default-src 'none'; script-src 'nonce-${nonce}'; style-src 'nonce-${nonce}'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'`,
    "Referrer-Policy": "no-referrer", "X-Content-Type-Options": "nosniff", "X-Frame-Options": "DENY",
  }});
}
