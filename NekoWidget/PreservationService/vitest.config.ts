import path from 'node:path';
import { cloudflareTest, readD1Migrations } from '@cloudflare/vitest-pool-workers';
import { configDefaults, defineConfig } from 'vitest/config';
export default defineConfig(async () => ({
  plugins: [cloudflareTest({ wrangler: { configPath: './wrangler.jsonc' },
    miniflare: { bindings: {
      TEST_MIGRATIONS: await readD1Migrations(path.join(import.meta.dirname, 'migrations')),
      // Billing's environment migration rebuilds the dependent FK/trigger
      // closure. Use the complete real schema, including its prerequisites.
      TEST_BILLING_MIGRATIONS: await readD1Migrations(path.join(import.meta.dirname, '../SharingService/migrations')),
    } } })],
  test: { setupFiles: ['./test/setup.ts'],
    exclude: [...configDefaults.exclude, 'test/live-staging-*.integration.test.ts'] },
}));
