const test = require('node:test');
const assert = require('node:assert/strict');
const {
  getDailyQuota,
  getDailyQuotaDate,
  getDrivingPointAward,
  getQuotaReservationSource,
} = require('./daily_quota_policy');

test('daily quota limits match the client limits for free and Pro accounts', () => {
  assert.equal(getDailyQuota('room', false).limit, 3);
  assert.equal(getDailyQuota('room', true).limit, 10);
  assert.equal(getDailyQuota('ai', false).limit, 3);
  assert.equal(getDailyQuota('ai', true).limit, 10);
  assert.throws(() => getDailyQuota('unknown', false), TypeError);
});

test('admin room reservations bypass daily and bonus quotas', () => {
  assert.equal(getQuotaReservationSource(true, 100, 3, 0), 'admin');
  assert.equal(getQuotaReservationSource(false, 2, 3, 5), 'daily');
  assert.equal(getQuotaReservationSource(false, 3, 3, 5), 'bonus');
  assert.equal(getQuotaReservationSource(false, 3, 3, 0), null);
});

test('daily quota date follows the Istanbul calendar', () => {
  assert.equal(getDailyQuotaDate(new Date('2026-10-23T20:59:00.000Z')), '2026-10-23');
  assert.equal(getDailyQuotaDate(new Date('2026-10-23T21:00:00.000Z')), '2026-10-24');
  assert.throws(() => getDailyQuotaDate(new Date('invalid')), TypeError);
});

test('driving awards are bounded and add the night bonus only at night', () => {
  assert.equal(
    getDrivingPointAward(10, 30, new Date('2026-10-23T12:00:00.000Z')),
    21,
  );
  assert.equal(
    getDrivingPointAward(200, 60, new Date('2026-10-23T20:00:00.000Z')),
    50,
  );
  assert.equal(
    getDrivingPointAward(200, 60, new Date('2026-10-23T12:00:00.000Z')),
    30,
  );
  assert.equal(
    getDrivingPointAward(0.1, 30, new Date('2026-10-23T12:00:00.000Z')),
    0,
  );
  assert.equal(
    getDrivingPointAward(10, 1441, new Date('2026-10-23T12:00:00.000Z')),
    0,
  );
});
