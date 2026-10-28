const assert = require('node:assert/strict');
const test = require('node:test');
const {
  CHAT_MESSAGE_MIN_INTERVAL_MS,
  CHAT_MESSAGE_WINDOW_LIMIT,
  CHAT_MESSAGE_WINDOW_MS,
  CHAT_USER_MUTE_MS,
  checkChatMessagePolicy,
} = require('./chat_moderation_policy');

test('chat messages require a three-second gap', () => {
  const now = new Date('2026-10-25T12:00:03.000Z');
  const result = checkChatMessagePolicy({
    now,
    rateState: {
      last_message_at: new Date(now.getTime() - CHAT_MESSAGE_MIN_INTERVAL_MS + 1),
      message_count: 1,
      window_started_at: new Date(now.getTime() - 1000),
    },
  });

  assert.equal(result.allowed, false);
  assert.equal(result.reason, 'too-fast');
});

test('chat allows at most ten messages in a rolling minute', () => {
  const now = new Date('2026-10-25T12:00:30.000Z');
  const result = checkChatMessagePolicy({
    now,
    rateState: {
      last_message_at: new Date(now.getTime() - CHAT_MESSAGE_MIN_INTERVAL_MS),
      message_count: CHAT_MESSAGE_WINDOW_LIMIT,
      window_started_at: new Date(now.getTime() - 10_000),
    },
  });

  assert.equal(result.allowed, false);
  assert.equal(result.reason, 'rate-limit');
});

test('expired rate windows reset and accepted messages advance the counter', () => {
  const now = new Date('2026-10-25T12:01:00.000Z');
  const result = checkChatMessagePolicy({
    now,
    rateState: {
      last_message_at: new Date(now.getTime() - CHAT_MESSAGE_MIN_INTERVAL_MS),
      message_count: CHAT_MESSAGE_WINDOW_LIMIT,
      window_started_at: new Date(now.getTime() - CHAT_MESSAGE_WINDOW_MS),
    },
  });

  assert.equal(result.allowed, true);
  assert.deepEqual(result.nextRateState, {
    last_message_at: now,
    message_count: 1,
    window_started_at: now,
  });
});

test('active administrator mutes block messages until their expiry', () => {
  const now = new Date('2026-10-25T12:00:00.000Z');
  const result = checkChatMessagePolicy({
    now,
    moderationState: {
      muted_until: new Date(now.getTime() + CHAT_USER_MUTE_MS),
    },
  });

  assert.equal(result.allowed, false);
  assert.equal(result.reason, 'muted');
});

test('rejects invalid moderation times', () => {
  assert.throws(
    () => checkChatMessagePolicy({ now: new Date('invalid') }),
    TypeError,
  );
});
