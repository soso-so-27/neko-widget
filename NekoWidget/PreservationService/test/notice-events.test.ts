import { describe, expect, it } from 'vitest';
import { parseDeliveredNoticeEvent, type NoticeEventSource } from '../src/notice-events';

const expected: NoticeEventSource = {
  accountId: 'f9f79265f388666de8122cfb508d7776',
  zoneId: '023e105f4ecef8ad9ca31a8372d0c353',
  subscriptionId: '1830c4bb612e43c3af7f4cada31fbf3f',
  domain: 'example.com',
  sender: 'notice@example.com',
};
const now = Date.UTC(2026, 8, 23, 12);
function sample(): Record<string, any> {
  return {
    type: 'cf.email.sending.message.delivered',
    source: { type: 'email.sending', zoneId: expected.zoneId, domain: expected.domain },
    payload: {
      eventId: '0190d0c4-7e9a-7b3c-9f12-1a2b3c4d5e6f',
      messageId: '0101018f7d0c4d9a-msg-deadbeef',
      sender: expected.sender, recipient: 'user@example.net', terminal: true,
      delivery: { status: 'delivered', smtpStatusCode: '250' },
    },
    metadata: {
      accountId: expected.accountId, eventSubscriptionId: expected.subscriptionId,
      eventSchemaVersion: 1, eventTimestamp: '2026-09-23T11:00:00.000Z',
    },
  };
}

describe('private final-notice delivery event parser', () => {
  it('accepts only the configured subscription and a terminal delivered event', () => {
    expect(parseDeliveredNoticeEvent(sample(), expected, now)).toEqual({
      eventId: '0190d0c4-7e9a-7b3c-9f12-1a2b3c4d5e6f',
      messageId: '0101018f7d0c4d9a-msg-deadbeef', recipient: 'user@example.net',
      acceptedAt: Date.UTC(2026, 8, 23, 11),
    });
  });

  it('rejects non-delivery, cross-account, malformed, and future events', () => {
    const edits: Array<(event: Record<string, any>) => void> = [
      event => { event.type = 'cf.email.sending.message.bounced'; },
      event => { event.payload.delivery.status = 'deferred'; },
      event => { event.payload.terminal = false; },
      event => { event.source.zoneId = '00000000000000000000000000000000'; },
      event => { event.source.domain = 'other.example.com'; },
      event => { event.metadata.accountId = '00000000000000000000000000000000'; },
      event => { event.metadata.eventSubscriptionId = '00000000000000000000000000000000'; },
      event => { event.metadata.eventSchemaVersion = 2; },
      event => { event.payload.sender = 'attacker@example.com'; },
      event => { event.payload.recipient = 'not-an-email'; },
      event => { event.payload.messageId = ''; },
      event => { event.payload.eventId = ''; },
      event => { event.metadata.eventTimestamp = '2026-09-23T12:00:00.001Z'; },
      event => { event.metadata.eventTimestamp = '2026-02-30T11:00:00.000Z'; },
    ];
    for (const edit of edits) {
      const event = sample(); edit(event);
      expect(() => parseDeliveredNoticeEvent(event, expected, now)).toThrowError(/NOTICE_EVENT_INVALID/u);
    }
    expect(() => parseDeliveredNoticeEvent(null, expected, now)).toThrowError(/NOTICE_EVENT_INVALID/u);
  });

  it('fails closed on an invalid trusted-source configuration', () => {
    expect(() => parseDeliveredNoticeEvent(sample(), { ...expected, sender: 'other@other.example' }, now))
      .toThrowError(/NOTICE_EVENT_INVALID/u);
    expect(() => parseDeliveredNoticeEvent(sample(), expected, Number.NaN))
      .toThrowError(/NOTICE_EVENT_INVALID/u);
  });
});
