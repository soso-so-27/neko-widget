import { ServiceError, sha256 } from './contracts';

const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;
const hex = /^[0-9a-f]{64}$/u;
const prefix = '__owner_deletion/v1/';
const unavailable = () => new ServiceError('OWNER_DELETION_UNAVAILABLE', 503);
export type OwnerDeletionRequest = {
  version: 1; ownerId: string; requestId: string; receiptHash: string;
  ownerEpoch: number; requestedAt: number;
};
export type DeletionStage = 'apple-revoked' | 'plan' | 'erasing' | 'completed';

/** This journal is outside D1 and outside both content prefixes. It survives
 * restoration of an old D1 bookmark. Keep its request/completion receipts;
 * they contain opaque IDs and digests, never Apple subjects or photo content.
 * Provision the format sentinel once, before enabling this feature. Never
 * silently recreate a missing journal during login or disaster recovery.
 */
export class OwnerDeletionJournal {
  constructor(private readonly bucket: R2Bucket) {}

  private key(ownerId: string, stage: 'request' | DeletionStage): string {
    if (!uuid.test(ownerId)) throw unavailable();
    return `${prefix}${stage}/${ownerId}.json`;
  }

  async requireAvailable(): Promise<void> {
    const value = await this.read(`${prefix}format.json`, 256);
    if (value !== '{"version":1}') throw unavailable();
  }

  private async read(key: string, maximum = 16 * 1024 * 1024): Promise<string | null> {
    const object = await this.bucket.get(key);
    if (!object) return null;
    if (object.size < 1 || object.size > maximum) throw unavailable();
    const bytes = await object.arrayBuffer();
    if (bytes.byteLength !== object.size) throw unavailable();
    return new TextDecoder('utf-8', { fatal: true }).decode(bytes);
  }

  private async once(key: string, text: string): Promise<string> {
    if (new TextEncoder().encode(text).length > 16 * 1024 * 1024) throw unavailable();
    await this.bucket.put(key, text, { onlyIf: { etagDoesNotMatch: '*' },
      httpMetadata: { contentType: 'application/json' } });
    const actual = await this.read(key);
    if (actual === null) throw unavailable();
    return actual;
  }

  private decode(text: string, ownerId: string): OwnerDeletionRequest {
    const r = JSON.parse(text) as OwnerDeletionRequest;
    if (!r || Object.keys(r).sort().join(',') !==
      'ownerEpoch,ownerId,receiptHash,requestId,requestedAt,version'
      || r.version !== 1 || r.ownerId !== ownerId || !uuid.test(r.requestId)
      || !hex.test(r.receiptHash) || !Number.isSafeInteger(r.ownerEpoch) || r.ownerEpoch < 1
      || !Number.isSafeInteger(r.requestedAt) || r.requestedAt < 1) throw unavailable();
    return r;
  }

  async request(ownerId: string): Promise<OwnerDeletionRequest | null> {
    await this.requireAvailable();
    const text = await this.read(this.key(ownerId, 'request'), 2048);
    return text === null ? null : this.decode(text, ownerId);
  }

  async prepare(request: OwnerDeletionRequest): Promise<OwnerDeletionRequest> {
    await this.requireAvailable();
    this.decode(JSON.stringify(request), request.ownerId);
    return this.decode(await this.once(this.key(request.ownerId, 'request'),
      JSON.stringify(request)), request.ownerId);
  }

  async assertNotRequested(ownerId: string): Promise<void> {
    if (await this.request(ownerId)) throw new ServiceError('OWNER_DELETION_PENDING', 409);
  }

  async stage<T>(request: OwnerDeletionRequest, stage: DeletionStage): Promise<T | null> {
    const text = await this.read(this.key(request.ownerId, stage));
    if (text === null) return null;
    const item = JSON.parse(text) as { requestSHA256: string; value: T };
    if (!item || Object.keys(item).sort().join(',') !== 'requestSHA256,value'
      || item.requestSHA256 !== await sha256(JSON.stringify(request))) throw unavailable();
    return item.value;
  }

  async record<T>(request: OwnerDeletionRequest, stage: DeletionStage, value: T): Promise<T> {
    const text = JSON.stringify({ requestSHA256: await sha256(JSON.stringify(request)), value });
    const actual = await this.once(this.key(request.ownerId, stage), text);
    if (actual !== text) throw unavailable();
    return value;
  }

  async status(ownerId: string, receipt: string): Promise<{ state: 'processing' | 'completed' }> {
    if (!/^[A-Za-z0-9_-]{43}$/u.test(receipt)) throw unavailable();
    const request = await this.request(ownerId);
    if (!request || request.receiptHash !== await sha256(receipt)) {
      throw new ServiceError('OWNER_DELETION_NOT_FOUND', 404);
    }
    const completed = await this.stage<{ completedAt: number }>(request, 'completed');
    if (completed && (!Number.isSafeInteger(completed.completedAt)
      || completed.completedAt < request.requestedAt)) throw unavailable();
    return { state: completed ? 'completed' : 'processing' };
  }

  async markAttempt(ownerId: string): Promise<void> {
    await this.requireAvailable();
    this.key(ownerId, 'request');
    await this.bucket.put(`${prefix}scan-after`, ownerId);
  }

  /** Round-robin across opaque receipts, including permanently blocked ones.
   * The cursor is scheduling state only; it never grants deletion authority.
   */
  async pending(limit = 10): Promise<OwnerDeletionRequest[]> {
    await this.requireAvailable();
    if (!Number.isSafeInteger(limit) || limit < 1 || limit > 100) throw unavailable();
    const requests: OwnerDeletionRequest[] = [];
    const last = await this.read(`${prefix}scan-after`, 128);
    if (last !== null && !uuid.test(last)) throw unavailable();
    const boundary = last ? this.key(last, 'request') : null;
    const seen = new Set<string>();
    for (const wrapped of boundary ? [false, true] : [false]) {
    let cursor: string | undefined;
    do {
      const page = await this.bucket.list({ prefix: `${prefix}request/`, limit: 1000,
        ...(!wrapped && boundary ? { startAfter: boundary } : {}),
        ...(cursor ? { cursor } : {}) });
      for (const object of page.objects) {
        if (wrapped && boundary && object.key > boundary) return requests;
        const ownerId = object.key.slice(`${prefix}request/`.length, -5);
        const request = await this.request(ownerId);
        if (!request) throw unavailable();
        if (!await this.stage(request, 'completed')) requests.push(request);
        if (requests.length >= limit) return requests;
      }
      if (!page.truncated) break;
      if (!page.cursor || seen.has(page.cursor)) throw unavailable();
      cursor = page.cursor;
      seen.add(cursor);
    } while (seen.size < 100);
    if (seen.size >= 100) throw unavailable();
    }
    return requests;
  }
}
