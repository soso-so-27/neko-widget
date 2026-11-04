// Public production reads only. Closed before any object-store access unless
// both the environment and the explicitly approved public gate match exactly.
import program from './program.js';

export default {
  async fetch(request, env) {
    if (env.ENVIRONMENT !== 'production' || env.INTAKE_ENABLED !== 'YES') {
      return new Response(request.method === 'HEAD' ? null : 'Feed temporarily unavailable', {
        status: 503, headers: { 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' },
      });
    }
    const prefix = env.OFFICIAL_PROGRAM_PREFIX;
    if (typeof prefix !== 'string' || !/^programs\/[a-f0-9]{64}$/.test(prefix)) {
      return new Response(null, { status: 503, headers: { 'Cache-Control': 'no-store' } });
    }
    return program.fetch(request, { OFFICIAL_ASSETS: { async fetch(input) {
      const pathname = new URL(input.url).pathname;
      const isIndex = pathname === '/__program/index.json';
      if (!isIndex && !/^\/__program\/images\/[a-f0-9]{64}\.jpg$/.test(pathname)) {
        return new Response(null, { status: 404 });
      }
      const object = await env.OFFICIAL.get(prefix + pathname);
      if (!object) return new Response(null, { status: 404 });
      const maximum = isIndex ? 256 * 1024 : 4 * 1024 * 1024;
      if (!Number.isSafeInteger(object.size) || object.size < 1 || object.size > maximum) {
        await object.body?.cancel();
        return new Response(null, { status: 503 });
      }
      return new Response(object.body);
    } } });
  },
};
