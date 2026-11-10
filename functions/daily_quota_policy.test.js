const test = require('node:test');
const assert = require('node:assert/strict');
const {
  getDailyQuota,
  getDailyQuotaDate,
  getQuotaReservationSource,
} = require('./daily_quota_policy');

test('daily quota limits match the client limits for free and Pro accounts', () => {
  assert.equal(getDailyQuota('room', false).limit, 3);
  assert.equal(getDailyQuota('room', true).limit, 10);
  assert.equal(getDailyQuota('ai', false).limit, 3);
  assert.equal(getDailyQuota('ai', true).limit, 10);
  assert.throws(() => getDailyQuota('unknown', false), TypeError);
});

test('daily quota reservations allow only admin bypass or remaining quota', () => {
  assert.equal(getQuotaReservationSource(true, 100, 3), 'admin');
  assert.equal(getQuotaReservationSource(false, 2, 3), 'daily');
  assert.equal(getQuotaReservationSource(false, 3, 3), null);
});

test('daily quota date follows the Istanbul calendar', () => {
  assert.equal(getDailyQuotaDate(new Date('2026-10-23T20:59:00.000Z')), '2026-10-23');
  assert.equal(getDailyQuotaDate(new Date('2026-10-23T21:00:00.000Z')), '2026-10-24');
  assert.throws(() => getDailyQuotaDate(new Date('invalid')), TypeError);
});
