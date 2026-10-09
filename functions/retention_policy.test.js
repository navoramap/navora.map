const assert = require('node:assert/strict');
const { test } = require('node:test');
const {
  getRetentionCutoffs,
  PUBLIC_CHAT_RETENTION_MS,
  ROOM_RETENTION_MS,
} = require('./retention_policy');

test('expires room data after 24 hours and general chat after 30 days', () => {
  const now = new Date('2026-10-09T12:00:00.000Z');
  const cutoffs = getRetentionCutoffs(now);

  assert.equal(cutoffs.roomsExpiresAtOrBefore.getTime(), now.getTime() - ROOM_RETENTION_MS);
  assert.equal(
    cutoffs.publicMessagesCreatedAtOrBefore.getTime(),
    now.getTime() - PUBLIC_CHAT_RETENTION_MS,
  );
});

test('rejects an invalid cleanup time', () => {
  assert.throws(() => getRetentionCutoffs(new Date('invalid')), /valid cleanup time/);
});