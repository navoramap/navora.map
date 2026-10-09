const assert = require('node:assert/strict');
const { pbkdf2Sync } = require('node:crypto');
const { test } = require('node:test');
const { Timestamp } = require('firebase-admin/firestore');
const {
  buildMigrationPlan,
  parseArguments,
} = require('../scripts/migrate_chat_rooms.cjs');

const now = Timestamp.fromDate(new Date('2026-10-01T12:00:00.000Z'));

function legacyRoom(overrides = {}) {
  return {
    owner_id: 'owner-123',
    name: 'Legacy room',
    type: 'Sohbet Odası',
    active_users: '2 kişi',
    active_users_count: 2,
    member_ids: ['owner-123', 'member-456'],
    moderator_ids: ['owner-123'],
    latitude: 41.01,
    longitude: 29.02,
    is_protected: true,
    password: 'a-legacy-room-password',
    messages: [
      {
        sender: 'Owner',
        sender_id: 'owner-123',
        text: 'Welcome',
        time: '12:00',
        created_at: now,
      },
    ],
    created_at: now,
    updated_at: now,
    expires_at: Timestamp.fromMillis(now.toMillis() + 60 * 60 * 1000),
    max_users: 50,
    ...overrides,
  };
}

function makeDocument(data, id = 'room-1') {
  return { id, data: () => data };
}

test('plans schema v2 room/listing/member/message documents without plaintext secrets', () => {
  const plan = buildMigrationPlan(makeDocument(legacyRoom()), now);

  assert.equal(plan.status, 'ready');
  assert.equal(plan.room.schema_version, 2);
  assert.equal(plan.room.owner_id, 'owner-123');
  assert.equal(plan.room.active_users_count, 2);
  assert.equal(plan.listing.password_salt, plan.room.password_salt);
  assert.equal(plan.room.password, undefined);
  assert.equal(plan.room.messages, undefined);
  assert.equal(plan.listing.password_hash, undefined);
  assert.equal(plan.access.password_hash.length, 64);
  assert.equal(plan.members.length, 2);
  assert.equal(plan.members[1].data.password_hash, plan.access.password_hash);
  assert.deepEqual(plan.messages.map((message) => message.id), ['legacy-000000']);
  assert.equal(plan.messages[0].data.sender_id, 'owner-123');
  assert.equal(plan.messages[0].data.text, 'Welcome');

  const expectedHash = pbkdf2Sync(
    'a-legacy-room-password',
    Buffer.from(plan.room.password_salt, 'utf8'),
    120000,
    32,
    'sha256',
  ).toString('hex');
  assert.equal(plan.access.password_hash, expectedHash);
});

test('blocks protected rooms with short passwords without exposing their contents', () => {
  const secret = 'old-secret';
  const plan = buildMigrationPlan(
    makeDocument(legacyRoom({ password: secret })),
    now,
  );

  assert.equal(plan.status, 'blocked');
  assert.ok(plan.issues.includes('protected-room-password-short-or-missing'));
  assert.equal(JSON.stringify(plan).includes(secret), false);
  assert.equal(JSON.stringify(plan).includes('Welcome'), false);
});

test('blocks malformed coordinates, invalid messages, and expired rooms', () => {
  const invalidCoordinates = buildMigrationPlan(
    makeDocument(legacyRoom({ latitude: 91 })),
    now,
  );
  assert.ok(invalidCoordinates.issues.includes('invalid-latitude'));

  const invalidMessage = buildMigrationPlan(
    makeDocument(legacyRoom({ messages: [{ text: 'x'.repeat(2001) }] })),
    now,
  );
  assert.ok(invalidMessage.issues.includes('invalid-message-0'));

  const expired = buildMigrationPlan(
    makeDocument(legacyRoom({ expires_at: Timestamp.fromMillis(now.toMillis() - 1) })),
    now,
  );
  assert.ok(expired.issues.includes('room-expired'));
});

test('blocks rooms whose atomic migration would exceed the Firestore batch limit', () => {
  const messages = Array.from({ length: 498 }, (_, index) => ({
    sender: 'Owner',
    sender_id: 'owner-123',
    text: `Message ${index}`,
    time: '12:00',
    created_at: now,
  }));
  const plan = buildMigrationPlan(
    makeDocument(legacyRoom({ is_protected: false, password: '', messages })),
    now,
  );

  assert.equal(plan.status, 'blocked');
  assert.ok(plan.issues.includes('batch-exceeds-500-writes'));
});

test('requires explicit project, apply flag, and backup confirmation', () => {
  assert.throws(() => parseArguments([]), /project/);
  assert.throws(
    () => parseArguments(['--project', 'demo-navora', '--apply']),
    /backup-confirmed/,
  );
  assert.deepEqual(
    parseArguments([
      '--project',
      'demo-navora',
      '--apply',
      '--backup-confirmed',
    ]),
    {
      apply: true,
      backupConfirmed: true,
      projectId: 'demo-navora',
    },
  );
});
