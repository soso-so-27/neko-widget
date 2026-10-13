import assert from 'node:assert/strict';
import fs from 'node:fs';
import { test } from 'node:test';
const sdk=fs.readFileSync(new URL('./lib/container.js',import.meta.resolve('@cloudflare/containers')),'utf8');
function method(name,next){const a=sdk.indexOf('    async '+name+'(');const b=sdk.indexOf('    '+next,a+1);assert.ok(a>=0&&b>a);return sdk.slice(a,b).trim().replace('async '+name+'(', 'async function(');}
const constants=sdk.slice(sdk.indexOf('const NO_CONTAINER_INSTANCE_ERROR'),sdk.indexOf('export function outboundParams'));
const helpers='const isNoInstanceError=e=>String(e?.message??e).includes(NO_CONTAINER_INSTANCE_ERROR);const isNotListeningError=e=>String(e?.message??e).includes(NOT_LISTENING_ERROR);const addTimeoutSignal=(signal)=>signal;';
function context({abortAt=Infinity}={}){
 let clock=0,polls=0,healthy=false;const abort=new AbortController();
 // Only the synthetic platform/clock is replaced: these are pinned SDK method bodies.
 const tick=(resolve,ms)=>{clock+=ms;if(clock>=abortAt)abort.abort();resolve();};
 const compile=(name,next)=>new Function('setTimeout',constants+helpers+'return ('+method(name,next)+');')(tick);
 const start=compile('doStartContainer','setupMonitorCallbacks()');
 const startup=compile('startAndWaitForPorts','/**');const wait=compile('waitForPort','// =======================');
 const physical={running:false,start(){this.running=true;},monitor(){return Promise.resolve(new Error('there is no container instance that can be provided to this durable object'));},getTcpPort(){return{async fetch(){polls++;if(abort.signal.aborted)throw Error('aborted');if(clock<9000)throw Error('there is no container instance that can be provided to this durable object');if(clock<11000)throw Error('the container is not listening');}};}};
 const instance={container:physical,defaultPort:8080,ctx:{blockConcurrencyWhile:async f=>f(),abort(){throw Error('unexpected platform abort');}},state:{async setRunning(){},async setStopped(){},async setHealthy(){healthy=true;}},async getPortsToCheck(){return[8080];},async syncPendingStoppedEvents(){},async scheduleNextAlarm(){},async refreshOutboundInterception(){},renewActivityTimeout(){},onError(){},setupMonitorCallbacks(){},onStart(){},startContainerIfNotRunning(opts,startOptions){return start.call(this,opts,startOptions);},waitForPort(opts){return wait.call(this,opts);}};
 return{run:options=>startup.call(instance,{ports:8080,cancellationOptions:{abort:abort.signal,...options}}),result:()=>({clock,polls,healthy,aborted:abort.signal.aborted})};
}
test('SDK default instance retry budget rejects a legal nine-second cold start',async()=>{
 const probe=context();await assert.rejects(probe.run({}),/there is no container instance/);
 assert.deepEqual(probe.result(),{clock:8100,polls:27,healthy:false,aborted:false});
});
test('configured SDK retry budgets accept nine-second instance and eleven-second port readiness',async()=>{
 const probe=context();await probe.run({instanceGetTimeoutMS:20000,portReadyTimeoutMS:30000});
 const result=probe.result();assert.ok(result.clock>=11000&&result.clock<12000);assert.equal(result.healthy,true);assert.equal(result.aborted,false);
});
test('configured startup still obeys the generation cancellation signal',async()=>{
 const probe=context({abortAt:1500});await assert.rejects(probe.run({instanceGetTimeoutMS:20000,portReadyTimeoutMS:30000}),/cancellation signal/);
 assert.equal(probe.result().healthy,false);assert.equal(probe.result().aborted,true);assert.equal(probe.result().clock,1500);
});
