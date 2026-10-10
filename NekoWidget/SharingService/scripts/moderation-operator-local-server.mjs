import http from 'node:http';
import {Readable} from 'node:stream';
import {pipeline} from 'node:stream/promises';

const bodyLimit = 32768;
const failure = (out, status) => { out.writeHead(status, {'Content-Type':'application/json','Cache-Control':'no-store','X-Content-Type-Options':'nosniff'}); out.end(JSON.stringify({error:'local_operator_connection_unavailable'})); };

/** Loopback transport behind the configured HTTPS Access front door.
 * Forwarded headers never choose the origin or confer authentication. */
export async function startLoopbackOperatorServer({origin, port, handler, authenticate, ready, requestTimeoutMilliseconds=20000}) {
  const canonical = new URL(origin);
  if (canonical.protocol !== 'https:' || canonical.origin !== origin || canonical.username || canonical.password
      || !Number.isInteger(port) || port < 0 || port > 65535
      || !Number.isInteger(requestTimeoutMilliseconds) || requestTimeoutMilliseconds < 1 || requestTimeoutMilliseconds > 20000
      || typeof handler !== 'function' || typeof authenticate !== 'function') throw Error('invalid_local_operator_transport');
  const active = new Set();
  const pending = new Set();
  const handle = async (input, output) => {
    let controller;
    let timer;
    let result;
    try {
      const duplicates = new Set();
      for (let i=0;i<input.rawHeaders.length;i+=2) {
        const name=input.rawHeaders[i].toLowerCase();
        if (['host','origin','cf-access-jwt-assertion','content-length','content-type','transfer-encoding'].includes(name)) {
          if (duplicates.has(name)) return failure(output,400);
          duplicates.add(name);
        }
      }
      if (input.headers.host !== `127.0.0.1:${server.address().port}`) return failure(output,403);
      if (input.url === '/health' && input.method === 'GET') {
        output.writeHead(200, {'Content-Type':'application/json','Cache-Control':'no-store'});
        output.end(JSON.stringify({mode:'local',remoteBindings:false,frontDoorRequired:true,ownerReviewConfigured:false,...ready}));
        return;
      }
      if (!/^\/operator(?:\/[A-Za-z0-9_-]+)*$/u.test(input.url) || !['GET','POST'].includes(input.method)) return failure(output,404);
      if (active.size >= 4) return failure(output,429);
      controller = new AbortController();
      active.add(controller);
      timer = setTimeout(() => {controller.abort();output.destroy();},requestTimeoutMilliseconds);
      input.once('aborted',() => controller.abort());
      output.once('close',() => { if (!output.writableFinished) controller.abort(); });
      const headers = new Headers();
      for (const name of ['origin','cf-access-jwt-assertion','content-type']) {
        if (input.headers[name] !== undefined) headers.set(name,input.headers[name]);
      }
      const requestURL = origin+input.url;
      // Authenticate before reading a body or dispatching the data-free HTML pages.
      try { await authenticate(new Request(requestURL,{method:input.method,headers,signal:controller.signal})); }
      catch { return failure(output,401); }
      if (controller.signal.aborted) return failure(output,503);
      if (input.method === 'POST' && headers.get('origin') !== origin) return failure(output,403);
      let size=0;
      const chunks=[];
      const abortBody = () => input.destroy();
      controller.signal.addEventListener('abort',abortBody,{once:true});
      try {
        for await (const chunk of input) {
          size += chunk.length;
          if (size > bodyLimit) return failure(output,413);
          chunks.push(chunk);
        }
      } finally { controller.signal.removeEventListener('abort',abortBody); }
      if (controller.signal.aborted || (input.method === 'GET' && size !== 0)) return failure(output,400);
      result = await handler(new Request(requestURL,{method:input.method,headers,signal:controller.signal,
        ...(input.method === 'POST' && size ? {body:Buffer.concat(chunks)} : {})}));
      if (controller.signal.aborted) return failure(output,503);
      output.writeHead(result.status,Object.fromEntries(result.headers));
      if (result.body) await pipeline(Readable.fromWeb(result.body),output,{signal:controller.signal});
      else output.end();
    } catch {
      if (!output.headersSent && !output.destroyed) failure(output,503);
      else output.destroy();
    } finally {
      clearTimeout(timer);
      if (controller) active.delete(controller);
      if (result?.body && !result.body.locked) await result.body.cancel().catch(() => {});
    }
  };
  const server = http.createServer({maxHeaderSize:24576}, (input,output) => {
    const task=handle(input,output);
    pending.add(task);
    void task.finally(() => pending.delete(task));
  });
  server.requestTimeout = 20000;
  server.headersTimeout = 10000;
  server.keepAliveTimeout = 1000;
  await new Promise((resolve,reject) => {
    server.once('error',reject);
    server.listen(port,'127.0.0.1',() => { server.removeListener('error',reject); resolve(); });
  });
  return {port:server.address().port, close:async () => {
    for (const controller of active) controller.abort();
    const closed = new Promise(resolve => server.close(resolve));
    server.closeAllConnections();
    await closed;
    // Aborting transport does not roll back an already accepted atomic DB write.
    // Keep its DB/key dependencies alive until every dispatched callback settles.
    await Promise.allSettled([...pending]);
  }};
}
