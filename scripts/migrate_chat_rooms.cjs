#!/usr/bin/env node
'use strict';

const { randomBytes, pbkdf2Sync } = require('node:crypto');
const { applicationDefault, initializeApp } = require('firebase-admin/app');
const { FieldValue, getFirestore, Timestamp } = require('firebase-admin/firestore');

const HASH_ITERATIONS = 120000;
const MAX_BATCH_WRITES = 500;
const MAX_ROOM_MEMBERS = 50;

function parseArguments(argv) {
  const options = { apply: false, backupConfirmed: false, projectId: null };
  for (let index = 0; index < argv.length; index++) {
    const argument = argv[index];
    if (argument === '--apply') {
      options.apply = true;
    } else if (argument === '--backup-confirmed') {
      options.backupConfirmed = true;
    } else if (argument === '--project') {
      options.projectId = argv[++index] ?? null;
    } else if (argument === '--help' || argument === '-h') {
      options.help = true;
    } else {
      throw new Error(`Unknown argument: ${argument}`);
    }
  }
  if (!options.help && !options.projectId) {
    throw new Error('--project is required; no project is inferred.');
  }
  if (options.apply && !options.backupConfirmed) {
    throw new Error('--apply requires --backup-confirmed after a verified Firestore backup.');
  }
  return options;
}

function isRecord(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function asTimestamp(value, fallback = null) {
  if (value instanceof Timestamp) return value;
  if (value instanceof Date && !Number.isNaN(value.getTime())) {
    return Timestamp.fromDate(value);
  }
  if (typeof value === 'string' || typeof value === 'number') {
    const parsed = new Date(value);
    if (!Number.isNaN(parsed.getTime())) return Timestamp.fromDate(parsed);
  }
  return fallback;
}

function boundedString(value, fallback, maxLength) {
  const candidate = typeof value === 'string' ? value.trim() : fallback;
  if (!candidate || candidate.length > maxLength) return null;
  return candidate;
}

function passwordVerifier(password, salt) {
  return pbkdf2Sync(password, Buffer.from(salt, 'utf8'), HASH_ITERATIONS, 32, 'sha256')
    .toString('hex');
}

function buildMigrationPlan(document, now = Timestamp.now()) {
  const data = document.data();
  const issues = [];
  const warnings = [];

  if (data.schema_version === 2) {
    return { status: 'already-v2', roomId: document.id, issues, warnings };
  }

  const ownerId = boundedString(data.owner_id, null, 128);
  const name = boundedString(data.name, null, 80);
  const type = boundedString(data.type, 'Sohbet Odası', 40);
  const latitude = typeof data.latitude === 'number' ? data.latitude : NaN;
  const longitude = typeof data.longitude === 'number' ? data.longitude : NaN;
  const createdAt = asTimestamp(data.created_at, now);
  const expiresAt = asTimestamp(data.expires_at);
  const isProtected = data.is_protected === true;
  const plaintextPassword = typeof data.password === 'string' ? data.password : '';

  if (!ownerId) issues.push('invalid-owner-id');
  if (!name) issues.push('invalid-room-name');
  if (!type) issues.push('invalid-room-type');
  if (!Number.isFinite(latitude) || latitude < -90 || latitude > 90) {
    issues.push('invalid-latitude');
  }
  if (!Number.isFinite(longitude) || longitude < -180 || longitude > 180) {
    issues.push('invalid-longitude');
  }
  if (!expiresAt) issues.push('missing-or-invalid-expiry');
  if (!data.created_at) warnings.push('created-at-defaulted-to-migration-time');
  if (expiresAt && expiresAt.toMillis() <= now.toMillis()) {
    issues.push('room-expired');
  }
  if (
    expiresAt
    && expiresAt.toMillis() > now.toMillis() + 2 * 24 * 60 * 60 * 1000
  ) {
    issues.push('expiry-exceeds-schema-limit');
  }
  if ('is_protected' in data && typeof data.is_protected !== 'boolean') {
    issues.push('invalid-protection-flag');
  }
  if (isProtected && plaintextPassword.length < 12) {
    issues.push('protected-room-password-short-or-missing');
  }
  if (isProtected && plaintextPassword.length > 256) {
    issues.push('protected-room-password-too-long');
  }
  if (isProtected && plaintextPassword !== plaintextPassword.trim()) {
    issues.push('protected-room-password-outer-whitespace');
  }

  const rawMembers = Array.isArray(data.member_ids) ? data.member_ids : [];
  if (data.member_ids != null && !Array.isArray(data.member_ids)) {
    issues.push('invalid-member-list');
  }
  if (rawMembers.some((uid) => typeof uid !== 'string' || uid.length > 128)) {
    issues.push('invalid-member-id');
  }
  const memberIds = ownerId
    ? [...new Set([ownerId, ...rawMembers.filter((uid) => typeof uid === 'string' && uid.length > 0)])]
    : [];
  if (ownerId && !rawMembers.includes(ownerId)) warnings.push('owner-added-to-members');
  if ((data.active_users_count ?? memberIds.length) !== memberIds.length) {
    warnings.push('active-user-count-normalized-to-members');
  }
  if (memberIds.length > MAX_ROOM_MEMBERS) issues.push('too-many-members');

  const rawMessages = data.messages ?? [];
  if (!Array.isArray(rawMessages)) issues.push('invalid-legacy-messages');
  const legacyMessages = Array.isArray(rawMessages) ? rawMessages : [];
  const messages = [];
  for (let index = 0; index < legacyMessages.length; index++) {
    const legacyMessage = legacyMessages[index];
    if (!isRecord(legacyMessage)) {
      issues.push(`invalid-message-${index}`);
      continue;
    }
    const text = typeof legacyMessage.text === 'string' ? legacyMessage.text : null;
    const sender = boundedString(legacyMessage.sender, 'Kullanıcı', 80);
    const senderId = boundedString(
      legacyMessage.sender_id ?? legacyMessage.senderId,
      ownerId,
      128,
    );
    if (!text || text.length === 0 || text.length > 2000 || !sender || !senderId) {
      issues.push(`invalid-message-${index}`);
      continue;
    }
    messages.push({
      id: `legacy-${String(index).padStart(6, '0')}`,
      data: {
        sender,
        sender_id: senderId,
        text,
        time: boundedString(legacyMessage.time, 'Şimdi', 24) ?? 'Şimdi',
        created_at: asTimestamp(legacyMessage.created_at, createdAt),
      },
    });
  }

  const operationCount = 2 + memberIds.length + messages.length + (isProtected ? 1 : 0);
  if (operationCount > MAX_BATCH_WRITES) issues.push('batch-exceeds-500-writes');

  if (issues.length > 0) {
    return { status: 'blocked', roomId: document.id, issues, warnings };
  }

  const maxUsersValue = Number.isInteger(data.max_users) ? data.max_users : 50;
  const maxUsers = Math.min(MAX_ROOM_MEMBERS, Math.max(2, memberIds.length, maxUsersValue));
  if (maxUsers !== maxUsersValue) warnings.push('maximum-members-normalized');
  const updatedAt = now;
  const passwordSalt = isProtected ? randomBytes(24).toString('base64url') : '';
  const hash = isProtected ? passwordVerifier(plaintextPassword, passwordSalt) : '';
  const moderators = Array.isArray(data.moderator_ids)
    ? [...new Set(data.moderator_ids.filter((uid) => memberIds.includes(uid)))].slice(0, 20)
    : [];
  if (moderators.length !== (Array.isArray(data.moderator_ids) ? new Set(data.moderator_ids).size : 0)) {
    warnings.push('invalid-moderators-removed');
  }
  if (isProtected) warnings.push('plaintext-password-replaced-with-pbkdf2-verifier');
  if (messages.length > 0) warnings.push('embedded-messages-moved-to-subcollection');
  const activeUsers = `${memberIds.length} kişi aktif`;

  const room = {
    schema_version: 2,
    owner_id: ownerId,
    name,
    type,
    active_users: activeUsers,
    active_users_count: memberIds.length,
    member_ids: memberIds,
    moderator_ids: moderators,
    latitude,
    longitude,
    is_protected: isProtected,
    password_salt: passwordSalt,
    created_at: createdAt,
    updated_at: updatedAt,
    expires_at: expiresAt,
    max_users: maxUsers,
  };
  const listing = {
    owner_id: ownerId,
    name,
    type,
    active_users: activeUsers,
    active_users_count: memberIds.length,
    latitude,
    longitude,
    is_protected: isProtected,
    password_salt: passwordSalt,
    created_at: createdAt,
    updated_at: updatedAt,
    expires_at: expiresAt,
    max_users: maxUsers,
  };
  const members = memberIds.map((uid) => ({
    uid,
    data: {
      password_hash: isProtected ? hash : '',
      joined_at: updatedAt,
    },
  }));
  const access = isProtected ? { password_hash: hash, updated_at: updatedAt } : null;

  return {
    status: 'ready',
    roomId: document.id,
    issues,
    warnings,
    operationCount,
    room,
    listing,
    members,
    messages,
    access,
  };
}

async function targetHasPartialMigration(db, roomId) {
  const roomRef = db.collection('chat_rooms').doc(roomId);
  const listingRef = db.collection('chat_room_listings').doc(roomId);
  const [listing, members, messages, access] = await Promise.all([
    listingRef.get(),
    roomRef.collection('members').limit(1).get(),
    roomRef.collection('messages').limit(1).get(),
    roomRef.collection('private').doc('access').get(),
  ]);
  return listing.exists || !members.empty || !messages.empty || access.exists;
}

async function verifyMigratedRoom(db, roomId, expected) {
  const roomRef = db.collection('chat_rooms').doc(roomId);
  const [room, listing, members, messages, access] = await Promise.all([
    roomRef.get(),
    db.collection('chat_room_listings').doc(roomId).get(),
    roomRef.collection('members').get(),
    roomRef.collection('messages').get(),
    roomRef.collection('private').doc('access').get(),
  ]);
  if (!room.exists || !listing.exists) return false;
  const roomData = room.data();
  const listingData = listing.data();
  const migratedMemberIds = new Set(members.docs.map((member) => member.id));
  const migratedMessageIds = new Set(messages.docs.map((message) => message.id));
  const expectedMessageIds = new Set(expected.messages.map((message) => message.id));
  return roomData.schema_version === 2
    && roomData.owner_id === expected.room.owner_id
    && roomData.password_salt === expected.room.password_salt
    && roomData.member_ids.length === expected.members.length
    && !Object.hasOwn(roomData, 'password')
    && !Object.hasOwn(roomData, 'messages')
    && listingData.owner_id === expected.listing.owner_id
    && listingData.password_salt === expected.listing.password_salt
    && !Object.hasOwn(listingData, 'password_hash')
    && !Object.hasOwn(listingData, 'messages')
    && expected.members.every((member) => migratedMemberIds.has(member.uid))
    && expectedMessageIds.size === migratedMessageIds.size
    && [...expectedMessageIds].every((messageId) => migratedMessageIds.has(messageId))
    && (expected.access == null
      ? !access.exists
      : access.exists
        && access.data().password_hash === expected.access.password_hash
        && expected.members.every((member) =>
          migratedMemberIds.has(member.uid)));
}

async function migrateRooms(db, { apply = false, projectId = 'unknown' } = {}) {
  const snapshot = await db.collection('chat_rooms').get();
  const results = [];
  let applied = 0;

  for (const document of snapshot.docs) {
    let plan = buildMigrationPlan(document);
    if (plan.status === 'already-v2') {
      const listing = await db.collection('chat_room_listings').doc(document.id).get();
      if (!listing.exists) {
        plan = {
          status: 'blocked',
          roomId: document.id,
          issues: ['schema-v2-listing-missing'],
          warnings: [],
        };
      }
    }
    if (plan.status === 'ready') {
      if (await targetHasPartialMigration(db, document.id)) {
        plan = {
          status: 'blocked',
          roomId: document.id,
          issues: ['target-documents-already-exist'],
          warnings: [],
        };
      } else if (apply) {
        const roomRef = db.collection('chat_rooms').doc(document.id);
        const listingRef = db.collection('chat_room_listings').doc(document.id);
        const batch = db.batch();
        batch.set(roomRef, plan.room);
        batch.set(listingRef, plan.listing);
        for (const member of plan.members) {
          batch.set(roomRef.collection('members').doc(member.uid), member.data);
        }
        if (plan.access) {
          batch.set(roomRef.collection('private').doc('access'), plan.access);
        }
        for (const message of plan.messages) {
          batch.set(roomRef.collection('messages').doc(message.id), message.data);
        }
        try {
          await batch.commit();
          if (!(await verifyMigratedRoom(db, document.id, plan))) {
            throw new Error('Post-write verification failed.');
          }
          applied++;
          plan = {
            status: 'applied',
            roomId: document.id,
            issues: [],
            warnings: [],
          };
        } catch (_) {
          plan = {
            status: 'blocked',
            roomId: document.id,
            issues: ['write-or-verification-failed'],
            warnings: [],
          };
        }
      }
    }
    results.push({
      roomId: plan.roomId,
      status: plan.status,
      issues: plan.issues,
      warnings: plan.warnings,
      ...(plan.operationCount == null ? {} : { operationCount: plan.operationCount }),
    });
  }

  const counts = results.reduce((summary, result) => {
    summary[result.status] = (summary[result.status] ?? 0) + 1;
    return summary;
  }, {});
  return {
    projectId,
    mode: apply ? 'apply' : 'dry-run',
    scanned: results.length,
    applied,
    counts,
    rooms: results,
    secretsOmitted: true,
  };
}

async function main() {
  const options = parseArguments(process.argv.slice(2));
  if (options.help) {
    console.log('Usage: node scripts/migrate_chat_rooms.cjs --project <project-id> [--apply --backup-confirmed]');
    console.log('Default mode is read-only dry-run. Apply requires both --apply and --backup-confirmed.');
    return;
  }

  const appOptions = { projectId: options.projectId };
  if (!process.env.FIRESTORE_EMULATOR_HOST) {
    appOptions.credential = applicationDefault();
  }
  const app = initializeApp(
    appOptions,
    `chat-room-migration-${Date.now()}`,
  );
  try {
    const report = await migrateRooms(getFirestore(app), options);
    console.log(JSON.stringify(report, null, 2));
    if (report.rooms.some((result) => result.status === 'blocked')) {
      process.exitCode = 2;
    }
  } finally {
    await app.delete();
  }
}

if (require.main === module) {
  main().catch((error) => {
    console.error(`Migration stopped: ${error.message}`);
    process.exitCode = 1;
  });
}

module.exports = {
  buildMigrationPlan,
  migrateRooms,
  parseArguments,
  passwordVerifier,
};
