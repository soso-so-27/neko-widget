import { lookup as dnsLookup } from "node:dns/promises";
import { isIP } from "node:net";

const DEFAULT_TIMEOUT_MS = 10_000;
const DEFAULT_MAX_BODY_BYTES = 256 * 1024;
const SHARING_BETA_BOUNDARY_PHRASE = "この共有仕様は、本人所有の2台で確認中の内部TestFlightベータです。App Storeで一般提供している版ではありません。";
const PHOTO_ALBUM_DISCLOSURE_PHRASES = Object.freeze([
  "写真アプリに「うちの子」アルバムを作成・更新",
  "元写真のアルバム所属を追加・解除",
  "このアルバム連携では元写真を複製、書き出し、アップロードせず",
  "写真アプリとiCloud写真の同期はAppleと利用者の設定によります",
  "「うちの子」アルバムの構成がほかのApple端末へ同期されることがあります",
]);
const LOCAL_ONLY_DELETION_PHRASES = Object.freeze([
  "アプリを削除しても、「うちの子」アルバムやその構成が写真アプリに残ることがあります",
  "アプリとWidgetの専用領域にあるデータはiOSにより削除されます",
]);
const USER_INITIATED_EXPORT_PHRASES = Object.freeze([
  "本アプリが写真やデータを自動で開発者のサーバーへアップロードすることはありません",
  "PDF、検証JSON、診断ログの書き出しを明示的に選ぶと、iOSの共有シートが開きます",
  "共有先のサービスとポリシーが適用されます",
  "写真PDFには利用者が選んだ写真が含まれます",
  "識別子や診断情報が含まれる場合があります",
  "内容と共有先を確認してから共有してください",
]);
const LOCAL_ONLY_SUBMISSION_BLOCKER_PHRASES = Object.freeze([
  "非公開で連絡できるプライバシー問い合わせ窓口は現在未掲載です",
  "App Storeで一般提供する前に、このページへ有効な非公開窓口を掲載する必要があります",
  "一般公開の提出準備は完了していません",
]);
const LOCAL_ONLY_FORBIDDEN_POLICY_PHRASES = Object.freeze([
  "写真アプリやiCloudへ独自に保存することもありません",
  "写真アプリやiCloudへ独自に保存することはありません",
  "写真アプリやiCloudへ独自に保存しません",
  "共有・招待・送信・受信はなく",
  "選んだ写真、縮小画像、Widget表示用の派生画像を外部へ送信しません",
  "写真、縮小画像、判定結果、Widget表示用画像などの派生画像を、開発者やその他の外部サーバーへ送信しません",
  "技術的な問い合わせとプライバシーに関する連絡方法は",
]);

const SHARING_BETA_PAGES = Object.freeze([
  Object.freeze({
    name: "overview",
    path: "",
    h1: "名前を付けたまどへ、一枚ずつ",
    visibleRevision: false,
    requiredPhrases: Object.freeze([
      SHARING_BETA_BOUNDARY_PHRASE,
      "名前を付けた1つの非公開なまど",
      "作成者と信頼できる招待相手1人",
      "それぞれ1台のiPhone",
      "信頼できる招待相手1人",
      "家族に限定しません",
      "公開フィード、検索、フォロー、匿名の出会いはありません",
    ]),
  }),
  Object.freeze({
    name: "privacy",
    path: "privacy/",
    h1: "プライバシーポリシー",
    visibleRevision: true,
    requiredPhrases: Object.freeze([
      SHARING_BETA_BOUNDARY_PHRASE,
      ...PHOTO_ALBUM_DISCLOSURE_PHRASES,
      "エンドツーエンド暗号化",
      "通報専用公開鍵",
      "ACK後7日",
      "未受領の通常暗号文：commit後30日",
      "生成AIの学習に利用しません",
      "受信写真の「しおり」",
      "無料・期限付き",
      "保持上限内なら優先して残す",
      "写真を新しく保存する機能や長期保管ではなく",
      "写真アプリやiCloudへ保存せず",
    ]),
  }),
  Object.freeze({
    name: "community",
    path: "community/",
    h1: "コミュニティ基準",
    visibleRevision: true,
    requiredPhrases: Object.freeze([
      SHARING_BETA_BOUNDARY_PHRASE,
      "通報",
      "ブロック",
      "48時間以内",
      "削除対象",
      "再試行",
    ]),
  }),
  Object.freeze({
    name: "support",
    path: "support/",
    h1: "サポート",
    visibleRevision: true,
    requiredPhrases: Object.freeze([
      SHARING_BETA_BOUNDARY_PHRASE,
      "GitHub Issues",
      "TestFlight",
      "招待コード",
      "緊急通報先ではありません",
      "届いた写真の「しおり」",
      "無料・期限付き",
      "保持上限内なら優先して残す",
      "写真を新しく保存する機能や長期保管ではなく",
      "写真アプリやiCloudへ保存せず",
    ]),
  }),
]);

const LOCAL_ONLY_COMMON_PHRASES = Object.freeze([
  "完全ローカル版",
  "現在の共有ベータ版とは別の仕様",
  "この完全ローカル版では",
  "写真の読み込み、解析、猫判定、一覧、Widget用画像の処理は端末内だけ",
  "ほかの利用者とのネットワーク写真共有・招待・自動送信・受信機能はなく",
  "アプリから開発者のサーバーへ通信しません",
  "公開フィード、検索、フォローもありません",
  "開発者の解析サービスへ自動接続せず、広告やトラッキングを行いません",
  ...PHOTO_ALBUM_DISCLOSURE_PHRASES,
  ...LOCAL_ONLY_DELETION_PHRASES,
  ...USER_INITIATED_EXPORT_PHRASES,
  ...LOCAL_ONLY_SUBMISSION_BLOCKER_PHRASES,
]);

const LOCAL_ONLY_PAGES = Object.freeze([
  Object.freeze({
    name: "overview",
    path: "",
    h1: "端末の中だけで、ねこの写真をウィジェットへ",
    visibleRevision: true,
    requiredPhrases: Object.freeze([
      ...LOCAL_ONLY_COMMON_PHRASES,
    ]),
    forbiddenPhrases: LOCAL_ONLY_FORBIDDEN_POLICY_PHRASES,
  }),
  Object.freeze({
    name: "privacy",
    path: "privacy/",
    h1: "プライバシーポリシー",
    visibleRevision: true,
    requiredPhrases: Object.freeze([
      ...LOCAL_ONLY_COMMON_PHRASES,
      "開発者によるデータ収集を行いません",
      "CloudKitやアプリ独自のiCloudコンテナも使用しません",
      "共有相手、招待、送信待ち、届いた写真の一覧、サーバー上の写真は作成しません",
      "開発者の共有サーバーや解析サービスへ自動接続しません",
      "データ販売、生成AIの学習にも利用しません",
    ]),
    forbiddenPhrases: LOCAL_ONLY_FORBIDDEN_POLICY_PHRASES,
  }),
  Object.freeze({
    name: "support",
    path: "support/",
    h1: "サポート",
    visibleRevision: true,
    requiredPhrases: Object.freeze([
      ...LOCAL_ONLY_COMMON_PHRASES,
      "TestFlight",
      "GitHub Issues",
      "Build番号",
      "公開してよい情報だけ",
      "緊急通報先ではありません",
    ]),
    forbiddenPhrases: LOCAL_ONLY_FORBIDDEN_POLICY_PHRASES,
  }),
]);

const PROFILE_DEFINITIONS = Object.freeze({
  "sharing-beta": Object.freeze({
    pages: SHARING_BETA_PAGES,
    requiredBaseSuffix: undefined,
    forbiddenBaseSuffix: "/app/",
    requiredSharingBetaLink: false,
  }),
  "local-only": Object.freeze({
    pages: LOCAL_ONLY_PAGES,
    requiredBaseSuffix: "/app/",
    forbiddenBaseSuffix: undefined,
    requiredSharingBetaLink: true,
  }),
});

const CLI_FIELDS = Object.freeze({
  "--profile": Object.freeze({ key: "profile", environment: "NEKO_PUBLIC_POLICY_PROFILE" }),
  "--site-base": Object.freeze({ key: "siteBase", environment: "NEKO_PUBLIC_POLICY_SITE_BASE" }),
  "--expected-revision": Object.freeze({ key: "expectedRevision", environment: "NEKO_PUBLIC_POLICY_REVISION" }),
});

function ipv4Number(address) {
  const parts = address.split(".").map(Number);
  if (parts.length !== 4 || parts.some((part) => !Number.isInteger(part) || part < 0 || part > 255)) {
    return undefined;
  }
  return (((parts[0] * 256 + parts[1]) * 256 + parts[2]) * 256 + parts[3]) >>> 0;
}

function ipv4InRange(value, network, prefix) {
  const networkValue = ipv4Number(network);
  const mask = prefix === 0 ? 0 : (0xffffffff << (32 - prefix)) >>> 0;
  return networkValue !== undefined && (value & mask) === (networkValue & mask);
}

function isPublicIpv4(address) {
  const value = ipv4Number(address);
  if (value === undefined) return false;
  const nonPublicRanges = [
    ["0.0.0.0", 8],
    ["10.0.0.0", 8],
    ["100.64.0.0", 10],
    ["127.0.0.0", 8],
    ["169.254.0.0", 16],
    ["172.16.0.0", 12],
    ["192.0.0.0", 24],
    ["192.0.2.0", 24],
    ["192.168.0.0", 16],
    ["198.18.0.0", 15],
    ["198.51.100.0", 24],
    ["203.0.113.0", 24],
    ["224.0.0.0", 4],
    ["240.0.0.0", 4],
  ];
  return !nonPublicRanges.some(([network, prefix]) => ipv4InRange(value, network, prefix));
}

function isPublicIpv6(address) {
  const normalized = address.toLowerCase().split("%")[0];
  if (normalized.startsWith("::ffff:")) {
    const mapped = normalized.slice("::ffff:".length);
    return isIP(mapped) === 4 && isPublicIpv4(mapped);
  }
  const firstGroup = Number.parseInt(normalized.split(":", 1)[0], 16);
  return Number.isInteger(firstGroup)
    && (firstGroup & 0xe000) === 0x2000
    && !normalized.startsWith("2001:2:")
    && !/^2001:0?1[0-9a-f]:/u.test(normalized)
    && !/^2001:0?2[0-9a-f]:/u.test(normalized)
    && !normalized.startsWith("2001:db8:")
    && !normalized.startsWith("3fff:");
}

export function isPublicIpAddress(address) {
  const family = isIP(address);
  if (family === 4) return isPublicIpv4(address);
  if (family === 6) return isPublicIpv6(address);
  return false;
}

export function normalizePublicHttpsSiteBase(input) {
  if (typeof input !== "string" || input.length === 0 || input.trim() !== input) {
    throw new Error("policy site base must be a non-empty canonical HTTPS URL");
  }

  let url;
  try {
    url = new URL(input);
  } catch {
    throw new Error("policy site base must be a valid HTTPS URL");
  }

  const hostname = url.hostname.replace(/^\[|\]$/gu, "").toLowerCase();
  if (
    url.protocol !== "https:"
    || url.username !== ""
    || url.password !== ""
    || url.port !== ""
    || !url.pathname.endsWith("/")
    || url.search !== ""
    || url.hash !== ""
    || url.href !== input
  ) {
    throw new Error("policy site base must be canonical HTTPS without credentials, port, query, or fragment and must end in /");
  }
  if (
    hostname.length === 0
    || isIP(hostname) !== 0
    || hostname === "localhost"
    || hostname.endsWith(".localhost")
    || hostname.endsWith(".local")
    || hostname.endsWith(".internal")
  ) {
    throw new Error("policy site base must use a public DNS hostname");
  }

  return url.href;
}

export function resolvePublicPolicyCheckInput({ argv, environment }) {
  if (!Array.isArray(argv) || environment === null || typeof environment !== "object") {
    throw new Error("CLI arguments and environment are required");
  }

  const argumentValues = new Map();
  for (let index = 0; index < argv.length; index += 1) {
    const flag = argv[index];
    const field = CLI_FIELDS[flag];
    const value = argv[index + 1];
    if (field === undefined || typeof value !== "string" || value.length === 0 || value.startsWith("--")) {
      throw new Error(`unknown or incomplete argument: ${flag ?? "<missing>"}`);
    }
    if (argumentValues.has(field.key)) {
      throw new Error(`duplicate argument: ${flag}`);
    }
    argumentValues.set(field.key, value);
    index += 1;
  }

  const result = {};
  for (const field of Object.values(CLI_FIELDS)) {
    const argumentValue = argumentValues.get(field.key);
    const environmentValue = environment[field.environment];
    if (argumentValue !== undefined && environmentValue !== undefined) {
      throw new Error(`${field.key} must be supplied by arguments or environment, not both`);
    }
    const value = argumentValue ?? environmentValue;
    if (typeof value !== "string" || value.length === 0) {
      throw new Error(`missing required ${field.key}`);
    }
    result[field.key] = value;
  }
  return Object.freeze(result);
}

async function requirePublicDns(hostname, lookupImpl) {
  let records;
  try {
    records = await lookupImpl(hostname, { all: true, verbatim: true });
  } catch (error) {
    const message = error instanceof Error ? error.message : "unknown DNS error";
    throw new Error(`policy site hostname did not resolve in public DNS: ${message}`);
  }
  if (!Array.isArray(records) || records.length === 0) {
    throw new Error("policy site hostname did not resolve in public DNS");
  }
  for (const record of records) {
    if (record === null || typeof record !== "object" || !isPublicIpAddress(record.address)) {
      throw new Error("policy site hostname must resolve only to public IP addresses");
    }
  }
}

function decodeHtmlEntities(value) {
  return value.replace(/&(#x[0-9a-f]+|#\d+|amp|lt|gt|quot|apos|nbsp);/giu, (match, entity) => {
    const lowered = entity.toLowerCase();
    if (lowered.startsWith("#x")) return String.fromCodePoint(Number.parseInt(lowered.slice(2), 16));
    if (lowered.startsWith("#")) return String.fromCodePoint(Number.parseInt(lowered.slice(1), 10));
    return {
      amp: "&",
      lt: "<",
      gt: ">",
      quot: "\"",
      apos: "'",
      nbsp: " ",
    }[lowered] ?? match;
  });
}

function visibleText(html) {
  const withoutNonContent = html
    .replace(/<!--[\s\S]*?-->/gu, " ")
    .replace(/<(script|style|template)\b[^>]*>[\s\S]*?<\/\1\s*>/giu, " ");
  return decodeHtmlEntities(withoutNonContent.replace(/<[^>]*>/gu, " "))
    .replace(/\s+/gu, " ")
    .trim();
}

function visibleHtml(html) {
  return html
    .replace(/<!--[\s\S]*?-->/gu, " ")
    .replace(/<(script|style|template)\b[^>]*>[\s\S]*?<\/\1\s*>/giu, " ");
}

function parseAttributes(tag) {
  const attributes = new Map();
  const pattern = /([:\w-]+)\s*=\s*(?:"([^"]*)"|'([^']*)')/gu;
  for (const match of tag.matchAll(pattern)) {
    attributes.set(match[1].toLowerCase(), decodeHtmlEntities(match[2] ?? match[3] ?? ""));
  }
  return attributes;
}

function extractPolicyRevision(html, label) {
  const revisions = [];
  for (const match of visibleHtml(html).matchAll(/<meta\b[^>]*>/giu)) {
    const attributes = parseAttributes(match[0]);
    if (attributes.get("name")?.toLowerCase() === "neko-policy-revision") {
      revisions.push(attributes.get("content"));
    }
  }
  if (revisions.length !== 1 || revisions[0] === undefined) {
    throw new Error(`${label} must expose exactly one neko-policy-revision meta value`);
  }
  return revisions[0];
}

function extractH1(html, label) {
  const content = visibleHtml(html);
  const openingCount = [...content.matchAll(/<h1\b[^>]*>/giu)].length;
  const matches = [...content.matchAll(/<h1\b[^>]*>([\s\S]*?)<\/h1\s*>/giu)];
  if (openingCount !== 1 || matches.length !== 1) {
    throw new Error(`${label} must contain exactly one complete h1`);
  }
  return visibleText(matches[0][1]);
}

function extractLinks(html) {
  const links = [];
  for (const match of visibleHtml(html).matchAll(/<a\b[^>]*>/giu)) {
    const href = parseAttributes(match[0]).get("href");
    if (href !== undefined) links.push(href);
  }
  return links;
}

function requireUtf8Html(response, label) {
  const contentType = response.headers.get("content-type");
  if (contentType === null) {
    throw new Error(`${label} did not return a Content-Type header`);
  }
  const parts = contentType.split(";").map((part) => part.trim());
  if (parts.shift()?.toLowerCase() !== "text/html") {
    throw new Error(`${label} did not return text/html`);
  }
  const charsets = parts
    .map((part) => part.match(/^charset\s*=\s*"?([^";\s]+)"?$/iu)?.[1]?.toLowerCase())
    .filter((value) => value !== undefined);
  if (charsets.length !== 1 || charsets[0] !== "utf-8") {
    throw new Error(`${label} did not declare charset=utf-8`);
  }
}

async function readBoundedUtf8Body(response, label, maximumBytes) {
  const contentLength = response.headers.get("content-length");
  if (contentLength !== null) {
    if (!/^\d+$/u.test(contentLength)) {
      throw new Error(`${label} returned an invalid Content-Length`);
    }
    if (Number(contentLength) > maximumBytes) {
      throw new Error(`${label} exceeds the ${maximumBytes}-byte response limit`);
    }
  }
  if (response.body === null) {
    throw new Error(`${label} returned an empty response body`);
  }

  const chunks = [];
  let total = 0;
  const reader = response.body.getReader();
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      total += value.byteLength;
      if (total > maximumBytes) {
        await reader.cancel();
        throw new Error(`${label} exceeds the ${maximumBytes}-byte response limit`);
      }
      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }

  const body = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    body.set(chunk, offset);
    offset += chunk.byteLength;
  }
  try {
    return { html: new TextDecoder("utf-8", { fatal: true }).decode(body), bytes: total };
  } catch {
    throw new Error(`${label} body is not valid UTF-8`);
  }
}

function validateLinks({
  html,
  pageUrl,
  baseUrl,
  expectedPageUrls,
  requiredSameOriginUrls,
  label,
}) {
  const internal = new Set();
  const requiredSameOrigin = new Set();
  for (const href of extractLinks(html)) {
    let target;
    try {
      target = new URL(href, pageUrl);
    } catch {
      throw new Error(`${label} contains an invalid link`);
    }
    if (target.protocol !== "https:" || target.username !== "" || target.password !== "") {
      throw new Error(`${label} contains a non-HTTPS or credentialed link`);
    }
    if (target.origin !== baseUrl.origin) continue;
    if (target.search !== "") {
      throw new Error(`${label} contains an internal link outside the policy site`);
    }
    target.hash = "";
    if (expectedPageUrls.has(target.href)) {
      internal.add(target.href);
    } else if (requiredSameOriginUrls.has(target.href)) {
      requiredSameOrigin.add(target.href);
    } else {
      throw new Error(`${label} contains an unresolved internal policy link: ${target.pathname}`);
    }
  }
  const missing = [...expectedPageUrls].filter((url) => !internal.has(url));
  if (missing.length > 0) {
    throw new Error(`${label} does not link to every page in its policy profile`);
  }
  const missingRequired = [...requiredSameOriginUrls]
    .filter((url) => !requiredSameOrigin.has(url));
  if (missingRequired.length > 0) {
    throw new Error(`${label} does not link to the sharing-beta policy root`);
  }
}

async function fetchPolicyPage({
  page,
  pageUrl,
  baseUrl,
  expectedPageUrls,
  requiredSameOriginUrls,
  expectedRevision,
  fetchImpl,
  timeoutMs,
  maximumBytes,
}) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  let response;
  try {
    response = await fetchImpl(pageUrl.href, {
      method: "GET",
      headers: { Accept: "text/html; charset=utf-8" },
      redirect: "manual",
      signal: controller.signal,
    });
    if (response.status >= 300 && response.status < 400) {
      throw new Error(`${page.name} returned a redirect`);
    }
    if (response.status !== 200) {
      throw new Error(`${page.name} returned HTTP ${response.status}; expected 200`);
    }
    requireUtf8Html(response, page.name);
    const { html, bytes } = await readBoundedUtf8Body(response, page.name, maximumBytes);
    const h1 = extractH1(html, page.name);
    if (h1 !== page.h1) {
      throw new Error(`${page.name} returned an unexpected h1`);
    }
    const revision = extractPolicyRevision(html, page.name);
    if (revision !== expectedRevision) {
      throw new Error(`${page.name} returned policy revision ${revision}; expected ${expectedRevision}`);
    }
    const text = visibleText(html);
    if (page.visibleRevision) {
      const [year, month, day] = expectedRevision.split("-").map(Number);
      const visibleRevision = `最終更新日：${year}年${month}月${day}日`;
      if (!text.includes(visibleRevision)) {
        throw new Error(`${page.name} is missing the visible policy revision`);
      }
    }
    for (const phrase of page.requiredPhrases) {
      if (!text.includes(phrase)) {
        throw new Error(`${page.name} is missing required policy content: ${phrase}`);
      }
    }
    for (const phrase of page.forbiddenPhrases ?? []) {
      if (text.includes(phrase)) {
        throw new Error(`${page.name} contains forbidden policy content: ${phrase}`);
      }
    }
    validateLinks({
      html,
      pageUrl,
      baseUrl,
      expectedPageUrls,
      requiredSameOriginUrls,
      label: page.name,
    });
    return Object.freeze({
      name: page.name,
      url: pageUrl.href,
      status: response.status,
      bytes,
      h1,
      revision,
    });
  } catch (error) {
    if (controller.signal.aborted) {
      throw new Error(`${page.name} timed out`);
    }
    throw error;
  } finally {
    clearTimeout(timer);
  }
}

export async function checkPublicPolicySite({
  profile,
  siteBase,
  expectedRevision,
  fetchImpl = globalThis.fetch,
  lookupImpl = dnsLookup,
  timeoutMs = DEFAULT_TIMEOUT_MS,
  maximumBytes = DEFAULT_MAX_BODY_BYTES,
}) {
  const profileDefinition = PROFILE_DEFINITIONS[profile];
  if (profileDefinition === undefined) {
    throw new Error("policy profile must be 'sharing-beta' or 'local-only'");
  }
  const normalizedBase = normalizePublicHttpsSiteBase(siteBase);
  if (typeof expectedRevision !== "string" || !/^\d{4}-\d{2}-\d{2}$/u.test(expectedRevision)) {
    throw new Error("expected policy revision must use YYYY-MM-DD");
  }
  const [year, month, day] = expectedRevision.split("-").map(Number);
  const parsedRevision = new Date(Date.UTC(year, month - 1, day));
  if (
    parsedRevision.getUTCFullYear() !== year
    || parsedRevision.getUTCMonth() !== month - 1
    || parsedRevision.getUTCDate() !== day
  ) {
    throw new Error("expected policy revision must be a real calendar date");
  }
  if (typeof fetchImpl !== "function" || typeof lookupImpl !== "function") {
    throw new Error("fetch and DNS lookup implementations are required");
  }
  if (!Number.isSafeInteger(timeoutMs) || timeoutMs < 1 || timeoutMs > 60_000) {
    throw new Error("timeout must be an integer from 1 through 60000 milliseconds");
  }
  if (!Number.isSafeInteger(maximumBytes) || maximumBytes < 1 || maximumBytes > 1024 * 1024) {
    throw new Error("maximum response bytes must be an integer from 1 through 1048576");
  }

  const baseUrl = new URL(normalizedBase);
  if (
    profileDefinition.requiredBaseSuffix !== undefined
    && !baseUrl.pathname.endsWith(profileDefinition.requiredBaseSuffix)
  ) {
    throw new Error(`${profile} policy site base must end in ${profileDefinition.requiredBaseSuffix}`);
  }
  if (
    profileDefinition.forbiddenBaseSuffix !== undefined
    && baseUrl.pathname.endsWith(profileDefinition.forbiddenBaseSuffix)
  ) {
    throw new Error(`${profile} policy site base must not end in ${profileDefinition.forbiddenBaseSuffix}`);
  }
  await requirePublicDns(baseUrl.hostname, lookupImpl);
  const pageUrls = profileDefinition.pages.map((page) => new URL(page.path, baseUrl));
  const expectedPageUrls = new Set(pageUrls.map((url) => url.href));
  const requiredSameOriginUrls = new Set(
    profileDefinition.requiredSharingBetaLink ? [new URL("../", baseUrl).href] : [],
  );
  const pages = await Promise.all(profileDefinition.pages.map((page, index) => fetchPolicyPage({
    page,
    pageUrl: pageUrls[index],
    baseUrl,
    expectedPageUrls,
    requiredSameOriginUrls,
    expectedRevision,
    fetchImpl,
    timeoutMs,
    maximumBytes,
  })));

  return Object.freeze({
    profile,
    siteBase: normalizedBase,
    expectedRevision,
    pages: Object.freeze(pages),
  });
}

export const publicPolicyProfiles = PROFILE_DEFINITIONS;
