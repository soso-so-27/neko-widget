import { pathToFileURL } from "node:url";

const origin = "https://neko-window-sharing-staging.nakanishisoya.workers.dev";
const maximumAdmissionMs = 7 * 24 * 60 * 60 * 1000;

// An ordinary Sandbox gateway is insufficient. The staging Worker must attest
// that it has the restricted two-device policy while the feature gates are closed.
export async function checkOwnerTwoDeviceBilling(url, { fetchImpl = fetch, now = Date.now() } = {}) {
  if (url !== origin) throw new Error("Two-device billing origin is not the reviewed staging endpoint.");
  const response = await fetchImpl(origin + "/v1/billing/health", {
    redirect: "error",
    cache: "no-store",
    signal: AbortSignal.timeout(10000),
  });
  if (response.status !== 200) throw new Error(`Two-device billing health returned HTTP ${response.status}.`);

  const required = {
    "neko-owner-two-device-readiness": "READY",
    "neko-owner-two-device-feature-gates": "OFF",
    "neko-runtime-billing-owner-admission": "READY",
    "neko-runtime-billing-transaction-ingestion": "ON",
    "neko-runtime-billing-effective-entitlement": "ON",
  };
  for (const [header, value] of Object.entries(required)) {
    if (response.headers.get(header) !== value) {
      throw new Error(`Two-device billing health did not confirm ${header}=${value}.`);
    }
  }
  const rawExpiry = response.headers.get("neko-owner-two-device-admission-expires-at-ms");
  const expiry = Number(rawExpiry);
  if (!/^[0-9]{13}$/u.test(rawExpiry ?? "") || expiry <= now || expiry - now > maximumAdmissionMs) {
    throw new Error("Two-device billing admission expiry is invalid.");
  }
  return new Date(expiry).toISOString();
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    const expiry = await checkOwnerTwoDeviceBilling(process.argv[2]);
    console.log(`PASS owner two-device Sandbox readiness; feature gates OFF; expiry ${expiry}.`);
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
