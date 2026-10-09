const assert = require('node:assert/strict');
const { test } = require('node:test');
const { hasRecentAuthentication } = require('./account_deletion_policy');

test('accepts a recent authentication time', () => {
  const now = Date.now();
  assert.equal(hasRecentAuthentication((now - 60_000) / 1000, now), true);
});

test('rejects stale, future, and malformed authentication times', () => {
  const now = Date.now();
  assert.equal(hasRecentAuthentication((now - 6 * 60_000) / 1000, now), false);
  assert.equal(hasRecentAuthentication((now + 2 * 60_000) / 1000, now), false);
  assert.equal(hasRecentAuthentication('invalid', now), false);
});