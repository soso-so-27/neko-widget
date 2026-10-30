import { pathToFileURL } from 'node:url';

// GET cannot reserve a report. The disabled gate is checked before method/authentication.
// Any enabled/unknown route fails closed without consuming a nonce or writing a record.
export async function check(fetcher = fetch) {
  const response = await fetcher('https://neko-window-sharing-staging.nakanishisoya.workers.dev/v3/group-windows/AAAAAAAAAAAAAAAAAAAAAA/reports/reserve',
    { method: 'GET', redirect: 'error', signal: AbortSignal.timeout(10000) });
  const body = await response.json();
  if (response.status !== 503 || body.error?.code !== 'group_reports_disabled') {
    throw Error('Group reporting must be OFF for owner internal release. No server setting was changed.');
  }
}
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  await check();
  console.log('PASS group reporting OFF (read-only; legacy report OFF is checked by staging runtime preflight)');
}
