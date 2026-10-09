const assert = require('node:assert/strict');
const { after, before, test } = require('node:test');
const { initializeApp, deleteApp } = require('firebase-admin/app');
const { getFirestore, Timestamp } = require('firebase-admin/firestore');
const { migrateRooms } = require('../scripts/migrate_chat_rooms.cjs');

const projectId = 'demo-navora-migration-tests';
const app = initializeApp({ projectId }, `migration-test-${process.pid}`);
const firestore = getFirestore(app);
const roomId = 'legacy-protected-room';
const shortPasswordRoomId = 'legacy-short-password-room';

async function seedLegacyRoom(id, overrides = {}) {
  const now = Timestamp.now();
  await firestore.collection('chat_rooms').doc(id).set({
    owner_id: 'owner-123',
    name: 'Legacy room',
    type: 'Sohbet Odası',
    active_users: '2 kişi aktif',
    active_users_count: 2,
    member_ids: ['owner-123', 'member-456'],
    moderator_ids: ['owner-123'],
    latitude: 41.01,
    longitude: 29.02,
    is_protected: true,
    password: 'legacy-room-password-123',
    messages: [
      {
        sender: 'Owner',
        sender_id: 'owner-123',
        text: 'Legacy hello',
        time: 'Şimdi',
        created_at: now,
      },
    ],
    created_at: now,
    updated_at: now,
    expires_at: Timestamp.fromMillis(now.toMillis() + 60 * 60 * 1000),
    max_users: 50,
    ...overrides,
  });
}

before(async () => {
  await seedLegacyRoom(roomId);
  await seedLegacyRoom(shortPasswordRoomId, {
    is_protected: true,
    password: 'short',
  });
});

after(async () => {
  await firestore.recursiveDelete(firestore.collection('chat_rooms'));
  await firestore.recursiveDelete(firestore.collection('chat_room_listings'));
  await deleteApp(app);
});

test('dry-run reports eligible rooms and leaves every legacy document unchanged', async () => {
  const report = await migrateRooms(firestore, { projectId });
  assert.equal(report.mode, 'dry-run');
  assert.equal(report.applied, 0);
  assert.equal(
    report.rooms.find((room) => room.roomId === roomId).status,
    'ready',
  );
  assert.ok(
    report.rooms
      .find((room) => room.roomId === shortPasswordRoomId)
      .issues.includes('protected-room-password-short-or-missing'),
  );

  const legacy = await firestore.collection('chat_rooms').doc(roomId).get();
  assert.equal(legacy.data().password, 'legacy-room-password-123');
  assert.equal(legacy.data().messages.length, 1);
  assert.equal(
    (await firestore.collection('chat_room_listings').doc(roomId).get()).exists,
    false,
  );
});

test('apply migrates a room atomically and removes plaintext fields from its root', async () => {
  const report = await migrateRooms(firestore, { projectId, apply: true });
  assert.equal(report.rooms.find((room) => room.roomId === roomId).status, 'applied');
  assert.equal(report.rooms.find((room) => room.roomId === shortPasswordRoomId).status, 'blocked');

  const room = await firestore.collection('chat_rooms').doc(roomId).get();
  const listing = await firestore.collection('chat_room_listings').doc(roomId).get();
  const access = await firestore
    .collection('chat_rooms')
    .doc(roomId)
    .collection('private')
    .doc('access')
    .get();
  const members = await firestore
    .collection('chat_rooms')
    .doc(roomId)
    .collection('members')
    .get();
  const messages = await firestore
    .collection('chat_rooms')
    .doc(roomId)
    .collection('messages')
    .get();

  assert.equal(room.data().schema_version, 2);
  assert.equal(Object.hasOwn(room.data(), 'password'), false);
  assert.equal(Object.hasOwn(room.data(), 'messages'), false);
  assert.equal(Object.hasOwn(listing.data(), 'password_hash'), false);
  assert.equal(access.data().password_hash.length, 64);
  assert.equal(members.size, 2);
  assert.equal(messages.size, 1);
});
