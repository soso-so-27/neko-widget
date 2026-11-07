# Anonymous daily usage ingestion

`POST /v1/usage` accepts schema 1 from the 1107 usage specification. No authentication, cookies, persistent device ID or external analytics SDK. Only allowlisted count names/state values are stored. Unknown count names are discarded. App versions are bounded numeric versions; OS is validated then discarded.

- `day + HMAC-SHA256(secret, day + daily UUID)` deduplicates retries across app versions. The raw UUID is never stored. Production/staging secrets are independent, managed as Worker secrets.
- `usage_days`, `usage_events`, `usage_states` contain aggregate counts only. Devices means daily batches, not independently verified people/devices.
- `usage_dedup` expires no later than 7 days 23 hours after receipt (earlier for old reports). A 15-minute cron and ingestion cleanup remove expired rows. Cron/platform outages can delay physical deletion; this is not a guarantee of provider backup erasure. D1 Time Travel is separate provider-managed recovery storage.
- Daily reports up to 7 days old are accepted; the next UTC date is allowed for client timezones. Payload max 16KiB, max 100 input names, each known count integer 0…10,000; unknown state properties discarded.
- Constant-key rate limiting: 120 requests/minute per Cloudflare location, no IP-derived key. An atomic database quota caps new batches at 5,000 per UTC receipt day. Duplicate accepted batches still return 204. This is abuse reduction, not verified unique-client enforcement.
- `db.batch` makes dedup/quota/aggregate writes atomic. A transient per-request marker only gates the transaction; it is cleared before commit. Failure returns 503; retry is safe.
- Response: 204 accepted/duplicate; 400 invalid; 415 wrong content type; 429 rate/quota; 503 unavailable. Response bodies contain no input. Workers logs/logpush/tails are disabled. No console logging.

## Deployment / rollback

Existing Workers Standard account; separate new Workers and D1 databases for staging/production. No existing business service, DNS, Access, Apple setting or customer data is changed. Configs contain resource IDs, never secrets. Fixed cost does not increase; included-plan limits and overage charges still apply.

1. Create a dedicated D1 per environment and apply `schema.sql` only to that empty DB.
2. `node NekoWidget/SharingService/node_modules/wrangler/bin/wrangler.js deploy --config UsageService/wrangler.staging.json`
3. Set a random 32-byte `HMAC_KEY` through secret stdin, never logs/repository. Without it the endpoint returns 503.
4. Verify synthetic duplicate POST/readback and log settings. Repeat production.
5. Future rollback: deploy the prior Worker version; retain its DB and HMAC secret so dedup history survives. To stop sending, ship an empty `UsageReportURL`. To stop accepting immediately, disable the dedicated endpoint or deploy a 503 response; do not clear aggregates or affect business services.

`0.0 (1)` is the reserved synthetic app version and excluded from exported reports. The initial synthetic fixture remains in each dedicated DB, not in user data.

## Export

Run from repository root with existing authenticated Wrangler:

```powershell
node UsageService/export.mjs production 2026-11-01 2026-11-30 C:\Users\soya_\Documents\usage-2026-11
```

Writes aggregate-only `days.csv`, `events.csv`, `states.csv`, `plus.csv` into a new directory. No public export endpoint. `device_fraction` uses same-day/app reporting batches as denominator. `count_ratio` compares daily offer/purchase event totals, not a person-linked conversion funnel or cross-day cohort. Purchase-only contexts are included with zero shown and empty ratio. Empty data still writes headers.

## Build / disclosure

- Production App Store candidate → production URL; media-staging → staging; disabled/pairing/review-preview → empty; synthetic production CI → empty. Share extension/widget have no usage endpoint.
- Existing ProductInteraction stays Linked=true, Tracking=false. Analytics is added beside AppFunctionality as approved; no duplicate entry. Anonymous ingestion does not erase the app's separate existing linked functionality declaration.
- No App Store Connect or public privacy page changes in this PR. Claude handles counting, opt-out UI and public text.

Tests: `node --test UsageService/worker.test.mjs` uses the SharingService locked Miniflare dependency and real local D1. `python NekoWidget/ci/test-usage-report-config.py` checks URL separation/manifest. Existing production and owner archive validators bind the processed endpoint.
