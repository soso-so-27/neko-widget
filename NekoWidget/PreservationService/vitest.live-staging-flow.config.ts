import path from 'node:path';
import { readD1Migrations } from '@cloudflare/vitest-pool-workers';
import { cloudflareTest } from '@cloudflare/vitest-pool-workers';
import { defineConfig } from 'vitest/config';

export default defineConfig({
  plugins: [cloudflareTest({
    wrangler: { configPath: './wrangler.live-staging-flow.jsonc' },
    miniflare: { bindings: {
      TEST_MIGRATIONS: await readD1Migrations(path.join(import.meta.dirname, 'migrations')),
      NEKO_PROBE_OWNER_ID: process.env.NEKO_PROBE_OWNER_ID ?? '',
      NEKO_PROBE_AWS_ACCESS_KEY_ID: process.env.NEKO_PROBE_AWS_ACCESS_KEY_ID ?? '',
      NEKO_PROBE_AWS_SECRET_ACCESS_KEY: process.env.NEKO_PROBE_AWS_SECRET_ACCESS_KEY ?? '',
    } },
  })],
  test: { include: ['test/live-staging-flow.integration.test.ts'],
    setupFiles: ['./test/setup.ts'], testTimeout: 120_000 },
});
