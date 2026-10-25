const ROOM_JOIN_FAILURE_LIMIT = 5;
const ROOM_JOIN_WINDOW_MS = 15 * 60 * 1000;
const ROOM_JOIN_LOCK_MS = 15 * 60 * 1000;

function dateMillis(value) {
  const candidate = value?.toDate?.() ?? value;
  if (candidate instanceof Date) return candidate.getTime();
  return Number.NaN;
}

function getRoomJoinFailureState(currentState, now = new Date()) {
  if (!(now instanceof Date) || !Number.isFinite(now.getTime())) {
    throw new TypeError('A valid room join attempt time is required.');
  }

  const nowMillis = now.getTime();
  const lockedUntilMillis = dateMillis(currentState.locked_until);
  if (lockedUntilMillis > nowMillis) {
    return {
      locked: true,
      failed_count: currentState.failed_count,
      window_started_at: currentState.window_started_at,
      locked_until: new Date(lockedUntilMillis),
    };
  }

  const windowStartedAtMillis = dateMillis(currentState.window_started_at);
  const isWindowExpired =
    !Number.isFinite(windowStartedAtMillis) ||
    nowMillis - windowStartedAtMillis >= ROOM_JOIN_WINDOW_MS;
  const failedCount = isWindowExpired
    ? 0
    : Number.isSafeInteger(currentState.failed_count) &&
        currentState.failed_count >= 0
      ? currentState.failed_count
      : 0;
  const nextFailedCount = failedCount + 1;

  return {
    locked: false,
    failed_count: nextFailedCount,
    window_started_at: isWindowExpired
      ? new Date(nowMillis)
      : currentState.window_started_at,
    locked_until:
      nextFailedCount >= ROOM_JOIN_FAILURE_LIMIT
        ? new Date(nowMillis + ROOM_JOIN_LOCK_MS)
        : null,
  };
}

function isValidRoomPasswordHash(value) {
  return typeof value === 'string' && /^[0-9a-f]{64}$/.test(value);
}

module.exports = {
  ROOM_JOIN_FAILURE_LIMIT,
  ROOM_JOIN_LOCK_MS,
  ROOM_JOIN_WINDOW_MS,
  getRoomJoinFailureState,
  isValidRoomPasswordHash,
};
