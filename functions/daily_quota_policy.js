const DAILY_LIMITS = {
  room: { free: 3, pro: 10, field: 'rooms' },
  ai: { free: 3, pro: 10, field: 'ai' },
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

function getQuotaReservationSource(isAdmin, currentCount, limit) {
  if (isAdmin) return 'admin';
  if (currentCount < limit) return 'daily';
  return null;
}

module.exports = {
  DAILY_LIMITS,
  getDailyQuota,
  getDailyQuotaDate,
  getQuotaReservationSource,
};
