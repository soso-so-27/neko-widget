import path from 'node:path';
import { cloudflareTest, readD1Migrations } from '@cloudflare/vitest-pool-workers';
import { configDefaults, defineConfig } from 'vitest/config';
export default defineConfig(async () => ({
  plugins: [cloudflareTest({ wrangler: { configPath: './wrangler.jsonc' },
    miniflare: { bindings: {
      TEST_MIGRATIONS: await readD1Migrations(path.join(import.meta.dirname, 'migrations')),
      TEST_BILLING_MIGRATIONS: (await readD1Migrations(path.join(import.meta.dirname, '../SharingService/migrations')))
        .filter(migration => /^00(19|20|21)_/u.test(migration.name)),
    } } })],
  test: { setupFiles: ['./test/setup.ts'],
    exclude: [...configDefaults.exclude, 'test/live-staging-*.integration.test.ts'] },
}));
