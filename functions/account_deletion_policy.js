const MAX_AUTH_AGE_MS = 5 * 60 * 1000;
const CLOCK_SKEW_MS = 60 * 1000;

function hasRecentAuthentication(authTimeSeconds, nowMs = Date.now()) {
  const authTimeMs = Number(authTimeSeconds) * 1000;
  if (!Number.isFinite(authTimeMs)) return false;
  const ageMs = nowMs - authTimeMs;
  return ageMs >= -CLOCK_SKEW_MS && ageMs <= MAX_AUTH_AGE_MS;
}

module.exports = { hasRecentAuthentication };