const DAILY_LIMITS = {
  room: { free: 3, pro: 10, field: 'rooms', bonusField: 'bonus_chat_rooms' },
  ai: { free: 3, pro: 10, field: 'ai', bonusField: 'bonus_ai_queries' },
};

function getDailyQuotaDate(date = new Date()) {
  if (!(date instanceof Date) || !Number.isFinite(date.getTime())) {
    throw new TypeError('A valid quota date is required.');
  }
  const parts = new Intl.DateTimeFormat('en-US', {
    timeZone: 'Europe/Istanbul',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  }).formatToParts(date);
  const values = Object.fromEntries(parts.map((part) => [part.type, part.value]));
  return `${values.year}-${values.month}-${values.day}`;
}

function getDailyQuota(kind, isPro) {
  const quota = DAILY_LIMITS[kind];
  if (!quota) throw new TypeError('Unsupported daily quota type.');
  return {
    ...quota,
    limit: isPro ? quota.pro : quota.free,
  };
}

function getQuotaReservationSource(isAdmin, currentCount, limit, bonusCount) {
  if (isAdmin) return 'admin';
  if (currentCount < limit) return 'daily';
  if (bonusCount > 0) return 'bonus';
  return null;
}

function getDrivingPointAward(distanceKm, durationMinutes, completedAt) {
  if (!Number.isFinite(distanceKm) ||
      distanceKm < 0.5 ||
      distanceKm > 2000 ||
      !Number.isSafeInteger(durationMinutes) ||
      durationMinutes < 1 ||
      durationMinutes > 1440 ||
      !(completedAt instanceof Date) ||
      !Number.isFinite(completedAt.getTime())) {
    return 0;
  }

  const parts = new Intl.DateTimeFormat('en-US', {
    timeZone: 'Europe/Istanbul',
    hour: '2-digit',
    hourCycle: 'h23',
  }).formatToParts(completedAt);
  const hour = Number(parts.find((part) => part.type === 'hour')?.value);
  const distanceBonus = Math.min(10, Math.floor(distanceKm / 10));
  const nightBonus = hour >= 22 || hour < 5 ? 20 : 0;
  return 20 + distanceBonus + nightBonus;
}

module.exports = {
  DAILY_LIMITS,
  getDailyQuota,
  getDailyQuotaDate,
  getQuotaReservationSource,
  getDrivingPointAward,
};
