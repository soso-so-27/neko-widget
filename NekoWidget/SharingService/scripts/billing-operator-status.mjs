#!/usr/bin/env node
import { open } from 'node:fs/promises';
import { billingOperatorStatusSQL, renderBillingOperatorSnapshot } from './billing-operator-status-lib.mjs';

try {
  const args = process.argv.slice(2);
  if (args.length === 1 && args[0] === '--sql') {
    console.log(billingOperatorStatusSQL);
  } else if (args.length === 1 && args[0] === '--help') {
    console.log('Usage: node scripts/billing-operator-status.mjs --sql | --input <local-snapshot.json>\n--sql prints a read-only SELECT; it never executes it. --input renders only the validated snapshot column JSON. Remote acquisition requires a separately approved process.');
  } else if (args.length === 2 && args[0] === '--input' && !/^(?:[a-z]+:\/\/|[\\/]{2})/iu.test(args[1])) {
    const file = await open(args[1], 'r');
    try {
      const stat = await file.stat();
      if (!stat.isFile() || stat.size > 65536) throw new Error();
      // Bound the actual read too, in case the file changes after stat().
      const data = Buffer.alloc(65537);
      const { bytesRead } = await file.read(data, 0, data.length, 0);
      if (bytesRead > 65536) throw new Error();
      console.log(renderBillingOperatorSnapshot(data.subarray(0, bytesRead).toString('utf8')));
    } finally { await file.close(); }
  } else {
    throw new Error();
  }
} catch {
  // Do not print file contents, paths, or arbitrary parser/OS error details.
  console.error('FAIL billing operator status: invalid arguments or local snapshot');
  process.exitCode = 1;
}
