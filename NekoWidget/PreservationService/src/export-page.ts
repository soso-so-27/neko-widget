import { ServiceError, type Session } from './contracts';
import { recordId } from './documents';
import type { ArchiveStore } from './storage';

const MAX_RECORDS = 50, MAX_TOTAL_RECORDS = 1000;
const MAX_QUOTA_BYTES = 64 * 1024 * 1024, MAX_FRAME_BYTES = 29 * 1024 * 1024;
const MAX_WIRE_BYTES = 96 * 1024 * 1024;
const utf8 = new TextEncoder();
type Dependencies = {
  db: D1Database;
  auth: { requireSession(token: string): Promise<Session> };
  read(token: string, id: string): ReturnType<ArchiveStore['read']>;
};
type Item = { record_id: string; quota_bytes: number; metadata_bytes: number; photo_bytes: number };
const unavailable = () => new ServiceError('EXPORT_UNAVAILABLE', 503);
const interrupted = () => new ServiceError('EXPORT_INTERRUPTED', 409);
const integer = (n: number, maximum = Number.MAX_SAFE_INTEGER) => Number.isSafeInteger(n) && n >= 0 && n <= maximum;

/** One bounded page. The owner lease and every output fence use primary D1;
 * the original session must survive the whole page. No lease/session renewal.
 * A consumer must reject EOF/body errors without a matching complete frame.
 */
export async function exportPage(d: Dependencies, request: Request, token: string,
  context?: Pick<ExecutionContext, 'waitUntil'>): Promise<Response> {
  const query = new URL(request.url).searchParams;
  for (const [key] of query) if (!['after', 'generation'].includes(key) || query.getAll(key).length !== 1) {
    throw new ServiceError('INVALID_REQUEST');
  }
  const after = query.has('after') ? recordId(query.get('after')!) : '';
  const rawGeneration = query.get('generation');
  if ((after && rawGeneration === null) || (rawGeneration !== null
    && (!/^(0|[1-9]\d{0,15})$/.test(rawGeneration) || !integer(Number(rawGeneration))))) {
    throw new ServiceError('INVALID_REQUEST');
  }
  if (request.signal.aborted) throw interrupted();
  const session = await d.auth.requireSession(token);
  const leaseId = crypto.randomUUID();
  const active = `EXISTS(SELECT 1 FROM pa_sessions s WHERE s.session_hash=?
    AND s.owner_id=pa_owners.owner_id AND s.owner_epoch=pa_owners.epoch
    AND s.expires_at>unixepoch('subsec')*1000)`;
  let releasePromise: Promise<boolean> | undefined;
  const release = () => {
    if (!releasePromise) {
      releasePromise = (async () => {
        const row = await d.db.prepare(`UPDATE pa_owners SET export_lease_id=NULL,export_lease_expires_at=0
          WHERE owner_id=? AND export_lease_id=? RETURNING owner_id`)
          .bind(session.ownerId, leaseId).first<{ owner_id: string }>();
        return !!row;
      })();
      // A disconnected HTTP request may be terminated before cancel finishes.
      // Allow cleanup the runtime's bounded grace; a DB outage still relies on expiry.
      context?.waitUntil(releasePromise.catch(() => {}));
    }
    return releasePromise;
  };
  let stopped = false, controller: ReadableStreamDefaultController<Uint8Array> | undefined;
  let deadline: ReturnType<typeof setTimeout> | undefined;
  const detach = () => { if (deadline !== undefined) clearTimeout(deadline); request.signal.removeEventListener('abort', cancel); };
  const cancel = () => {
    if (stopped) return;
    stopped = true; detach(); controller?.error(interrupted());
    void release().catch(() => { /* The fixed lease expiry remains the fail-closed fallback. */ });
  };
  const open = () => { if (stopped || request.signal.aborted) throw interrupted(); };
  try {
    const lease = await d.db.prepare(`UPDATE pa_owners SET export_lease_id=?,
      export_lease_expires_at=(SELECT expires_at FROM pa_sessions WHERE session_hash=?)
      WHERE owner_id=? AND disabled=0 AND purge_fence_id IS NULL AND ${active}
        AND (export_lease_id IS NULL OR export_lease_expires_at<=unixepoch('subsec')*1000)
        AND NOT EXISTS(SELECT 1 FROM pa_owner_deletion_requests r WHERE r.owner_id=pa_owners.owner_id)
      RETURNING export_lease_expires_at,CAST(unixepoch('subsec')*1000 AS INTEGER) AS now_ms`)
      .bind(leaseId, session.sessionHash, session.ownerId, session.sessionHash)
      .first<{ export_lease_expires_at: number; now_ms: number }>();
    if (!lease) throw new ServiceError('EXPORT_PAGE_BUSY', 409);
    if (!integer(lease.export_lease_expires_at) || !integer(lease.now_ms)
      || lease.export_lease_expires_at <= lease.now_ms || lease.export_lease_expires_at > session.expiresAt
      || lease.export_lease_expires_at - lease.now_ms > 15 * 60_000) throw unavailable();
    request.signal.addEventListener('abort', cancel, { once: true });
    deadline = setTimeout(cancel, lease.export_lease_expires_at - lease.now_ms);
    open();
    const snapshot = await d.db.prepare(`SELECT
      COALESCE((SELECT generation FROM pa_inventory WHERE owner_id=?),0) AS generation,
      (SELECT COUNT(*) FROM pa_records WHERE owner_id=? AND deleted=0) AS total_records,
      EXISTS(SELECT 1 FROM pa_inventory WHERE owner_id=?) AS inventory_present`)
      .bind(session.ownerId, session.ownerId, session.ownerId)
      .first<{ generation: number; total_records: number; inventory_present: number }>();
    if (!snapshot || !integer(snapshot.generation) || !integer(snapshot.total_records, MAX_TOTAL_RECORDS)
      || (snapshot.total_records > 0 && snapshot.inventory_present !== 1)) throw unavailable();
    const generation = snapshot.generation;
    if (rawGeneration !== null && Number(rawGeneration) !== generation) throw new ServiceError('ARCHIVE_CHANGED', 409);
    if (after) {
      const cursor = await d.db.prepare('SELECT 1 AS found FROM pa_records WHERE owner_id=? AND record_id=? AND deleted=0')
        .bind(session.ownerId, after).first();
      if (!cursor) throw new ServiceError('INVALID_REQUEST');
    }
    const rows = (await d.db.prepare(`SELECT record_id,quota_bytes,length(metadata) AS metadata_bytes,photo_bytes
      FROM pa_records WHERE owner_id=? AND deleted=0 AND record_id>? ORDER BY record_id LIMIT ?`)
      .bind(session.ownerId, after, MAX_RECORDS + 1).all<Item>()).results;
    const page: Item[] = []; let quotaBytes = 0, previous = after;
    for (const row of rows) {
      recordId(row.record_id);
      if (row.record_id <= previous || !integer(row.metadata_bytes, 512 * 1024) || row.metadata_bytes < 1
        || !integer(row.photo_bytes, 20 * 1024 * 1024) || !integer(row.quota_bytes, 30.5 * 1024 * 1024)
        || row.quota_bytes < row.metadata_bytes + row.photo_bytes) throw unavailable();
      previous = row.record_id;
      if (page.length === MAX_RECORDS || quotaBytes + row.quota_bytes > MAX_QUOTA_BYTES) break;
      quotaBytes += row.quota_bytes; page.push(row);
    }
    if (rows.length && !page.length) throw unavailable();
    const nextCursor = rows.length > page.length ? page.at(-1)!.record_id : null;
    const fence = async () => {
      open();
      const current = await d.auth.requireSession(token);
      if (current.ownerId !== session.ownerId || current.sessionHash !== session.sessionHash) throw interrupted();
      const allowed = await d.db.prepare(`SELECT 1 AS allowed FROM pa_owners
        WHERE owner_id=? AND disabled=0 AND purge_fence_id IS NULL AND ${active}
          AND export_lease_id=? AND export_lease_expires_at>unixepoch('subsec')*1000
          AND COALESCE((SELECT generation FROM pa_inventory WHERE owner_id=pa_owners.owner_id),0)=?
          AND NOT EXISTS(SELECT 1 FROM pa_owner_deletion_requests r WHERE r.owner_id=pa_owners.owner_id)`)
        .bind(session.ownerId, session.sessionHash, leaseId, generation).first();
      if (!allowed) throw interrupted();
      open();
    };
    await fence();
    let phase: 'header' | 'records' = 'header', index = 0, wireBytes = 0;
    const frame = (value: unknown) => {
      const json = JSON.stringify(value);
      if (json.length + 1 > MAX_FRAME_BYTES) throw unavailable();
      const bytes = utf8.encode(json + '\n');
      if (bytes.length > MAX_FRAME_BYTES || wireBytes + bytes.length > MAX_WIRE_BYTES) throw unavailable();
      wireBytes += bytes.length; return bytes;
    };
    const recordFrame = (record: Awaited<ReturnType<Dependencies['read']>>) => {
      if (record.photoBase64 === null) return frame({ type: 'record', ...record });
      const { photoBase64, ...metadata } = record;
      // Keep a Japanese memo from widening a photo-sized JSON string to UTF-16.
      // Only small metadata is stringified; the existing encoder's ASCII base64
      // goes directly into the single, bounded output frame.
      if (typeof photoBase64 !== 'string') throw unavailable();
      const head = utf8.encode(JSON.stringify({ type: 'record', ...metadata }).slice(0, -1) + ',"photoBase64":"');
      const size = head.length + photoBase64.length + 3; // closing quote, brace, newline
      if (size > MAX_FRAME_BYTES || wireBytes + size > MAX_WIRE_BYTES) throw unavailable();
      // ArchiveStore.read produces base64 internally. Verify that assumption
      // before writing its content without JSON escaping.
      if (!/^[A-Za-z0-9+/]*={0,2}(?![\s\S])/.test(photoBase64)) throw unavailable();
      const bytes = new Uint8Array(size); bytes.set(head);
      const encoded = utf8.encodeInto(photoBase64, bytes.subarray(head.length, size - 3));
      if (encoded.read !== photoBase64.length || encoded.written !== photoBase64.length) throw unavailable();
      bytes.set([34, 125, 10], size - 3);
      wireBytes += size; return bytes;
    };
    const body = new ReadableStream<Uint8Array>({
      start(value) { controller = value; },
      async pull(output) {
        try {
          open();
          if (phase === 'header') {
            await fence();
            output.enqueue(frame({ version: 1, type: 'header', generation, totalRecords: snapshot.total_records }));
            phase = 'records'; return;
          }
          if (index < page.length) {
            const item = page[index]!;
            await fence();
            const record = await d.read(token, item.record_id);
            const bytes = recordFrame(record);
            await fence(); // Recheck after decrypt/read/serialization and before bytes leave this page.
            if (record.recordId !== item.record_id) throw interrupted();
            output.enqueue(bytes); index++; return;
          }
          await fence();
          const bytes = frame({ type: 'complete', generation, recordCount: index, nextCursor });
          const completed = await d.db.prepare(`UPDATE pa_owners SET export_lease_id=NULL,export_lease_expires_at=0
            WHERE owner_id=? AND export_lease_id=? AND disabled=0 AND purge_fence_id IS NULL AND ${active}
              AND export_lease_expires_at>unixepoch('subsec')*1000
              AND COALESCE((SELECT generation FROM pa_inventory WHERE owner_id=pa_owners.owner_id),0)=?
              AND NOT EXISTS(SELECT 1 FROM pa_owner_deletion_requests r WHERE r.owner_id=pa_owners.owner_id)
            RETURNING owner_id`).bind(session.ownerId, leaseId, session.sessionHash, generation).first();
          if (!completed) throw interrupted();
          releasePromise = Promise.resolve(true);
          open(); stopped = true; detach(); output.enqueue(bytes); output.close();
        } catch {
          if (!stopped) { stopped = true; detach(); output.error(interrupted()); }
          await release().catch(() => { /* No complete frame on uncertain cleanup. */ });
        }
      },
      async cancel() { stopped = true; detach(); await release(); },
    }, { highWaterMark: 0 });
    return new Response(body, { headers: { 'content-type': 'application/x-ndjson', 'cache-control': 'no-store',
      'x-content-type-options': 'nosniff' } });
  } catch (error) {
    stopped = true; detach(); await release().catch(() => {});
    if (error instanceof ServiceError) throw error;
    throw unavailable();
  }
}
