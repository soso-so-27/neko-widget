import { ServiceError } from './contracts';
import { readBoundedBody } from './bounded-body';

const endpoint = 'https://appleid.apple.com/auth/revoke';
const unavailable = () => new ServiceError('APPLE_REVOCATION_UNAVAILABLE', 503);
type Options = {
  enabled?: boolean;
  clientId: string;
  getClientSecret: () => Promise<string>;
  fetchImpl?: typeof fetch;
};

/** Private deletion-stage transport only. No public HTTP route calls it.
 * The controller must first verify the exact owner's durable deletion request
 * and open that owner's encrypted credential. Keep the credential until this
 * step succeeds so an outage can be retried. This does not erase storage,
 * cancel an App Store subscription, or authorize deletion by itself.
 */
export class AppleTokenRevoker {
  constructor(private readonly options: Options) {}

  async revokeRefreshToken(refreshToken: string): Promise<void> {
    if (this.options.enabled !== true) throw new ServiceError('APPLE_REVOCATION_DISABLED', 503);
    if (!/^[a-zA-Z0-9][a-zA-Z0-9.-]{1,254}$/u.test(this.options.clientId)
      || typeof refreshToken !== 'string' || !/^[\x21-\x7e]{1,16384}$/u.test(refreshToken)) throw unavailable();
    try {
      const clientSecret = await this.options.getClientSecret();
      if (typeof clientSecret !== 'string' || !/^[\x21-\x7e]{1,16384}$/u.test(clientSecret)) throw unavailable();
      const signal = AbortSignal.timeout(5000);
      const form = new URLSearchParams({ client_id: this.options.clientId, client_secret: clientSecret,
        token: refreshToken, token_type_hint: 'refresh_token' });
      const send = this.options.fetchImpl ?? fetch;
      const reply = await send(endpoint, { method: 'POST', redirect: 'manual', cache: 'no-store',
        signal, headers: { 'content-type': 'application/x-www-form-urlencoded' }, body: form.toString() });
      // Apple documents empty HTTP200 for successful or already-invalidated
      // tokens. Reject redirects/error bodies; never log provider credentials.
      if (reply.status !== 200) {
        // Stream cleanup is best-effort; a provider failure must not wait on it.
        void reply.body?.cancel().catch(() => {});
        throw unavailable();
      }
      if (signal.aborted) throw unavailable();
      if (reply.body && (await readBoundedBody(reply.body, 1, unavailable, signal)).byteLength !== 0) throw unavailable();
      if (signal.aborted) throw unavailable();
    } catch { throw unavailable(); }
  }
}
