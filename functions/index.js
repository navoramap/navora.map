const { initializeApp } = require('firebase-admin/app');
const { getAuth } = require('firebase-admin/auth');
const {
  FieldPath,
  FieldValue,
  getFirestore,
} = require('firebase-admin/firestore');
const { getStorage } = require('firebase-admin/storage');
const { HttpsError, onCall } = require('firebase-functions/v2/https');
const { onSchedule } = require('firebase-functions/v2/scheduler');
const { hasRecentAuthentication } = require('./account_deletion_policy');
const { getRetentionCutoffs } = require('./retention_policy');

const storageBucket = process.env.FIREBASE_STORAGE_BUCKET
  || 'navoramapa.firebasestorage.app';

initializeApp({ storageBucket });

const PAGE_SIZE = 100;

async function deleteQueryDocuments(query, db) {
  let deleted = 0;
  while (true) {
    const snapshot = await query.limit(PAGE_SIZE).get();
    if (snapshot.empty) return deleted;
    await Promise.all(snapshot.docs.map((document) => db.recursiveDelete(document.ref)));
    deleted += snapshot.size;
  }
}

async function deleteAuthoredMessages(db, uid) {
  let deleted = 0;
  while (true) {
    const snapshot = await db
        .collectionGroup('messages')
        .where('sender_id', '==', uid)
        .limit(PAGE_SIZE)
        .get();
    if (snapshot.empty) return deleted;
    const batch = db.batch();
    for (const document of snapshot.docs) batch.delete(document.ref);
    await batch.commit();
    deleted += snapshot.size;
  }
}

async function deleteLegacyAuthoredMessages(db, uid) {
  let cursor = null;
  while (true) {
    let query = db
        .collection('chat_rooms')
        .orderBy(FieldPath.documentId())
        .limit(PAGE_SIZE);
    if (cursor) query = query.startAfter(cursor);
    const snapshot = await query.get();
    if (snapshot.empty) return;

    const batch = db.batch();
    let updates = 0;
    for (const room of snapshot.docs) {
      const messages = room.data().messages;
      if (!Array.isArray(messages)) continue;
      const remaining = messages.filter((message) =>
        message?.sender_id !== uid && message?.senderId !== uid,
      );
      if (remaining.length === messages.length) continue;
      batch.update(room.ref, { messages: remaining });
      updates++;
    }
    if (updates > 0) await batch.commit();
    cursor = snapshot.docs[snapshot.docs.length - 1];
  }
}

async function removeRoomMemberships(db, uid) {
  while (true) {
    const snapshot = await db
        .collection('chat_rooms')
        .where('member_ids', 'array-contains', uid)
        .limit(PAGE_SIZE)
        .get();
    if (snapshot.empty) return;

    await Promise.all(snapshot.docs.map(async (roomDocument) => {
      const roomReference = roomDocument.ref;
      const memberReference = roomReference.collection('members').doc(uid);
      const listingReference = db.collection('chat_room_listings').doc(roomDocument.id);

      await db.runTransaction(async (transaction) => {
        const [room, member, listing] = await Promise.all([
          transaction.get(roomReference),
          transaction.get(memberReference),
          transaction.get(listingReference),
        ]);
        if (!room.exists || room.data().owner_id === uid) return;

        const currentMembers = Array.isArray(room.data().member_ids)
            ? room.data().member_ids
            : [];
        const nextMembers = currentMembers.filter((memberId) => memberId !== uid);
        if (member.exists) transaction.delete(memberReference);
        if (nextMembers.length === currentMembers.length) return;

        const activeUsers = `${nextMembers.length} kişi aktif`;
        const updatedAt = FieldValue.serverTimestamp();
        transaction.update(roomReference, {
          member_ids: nextMembers,
          active_users_count: nextMembers.length,
          active_users: activeUsers,
          updated_at: updatedAt,
        });
        if (listing.exists) {
          transaction.update(listingReference, {
            active_users_count: nextMembers.length,
            active_users: activeUsers,
            updated_at: updatedAt,
          });
        }
      });
    }));
  }
}

async function deleteRoadFeedback(db, uid) {
  let cursor = null;
  while (true) {
    let query = db
        .collection('road_reports')
        .orderBy(FieldPath.documentId())
        .limit(PAGE_SIZE);
    if (cursor) query = query.startAfter(cursor);
    const snapshot = await query.get();
    if (snapshot.empty) return;

    const batch = db.batch();
    for (const report of snapshot.docs) {
      batch.delete(report.ref.collection('feedback').doc(uid));
    }
    await batch.commit();
    cursor = snapshot.docs[snapshot.docs.length - 1];
  }
}

async function deleteUserData(uid) {
  const db = getFirestore();

  await deleteQueryDocuments(
      db.collection('chat_rooms').where('owner_id', '==', uid),
      db,
  );
  await removeRoomMemberships(db, uid);

  const ownedCollections = [
    ['property_listings', 'owner_uid'],
    ['lost_pet_reports', 'owner_uid'],
    ['pet_adoption_listings', 'owner_uid'],
    ['road_reports', 'user_id'],
    ['community_places', 'owner_uid'],
    ['chat_room_listings', 'owner_id'],
    ['public_chat_messages', 'senderId'],
    ['chat_message_reports', 'reported_by'],
    ['explore_highlights', 'created_by'],
  ];
  for (const [collectionName, ownerField] of ownedCollections) {
    await deleteQueryDocuments(
        db.collection(collectionName).where(ownerField, '==', uid),
        db,
    );
  }

  await deleteLegacyAuthoredMessages(db, uid);
  await deleteAuthoredMessages(db, uid);
  await deleteRoadFeedback(db, uid);
  await db.recursiveDelete(db.collection('users').doc(uid));

  const bucket = getStorage().bucket();
  const storagePrefixes = [
    'property_listings',
    'lost_pet_reports',
    'pet_adoption_listings',
    'community_places',
  ].map((collectionName) => `${collectionName}/${uid}/`);
  await Promise.all(
      storagePrefixes.map((prefix) => bucket.deleteFiles({ prefix })),
  );
}

exports.deleteAccount = onCall(
    { timeoutSeconds: 540, memory: '1GiB' },
    async (request) => {
      if (!request.auth) {
        throw new HttpsError('unauthenticated', 'Oturum açmanız gerekiyor.');
      }
      if (!hasRecentAuthentication(request.auth.token.auth_time)) {
        throw new HttpsError(
            'failed-precondition',
            'Hesap silme için yakın zamanda yeniden giriş yapın.',
        );
      }

      const uid = request.auth.uid;
      try {
        await deleteUserData(uid);
        await getAuth().deleteUser(uid);
        return { deleted: true };
      } catch (error) {
        console.error('Account deletion failed.', { uid, message: error.message });
        throw new HttpsError(
            'internal',
            'Hesap verileri silinemedi. İşlem güvenle tekrar denenebilir.',
        );
      }
    },
);

async function deleteExpiredRooms(db, cutoff) {
  let deleted = 0;
  while (true) {
    const snapshot = await db
        .collection('chat_rooms')
        .where('expires_at', '<=', cutoff)
        .orderBy('expires_at')
        .limit(PAGE_SIZE)
        .get();
    if (snapshot.empty) return deleted;

    for (const room of snapshot.docs) {
      await db.recursiveDelete(room.ref);
      await db.collection('chat_room_listings').doc(room.id).delete();
      deleted++;
    }
  }
}

async function deleteExpiredDocuments(db, collectionName, fieldName, cutoff) {
  let deleted = 0;
  while (true) {
    const snapshot = await db
        .collection(collectionName)
        .where(fieldName, '<=', cutoff)
        .orderBy(fieldName)
        .limit(PAGE_SIZE)
        .get();
    if (snapshot.empty) return deleted;

    const batch = db.batch();
    for (const document of snapshot.docs) batch.delete(document.ref);
    await batch.commit();
    deleted += snapshot.size;
  }
}

async function cleanupExpiredChatData(db = getFirestore(), now = new Date()) {
  const cutoffs = getRetentionCutoffs(now);
  const expiredRooms = await deleteExpiredRooms(
      db,
      cutoffs.roomsExpiresAtOrBefore,
  );
  const expiredListings = await deleteExpiredDocuments(
      db,
      'chat_room_listings',
      'expires_at',
      cutoffs.roomsExpiresAtOrBefore,
  );
  const oldPublicMessages = await deleteExpiredDocuments(
      db,
      'public_chat_messages',
      'createdAt',
      cutoffs.publicMessagesCreatedAtOrBefore,
  );

  return { expiredRooms, expiredListings, oldPublicMessages };
}

exports.cleanupExpiredChatData = onSchedule(
    {
      schedule: 'every 60 minutes',
      timeZone: 'Etc/UTC',
      timeoutSeconds: 540,
      memory: '1GiB',
      maxInstances: 1,
    },
    async () => {
      const result = await cleanupExpiredChatData();
      console.log('Expired chat data cleanup complete.', result);
      return result;
    },
);

exports.deleteUserData = deleteUserData;
exports.cleanupExpiredChatDataHandler = cleanupExpiredChatData;