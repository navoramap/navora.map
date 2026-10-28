const CHAT_MESSAGE_MIN_INTERVAL_MS = 3 * 1000;
const CHAT_MESSAGE_WINDOW_MS = 60 * 1000;
const CHAT_MESSAGE_WINDOW_LIMIT = 10;
const CHAT_USER_MUTE_MS = 60 * 60 * 1000;
const CHAT_ADMIN_ACTION_RETENTION_MS = 90 * 24 * 60 * 60 * 1000;

function timestampMillis(value) {
  const timestamp = value?.toDate?.() ?? value;
  return timestamp instanceof Date ? timestamp.getTime() : Number.NaN;
}

function checkChatMessagePolicy({
  now = new Date(),
  rateState = {},
  moderationState = {},
}) {
  if (!(now instanceof Date) || !Number.isFinite(now.getTime())) {
    throw new TypeError('A valid chat moderation time is required.');
  }

  const nowMillis = now.getTime();
  const mutedUntil = timestampMillis(moderationState.muted_until);
  if (mutedUntil > nowMillis) {
    return { allowed: false, reason: 'muted' };
  }

  const lastMessageAt = timestampMillis(rateState.last_message_at);
  if (Number.isFinite(lastMessageAt) &&
      nowMillis - lastMessageAt < CHAT_MESSAGE_MIN_INTERVAL_MS) {
    return { allowed: false, reason: 'too-fast' };
  }

  const windowStartedAt = timestampMillis(rateState.window_started_at);
  const windowExpired = !Number.isFinite(windowStartedAt) ||
    nowMillis - windowStartedAt >= CHAT_MESSAGE_WINDOW_MS;
  const messageCount = windowExpired
    ? 0
    : Number.isSafeInteger(rateState.message_count) &&
        rateState.message_count >= 0
      ? rateState.message_count
      : 0;
  if (messageCount >= CHAT_MESSAGE_WINDOW_LIMIT) {
    return { allowed: false, reason: 'rate-limit' };
  }

  return {
    allowed: true,
    nextRateState: {
      last_message_at: now,
      message_count: messageCount + 1,
      window_started_at: windowExpired
        ? now
        : new Date(windowStartedAt),
    },
  };
}

module.exports = {
  CHAT_ADMIN_ACTION_RETENTION_MS,
  CHAT_MESSAGE_MIN_INTERVAL_MS,
  CHAT_MESSAGE_WINDOW_LIMIT,
  CHAT_MESSAGE_WINDOW_MS,
  CHAT_USER_MUTE_MS,
  checkChatMessagePolicy,
};
