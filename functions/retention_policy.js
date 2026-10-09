const ROOM_RETENTION_MS = 24 * 60 * 60 * 1000;
const PUBLIC_CHAT_RETENTION_MS = 30 * 24 * 60 * 60 * 1000;

function getRetentionCutoffs(now = new Date()) {
  const nowMs = now instanceof Date ? now.getTime() : Number(now);
  if (!Number.isFinite(nowMs)) {
    throw new TypeError('A valid cleanup time is required.');
  }

  return {
    roomsExpiresAtOrBefore: new Date(nowMs - ROOM_RETENTION_MS),
    publicMessagesCreatedAtOrBefore: new Date(
      nowMs - PUBLIC_CHAT_RETENTION_MS,
    ),
  };
}

module.exports = {
  getRetentionCutoffs,
  PUBLIC_CHAT_RETENTION_MS,
  ROOM_RETENTION_MS,
};