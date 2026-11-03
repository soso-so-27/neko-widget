import { describe, expect, it } from 'vitest';
import { testEnv } from './group-fixture';

describe('A1 isolated late upload probe (no live route)', () => {
  it('distinguishes create-if-missing from a write bound to a retired reservation', async () => {
    const media = testEnv.MEDIA!, prefix = 'a1-synthetic/' + crypto.randomUUID() + '/';
    // The late continuation already passed its D1 membership check. Deleting
    // the key alone cannot cancel today's create-if-absent upload.
    await media.delete(prefix+'current');
    expect(await media.put(prefix+'current','late bytes',{onlyIf:{etagDoesNotMatch:'*'}})).not.toBeNull();
    // A proposed reservation CAS can only replace this particular reservation,
    // and cannot recreate bytes after the eraser retires it. The sentinel
    // contains a unique reservation nonce, not an empty constant shared by all.
    const key=prefix+'reserved';
    const reservation=await media.put(key,crypto.randomUUID(),{onlyIf:{etagDoesNotMatch:'*'}});
    expect(reservation).not.toBeNull();
    await media.delete(key);
    expect(await media.put(key,'late bytes',{onlyIf:{etagMatches:reservation!.etag}})).toBeNull();
    expect(await media.head(key)).toBeNull();
    const replacement=await media.put(key,crypto.randomUUID(),{onlyIf:{etagDoesNotMatch:'*'}});
    expect(await media.put(key,'stale',{onlyIf:{etagMatches:reservation!.etag}})).toBeNull();
    expect(await media.put(key,'fresh',{onlyIf:{etagMatches:replacement!.etag}})).not.toBeNull();
  });
});
