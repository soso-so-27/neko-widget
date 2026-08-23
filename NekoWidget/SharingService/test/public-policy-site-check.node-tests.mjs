import assert from "node:assert/strict";
import test from "node:test";

import {
  checkPublicPolicySite,
  isPublicIpAddress,
  normalizePublicHttpsSiteBase,
  publicPolicyPageSpecifications,
} from "../scripts/public-policy-site-check-lib.mjs";

const siteBase = "https://policy.example.net/neko-widget/";
const revision = "2026-08-24";
const policyUrls = publicPolicyPageSpecifications.map((page) => new URL(page.path, siteBase).href);

function pageHtml(page, overrides = {}) {
  const h1 = overrides.h1 ?? page.h1;
  const pageRevision = overrides.revision ?? revision;
  const links = overrides.links ?? policyUrls;
  const phrases = overrides.phrases ?? page.requiredPhrases;
  const extraHead = overrides.extraHead ?? "";
  const visibleRevision = page.name === "overview" ? "" : "<p>最終更新日：2026年8月24日</p>";
  return `<!doctype html>
<html lang="ja"><head>
<meta charset="utf-8">
<meta name="neko-policy-revision" content="${pageRevision}">
${extraHead}
<title>ねこのまど</title></head><body>
<h1>${h1}</h1>
${visibleRevision}
${phrases.map((phrase) => `<p>${phrase}</p>`).join("\n")}
${links.map((href) => `<a href="${href}">link</a>`).join("\n")}
</body></html>`;
}

function makeFetch(overrides = new Map()) {
  return async (url, options) => {
    assert.equal(options.method, "GET");
    assert.equal(options.redirect, "manual");
    assert.equal(options.headers.Accept, "text/html; charset=utf-8");
    const page = publicPolicyPageSpecifications.find(
      (candidate) => new URL(candidate.path, siteBase).href === url,
    );
    assert.ok(page, `unexpected URL: ${url}`);
    const override = overrides.get(page.name);
    if (override instanceof Response) return override;
    const html = override ?? pageHtml(page);
    return new Response(html, {
      status: 200,
      headers: { "Content-Type": "text/html; charset=utf-8" },
    });
  };
}

const publicDns = async () => [
  { address: "8.8.8.8", family: 4 },
  { address: "2606:4700:4700::1111", family: 6 },
];

async function check(overrides = new Map(), options = {}) {
  return checkPublicPolicySite({
    siteBase,
    expectedRevision: revision,
    fetchImpl: makeFetch(overrides),
    lookupImpl: publicDns,
    ...options,
  });
}

test("accepts the complete public policy site boundary", async () => {
  const result = await check();
  assert.equal(result.pages.length, 4);
  assert.deepEqual(result.pages.map(({ name, status, revision: actual }) => ({ name, status, revision: actual })), [
    { name: "overview", status: 200, revision },
    { name: "privacy", status: 200, revision },
    { name: "community", status: 200, revision },
    { name: "support", status: 200, revision },
  ]);
});

test("accepts only canonical public HTTPS site bases", () => {
  assert.equal(normalizePublicHttpsSiteBase(siteBase), siteBase);
  for (const unsafe of [
    "http://policy.example.net/neko-widget/",
    "https://policy.example.net/neko-widget",
    "https://user:pass@policy.example.net/neko-widget/",
    "https://policy.example.net:8443/neko-widget/",
    "https://policy.example.net/neko-widget/?draft=1",
    "https://policy.example.net/neko-widget/#top",
    "https://localhost/neko-widget/",
    "https://127.0.0.1/neko-widget/",
    "https://service.internal/neko-widget/",
    ` ${siteBase}`,
  ]) {
    assert.throws(() => normalizePublicHttpsSiteBase(unsafe));
  }
});

test("recognizes public and non-public IP address ranges", () => {
  for (const address of ["8.8.8.8", "1.1.1.1", "2606:4700:4700::1111"]) {
    assert.equal(isPublicIpAddress(address), true, address);
  }
  for (const address of [
    "0.0.0.0",
    "10.0.0.1",
    "100.64.0.1",
    "127.0.0.1",
    "169.254.1.1",
    "172.16.0.1",
    "192.168.1.1",
    "192.0.2.1",
    "198.51.100.1",
    "203.0.113.1",
    "::",
    "::1",
    "fc00::1",
    "fe80::1",
    "ff02::1",
    "2001:db8::1",
    "2001:2::1",
    "2001:10::1",
    "2001:20::1",
    "3fff::1",
  ]) {
    assert.equal(isPublicIpAddress(address), false, address);
  }
});

test("requires DNS to resolve and return only public addresses", async () => {
  await assert.rejects(
    check(new Map(), { lookupImpl: async () => [] }),
    /did not resolve in public DNS/u,
  );
  await assert.rejects(
    check(new Map(), {
      lookupImpl: async () => [
        { address: "8.8.8.8", family: 4 },
        { address: "10.0.0.1", family: 4 },
      ],
    }),
    /only to public IP addresses/u,
  );
  await assert.rejects(
    check(new Map(), { lookupImpl: async () => { throw new Error("not found"); } }),
    /did not resolve in public DNS: not found/u,
  );
});

test("rejects redirects and non-200 responses", async () => {
  await assert.rejects(
    check(new Map([[
      "overview",
      new Response(null, { status: 302, headers: { Location: "https://example.org/" } }),
    ]])),
    /overview returned a redirect/u,
  );
  await assert.rejects(
    check(new Map([[
      "privacy",
      new Response("missing", {
        status: 404,
        headers: { "Content-Type": "text/html; charset=utf-8" },
      }),
    ]])),
    /privacy returned HTTP 404; expected 200/u,
  );
});

test("requires text/html with an explicit UTF-8 charset", async () => {
  await assert.rejects(
    check(new Map([[
      "overview",
      new Response(pageHtml(publicPolicyPageSpecifications[0]), {
        status: 200,
        headers: { "Content-Type": "text/plain; charset=utf-8" },
      }),
    ]])),
    /did not return text\/html/u,
  );
  await assert.rejects(
    check(new Map([[
      "overview",
      new Response(pageHtml(publicPolicyPageSpecifications[0]), {
        status: 200,
        headers: { "Content-Type": "text/html" },
      }),
    ]])),
    /did not declare charset=utf-8/u,
  );
});

test("enforces both declared and streamed response size limits", async () => {
  const page = publicPolicyPageSpecifications[0];
  const html = pageHtml(page);
  await assert.rejects(
    check(new Map([[
      "overview",
      new Response(html, {
        status: 200,
        headers: {
          "Content-Type": "text/html; charset=utf-8",
          "Content-Length": "999999",
        },
      }),
    ]])),
    /exceeds the 262144-byte response limit/u,
  );
  await assert.rejects(
    check(new Map(), { maximumBytes: 32 }),
    /exceeds the 32-byte response limit/u,
  );
});

test("rejects malformed UTF-8 bodies", async () => {
  await assert.rejects(
    check(new Map([[
      "overview",
      new Response(new Uint8Array([0xc3, 0x28]), {
        status: 200,
        headers: { "Content-Type": "text/html; charset=utf-8" },
      }),
    ]])),
    /body is not valid UTF-8/u,
  );
});

test("requires exactly one expected h1", async () => {
  const page = publicPolicyPageSpecifications[0];
  await assert.rejects(
    check(new Map([["overview", pageHtml(page, { h1: "wrong" })]])),
    /unexpected h1/u,
  );
  await assert.rejects(
    check(new Map([["overview", pageHtml(page).replace("</h1>", "</h1><h1>duplicate</h1>")]])),
    /exactly one complete h1/u,
  );
});

test("requires one exact policy revision on every page", async () => {
  const page = publicPolicyPageSpecifications[0];
  await assert.rejects(
    check(new Map([["overview", pageHtml(page, { revision: "2026-08-23" })]])),
    /policy revision 2026-08-23; expected 2026-08-24/u,
  );
  await assert.rejects(
    check(new Map([[
      "overview",
      pageHtml(page, {
        extraHead: '<meta name="neko-policy-revision" content="2026-08-24">',
      }),
    ]])),
    /exactly one neko-policy-revision/u,
  );
});

test("requires the visible revision on policy detail pages", async () => {
  const page = publicPolicyPageSpecifications[1];
  await assert.rejects(
    check(new Map([[
      "privacy",
      pageHtml(page).replace("<p>最終更新日：2026年8月24日</p>", ""),
    ]])),
    /privacy is missing the visible policy revision/u,
  );
});

test("requires the policy safety content for each route", async () => {
  const page = publicPolicyPageSpecifications[1];
  const phrases = page.requiredPhrases.filter((phrase) => phrase !== "通報専用公開鍵");
  await assert.rejects(
    check(new Map([["privacy", pageHtml(page, { phrases })]])),
    /privacy is missing required policy content: 通報専用公開鍵/u,
  );
});

test("requires every page to link to all policy routes", async () => {
  const page = publicPolicyPageSpecifications[2];
  await assert.rejects(
    check(new Map([["community", pageHtml(page, { links: policyUrls.slice(0, -1) })]])),
    /does not link to every public policy page/u,
  );
});

test("rejects unresolved, escaping, and non-HTTPS links", async () => {
  const page = publicPolicyPageSpecifications[3];
  for (const unsafe of [
    [...policyUrls, `${siteBase}missing/`],
    [...policyUrls, "https://policy.example.net/outside/"],
    [...policyUrls, "http://example.org/"],
  ]) {
    await assert.rejects(check(new Map([["support", pageHtml(page, { links: unsafe })]])));
  }
});

test("rejects invalid revisions and option limits before network access", async () => {
  await assert.rejects(
    checkPublicPolicySite({
      siteBase,
      expectedRevision: "2026/08/24",
      fetchImpl: makeFetch(),
      lookupImpl: publicDns,
    }),
    /must use YYYY-MM-DD/u,
  );
  await assert.rejects(
    checkPublicPolicySite({
      siteBase,
      expectedRevision: "2026-02-31",
      fetchImpl: makeFetch(),
      lookupImpl: publicDns,
    }),
    /must be a real calendar date/u,
  );
  await assert.rejects(check(new Map(), { timeoutMs: 0 }), /timeout must be an integer/u);
  await assert.rejects(check(new Map(), { maximumBytes: 1024 * 1024 + 1 }), /maximum response bytes/u);
});

test("fails closed when a page request exceeds its timeout", async () => {
  const fetchImpl = async (_url, { signal }) => new Promise((_resolve, reject) => {
    signal.addEventListener("abort", () => reject(signal.reason), { once: true });
  });
  await assert.rejects(
    checkPublicPolicySite({
      siteBase,
      expectedRevision: revision,
      fetchImpl,
      lookupImpl: publicDns,
      timeoutMs: 10,
    }),
    /timed out/u,
  );
});
