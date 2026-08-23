import { lookup as dnsLookup } from "node:dns/promises";
import { isIP } from "node:net";

const DEFAULT_TIMEOUT_MS = 10_000;
const DEFAULT_MAX_BODY_BYTES = 256 * 1024;

const POLICY_PAGES = Object.freeze([
  Object.freeze({
    name: "overview",
    path: "",
    h1: "名前を付けたまどへ、一枚ずつ",
    requiredPhrases: Object.freeze([
      "名前を付けた1つの非公開なまど",
      "信頼できる招待相手1人",
      "2人・各1台",
      "家族に限定しません",
      "公開フィード、検索、フォロー、匿名の出会いはありません",
    ]),
  }),
  Object.freeze({
    name: "privacy",
    path: "privacy/",
    h1: "プライバシーポリシー",
    requiredPhrases: Object.freeze([
      "エンドツーエンド暗号化",
      "通報専用公開鍵",
      "ACK後7日",
      "未受領の通常暗号文：commit後30日",
      "生成AIの学習に利用しません",
      "「思い出に残す」",
      "写真アプリやiCloudへ保存せず",
    ]),
  }),
  Object.freeze({
    name: "community",
    path: "community/",
    h1: "コミュニティ基準",
    requiredPhrases: Object.freeze([
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
    requiredPhrases: Object.freeze([
      "GitHub Issues",
      "TestFlight",
      "招待コード",
      "緊急通報先ではありません",
      "「思い出に残す」",
      "写真アプリやiCloudへ保存せず",
    ]),
  }),
]);

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

function validateLinks({ html, pageUrl, baseUrl, expectedPageUrls, label }) {
  const internal = new Set();
  for (const href of extractLinks(html)) {
    let target;
    try {
      target = new URL(href, pageUrl);
    } catch {
      throw new Error(`${label} contains an invalid link`);
    }
    if (target.protocol !== "https:") {
      throw new Error(`${label} contains a non-HTTPS link`);
    }
    if (target.origin !== baseUrl.origin) continue;
    if (!target.pathname.startsWith(baseUrl.pathname) || target.search !== "") {
      throw new Error(`${label} contains an internal link outside the policy site`);
    }
    target.hash = "";
    if (!expectedPageUrls.has(target.href)) {
      throw new Error(`${label} contains an unresolved internal policy link: ${target.pathname}`);
    }
    internal.add(target.href);
  }
  const missing = [...expectedPageUrls].filter((url) => !internal.has(url));
  if (missing.length > 0) {
    throw new Error(`${label} does not link to every public policy page`);
  }
}

async function fetchPolicyPage({
  page,
  pageUrl,
  baseUrl,
  expectedPageUrls,
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
    if (page.name !== "overview") {
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
    validateLinks({ html, pageUrl, baseUrl, expectedPageUrls, label: page.name });
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
  siteBase,
  expectedRevision,
  fetchImpl = globalThis.fetch,
  lookupImpl = dnsLookup,
  timeoutMs = DEFAULT_TIMEOUT_MS,
  maximumBytes = DEFAULT_MAX_BODY_BYTES,
}) {
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
  await requirePublicDns(baseUrl.hostname, lookupImpl);
  const pageUrls = POLICY_PAGES.map((page) => new URL(page.path, baseUrl));
  const expectedPageUrls = new Set(pageUrls.map((url) => url.href));
  const pages = await Promise.all(POLICY_PAGES.map((page, index) => fetchPolicyPage({
    page,
    pageUrl: pageUrls[index],
    baseUrl,
    expectedPageUrls,
    expectedRevision,
    fetchImpl,
    timeoutMs,
    maximumBytes,
  })));

  return Object.freeze({
    siteBase: normalizedBase,
    expectedRevision,
    pages: Object.freeze(pages),
  });
}

export const publicPolicyPageSpecifications = POLICY_PAGES;
