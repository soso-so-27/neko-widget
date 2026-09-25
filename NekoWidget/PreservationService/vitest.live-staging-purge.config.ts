import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    environment: 'node',
    include: ['test/live-staging-s3-purge.integration.test.ts'],
    testTimeout: 30_000,
  },
});
