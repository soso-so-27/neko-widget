import { ServiceError } from './contracts';

const uuid = '[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}';
const recordUuid = '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}';
const ownerPattern = new RegExp(`^${uuid}$`, 'u');
const photoKeyPattern = new RegExp(`^personal/${uuid}/${recordUuid}/${uuid}$`, 'u');
const unavailable = () => new ServiceError('ARCHIVE_INVENTORY_UNAVAILABLE', 503);

export type OwnerPhoto = { key: string; version: string; bytes: number };
export type OwnerPhotoCursor = { ownerId: string; token: string; lastKey: string | null };
export type OwnerPhotoPage = { objects: OwnerPhoto[]; nextCursor: OwnerPhotoCursor | null };

/** Read-only inventory page. No page, even an untruncated one, is deletion
 * authority: a caller must first stop owner writes, finish every page, compare
 * all DB references and recovery versions, and verify absence after deletion.
 */
export async function listOwnerPhotoPage(bucket: R2Bucket, ownerId: string,
  cursor?: OwnerPhotoCursor): Promise<OwnerPhotoPage> {
  if (!ownerPattern.test(ownerId) || (cursor && (cursor.ownerId !== ownerId
    || !cursor.token || cursor.token.length > 4096
    || (cursor.lastKey !== null && (!photoKeyPattern.test(cursor.lastKey)
      || !cursor.lastKey.startsWith(`personal/${ownerId}/`)))))) throw unavailable();
  const prefix = `personal/${ownerId}/`;
  try {
    const result = await bucket.list({ prefix, limit: 1000,
      ...(cursor ? { cursor: cursor.token } : {}) });
    if (!result || !Array.isArray(result.objects) || result.objects.length > 1000
      || typeof result.truncated !== 'boolean' || !Array.isArray(result.delimitedPrefixes)
      || result.delimitedPrefixes.length !== 0) throw unavailable();
    const objects: OwnerPhoto[] = [];
    let lastKey = cursor?.lastKey ?? null;
    for (const item of result.objects) {
      if (!photoKeyPattern.test(item.key) || !item.key.startsWith(prefix)
        || (lastKey !== null && item.key <= lastKey)
        || typeof item.version !== 'string' || !item.version || item.version.length > 1024
        || !Number.isSafeInteger(item.size) || item.size < 1 || item.size > 30 * 1024 * 1024) {
        throw unavailable();
      }
      objects.push({ key: item.key, version: item.version, bytes: item.size });
      lastKey = item.key;
    }
    const token = (result as { cursor?: unknown }).cursor;
    if (!result.truncated) {
      if (token) throw unavailable();
      return { objects, nextCursor: null };
    }
    if (typeof token !== 'string' || !token || token.length > 4096
      || token === cursor?.token) throw unavailable();
    return { objects, nextCursor: { ownerId, token, lastKey } };
  } catch { throw unavailable(); }
}
