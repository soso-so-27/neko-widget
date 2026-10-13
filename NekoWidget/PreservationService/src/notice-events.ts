import { contactEmailValid, ServiceError } from './contracts';

export interface NoticeEventSource {
  accountId: string;
  zoneId: string;
  subscriptionId: string;
  domain: string;
  sender: string;
}

export interface DeliveredNoticeEvent {
  eventId: string;
  messageId: string;
  recipient: string;
  acceptedAt: number;
}

const object = (value: unknown): Record<string, unknown> | null =>
  value !== null && typeof value === 'object' && !Array.isArray(value) ? value as Record<string, unknown> : null;
function invalid(): never { throw new ServiceError('NOTICE_EVENT_INVALID', 503); }
const hex32 = (value: unknown): value is string => typeof value === 'string' && /^[0-9a-f]{32}$/u.test(value);
const eventIdValid = (value: unknown): value is string => typeof value === 'string'
  && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/u.test(value);
/** Preserve opaque provider IDs byte-for-byte. Also accept canonical angle
 * Message-IDs with an ASCII dot-atom and DNS name; never headers or whitespace.
 */
export function noticeMessageIdValid(value: unknown): value is string {
  if (typeof value !== 'string' || value.length < 8 || value.length > 256) return false;
  return /^[A-Za-z0-9._:-]+(?![\s\S])/u.test(value)
    || /^<[A-Za-z0-9!#$%&'*+\/=?^_`{|}~-]+(?:\.[A-Za-z0-9!#$%&'*+\/=?^_`{|}~-]+)*@(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}>(?![\s\S])/u.test(value);
}

const domainValid = (value: unknown): value is string => typeof value === 'string'
  && value.length <= 253 && /^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$/u.test(value);

/** Parse only an event from the configured Cloudflare sending subscription.
 * Calling code must also trust the private Queue binding and match this result
 * against a durable submission and the currently verified contact. This parser
 * alone never records a delivery or authorizes deletion.
 */
export function parseDeliveredNoticeEvent(input: unknown, expected: NoticeEventSource, now: number): DeliveredNoticeEvent {
  if (!hex32(expected.accountId) || !hex32(expected.zoneId) || !hex32(expected.subscriptionId)
      || !domainValid(expected.domain) || !contactEmailValid(expected.sender)
      || !expected.sender.endsWith(`@${expected.domain}`)
      || !Number.isSafeInteger(now) || now <= 0) invalid();
  const envelope = object(input);
  const source = object(envelope?.source);
  const payload = object(envelope?.payload);
  const delivery = object(payload?.delivery);
  const metadata = object(envelope?.metadata);
  if (!envelope || !source || !payload || !delivery || !metadata) invalid();
  if (envelope.type !== 'cf.email.sending.message.delivered'
      || source?.type !== 'email.sending' || source.zoneId !== expected.zoneId
      || source.domain !== expected.domain || metadata?.accountId !== expected.accountId
      || metadata.eventSubscriptionId !== expected.subscriptionId || metadata.eventSchemaVersion !== 1
      || payload.terminal !== true || delivery?.status !== 'delivered') invalid();
  const { eventId, messageId, recipient } = payload;
  if (!eventIdValid(eventId) || !noticeMessageIdValid(messageId)
      || payload.sender !== expected.sender || !contactEmailValid(recipient)) invalid();
  const timestamp = metadata.eventTimestamp;
  if (typeof timestamp !== 'string' || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/u.test(timestamp)) {
    invalid();
  }
  const acceptedAt = Date.parse(timestamp);
  if (!Number.isSafeInteger(acceptedAt) || acceptedAt <= 0 || acceptedAt > now
      || new Date(acceptedAt).toISOString() !== timestamp) invalid();
  return { eventId, messageId, recipient, acceptedAt };
}
