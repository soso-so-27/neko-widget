import { cloudflareTest } from '@cloudflare/vitest-pool-workers';
import { defineConfig } from 'vitest/config';

export default defineConfig({
  plugins: [cloudflareTest({
    wrangler: { configPath: './wrangler.kms.disabled.jsonc' },
    miniflare: { bindings: {
      PRESERVATION_KMS_ENABLED: 'YES',
      KMS_REGION: 'ap-northeast-1',
      KMS_KEY_ARN: 'arn:aws:kms:ap-northeast-1:164892691568:key/339319dc-388b-4bd7-adb8-29d37d836d72',
      KMS_ACCESS_KEY_ID: process.env.NEKO_PROBE_AWS_ACCESS_KEY_ID ?? '',
      KMS_SECRET_ACCESS_KEY: process.env.NEKO_PROBE_AWS_SECRET_ACCESS_KEY ?? '',
      KEY_WRAPPER_CALLER_SECRET: 's'.repeat(43),
    } },
  })],
  test: { include: ['test/live-staging-kms.integration.test.ts'], testTimeout: 30_000 },
});
