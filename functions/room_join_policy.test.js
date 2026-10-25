const test = require('node:test');
const assert = require('node:assert/strict');
const {
  ROOM_JOIN_FAILURE_LIMIT,
  ROOM_JOIN_LOCK_MS,
  ROOM_JOIN_WINDOW_MS,
  getRoomJoinFailureState,
  isValidRoomPasswordHash,
} = require('./room_join_policy');

test('room join failures lock after five attempts for fifteen minutes', () => {
  const now = new Date('2026-10-25T12:00:00.000Z');
  let state = {};
  for (let attempt = 0; attempt < ROOM_JOIN_FAILURE_LIMIT; attempt++) {
    state = getRoomJoinFailureState(state, now);
    assert.equal(state.locked, false);
  }

  assert.equal(state.failed_count, 5);
  assert.equal(state.locked_until.getTime(), now.getTime() + ROOM_JOIN_LOCK_MS);
  assert.equal(getRoomJoinFailureState(state, now).locked, true);
});

test('expired attempt windows start a fresh counter', () => {
  const firstAttemptAt = new Date('2026-10-25T12:00:00.000Z');
  const nextAttemptAt = new Date(
    firstAttemptAt.getTime() + ROOM_JOIN_WINDOW_MS,
  );
  const state = getRoomJoinFailureState(
    {
      failed_count: 4,
      window_started_at: firstAttemptAt,
      locked_until: null,
    },
    nextAttemptAt,
  );

  assert.equal(state.failed_count, 1);
  assert.equal(state.window_started_at.getTime(), nextAttemptAt.getTime());
  assert.equal(state.locked_until, null);
});

test('password hashes must be exactly 64 lowercase hexadecimal characters', () => {
  assert.equal(isValidRoomPasswordHash('a'.repeat(64)), true);
  assert.equal(isValidRoomPasswordHash('A'.repeat(64)), false);
  assert.equal(isValidRoomPasswordHash('a'.repeat(63)), false);
  assert.equal(isValidRoomPasswordHash(null), false);
});

test('rejects invalid attempt timestamps', () => {
  assert.throws(
    () => getRoomJoinFailureState({}, new Date('invalid')),
    TypeError,
  );
});
