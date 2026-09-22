import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { inspectJPEG } from './jpeg-envelope.js';
import { DECODE_TIMEOUT_MS, Unavailable } from './limits.js';

// Deadline covers process startup and libuv queueing too. Killing the process stops
// native work; Promise.race alone would merely stop waiting for it.
export async function validateJPEG(bytes: Uint8Array, signal?: AbortSignal): Promise<boolean> {
  if (signal?.aborted) throw new Unavailable();
  if (!inspectJPEG(bytes)) return false;
  return new Promise<boolean>((resolve, reject) => {
    const child = spawn(process.execPath, ['--max-old-space-size=128',
      fileURLToPath(new URL('./decode-child.js', import.meta.url))], {
      serialization: 'advanced', stdio: ['ignore', 'ignore', 'ignore', 'ipc'],
      windowsHide: true,
      // Do not pass server credentials or NODE_OPTIONS to the disposable decoder.
      env: { ...(process.env.SystemRoot ? { SystemRoot: process.env.SystemRoot } : {}),
        UV_THREADPOOL_SIZE: '1', VIPS_CONCURRENCY: '1' },
    });
    let result: boolean | undefined;
    let failed = false;
    const stop = () => { failed = true; child.kill('SIGKILL'); };
    const timer = setTimeout(stop, DECODE_TIMEOUT_MS);
    signal?.addEventListener('abort', stop, { once: true });
    child.once('error', stop);
    child.once('message', (value: unknown) => {
      if (value && typeof value === 'object' && Object.keys(value).length === 1
        && 'valid' in value && typeof value.valid === 'boolean') result = value.valid;
      else stop();
    });
    child.once('close', (code) => {
      clearTimeout(timer);
      signal?.removeEventListener('abort', stop);
      if (failed || code !== 0 || result === undefined) reject(new Unavailable());
      else resolve(result);
    });
    child.send!(bytes, (error) => { if (error) stop(); });
    if (signal?.aborted) stop();
  });
}
