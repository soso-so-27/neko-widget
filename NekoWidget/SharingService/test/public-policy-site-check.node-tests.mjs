import assert from "node:assert/strict";
import test from "node:test";

import {
  checkPublicPolicySite,
  isPublicIpAddress,
  normalizePublicHttpsSiteBase,
  publicPolicyProfiles,
  resolvePublicPolicyCheckInput,
} from "../scripts/public-policy-site-check-lib.mjs";

const revision = "2026-08-24";
const sharingBeta = Object.freeze({
  profile: "sharing-beta",
  siteBase: "https://policy.example.net/neko-widget/",
  definition: publicPolicyProfiles["sharing-beta"],
});
const localOnly = Object.freeze({
  profile: "local-only",
  siteBase: "https://policy.example.net/neko-widget/app/",
  definition: publicPolicyProfiles["local-only"],
});

function profileUrls(profileCase) {
  return profileCase.definition.pages.map(
    (page) => new URL(page.path, profileCase.siteBase).href,
  );
}

function requiredCrossProfileUrls(profileCase) {
  return profileCase.definition.requiredSharingBetaLink
    ? [new URL("../", profileCase.siteBase).href]
    : [];
}

function pageHtml(profileCase, page, overrides = {}) {
  const h1 = overrides.h1 ?? page.h1;
  const pageRevision = overrides.revision ?? revision;
  const links = overrides.links ?? [
    ...profileUrls(profileCase),
    ...requiredCrossProfileUrls(profileCase),
  ];
  const phrases = overrides.phrases ?? page.requiredPhrases;
  const extraHead = overrides.extraHead ?? "";
  const extraBody = overrides.extraBody ?? "";
  const visibleRevision = page.visibleRevision
    ? "<p>最終更新日：2026年8月24日</p>"
    : "";
  return `<!doctype html>
<html lang="ja"><head>
<meta charset="utf-8">
<meta name="neko-policy-revision" content="${pageRevision}">
${extraHead}
<title>ねこのまど</title></head><body>
<h1>${h1}</h1>
${visibleRevision}
${phrases.map((phrase) => `<p>${phrase}</p>`).join("\n")}
${extraBody}
${links.map((href) => `<a href="${href}">link</a>`).join("\n")}
</body></html>`;
}

function makeFetch(profileCase, overrides = new Map()) {
  return async (url, options) => {
    assert.equal(options.method, "GET");
    assert.equal(options.redirect, "manual");
    assert.equal(options.headers.Accept, "text/html; charset=utf-8");
    const page = profileCase.definition.pages.find(
      (candidate) => new URL(candidate.path, profileCase.siteBase).href === url,
    );
    assert.ok(page, `unexpected URL: ${url}`);
    const override = overrides.get(page.name);
    if (override instanceof Response) return override;
    const html = override ?? pageHtml(profileCase, page);
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

async function check(profileCase = sharingBeta, overrides = new Map(), options = {}) {
  return checkPublicPolicySite({
    profile: profileCase.profile,
    siteBase: profileCase.siteBase,
    expectedRevision: revision,
    fetchImpl: makeFetch(profileCase, overrides),
    lookupImpl: publicDns,
    ...options,
  });
}

test("accepts the complete sharing-beta policy profile", async () => {
  const result = await check();
  assert.equal(result.profile, "sharing-beta");
  assert.deepEqual(result.pages.map(({ name, status, revision: actual }) => ({ name, status, revision: actual })), [
    { name: "overview", status: 200, revision },
    { name: "privacy", status: 200, revision },
    { name: "community", status: 200, revision },
    { name: "support", status: 200, revision },
  ]);
});

test("accepts the separate local-only App Store policy profile", async () => {
  const result = await check(localOnly);
  assert.equal(result.profile, "local-only");
  assert.deepEqual(result.pages.map(({ name, status }) => ({ name, status })), [
    { name: "overview", status: 200 },
    { name: "privacy", status: 200 },
    { name: "support", status: 200 },
  ]);
});

test("local-only pages require the exact explicit sharing-beta root link", async () => {
  const page = localOnly.definition.pages[0];
  await assert.rejects(
    check(localOnly, new Map([[
      "overview",
      pageHtml(localOnly, page, { links: profileUrls(localOnly) }),
    ]])),
    /does not link to the sharing-beta policy root/u,
  );
  await assert.rejects(
    check(localOnly, new Map([[
      "overview",
      pageHtml(localOnly, page, {
        links: [...profileUrls(localOnly), "https://policy.example.net/neko-widget/other/"],
      }),
    ]])),
    /unresolved internal policy link/u,
  );
});

test("requires every page to link to every page in its own profile", async () => {
  for (const profileCase of [sharingBeta, localOnly]) {
    const page = profileCase.definition.pages[0];
    const links = [
      ...profileUrls(profileCase).slice(0, -1),
      ...requiredCrossProfileUrls(profileCase),
    ];
    await assert.rejects(
      check(profileCase, new Map([[
        "overview",
        pageHtml(profileCase, page, { links }),
      ]])),
      /does not link to every page in its policy profile/u,
    );
  }
});

test("fails closed on unknown or mismatched profile and base combinations", async () => {
  await assert.rejects(
    checkPublicPolicySite({
      profile: "unknown",
      siteBase: sharingBeta.siteBase,
      expectedRevision: revision,
    }),
    /policy profile must be/u,
  );
  await assert.rejects(
    checkPublicPolicySite({
      profile: "local-only",
      siteBase: sharingBeta.siteBase,
      expectedRevision: revision,
      fetchImpl: makeFetch(localOnly),
      lookupImpl: publicDns,
    }),
    /local-only policy site base must end in \/app\//u,
  );
  await assert.rejects(
    checkPublicPolicySite({
      profile: "sharing-beta",
      siteBase: localOnly.siteBase,
      expectedRevision: revision,
      fetchImpl: makeFetch(sharingBeta),
      lookupImpl: publicDns,
    }),
    /sharing-beta policy site base must not end in \/app\//u,
  );
});

test("resolves complete CLI arguments or complete environment input", () => {
  const expected = {
    profile: "sharing-beta",
    siteBase: sharingBeta.siteBase,
    expectedRevision: revision,
  };
  assert.deepEqual(resolvePublicPolicyCheckInput({
    argv: [
      "--profile", expected.profile,
      "--site-base", expected.siteBase,
      "--expected-revision", expected.expectedRevision,
    ],
    environment: {},
  }), expected);
  assert.deepEqual(resolvePublicPolicyCheckInput({
    argv: [],
    environment: {
      NEKO_PUBLIC_POLICY_PROFILE: expected.profile,
      NEKO_PUBLIC_POLICY_SITE_BASE: expected.siteBase,
      NEKO_PUBLIC_POLICY_REVISION: expected.expectedRevision,
    },
  }), expected);
});

test("CLI input rejects mixed sources, duplicates, unknowns, and missing fields", () => {
  const completeArgs = [
    "--profile", "sharing-beta",
    "--site-base", sharingBeta.siteBase,
    "--expected-revision", revision,
  ];
  assert.throws(() => resolvePublicPolicyCheckInput({
    argv: completeArgs,
    environment: { NEKO_PUBLIC_POLICY_PROFILE: "sharing-beta" },
  }), /arguments or environment, not both/u);
  assert.throws(() => resolvePublicPolicyCheckInput({
    argv: [...completeArgs, "--profile", "sharing-beta"],
    environment: {},
  }), /duplicate argument/u);
  assert.throws(() => resolvePublicPolicyCheckInput({
    argv: ["--unknown", "value"],
    environment: {},
  }), /unknown or incomplete argument/u);
  assert.throws(() => resolvePublicPolicyCheckInput({
    argv: ["--profile"],
    environment: {},
  }), /unknown or incomplete argument/u);
  assert.throws(() => resolvePublicPolicyCheckInput({
    argv: ["--profile", "sharing-beta"],
    environment: {},
  }), /missing required siteBase/u);
});

test("accepts only canonical public HTTPS site bases", () => {
  assert.equal(normalizePublicHttpsSiteBase(sharingBeta.siteBase), sharingBeta.siteBase);
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
    ` ${sharingBeta.siteBase}`,
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
    check(sharingBeta, new Map(), { lookupImpl: async () => [] }),
    /did not resolve in public DNS/u,
  );
  await assert.rejects(
    check(sharingBeta, new Map(), {
      lookupImpl: async () => [
        { address: "8.8.8.8", family: 4 },
        { address: "10.0.0.1", family: 4 },
      ],
    }),
    /only to public IP addresses/u,
  );
  await assert.rejects(
    check(sharingBeta, new Map(), {
      lookupImpl: async () => { throw new Error("not found"); },
    }),
    /did not resolve in public DNS: not found/u,
  );
});

test("rejects redirects and non-200 responses", async () => {
  await assert.rejects(
    check(sharingBeta, new Map([[
      "overview",
      new Response(null, { status: 302, headers: { Location: "https://example.org/" } }),
    ]])),
    /overview returned a redirect/u,
  );
  await assert.rejects(
    check(sharingBeta, new Map([[
      "privacy",
      new Response("missing", {
        status: 404,
        headers: { "Content-Type": "text/html; charset=utf-8" },
      }),
    ]])),
    /privacy returned HTTP 404; expected 200/u,
  );
});

test("requires text/html with one explicit UTF-8 charset", async () => {
  const page = sharingBeta.definition.pages[0];
  await assert.rejects(
    check(sharingBeta, new Map([[
      "overview",
      new Response(pageHtml(sharingBeta, page), {
        status: 200,
        headers: { "Content-Type": "text/plain; charset=utf-8" },
      }),
    ]])),
    /did not return text\/html/u,
  );
  for (const contentType of ["text/html", "text/html; charset=utf-8; charset=utf-8"]) {
    await assert.rejects(
      check(sharingBeta, new Map([[
        "overview",
        new Response(pageHtml(sharingBeta, page), {
          status: 200,
          headers: { "Content-Type": contentType },
        }),
      ]])),
      /did not declare charset=utf-8/u,
    );
  }
});

test("enforces both declared and streamed response size limits", async () => {
  const page = sharingBeta.definition.pages[0];
  await assert.rejects(
    check(sharingBeta, new Map([[
      "overview",
      new Response(pageHtml(sharingBeta, page), {
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
    check(sharingBeta, new Map(), { maximumBytes: 32 }),
    /exceeds the 32-byte response limit/u,
  );
});

test("rejects malformed UTF-8 bodies", async () => {
  await assert.rejects(
    check(sharingBeta, new Map([[
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
  const page = sharingBeta.definition.pages[0];
  await assert.rejects(
    check(sharingBeta, new Map([[
      "overview",
      pageHtml(sharingBeta, page, { h1: "wrong" }),
    ]])),
    /unexpected h1/u,
  );
  await assert.rejects(
    check(sharingBeta, new Map([[
      "overview",
      pageHtml(sharingBeta, page).replace("</h1>", "</h1><h1>duplicate</h1>"),
    ]])),
    /exactly one complete h1/u,
  );
});

test("requires one exact policy revision on every page", async () => {
  const page = sharingBeta.definition.pages[0];
  await assert.rejects(
    check(sharingBeta, new Map([[
      "overview",
      pageHtml(sharingBeta, page, { revision: "2026-08-23" }),
    ]])),
    /policy revision 2026-08-23; expected 2026-08-24/u,
  );
  await assert.rejects(
    check(sharingBeta, new Map([[
      "overview",
      pageHtml(sharingBeta, page, {
        extraHead: '<meta name="neko-policy-revision" content="2026-08-24">',
      }),
    ]])),
    /exactly one neko-policy-revision/u,
  );
});

test("requires the visible revision wherever the profile specifies it", async () => {
  for (const profileCase of [sharingBeta, localOnly]) {
    const page = profileCase.definition.pages.find((candidate) => candidate.visibleRevision);
    await assert.rejects(
      check(profileCase, new Map([[
        page.name,
        pageHtml(profileCase, page).replace("<p>最終更新日：2026年8月24日</p>", ""),
      ]])),
      /is missing the visible policy revision/u,
    );
  }
});

test("requires profile-specific safety content", async () => {
  const sharingPage = sharingBeta.definition.pages[1];
  await assert.rejects(
    check(sharingBeta, new Map([[
      "privacy",
      pageHtml(sharingBeta, sharingPage, {
        phrases: sharingPage.requiredPhrases.filter(
          (phrase) => phrase !== "新規の暗号化通報受付は停止",
        ),
      }),
    ]])),
    /privacy is missing required policy content: 新規の暗号化通報受付は停止/u,
  );

  const localPage = localOnly.definition.pages[1];
  await assert.rejects(
    check(localOnly, new Map([[
      "privacy",
      pageHtml(localOnly, localPage, {
        phrases: localPage.requiredPhrases.filter(
          (phrase) => phrase !== "開発者によるデータ収集を行いません",
        ),
      }),
    ]])),
    /privacy is missing required policy content: 開発者によるデータ収集を行いません/u,
  );
});

test("requires the PhotoAlbumService disclosure in sharing and local-only policy", async () => {
  const albumPhrase = "写真アプリに「うちの子」アルバムを作成・更新";
  for (const [profileCase, page] of [
    [sharingBeta, sharingBeta.definition.pages[1]],
    [localOnly, localOnly.definition.pages[0]],
  ]) {
    await assert.rejects(
      check(profileCase, new Map([[
        page.name,
        pageHtml(profileCase, page, {
          phrases: page.requiredPhrases.filter((phrase) => phrase !== albumPhrase),
        }),
      ]])),
      new RegExp(`${page.name} is missing required policy content`, "u"),
    );
  }
});

test("rejects false local-only persistence, export, and contact claims", async () => {
  const page = localOnly.definition.pages[0];
  for (const phrase of page.forbiddenPhrases) {
    await assert.rejects(
      check(localOnly, new Map([[
        page.name,
        pageHtml(localOnly, page, { extraBody: `<p>${phrase}</p>` }),
      ]])),
      new RegExp(`${page.name} contains forbidden policy content`, "u"),
    );
  }
});

test("rejects a sharing privacy claim that hides opaque APNs routing identifiers", async () => {
  const page = sharingBeta.definition.pages.find(({ name }) => name === "privacy");
  assert.ok(page);
  for (const phrase of page.forbiddenPhrases) {
    await assert.rejects(
      check(sharingBeta, new Map([[
        page.name,
        pageHtml(sharingBeta, page, { extraBody: phrase }),
      ]])),
      new RegExp(`privacy contains forbidden policy content: ${phrase}`, "u"),
    );
  }
});

test("requires explicit export risk and submission blocker copy on every local-only page", async () => {
  const required = [
    "写真PDFには利用者が選んだ写真が含まれます",
    "非公開で連絡できるプライバシー問い合わせ窓口は現在未掲載です",
  ];
  for (const page of localOnly.definition.pages) {
    for (const phrase of required) {
      await assert.rejects(
        check(localOnly, new Map([[
          page.name,
          pageHtml(localOnly, page, {
            phrases: page.requiredPhrases.filter((value) => value !== phrase),
          }),
        ]])),
        new RegExp(`${page.name} is missing required policy content`, "u"),
      );
    }
  }
});

test("requires the limited external TestFlight boundary on every sharing-beta page", async () => {
  const boundary = "この共有仕様は、招待した少人数だけの限定外部TestFlightベータとして確認中です。App Storeで一般提供している版ではありません。";
  for (const page of sharingBeta.definition.pages) {
    await assert.rejects(
      check(sharingBeta, new Map([[
        page.name,
        pageHtml(sharingBeta, page, {
          phrases: page.requiredPhrases.filter((phrase) => phrase !== boundary),
        }),
      ]])),
      new RegExp(`${page.name} is missing required policy content`, "u"),
    );
  }
});

test("rejects unresolved, escaping, credentialed, and non-HTTPS links", async () => {
  const page = sharingBeta.definition.pages[3];
  for (const unsafe of [
    [...profileUrls(sharingBeta), `${sharingBeta.siteBase}missing/`],
    [...profileUrls(sharingBeta), "https://policy.example.net/outside/"],
    [...profileUrls(sharingBeta), "https://user:pass@example.org/"],
    [...profileUrls(sharingBeta), "http://example.org/"],
  ]) {
    await assert.rejects(
      check(sharingBeta, new Map([[
        "support",
        pageHtml(sharingBeta, page, { links: unsafe }),
      ]])),
    );
  }
});

test("rejects invalid revisions and option limits before fetching", async () => {
  await assert.rejects(
    checkPublicPolicySite({
      profile: sharingBeta.profile,
      siteBase: sharingBeta.siteBase,
      expectedRevision: "2026/08/24",
      fetchImpl: makeFetch(sharingBeta),
      lookupImpl: publicDns,
    }),
    /must use YYYY-MM-DD/u,
  );
  await assert.rejects(
    checkPublicPolicySite({
      profile: sharingBeta.profile,
      siteBase: sharingBeta.siteBase,
      expectedRevision: "2026-02-31",
      fetchImpl: makeFetch(sharingBeta),
      lookupImpl: publicDns,
    }),
    /must be a real calendar date/u,
  );
  await assert.rejects(
    check(sharingBeta, new Map(), { timeoutMs: 0 }),
    /timeout must be an integer/u,
  );
  await assert.rejects(
    check(sharingBeta, new Map(), { maximumBytes: 1024 * 1024 + 1 }),
    /maximum response bytes/u,
  );
});

test("fails closed when a page request exceeds its timeout", async () => {
  const fetchImpl = async (_url, { signal }) => new Promise((_resolve, reject) => {
    signal.addEventListener("abort", () => reject(signal.reason), { once: true });
  });
  await assert.rejects(
    checkPublicPolicySite({
      profile: sharingBeta.profile,
      siteBase: sharingBeta.siteBase,
      expectedRevision: revision,
      fetchImpl,
      lookupImpl: publicDns,
      timeoutMs: 10,
    }),
    /timed out/u,
  );
});
