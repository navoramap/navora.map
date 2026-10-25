const { initializeApp } = require('firebase-admin/app');
const { timingSafeEqual } = require('node:crypto');
const { getAuth } = require('firebase-admin/auth');
const {
  FieldPath,
  FieldValue,
  getFirestore,
} = require('firebase-admin/firestore');
const { getStorage } = require('firebase-admin/storage');
const { HttpsError, onCall } = require('firebase-functions/v2/https');
const { onDocumentCreated } = require('firebase-functions/v2/firestore');
const { onSchedule } = require('firebase-functions/v2/scheduler');
const { setGlobalOptions } = require('firebase-functions/v2');
const { hasRecentAuthentication } = require('./account_deletion_policy');
const { deleteExpiredUserHistory } = require('./history_retention');
const {
  getDailyQuota,
  getDailyQuotaDate,
  getDrivingPointAward,
  getQuotaReservationSource,
} = require('./daily_quota_policy');
const { getRetentionCutoffs } = require('./retention_policy');
const {
  getRoomJoinFailureState,
  isValidRoomPasswordHash,
} = require('./room_join_policy');

const storageBucket = process.env.FIREBASE_STORAGE_BUCKET
  || 'navoramapa.firebasestorage.app';

initializeApp({ storageBucket });
setGlobalOptions({
  region: 'europe-west1',
  maxInstances: 10,
  invoker: 'public',
});

const PAGE_SIZE = 100;
const MAX_DAILY_EARNED_POINTS = 100;
const QUOTA_RESERVATION_LIFETIME_MS = 10 * 60 * 1000;
const PUBLIC_CALLABLE_OPTIONS = { invoker: 'public' };
const REWARDS = {
  room: { title: 'Ek sohbet odası', cost: 200, field: 'bonus_chat_rooms' },
  ai: { title: 'Ek Navora AI sorusu', cost: 150, field: 'bonus_ai_queries' },
  pro_discount: { title: 'Navora Pro indirimi', cost: 500, field: null },
};

function requireUser(request) {
  if (!request.auth) {
    throw new HttpsError('unauthenticated', 'Oturum açmanız gerekiyor.');
  }
  return request.auth.uid;
}

function validateReservationId(reservationId) {
  if (typeof reservationId !== 'string' ||
      !/^[A-Za-z0-9_-]{10,128}$/.test(reservationId)) {
    throw new HttpsError('invalid-argument', 'Geçersiz kota işlemi.');
  }
}

function safeCount(value) {
  return Number.isSafeInteger(value) && value >= 0 ? value : 0;
}

function quotaResult(usage, profile, date) {
  return {
    date,
    rooms: safeCount(usage.rooms),
    ai: safeCount(usage.ai),
    bonusChatRooms: safeCount(profile.bonus_chat_rooms),
    bonusAiQueries: safeCount(profile.bonus_ai_queries),
  };
}

exports.joinChatRoom = onCall(
    { ...PUBLIC_CALLABLE_OPTIONS, enforceAppCheck: true },
    async (request) => {
      const uid = requireUser(request);
      const { roomId, passwordHash = '' } = request.data ?? {};
      if (
        typeof roomId !== 'string' ||
        !/^[A-Za-z0-9_-]{1,128}$/.test(roomId) ||
        typeof passwordHash !== 'string' ||
        (passwordHash !== '' && !isValidRoomPasswordHash(passwordHash))
      ) {
        throw new HttpsError('invalid-argument', 'Geçersiz oda giriş bilgisi.');
      }

      const db = getFirestore();
      const roomReference = db.collection('chat_rooms').doc(roomId);
      const listingReference = db.collection('chat_room_listings').doc(roomId);
      const memberReference = roomReference.collection('members').doc(uid);
      const accessReference = roomReference.collection('private').doc('access');
      const attemptsReference = db
          .collection('users')
          .doc(uid)
          .collection('room_join_attempts')
          .doc(roomId);

      const result = await db.runTransaction(async (transaction) => {
        const [
          roomSnapshot,
          listingSnapshot,
          memberSnapshot,
          attemptsSnapshot,
        ] = await Promise.all([
          transaction.get(roomReference),
          transaction.get(listingReference),
          transaction.get(memberReference),
          transaction.get(attemptsReference),
        ]);
        if (!roomSnapshot.exists || !listingSnapshot.exists) {
          return { status: 'not-found' };
        }

        const room = roomSnapshot.data();
        const listing = listingSnapshot.data();
        const currentMembers = room.member_ids;
        const isAdmin = request.auth.token.admin === true;
        const isPrivileged = isAdmin || room.owner_id === uid;
        const expiresAt = room.expires_at?.toDate?.() ?? room.expires_at;
        if (
          room.schema_version !== 2 ||
          typeof room.owner_id !== 'string' ||
          typeof room.is_protected !== 'boolean' ||
          !(expiresAt instanceof Date) ||
          expiresAt.getTime() <= Date.now()
        ) {
          return { status: 'not-available' };
        }
        if (memberSnapshot.exists) return { status: 'joined' };
        if (
          !Array.isArray(currentMembers) ||
          currentMembers.includes(uid) ||
          !currentMembers.includes(room.owner_id) ||
          !Number.isSafeInteger(room.active_users_count) ||
          room.active_users_count !== currentMembers.length ||
          listing.active_users_count !== room.active_users_count ||
          listing.owner_id !== room.owner_id
        ) {
          return { status: 'not-available' };
        }

        const now = new Date();
        const currentAttempts = attemptsSnapshot.exists
          ? attemptsSnapshot.data()
          : {};
        const attemptState = getRoomJoinFailureState(currentAttempts, now);
        if (!isPrivileged && attemptState.locked) {
          return { status: 'locked' };
        }

        let acceptedPasswordHash = '';
        if (room.is_protected && !isPrivileged) {
          const accessSnapshot = await transaction.get(accessReference);
          const storedPasswordHash = accessSnapshot.data()?.password_hash;
          const hashesMatch =
            isValidRoomPasswordHash(passwordHash) &&
            isValidRoomPasswordHash(storedPasswordHash) &&
            timingSafeEqual(
              Buffer.from(passwordHash, 'hex'),
              Buffer.from(storedPasswordHash, 'hex'),
            );
          if (!hashesMatch) {
            const nextAttempts = getRoomJoinFailureState(currentAttempts, now);
            transaction.set(attemptsReference, {
              failed_count: nextAttempts.failed_count,
              window_started_at: nextAttempts.window_started_at,
              locked_until: nextAttempts.locked_until,
              updated_at: FieldValue.serverTimestamp(),
            });
            return {
              status: nextAttempts.locked_until ? 'locked' : 'invalid-password',
            };
          }
          acceptedPasswordHash = passwordHash;
        }

        const activeCount = room.active_users_count;
        const maximumUsers = room.max_users;
        if (
          !Number.isSafeInteger(maximumUsers) ||
          maximumUsers < 2 ||
          activeCount >= maximumUsers && !isPrivileged ||
          activeCount >= 51
        ) {
          return { status: 'full' };
        }

        const nextCount = activeCount + 1;
        const timestamp = FieldValue.serverTimestamp();
        transaction.create(memberReference, {
          password_hash: acceptedPasswordHash,
          joined_at: timestamp,
        });
        transaction.update(roomReference, {
          member_ids: [...currentMembers, uid],
          active_users_count: nextCount,
          active_users: `${nextCount} kişi aktif`,
          updated_at: timestamp,
        });
        transaction.update(listingReference, {
          active_users_count: nextCount,
          active_users: `${nextCount} kişi aktif`,
          updated_at: timestamp,
        });
        if (attemptsSnapshot.exists) transaction.delete(attemptsReference);
        return { status: 'joined' };
      });

      if (result.status === 'joined') return { joined: true };
      if (result.status === 'locked') {
        throw new HttpsError(
            'resource-exhausted',
            'Çok fazla hatalı şifre denemesi. 15 dakika sonra tekrar deneyin.',
        );
      }
      if (result.status === 'full') {
        throw new HttpsError('resource-exhausted', 'Sohbet odası dolu.');
      }
      if (result.status === 'not-found') {
        throw new HttpsError('not-found', 'Sohbet odası bulunamadı.');
      }
      throw new HttpsError(
          'permission-denied',
          'Şifre hatalı veya bu odaya giriş yapılamıyor.',
      );
    },
);

exports.reserveDailyQuota = onCall(PUBLIC_CALLABLE_OPTIONS, async (request) => {
  const uid = requireUser(request);
  const { kind, reservationId } = request.data ?? {};
  validateReservationId(reservationId);
  if (kind !== 'room' && kind !== 'ai') {
    throw new HttpsError('invalid-argument', 'Geçersiz kullanım türü.');
  }

  const db = getFirestore();
  const userReference = db.collection('users').doc(uid);
  const usageDate = getDailyQuotaDate();
  const usageReference = userReference
      .collection('daily_usage')
      .doc(usageDate);
  const reservationReference = userReference
      .collection('quota_reservations')
      .doc(reservationId);
  const roomReference = kind === 'room'
    ? db.collection('chat_rooms').doc(reservationId)
    : null;

  return db.runTransaction(async (transaction) => {
    const [profileSnapshot, usageSnapshot, reservationSnapshot, roomSnapshot] =
      await Promise.all([
        transaction.get(userReference),
        transaction.get(usageReference),
        transaction.get(reservationReference),
        roomReference ? transaction.get(roomReference) : Promise.resolve(null),
      ]);
    if (!profileSnapshot.exists) {
      throw new HttpsError('failed-precondition', 'Profil bulunamadı.');
    }
    if (reservationSnapshot.exists || roomSnapshot?.exists) {
      throw new HttpsError('already-exists', 'Bu kota işlemi daha önce kullanıldı.');
    }

    const profile = profileSnapshot.data();
    const usage = usageSnapshot.data() ?? {};
    const trustedUsage = usage.quota_version === 1;
    const isAdmin = kind === 'room' && request.auth.token.admin === true;
    const quota = getDailyQuota(kind, request.auth.token.pro === true);
    const currentCount = trustedUsage ? safeCount(usage[quota.field]) : 0;
    const nextBonus = safeCount(profile[quota.bonusField]);
    const source = getQuotaReservationSource(
        isAdmin,
        currentCount,
        quota.limit,
        nextBonus,
    );
    if (source === null) {
      throw new HttpsError(
          'resource-exhausted',
          'Günlük kullanım hakkınız doldu.',
      );
    }
    let nextCount = currentCount;
    if (source === 'daily') {
      nextCount++;
    } else if (source === 'bonus') {
      nextBonus--;
    }

    const nextUsage = trustedUsage
      ? { ...usage, date: usageDate, quota_version: 1 }
      : { date: usageDate, rooms: 0, ai: 0, earned_points: 0, quota_version: 1 };
    if (source !== 'admin') {
      nextUsage.updated_at = FieldValue.serverTimestamp();
    }
    if (source === 'daily') nextUsage[quota.field] = nextCount;
    const nextProfile = { [quota.bonusField]: nextBonus };
    if (source !== 'admin') {
      transaction.set(usageReference, nextUsage, { merge: true });
    }
    if (source === 'bonus') {
      transaction.set(userReference, nextProfile, { merge: true });
    }
    transaction.create(reservationReference, {
      uid,
      kind,
      date: usageDate,
      source,
      status: 'pending',
      created_at: FieldValue.serverTimestamp(),
      expires_at: new Date(Date.now() + QUOTA_RESERVATION_LIFETIME_MS),
    });
    if (source === 'bonus') nextUsage[quota.field] = currentCount;
    return quotaResult(nextUsage, { ...profile, ...nextProfile }, usageDate);
  });
});

exports.completeDailyQuotaReservation = onCall(
    PUBLIC_CALLABLE_OPTIONS,
    async (request) => {
  const uid = requireUser(request);
  const { reservationId } = request.data ?? {};
  validateReservationId(reservationId);

  const db = getFirestore();
  const reservationReference = db.collection('users')
      .doc(uid)
      .collection('quota_reservations')
      .doc(reservationId);
  const roomReference = db.collection('chat_rooms').doc(reservationId);
  await db.runTransaction(async (transaction) => {
    const reservation = await transaction.get(reservationReference);
    if (!reservation.exists) {
      throw new HttpsError('not-found', 'Kota işlemi bulunamadı.');
    }
    if (reservation.data().status === 'completed') return;
    if (reservation.data().status !== 'pending') {
      throw new HttpsError('failed-precondition', 'Kota işlemi tamamlanamadı.');
    }
    if (reservation.data().kind === 'room') {
      const room = await transaction.get(roomReference);
      if (!room.exists || room.data().owner_id !== uid) {
        throw new HttpsError('failed-precondition', 'Sohbet odası oluşturulamadı.');
      }
    }
    transaction.update(reservationReference, {
      status: 'completed',
      completed_at: FieldValue.serverTimestamp(),
    });
  });
  return { completed: true };
    },
);

exports.cancelDailyQuotaReservation = onCall(
    PUBLIC_CALLABLE_OPTIONS,
    async (request) => {
  const uid = requireUser(request);
  const { reservationId } = request.data ?? {};
  validateReservationId(reservationId);

  const db = getFirestore();
  const userReference = db.collection('users').doc(uid);
  const reservationReference = userReference
      .collection('quota_reservations')
      .doc(reservationId);
  const roomReference = db.collection('chat_rooms').doc(reservationId);
  return db.runTransaction(async (transaction) => {
    const reservationSnapshot = await transaction.get(reservationReference);
    if (!reservationSnapshot.exists) return { released: false };
    const reservation = reservationSnapshot.data();
    if (reservation.status !== 'pending') return { released: false };
    const roomSnapshot = reservation.kind === 'room'
      ? await transaction.get(roomReference)
      : null;
    if (roomSnapshot?.exists) {
      throw new HttpsError(
          'failed-precondition',
          'Oluşturulan sohbet odasının kotası geri alınamaz.',
      );
    }

    const usageReference = userReference
        .collection('daily_usage')
        .doc(reservation.date);
    const [usageSnapshot, profileSnapshot] = await Promise.all([
      transaction.get(usageReference),
      transaction.get(userReference),
    ]);
    const quota = getDailyQuota(reservation.kind, false);
    if (reservation.source === 'daily' && usageSnapshot.exists) {
      const usage = usageSnapshot.data();
      transaction.set(usageReference, {
        [quota.field]: Math.max(0, safeCount(usage[quota.field]) - 1),
        updated_at: FieldValue.serverTimestamp(),
      }, { merge: true });
    } else if (reservation.source === 'bonus' && profileSnapshot.exists) {
      const profile = profileSnapshot.data();
      transaction.set(userReference, {
        [quota.bonusField]: safeCount(profile[quota.bonusField]) + 1,
      }, { merge: true });
    }
    transaction.delete(reservationReference);
    return { released: true };
  });
    },
);

exports.redeemNavoraReward = onCall(
    PUBLIC_CALLABLE_OPTIONS,
    async (request) => {
  const uid = requireUser(request);
  const rewardId = request.data?.rewardId;
  if (typeof rewardId !== 'string' ||
      !Object.hasOwn(REWARDS, rewardId)) {
    throw new HttpsError('invalid-argument', 'Geçersiz ödül seçildi.');
  }
  const reward = REWARDS[rewardId];

  const db = getFirestore();
  const userReference = db.collection('users').doc(uid);
  const ledgerReference = userReference.collection('point_ledger').doc();
  return db.runTransaction(async (transaction) => {
    const profileSnapshot = await transaction.get(userReference);
    if (!profileSnapshot.exists) {
      throw new HttpsError('failed-precondition', 'Profil bulunamadı.');
    }
    const profile = profileSnapshot.data();
    if (rewardId === 'pro_discount' && profile.pro_discount_unlocked === true) {
      throw new HttpsError('already-exists', 'Bu ödül daha önce alınmış.');
    }
    const points = profile.points_version === 1
      ? safeCount(profile.navora_points)
      : 0;
    if (points < reward.cost) {
      throw new HttpsError('resource-exhausted', 'Yeterli puanınız yok.');
    }

    const update = {
      navora_points: points - reward.cost,
      points_version: 1,
      updated_at: FieldValue.serverTimestamp(),
    };
    if (reward.field) {
      update[reward.field] = safeCount(profile[reward.field]) + 1;
    } else {
      update.pro_discount_unlocked = true;
    }
    transaction.set(userReference, update, { merge: true });
    transaction.create(ledgerReference, {
      title: reward.title,
      detail: 'Takas',
      amount: -reward.cost,
      date: 'Şimdi',
      version: 1,
      created_at: FieldValue.serverTimestamp(),
        },
    );
    return {
      points: points - reward.cost,
      bonusChatRooms: safeCount(update.bonus_chat_rooms ??
          profile.bonus_chat_rooms),
      bonusAiQueries: safeCount(update.bonus_ai_queries ??
          profile.bonus_ai_queries),
      proDiscountUnlocked: update.pro_discount_unlocked ??
          profile.pro_discount_unlocked === true,
    };
  });
});

async function awardPointsToUser({
  uid,
  eventId,
  title,
  detail,
  amount,
  occurredAt,
}) {
  if (!Number.isSafeInteger(amount) || amount <= 0) return;
  const db = getFirestore();
  const userReference = db.collection('users').doc(uid);
  const ledgerReference = userReference
      .collection('point_ledger')
      .doc(eventId);
  const usageDate = getDailyQuotaDate(occurredAt);
  const usageReference = userReference
      .collection('daily_usage')
      .doc(usageDate);

  await db.runTransaction(async (transaction) => {
    const [profileSnapshot, usageSnapshot, ledgerSnapshot] =
        await Promise.all([
          transaction.get(userReference),
          transaction.get(usageReference),
          transaction.get(ledgerReference),
        ]);
    if (!profileSnapshot.exists || ledgerSnapshot.exists) return;

    const profile = profileSnapshot.data();
    const usage = usageSnapshot.data() ?? {};
    const awardedToday = usage.quota_version === 1
      ? safeCount(usage.earned_points)
      : 0;
    const currentPoints = profile.points_version === 1
      ? safeCount(profile.navora_points)
      : 0;
    const awardAmount = Math.max(0, Math.min(
        amount,
        MAX_DAILY_EARNED_POINTS - awardedToday,
        Math.max(0, 10000000 - currentPoints),
    ));
    transaction.create(ledgerReference, {
      title,
      detail: typeof detail === 'string' ? detail.slice(0, 200) : '',
      amount: awardAmount,
      date: 'Şimdi',
      version: 1,
      created_at: FieldValue.serverTimestamp(),
    });
    if (awardAmount === 0) return;

    transaction.set(userReference, {
      navora_points: currentPoints + awardAmount,
      points_version: 1,
      updated_at: FieldValue.serverTimestamp(),
    }, { merge: true });
    transaction.set(usageReference, {
      date: usageDate,
      quota_version: 1,
      earned_points: awardedToday + awardAmount,
      updated_at: FieldValue.serverTimestamp(),
    }, { merge: true });
  });
}

exports.awardDrivingHistoryPoints = onDocumentCreated(
    'users/{uid}/driving_history/{historyId}',
    async (event) => {
      const uid = event.params.uid;
      const history = event.data?.data();
      if (!history) return;
      const completedAt = history.completed_at?.toDate?.();
      const award = getDrivingPointAward(
          history.distance_km,
          history.duration_minutes,
          completedAt,
      );
      if (award === 0) return;

      await awardPointsToUser({
        uid,
        eventId: `drive_${event.params.historyId}`,
        title: 'Tamamlanan rota',
        detail: history.route,
        amount: award,
        occurredAt: completedAt,
      });
    },
);

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
    { ...PUBLIC_CALLABLE_OPTIONS, timeoutSeconds: 540, memory: '1GiB' },
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

exports.recordPropertyListingView = onCall(
    PUBLIC_CALLABLE_OPTIONS,
    async (request) => {
  if (!request.auth) {
    throw new HttpsError('unauthenticated', 'Oturum açmanız gerekiyor.');
  }

  const listingId = request.data?.listingId;
  if (typeof listingId !== 'string' || listingId.length === 0 ||
      listingId.length > 128 || listingId.includes('/')) {
    throw new HttpsError('invalid-argument', 'Geçersiz ilan kimliği.');
  }

  const listingReference = getFirestore()
      .collection('property_listings')
      .doc(listingId);
  const viewerReference = listingReference
      .collection('_views')
      .doc(request.auth.uid);
  let viewCount = 0;

  await getFirestore().runTransaction(async (transaction) => {
    const listing = await transaction.get(listingReference);
    if (!listing.exists || listing.data().status !== 'active') {
      throw new HttpsError('not-found', 'Yayındaki ilan bulunamadı.');
    }

    const currentCount = listing.data().view_count;
    viewCount = Number.isSafeInteger(currentCount) && currentCount >= 0
        ? currentCount
        : 0;
    if (listing.data().owner_uid === request.auth.uid) return;

    const existingView = await transaction.get(viewerReference);
    if (existingView.exists) return;

    viewCount++;
    transaction.create(viewerReference, {
      created_at: FieldValue.serverTimestamp(),
    });
    transaction.set(listingReference, { view_count: viewCount }, { merge: true });
  });

  return { viewCount };
    },
);

exports.deletePropertyListing = onCall(
    PUBLIC_CALLABLE_OPTIONS,
    async (request) => {
  if (!request.auth) {
    throw new HttpsError('unauthenticated', 'Oturum açmanız gerekiyor.');
  }

  const listingId = request.data?.listingId;
  if (typeof listingId !== 'string' || listingId.length === 0 ||
      listingId.length > 128 || listingId.includes('/')) {
    throw new HttpsError('invalid-argument', 'Geçersiz ilan kimliği.');
  }

  const db = getFirestore();
  const listingReference = db.collection('property_listings').doc(listingId);
  const listing = await listingReference.get();
  if (!listing.exists) return { deleted: true };
  if (listing.data().owner_uid !== request.auth.uid) {
    throw new HttpsError('permission-denied', 'Bu ilanı silme yetkiniz yok.');
  }

  await getStorage().bucket().deleteFiles({
    prefix: `property_listings/${request.auth.uid}/${listingId}/`,
      },
  );
  await db.recursiveDelete(listingReference);
  return { deleted: true };
});

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

async function cleanupExpiredQuotaReservations(db = getFirestore(), now = new Date()) {
  const snapshot = await db
      .collectionGroup('quota_reservations')
      .where('expires_at', '<=', now)
      .limit(PAGE_SIZE)
      .get();
  let cleaned = 0;

  for (const candidate of snapshot.docs) {
    const didClean = await db.runTransaction(async (transaction) => {
      const reservationSnapshot = await transaction.get(candidate.ref);
      if (!reservationSnapshot.exists) return false;
      const reservation = reservationSnapshot.data();
      const expiresAt = reservation.expires_at?.toDate?.()
          ?? reservation.expires_at;
      if (!(expiresAt instanceof Date) ||
          expiresAt > now) {
        return false;
      }
        if (reservation.status === 'completed') {
        transaction.delete(candidate.ref);
        return true;
      }
      if (reservation.status !== 'pending') return false;
        if (reservation.kind !== 'room' && reservation.kind !== 'ai') {
          transaction.delete(candidate.ref);
          return true;
        }

      const userReference = candidate.ref.parent.parent;
      if (!userReference) return false;
      const roomReference = db.collection('chat_rooms').doc(candidate.id);
      const usageReference = userReference
          .collection('daily_usage')
          .doc(reservation.date);
      const [roomSnapshot, usageSnapshot, profileSnapshot] = await Promise.all([
        reservation.kind === 'room'
          ? transaction.get(roomReference)
          : Promise.resolve(null),
        transaction.get(usageReference),
        transaction.get(userReference),
      ]);
      if (!roomSnapshot?.exists) {
        const quota = getDailyQuota(reservation.kind, false);
        if (reservation.source === 'daily' && usageSnapshot.exists) {
          const usage = usageSnapshot.data();
          transaction.set(usageReference, {
            [quota.field]: Math.max(0, safeCount(usage[quota.field]) - 1),
            updated_at: FieldValue.serverTimestamp(),
          }, { merge: true });
        } else if (reservation.source === 'bonus' && profileSnapshot.exists) {
          const profile = profileSnapshot.data();
          transaction.set(userReference, {
            [quota.bonusField]: safeCount(profile[quota.bonusField]) + 1,
          }, { merge: true });
        }
      }
      transaction.delete(candidate.ref);
      return true;
    });
    if (didClean) cleaned++;
  }

  return cleaned;
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
  const expiredDrivingHistory = await deleteExpiredUserHistory(
      db,
      'driving_history',
      now,
      PAGE_SIZE,
  );
  const expiredRouteHistory = await deleteExpiredUserHistory(
      db,
      'route_history',
      now,
      PAGE_SIZE,
  );
  const expiredQuotaReservations = await cleanupExpiredQuotaReservations(db, now);

  return {
    expiredRooms,
    expiredListings,
    oldPublicMessages,
    expiredDrivingHistory,
    expiredRouteHistory,
    expiredQuotaReservations,
  };
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