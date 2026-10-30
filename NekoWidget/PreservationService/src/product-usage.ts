import { ServiceError, sha256, type ArchiveDocument } from './contracts';
import { parseAppRecordHead, toolManifests, type ToolIndexFile } from './documents';
import { parseToolNode, isCompleteToolRoot } from './tool-index-v4';
import { pendingProductQuota, productQuotaPolicy, type ProductQuotaSettings } from './product-quota-policy';
import { productRecordCounter } from './product-record-counter';

export interface LogicalUsage { bytes: number; records: number }
export interface ProductCounters { product_bytes: number; product_records: number; product_unknown: number }
type OpenRecord = (id: string) => Promise<{ document: ArchiveDocument; photoBytes: number }>;
const encoder = new TextEncoder();
const decoder = new TextDecoder('utf-8', { fatal: true });
const zero = (): LogicalUsage => ({ bytes: 0, records: 0 });
const object = (value: unknown): value is Record<string, unknown> => !!value && typeof value === 'object' && !Array.isArray(value);

function safe(value: number): number {
  if (!Number.isSafeInteger(value) || value < 0) throw new ServiceError('PRODUCT_QUOTA_ACCOUNTING_UNAVAILABLE', 503);
  return value;
}

/** Only used at publication/recount, not by GET usage. Existing immutable tree
 * validation protects descendants; still verify owner, live revision and hashes
 * through the supplied authenticated opener. Photos are never downloaded. */
export async function measureProductRecord(document: ArchiveDocument, photoBytes: number, open: OpenRecord): Promise<LogicalUsage | null> {
  let active = 0;
  const waiting: (() => void)[] = [];
  const opened: OpenRecord = async id => {
    if (active >= 8) await new Promise<void>(resolve => waiting.push(resolve));
    else active++;
    try { return await open(id); }
    finally { const next = waiting.shift(); if (next) next(); else active--; }
  };
  const head = parseAppRecordHead(document);
  const manual = !head && document.toolBackup?.kind === 'index' && parseToolNode(document.toolBackup).version !== 4
    ? document.toolBackup : null;
  if (!head) {
    if (!document.toolBackup) return { bytes: encoder.encode(JSON.stringify(document)).length + photoBytes, records: 1 };
    if (!manual) return zero();
  }
  const visited = new Set<string>(), files = new Map<string, ToolIndexFile>();
  const visit = async (id: string, hash: string, prefix?: string): Promise<void> => {
    id = id.toLowerCase();
    if (visited.has(id) || visited.size >= 8192) throw new ServiceError('ARCHIVE_INTEGRITY_FAILED', 503);
    visited.add(id);
    const part = manual?.snapshotId === id ? manual : (await opened(id)).document.toolBackup;
    if (!part || part.kind !== 'index' || part.snapshotId !== id || part.sha256 !== hash
      || await sha256(Uint8Array.from(atob(part.payload), c => c.charCodeAt(0))) !== hash) throw new ServiceError('ARCHIVE_INTEGRITY_FAILED', 503);
    const node = parseToolNode(part);
    if (prefix === undefined ? !manual && !isCompleteToolRoot(node) : node.version !== 4 || node.prefix !== prefix) throw new ServiceError('ARCHIVE_INTEGRITY_FAILED', 503);
    // v1-v3 indexes are visible standalone copies and carry their own count.
    // A head pointing to one must not charge the same saved copy a second time.
    if (head && prefix === undefined && node.version !== 4) return;
    if (node.version === 4 && node.children) {
      // Observe all children before propagating an error; no detached key work.
      const results = await Promise.allSettled(node.children.map(child => visit(child.snapshotID, child.sha256, child.prefix)));
      const failed = results.find(result => result.status === 'rejected');
      if (failed?.status === 'rejected') throw failed.reason;
    } else for (const file of node.files!) {
      if (files.has(file.path) || files.size >= 100_000) throw new ServiceError('ARCHIVE_INTEGRITY_FAILED', 503);
      files.set(file.path, file);
    }
  };
  await visit(head?.snapshotID ?? manual!.snapshotId, head?.indexHash ?? manual!.sha256);
  const read = async (file: ToolIndexFile): Promise<Uint8Array> => {
    const combined = new Uint8Array(file.bytes); let offset = 0;
    for (const id of file.records) {
      const { document: saved } = await opened(id.toLowerCase()), part = saved.toolBackup;
      if (!part || part.kind !== 'json' || part.path !== file.path) throw new ServiceError('ARCHIVE_INTEGRITY_FAILED', 503);
      const data = Uint8Array.from(atob(part.payload), c => c.charCodeAt(0));
      if (offset + data.length > combined.length) throw new ServiceError('ARCHIVE_INTEGRITY_FAILED', 503);
      combined.set(data, offset); offset += data.length; data.fill(0);
    }
    if (offset !== file.bytes || await sha256(combined) !== file.sha256) throw new ServiceError('ARCHIVE_INTEGRITY_FAILED', 503);
    return combined;
  };
  const result = zero();
  for (const file of files.values()) {
    if (file.path.endsWith('.jpg')) { result.bytes = safe(result.bytes + file.bytes); continue; }
    const [tool, name] = file.path.split('/');
    if (name !== toolManifests[tool!]) continue;
    let raw = await read(file);
    try {
      const counter = productRecordCounter(tool!);
      let logicalBytes = raw.length;
      const magic = 'NEKO-JSON-CHUNKS-1\n';
      if (decoder.decode(raw.slice(0, magic.length)) === magic) {
        const pointer: unknown = JSON.parse(decoder.decode(raw.slice(magic.length)));
        if (!object(pointer) || !Number.isSafeInteger(pointer.bytes) || (pointer.bytes as number) < 1
          || (pointer.bytes as number) > 128 * 1024 * 1024 || typeof pointer.sha256 !== 'string'
          || !Array.isArray(pointer.chunks) || pointer.chunks.length > 16384) return null;
        // lib.webworker declares a narrower Crypto than the Workers runtime.
        const Digest = (crypto as unknown as { DigestStream: typeof DigestStream }).DigestStream;
        const digest = new Digest('SHA-256'), writer = digest.getWriter();
        let offset = 0, finished = false;
        try {
          for (let at=0;at<pointer.chunks.length;at+=8) {
            const batch = await Promise.allSettled(pointer.chunks.slice(at,at+8).map(async (chunk:unknown) => {
              if (!object(chunk) || typeof chunk.file !== 'string') throw new ServiceError('ARCHIVE_INTEGRITY_FAILED',503);
              const entry=files.get(tool+'/'+chunk.file);
              if (!entry || entry.bytes!==chunk.bytes || entry.sha256!==chunk.sha256 || entry.bytes>32768) throw new ServiceError('ARCHIVE_INTEGRITY_FAILED',503);
              return read(entry);
            }));
            try {
              for (const item of batch) {
                if (item.status==='rejected') throw item.reason;
                offset+=item.value.length;
                if(offset>(pointer.bytes as number)) return null;
                counter.write(item.value);await writer.write(item.value);
              }
            } finally { for(const item of batch)if(item.status==='fulfilled')item.value.fill(0); }
          }
          await writer.close();finished=true;
          const hash=Array.from(new Uint8Array(await digest.digest),b=>b.toString(16).padStart(2,'0')).join('');
          if(offset!==pointer.bytes || hash!==pointer.sha256)return null;
        } finally {
          if(!finished){await writer.abort();await digest.digest.catch(()=>{});}
        }
        logicalBytes=offset;
      } else counter.write(raw);
      const count = counter.finish();
      if (count === null) return null;
      result.records = safe(result.records + count); result.bytes = safe(result.bytes + logicalBytes);
    } catch (error) {
      if (error instanceof ServiceError) throw error;
      return null;
    } finally { raw.fill(0); }
  }
  return result;
}

export function productUsage(settings: ProductQuotaSettings, counters: ProductCounters | null, trial: boolean) {
  const pending = pendingProductQuota(settings);
  if (!pending.policy || !counters || counters.product_unknown !== 0) return pending;
  safe(counters.product_bytes); safe(counters.product_records);
  const limit = trial ? pending.policy.trial : pending.policy.plus;
  return { ...pending, accountingStatus: 'ready' as const,
    enforcementStatus: settings.PRODUCT_QUOTA_ENFORCEMENT === 'true' ? 'enabled' as const : 'not_enabled' as const,
    usage: { version: 1, accounting: 'committed-visible-records-v1', tier: trial ? 'trial' : 'plus',
      storage: { usedBytes: counters.product_bytes, limitBytes: limit.limitBytes,
        availableBytes: Math.max(0, limit.limitBytes - counters.product_bytes), overLimit: counters.product_bytes > limit.limitBytes },
      records: { saved: counters.product_records, maximumRecords: limit.maximumRecords,
        available: Math.max(0, limit.maximumRecords - counters.product_records), overLimit: counters.product_records > limit.maximumRecords } } };
}

export function requireProductCapacity(settings: ProductQuotaSettings, current: ProductCounters | null,
  previous: LogicalUsage | null, next: LogicalUsage | null, trial: boolean): void {
  if (settings.PRODUCT_QUOTA_ENFORCEMENT !== 'true') return;
  if (!current || current.product_unknown !== 0 || !previous || !next) throw new ServiceError('PRODUCT_QUOTA_ACCOUNTING_UNAVAILABLE', 503);
  const policy = productQuotaPolicy(settings), limit = trial ? policy.trial : policy.plus;
  const byteLimit = safe(current.product_bytes - previous.bytes + next.bytes) > limit.limitBytes && next.bytes > previous.bytes;
  const recordLimit = safe(current.product_records - previous.records + next.records) > limit.maximumRecords && next.records > previous.records;
  if (byteLimit || recordLimit) throw new ServiceError(byteLimit && recordLimit ? 'PRODUCT_STORAGE_AND_RECORD_LIMIT_EXCEEDED'
    : byteLimit ? 'PRODUCT_STORAGE_LIMIT_EXCEEDED' : 'PRODUCT_RECORD_LIMIT_EXCEEDED', 409);
}
