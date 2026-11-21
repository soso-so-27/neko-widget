import { describe, expect, it } from 'vitest';
import { matchesErasureReviewSlot } from '../src/record-deletion-worker';

const reviewAt = Date.UTC(2026, 10, 21, 7, 29);
const cron = '29 7 21 11 *';

describe('one-time record erasure schedule', () => {
  it.each([0, 20_796, 59_999])('accepts the exact cron %i ms into the approved minute', offset => {
    expect(matchesErasureReviewSlot({ cron, scheduledTime: reviewAt + offset }, reviewAt)).toBe(true);
  });

  it.each([-1, 60_000, Date.UTC(2027, 10, 21, 7, 29) - reviewAt])('rejects a matching cron outside the approved minute (%i ms)', offset => {
    expect(matchesErasureReviewSlot({ cron, scheduledTime: reviewAt + offset }, reviewAt)).toBe(false);
  });

  it('rejects a different cron in that minute and a misaligned configuration', () => {
    const scheduledTime = reviewAt + 20_796;
    expect(matchesErasureReviewSlot({ cron: '* * * * *', scheduledTime }, reviewAt)).toBe(false);
    expect(matchesErasureReviewSlot({ cron, scheduledTime }, scheduledTime)).toBe(false);
  });
});
