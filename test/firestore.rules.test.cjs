const fs = require('node:fs');
const path = require('node:path');
const { after, before, beforeEach, test } = require('node:test');
const {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} = require('@firebase/rules-unit-testing');
const {
  Timestamp,
  arrayUnion,
  doc,
  getDoc,
  increment,
  serverTimestamp,
  setDoc,
  updateDoc,
  collection,
  deleteDoc,
  getDocs,
  orderBy,
  query,
  where,
  writeBatch,
} = require('firebase/firestore');

const projectId = 'demo-navora';
let testEnvironment;
const now = Timestamp.now();
const salt = '0123456789abcdef0123456789abcdef';
const validRoom = {
  schema_version: 2,
  owner_id: 'owner',
  name: 'Test room',
  type: 'Sohbet Odası',
  active_users: '1 kişi aktif',
  active_users_count: 1,
  member_ids: ['owner'],
  moderator_ids: [],
  latitude: 41,
  longitude: 29,
  is_protected: true,
  password_salt: salt,
  created_at: now,
  updated_at: now,
  expires_at: Timestamp.fromMillis(now.toMillis() + 60 * 60 * 1000),
  max_users: 50,
};
const validListing = {
  owner_id: 'owner',
  name: 'Test room',
  type: 'Sohbet Odası',
  active_users: '1 kişi aktif',
  active_users_count: 1,
  latitude: 41,
  longitude: 29,
  is_protected: true,
  password_salt: salt,
  created_at: now,
  updated_at: now,
  expires_at: validRoom.expires_at,
  max_users: 50,
};
const activePropertyListing = {
  owner_uid: 'owner',
  listing_type: 'kiralik',
  title: 'Aydınlık daire',
  price: 25000,
  currency: 'TRY',
  city: 'İstanbul',
  district: 'Kadıköy',
  address: 'Moda Mahallesi, Kadıköy, İstanbul',
  latitude: 40.99,
  longitude: 29.03,
  area_sqm: 90,
  rooms: '2+1',
  description: 'Bakımlı daire.',
  photo_urls: ['https://firebasestorage.googleapis.com/v0/b/test/o/photo.jpg'],
  cover_image_url: 'https://example.com/cover.jpg',
  status: 'active',
  created_at: now,
  updated_at: now,
};
const validLostPetReport = {
  owner_uid: 'owner',
  pet_type: 'dog',
  pet_name: 'Boncuk',
  description: 'Kahverengi tasmalı küçük köpek.',
  city: 'İstanbul',
  district: 'Kadıköy',
  address: 'Moda Mahallesi, Kadıköy, İstanbul',
  latitude: 40.99,
  longitude: 29.03,
  last_seen_at: now,
  contact_phone: '+90 555 000 0000',
  contact_phone_shared: true,
  photo_urls: [],
  cover_image_url: '',
  status: 'active',
  created_at: now,
  updated_at: now,
};
const validPetAdoptionListing = {
  owner_uid: 'owner',
  pet_type: 'cat',
  pet_name: 'Misket',
  description: 'Uysal, aşıları tamam ve sevgi dolu bir yuva arıyor.',
  city: 'İstanbul',
  district: 'Kadıköy',
  address: 'Moda Mahallesi, Kadıköy, İstanbul',
  latitude: 40.99,
  longitude: 29.03,
  contact_phone: '+90 555 000 0000',
  contact_phone_shared: true,
  photo_urls: [],
  cover_image_url: '',
  status: 'active',
  created_at: now,
  updated_at: now,
};
const validExploreHighlight = {
  title: 'Yeni özellikler',
  subtitle: 'Navora yeniliklerini keşfet.',
  image_url: 'https://images.unsplash.com/photo-1500530855697-b586d89ba3ee',
  action_url: '',
  icon_name: 'new_releases',
  order: 1,
  is_active: true,
  created_by: 'publisher',
  created_at: now,
  updated_at: now,
};

before(async () => {
  testEnvironment = await initializeTestEnvironment({
    projectId,
    firestore: {
      rules: fs.readFileSync(path.join(__dirname, '..', 'firestore.rules'), 'utf8'),
    },
  });
});

after(async () => {
  await testEnvironment?.cleanup();
});

beforeEach(async () => {
  await testEnvironment.clearFirestore();
  await testEnvironment.withSecurityRulesDisabled(async (context) => {
    const firestore = context.firestore();
    await setDoc(doc(firestore, 'chat_rooms/room-1'), validRoom);
    await setDoc(doc(firestore, 'chat_room_listings/room-1'), validListing);
    await setDoc(doc(firestore, 'chat_rooms/room-1/private/access'), {
      password_hash: 'a'.repeat(64),
      updated_at: now,
    });
    await setDoc(doc(firestore, 'chat_rooms/room-1/members/owner'), {
      password_hash: 'a'.repeat(64),
      joined_at: now,
    });
    await setDoc(doc(firestore, 'chat_rooms/room-1/messages/message-1'), {
      sender: 'Owner',
      sender_id: 'owner',
      text: 'secret message',
      time: 'Şimdi',
      created_at: now,
    });
    await setDoc(doc(firestore, 'users/owner'), {
      display_name: 'Owner',
      email: 'owner@example.com',
    });
    await setDoc(
      doc(firestore, 'property_listings/rent-1'),
      activePropertyListing,
    );
    await setDoc(doc(firestore, 'property_listings/pending-1'), {
      ...activePropertyListing,
      status: 'pending_review',
    });
    await setDoc(
      doc(firestore, 'lost_pet_reports/lost-1'),
      validLostPetReport,
    );
  });
});

test('signed-in users can query active lost pet reports', async () => {
  const signedIn = testEnvironment.authenticatedContext('visitor').firestore();
  const signedOut = testEnvironment.unauthenticatedContext().firestore();
  const results = await assertSucceeds(
    getDocs(
      query(
        collection(signedIn, 'lost_pet_reports'),
        where('status', '==', 'active'),
        orderBy('created_at', 'desc'),
      ),
    ),
  );
  if (results.size !== 1 || results.docs[0].id !== 'lost-1') {
    throw new Error('The active lost pet query returned an unexpected result');
  }
  await assertFails(getDoc(doc(signedOut, 'lost_pet_reports/lost-1')));
});

test('lost pet owners can publish and resolve reports without editing contact data', async () => {
  const owner = testEnvironment.authenticatedContext('reporter').firestore();
  const visitor = testEnvironment.authenticatedContext('visitor').firestore();
  const reportReference = doc(owner, 'lost_pet_reports/new-report');
  await assertSucceeds(
    setDoc(reportReference, {
      ...validLostPetReport,
      owner_uid: 'reporter',
      created_at: serverTimestamp(),
      updated_at: serverTimestamp(),
    }),
  );
  const photoUrl =
      'https://firebasestorage.googleapis.com/v0/b/test/o/lost-pet.jpg';
  await assertSucceeds(
    updateDoc(reportReference, {
      photo_urls: [photoUrl],
      cover_image_url: photoUrl,
      updated_at: serverTimestamp(),
    }),
  );
  await assertFails(
    updateDoc(reportReference, {
      contact_phone: '+90 555 111 1111',
      updated_at: serverTimestamp(),
    }),
  );
  await assertFails(
    updateDoc(doc(visitor, 'lost_pet_reports/new-report'), {
      status: 'resolved',
      updated_at: serverTimestamp(),
    }),
  );
  await assertSucceeds(
    updateDoc(reportReference, {
      status: 'resolved',
      updated_at: serverTimestamp(),
    }),
  );
  await assertFails(getDoc(doc(visitor, 'lost_pet_reports/new-report')));
});

test('lost pet reports require consent and valid coordinates', async () => {
  const firestore = testEnvironment.authenticatedContext('reporter').firestore();
  await assertFails(
    setDoc(doc(firestore, 'lost_pet_reports/no-phone-consent'), {
      ...validLostPetReport,
      owner_uid: 'reporter',
      photo_urls: [],
      cover_image_url: '',
      contact_phone_shared: false,
      created_at: serverTimestamp(),
      updated_at: serverTimestamp(),
    }),
  );
  await assertFails(
    setDoc(doc(firestore, 'lost_pet_reports/invalid-location'), {
      ...validLostPetReport,
      owner_uid: 'reporter',
      photo_urls: [],
      cover_image_url: '',
      latitude: 120,
      created_at: serverTimestamp(),
      updated_at: serverTimestamp(),
    }),
  );
});

test('signed-in users can query active adoption listings', async () => {
  await testEnvironment.withSecurityRulesDisabled(async (context) => {
    await setDoc(
      doc(context.firestore(), 'pet_adoption_listings/adoption-1'),
      validPetAdoptionListing,
    );
  });
  const signedIn = testEnvironment.authenticatedContext('visitor').firestore();
  const signedOut = testEnvironment.unauthenticatedContext().firestore();
  const results = await assertSucceeds(
    getDocs(
      query(
        collection(signedIn, 'pet_adoption_listings'),
        where('status', '==', 'active'),
        orderBy('created_at', 'desc'),
      ),
    ),
  );
  if (results.size !== 1 || results.docs[0].id !== 'adoption-1') {
    throw new Error('The active adoption query returned an unexpected result');
  }
  await assertFails(getDoc(doc(signedOut, 'pet_adoption_listings/adoption-1')));
});

test('adoption owners can publish, update photos, and close listings safely', async () => {
  const owner = testEnvironment.authenticatedContext('reporter').firestore();
  const visitor = testEnvironment.authenticatedContext('visitor').firestore();
  const listingReference = doc(owner, 'pet_adoption_listings/new-listing');
  await assertSucceeds(
    setDoc(listingReference, {
      ...validPetAdoptionListing,
      owner_uid: 'reporter',
      created_at: serverTimestamp(),
      updated_at: serverTimestamp(),
    }),
  );
  const photoUrl =
    'https://firebasestorage.googleapis.com/v0/b/test/o/adoption-photo.jpg';
  await assertSucceeds(
    updateDoc(listingReference, {
      photo_urls: [photoUrl],
      cover_image_url: photoUrl,
      updated_at: serverTimestamp(),
    }),
  );
  await assertFails(
    updateDoc(listingReference, {
      contact_phone: '+90 555 111 1111',
      updated_at: serverTimestamp(),
    }),
  );
  await assertFails(
    updateDoc(doc(visitor, 'pet_adoption_listings/new-listing'), {
      status: 'resolved',
      updated_at: serverTimestamp(),
    }),
  );
  await assertSucceeds(
    updateDoc(listingReference, {
      status: 'resolved',
      updated_at: serverTimestamp(),
    }),
  );
  await assertFails(
    updateDoc(listingReference, {
      status: 'active',
      updated_at: serverTimestamp(),
    }),
  );
  await assertFails(getDoc(doc(visitor, 'pet_adoption_listings/new-listing')));
});

test('adoption listings reject missing consent, invalid coordinates, and extra fields', async () => {
  const firestore = testEnvironment.authenticatedContext('reporter').firestore();
  const listing = (overrides = {}) => ({
    ...validPetAdoptionListing,
    owner_uid: 'reporter',
    created_at: serverTimestamp(),
    updated_at: serverTimestamp(),
    ...overrides,
  });
  await assertFails(
    setDoc(
      doc(firestore, 'pet_adoption_listings/no-phone-consent'),
      listing({ contact_phone_shared: false }),
    ),
  );
  await assertFails(
    setDoc(
      doc(firestore, 'pet_adoption_listings/invalid-location'),
      listing({ latitude: 120 }),
    ),
  );
  await assertFails(
    setDoc(
      doc(firestore, 'pet_adoption_listings/extra-field'),
      listing({ is_admin: true }),
    ),
  );
});

test('signed-in users can read active highlights but not drafts or manage content', async () => {
  const admin = testEnvironment.authenticatedContext('publisher', {
    admin: true,
  }).firestore();
  await assertSucceeds(
    setDoc(doc(admin, 'explore_highlights/active-1'), {
      ...validExploreHighlight,
      created_at: serverTimestamp(),
      updated_at: serverTimestamp(),
    }),
  );
  await assertSucceeds(
    setDoc(doc(admin, 'explore_highlights/draft-1'), {
      ...validExploreHighlight,
      is_active: false,
      order: 2,
      created_at: serverTimestamp(),
      updated_at: serverTimestamp(),
    }),
  );

  const visitor = testEnvironment.authenticatedContext('visitor').firestore();
  const activeHighlights = await assertSucceeds(
    getDocs(
      query(
        collection(visitor, 'explore_highlights'),
        where('is_active', '==', true),
        orderBy('order'),
      ),
    ),
  );
  if (activeHighlights.size !== 1 || activeHighlights.docs[0].id !== 'active-1') {
    throw new Error('The active Explore highlights query returned unexpected data');
  }
  await assertFails(getDoc(doc(visitor, 'explore_highlights/draft-1')));
  await assertFails(
    setDoc(doc(visitor, 'explore_highlights/visitor-card'), {
      ...validExploreHighlight,
      created_by: 'visitor',
      created_at: serverTimestamp(),
      updated_at: serverTimestamp(),
    }),
  );
  await assertFails(
    updateDoc(doc(visitor, 'explore_highlights/active-1'), {
      title: 'İzinsiz değişiklik',
      updated_at: serverTimestamp(),
    }),
  );
});

test('Explore admins can manage valid highlights without changing creator metadata', async () => {
  const admin = testEnvironment.authenticatedContext('publisher', {
    admin: true,
  }).firestore();
  const reference = doc(admin, 'explore_highlights/card-1');
  await assertSucceeds(
    setDoc(reference, {
      ...validExploreHighlight,
      created_at: serverTimestamp(),
      updated_at: serverTimestamp(),
    }),
  );
  await assertSucceeds(
    updateDoc(reference, {
      title: 'Bisiklet rotaları',
      icon_name: 'pedal_bike',
      updated_at: serverTimestamp(),
    }),
  );
  await assertFails(
    updateDoc(reference, {
      created_by: 'another-user',
      updated_at: serverTimestamp(),
    }),
  );
  await assertFails(
    updateDoc(reference, {
      is_admin: true,
      updated_at: serverTimestamp(),
    }),
  );
  await assertSucceeds(deleteDoc(reference));
});

test('signed-in users can query active property listings by type', async () => {
  const firestore = testEnvironment.authenticatedContext('visitor').firestore();
  const results = await assertSucceeds(
    getDocs(
      query(
        collection(firestore, 'property_listings'),
        where('status', '==', 'active'),
        where('listing_type', '==', 'kiralik'),
        orderBy('created_at', 'desc'),
      ),
    ),
  );
  if (results.size !== 1 || results.docs[0].id !== 'rent-1') {
    throw new Error('The active property query returned an unexpected result');
  }
});

test('property listing access is authenticated and pending data is owner-only', async () => {
  const signedOut = testEnvironment.unauthenticatedContext().firestore();
  const visitor = testEnvironment.authenticatedContext('visitor').firestore();
  await assertFails(getDoc(doc(signedOut, 'property_listings/rent-1')));
  await assertSucceeds(getDoc(doc(visitor, 'property_listings/rent-1')));
  await assertFails(getDoc(doc(visitor, 'property_listings/pending-1')));
  await assertSucceeds(
    getDoc(
      doc(
        testEnvironment.authenticatedContext('owner').firestore(),
        'property_listings/pending-1',
      ),
    ),
  );
});

test('owners can submit pending listings but cannot publish or edit them', async () => {
  const firestore = testEnvironment.authenticatedContext('visitor').firestore();
  const listingReference = doc(firestore, 'property_listings/new-listing');
  await assertSucceeds(
    setDoc(listingReference, {
      ...activePropertyListing,
      owner_uid: 'visitor',
      photo_urls: [],
      cover_image_url: '',
      status: 'pending_review',
      created_at: serverTimestamp(),
      updated_at: serverTimestamp(),
    }),
  );
  await assertFails(
    updateDoc(listingReference, {
      status: 'active',
      updated_at: serverTimestamp(),
    }),
  );
  await assertFails(
    updateDoc(listingReference, {
      price: 1,
      updated_at: serverTimestamp(),
    }),
  );
  const photoUrl =
      'https://firebasestorage.googleapis.com/v0/b/test/o/photo.jpg';
  await assertSucceeds(
    updateDoc(listingReference, {
      photo_urls: [photoUrl],
      cover_image_url: photoUrl,
      updated_at: serverTimestamp(),
    }),
  );
  await assertSucceeds(deleteDoc(listingReference));
});

test('users cannot submit listings for another owner or with invalid values', async () => {
  const firestore = testEnvironment.authenticatedContext('visitor').firestore();
  await assertFails(
    setDoc(doc(firestore, 'property_listings/forged-owner'), {
      ...activePropertyListing,
      status: 'pending_review',
      created_at: serverTimestamp(),
      updated_at: serverTimestamp(),
    }),
  );
  await assertFails(
    setDoc(doc(firestore, 'property_listings/invalid-price'), {
      ...activePropertyListing,
      owner_uid: 'visitor',
      price: -1,
      status: 'pending_review',
      created_at: serverTimestamp(),
      updated_at: serverTimestamp(),
    }),
  );
});

test('signed-out users cannot read listings', async () => {
  const firestore = testEnvironment.unauthenticatedContext().firestore();
  await assertFails(getDoc(doc(firestore, 'chat_room_listings/room-1')));
});

test('authenticated non-members can read only safe listing fields', async () => {
  const firestore = testEnvironment.authenticatedContext('visitor').firestore();
  const listing = await assertSucceeds(
    getDoc(doc(firestore, 'chat_room_listings/room-1')),
  );
  if ('password_hash' in listing.data() || 'messages' in listing.data()) {
    throw new Error('Room listing exposed private data');
  }
  await assertFails(getDoc(doc(firestore, 'chat_rooms/room-1')));
  await assertFails(
    getDoc(doc(firestore, 'chat_rooms/room-1/private/access')),
  );
  await assertFails(
    getDoc(doc(firestore, 'chat_rooms/room-1/messages/message-1')),
  );
});

test('owner can atomically create a protected room without plaintext password', async () => {
  const firestore = testEnvironment.authenticatedContext('owner').firestore();
  const room = doc(firestore, 'chat_rooms/new-room');
  const listing = doc(firestore, 'chat_room_listings/new-room');
  const batch = firestore.batch();
  const expiresAt = Timestamp.fromMillis(now.toMillis() + 60 * 60 * 1000);
  const roomData = {
    ...validRoom,
    owner_id: 'owner',
    member_ids: ['owner'],
    password_salt: salt,
    expires_at: expiresAt,
  };
  const listingData = {
    ...validListing,
    owner_id: 'owner',
    password_salt: salt,
    expires_at: expiresAt,
  };
  batch.set(room, {
    ...roomData,
    created_at: serverTimestamp(),
    updated_at: serverTimestamp(),
  });
  batch.set(listing, {
    ...listingData,
    created_at: serverTimestamp(),
    updated_at: serverTimestamp(),
  });
  batch.set(doc(firestore, 'chat_rooms/new-room/members/owner'), {
    password_hash: 'a'.repeat(64),
    joined_at: serverTimestamp(),
  });
  batch.set(doc(firestore, 'chat_rooms/new-room/private/access'), {
    password_hash: 'a'.repeat(64),
    updated_at: serverTimestamp(),
  });
  batch.set(doc(firestore, 'chat_rooms/new-room/messages/welcome'), {
    sender: 'Owner',
    sender_id: 'owner',
    text: 'Welcome',
    time: 'Şimdi',
    created_at: serverTimestamp(),
  });
  await assertSucceeds(batch.commit());
  const createdRoom = await assertSucceeds(getDoc(room));
  if ('password' in createdRoom.data() || 'messages' in createdRoom.data()) {
    throw new Error('Private room data was written to the room document');
  }
});

async function joinBatch(firestore, uid, passwordHash) {
  const batch = firestore.batch();
  const room = doc(firestore, 'chat_rooms/room-1');
  const listing = doc(firestore, 'chat_room_listings/room-1');
  const memberIds = ['owner', uid];
  batch.set(doc(firestore, `chat_rooms/room-1/members/${uid}`), {
    password_hash: passwordHash,
    joined_at: serverTimestamp(),
  });
  batch.update(room, {
    member_ids: arrayUnion(uid),
    active_users_count: increment(1),
    active_users: '2 kişi',
    updated_at: serverTimestamp(),
  });
  batch.update(listing, {
    active_users_count: increment(1),
    active_users: '2 kişi',
    updated_at: serverTimestamp(),
  });
  return batch.commit();
}

test('a protected-room password hash is required to become a member', async () => {
  const firestore = testEnvironment.authenticatedContext('intruder').firestore();
  await assertFails(joinBatch(firestore, 'intruder', 'b'.repeat(64)));
});

test('a matching password hash can create a member and update room counts', async () => {
  const firestore = testEnvironment.authenticatedContext('member').firestore();
  await assertSucceeds(joinBatch(firestore, 'member', 'a'.repeat(64)));
  await assertSucceeds(
    getDoc(doc(firestore, 'chat_rooms/room-1/messages/message-1')),
  );
});

test('room member can read messages but cannot forge sender identity', async () => {
  await testEnvironment.withSecurityRulesDisabled(async (context) => {
    await setDoc(
      doc(context.firestore(), 'chat_rooms/room-1/members/member'),
      { password_hash: 'a'.repeat(64), joined_at: now },
    );
  });
  const firestore = testEnvironment.authenticatedContext('member').firestore();
  await assertSucceeds(
    getDoc(doc(firestore, 'chat_rooms/room-1/messages/message-1')),
  );
  await assertFails(
    setDoc(doc(firestore, 'chat_rooms/room-1/messages/forged'), {
      sender: 'Owner',
      sender_id: 'owner',
      text: 'forged message',
      time: 'Şimdi',
      created_at: Timestamp.now(),
    }),
  );
  await assertFails(
    setDoc(doc(firestore, 'chat_rooms/room-1/messages/fake-pro'), {
      sender: 'Member',
      sender_id: 'member',
      sender_is_pro: true,
      text: 'fake badge',
      time: 'Şimdi',
      created_at: serverTimestamp(),
    }),
  );
});

test('public chat does not accept a client-authored Pro badge', async () => {
  const firestore = testEnvironment.authenticatedContext('owner').firestore();
  await assertFails(
    setDoc(doc(firestore, 'public_chat_messages/fake-pro'), {
      senderId: 'owner',
      senderName: 'Owner',
      text: 'fake badge',
      isPro: true,
      createdAt: serverTimestamp(),
    }),
  );
});

test('user profile cannot self-assign Pro or client-controlled quotas', async () => {
  const firestore = testEnvironment.authenticatedContext('owner').firestore();
  await assertFails(
    setDoc(doc(firestore, 'users/new-user'), {
      display_name: 'New user',
      is_pro: true,
      created_at: serverTimestamp(),
    }),
  );
  await assertFails(
    updateDoc(doc(firestore, 'users/owner'), {
      is_pro: true,
      updated_at: Timestamp.now(),
    }),
  );
  await assertFails(
    updateDoc(doc(firestore, 'users/owner'), {
      daily_ai_queries_used: 0,
      updated_at: Timestamp.now(),
    }),
  );
  await assertFails(
    updateDoc(doc(firestore, 'users/owner'), {
      navora_points: 1000000,
      updated_at: serverTimestamp(),
    }),
  );
});

test('existing legacy entitlements survive editable profile updates unchanged', async () => {
  await testEnvironment.withSecurityRulesDisabled(async (context) => {
    await setDoc(doc(context.firestore(), 'users/legacy'), {
      display_name: 'Legacy user',
      is_pro: true,
      plan: 'pro',
      navora_points: 200,
      daily_quota_date: '2026-09-30',
      daily_rooms_created: 2,
      daily_ai_queries_used: 1,
      visited_cities: ['İstanbul'],
    });
  });
  const firestore = testEnvironment.authenticatedContext('legacy').firestore();
  const profileReference = doc(firestore, 'users/legacy');
  await assertSucceeds(
    updateDoc(profileReference, {
      bio: 'Profil güncellendi',
      updated_at: serverTimestamp(),
    }),
  );
  await assertFails(
    updateDoc(profileReference, {
      is_pro: false,
      updated_at: serverTimestamp(),
    }),
  );
});

test('profile accepts app fields while enforcing value limits', async () => {
  const firestore = testEnvironment.authenticatedContext('owner').firestore();
  await assertSucceeds(
    updateDoc(doc(firestore, 'users/owner'), {
      gender_preference: 'Belirtmek istemiyorum',
      selected_vehicle: 'Araba',
      explore_preferences: ['Kafeler', 'Doğa'],
      bio: 'Merhaba',
      updated_at: serverTimestamp(),
    }),
  );
  await assertFails(
    updateDoc(doc(firestore, 'users/owner'), {
      explore_preferences: ['Kafeler', 'Bilinmeyen'],
      updated_at: serverTimestamp(),
    }),
  );
  await assertFails(
    updateDoc(doc(firestore, 'users/owner'), {
      bio: 'x'.repeat(301),
      updated_at: serverTimestamp(),
    }),
  );
});

test('shared lists are blocked entirely', async () => {
  const owner = testEnvironment.authenticatedContext('owner').firestore();
  const friend = testEnvironment.authenticatedContext('friend').firestore();
  const list = {
    owner_uid: 'owner',
    title: 'İzmir hafta sonu',
    city: 'İzmir',
    kind: 'places',
    stops: ['Kordon', 'Kemeraltı'],
    created_at: serverTimestamp(),
    updated_at: serverTimestamp(),
  };

  await assertFails(setDoc(doc(owner, 'shared_lists/izmir-weekend'), list));
  await assertFails(getDoc(doc(friend, 'shared_lists/izmir-weekend')));
  await assertFails(setDoc(doc(friend, 'shared_lists/other'), list));
  await assertFails(
    getDoc(
      doc(
        testEnvironment.unauthenticatedContext().firestore(),
        'shared_lists/izmir-weekend',
      ),
    ),
  );
});

test('road reports reject oversized text and invalid coordinates', async () => {
  const firestore = testEnvironment.authenticatedContext('owner').firestore();
  const expiresAt = Timestamp.fromMillis(Date.now() + 60 * 60 * 1000);
  const validReport = {
    user_id: 'owner',
    type: 'Radar',
    description: 'Radar bildirimi',
    latitude: 41,
    longitude: 29,
    created_at: serverTimestamp(),
    expires_at: expiresAt,
    confirmation_count: 0,
    incorrect_count: 0,
  };
  await assertSucceeds(setDoc(doc(firestore, 'road_reports/valid'), validReport));
  await assertFails(
    setDoc(doc(firestore, 'road_reports/oversized'), {
      ...validReport,
      description: 'x'.repeat(501),
    }),
  );
  await assertFails(
    setDoc(doc(firestore, 'road_reports/invalid-coordinate'), {
      ...validReport,
      latitude: 120,
    }),
  );
});

test('road report feedback updates one counter atomically and only once per user', async () => {
  const owner = testEnvironment.authenticatedContext('owner').firestore();
  const voter = testEnvironment.authenticatedContext('voter').firestore();
  const unauthenticated = testEnvironment.unauthenticatedContext().firestore();
  const reportReference = doc(owner, 'road_reports/verified-report');
  await assertSucceeds(
    setDoc(reportReference, {
      user_id: 'owner',
      type: 'Trafik',
      description: 'Yoğunluk var',
      latitude: 41,
      longitude: 29,
      created_at: serverTimestamp(),
      expires_at: Timestamp.fromMillis(Date.now() + 60 * 60 * 1000),
      confirmation_count: 0,
      incorrect_count: 0,
    }),
  );
  await assertFails(getDoc(doc(unauthenticated, 'road_reports/verified-report')));
  await assertFails(getDocs(collection(unauthenticated, 'road_reports')));

  const voterReport = doc(voter, 'road_reports/verified-report');
  const voterFeedback = doc(voter, 'road_reports/verified-report/feedback/voter');
  const counterOnlyBatch = writeBatch(voter);
  counterOnlyBatch.update(voterReport, { confirmation_count: increment(1) });
  await assertFails(counterOnlyBatch.commit());

  const orphanFeedbackBatch = writeBatch(voter);
  orphanFeedbackBatch.set(voterFeedback, {
    vote: 'confirmed',
    created_at: serverTimestamp(),
  });
  await assertFails(orphanFeedbackBatch.commit());

  const mismatchedFeedbackBatch = writeBatch(voter);
  mismatchedFeedbackBatch.update(voterReport, { incorrect_count: increment(1) });
  mismatchedFeedbackBatch.set(voterFeedback, {
    vote: 'confirmed',
    created_at: serverTimestamp(),
  });
  await assertFails(mismatchedFeedbackBatch.commit());

  const spoofedVoter = testEnvironment.authenticatedContext('spoofed-voter').firestore();
  const spoofedFeedbackBatch = writeBatch(spoofedVoter);
  spoofedFeedbackBatch.update(doc(spoofedVoter, 'road_reports/verified-report'), {
    confirmation_count: increment(1),
  });
  spoofedFeedbackBatch.set(
    doc(spoofedVoter, 'road_reports/verified-report/feedback/voter'),
    { vote: 'confirmed', created_at: serverTimestamp() },
  );
  await assertFails(spoofedFeedbackBatch.commit());

  const confirmationBatch = writeBatch(voter);
  confirmationBatch.update(voterReport, { confirmation_count: increment(1) });
  confirmationBatch.set(voterFeedback, {
    vote: 'confirmed',
    created_at: serverTimestamp(),
  });
  await assertSucceeds(confirmationBatch.commit());

  const duplicateBatch = writeBatch(voter);
  duplicateBatch.update(voterReport, { incorrect_count: increment(1) });
  duplicateBatch.set(voterFeedback, {
    vote: 'incorrect',
    created_at: serverTimestamp(),
  });
  await assertFails(duplicateBatch.commit());

  const ownerFeedbackBatch = writeBatch(owner);
  ownerFeedbackBatch.update(reportReference, { incorrect_count: increment(1) });
  ownerFeedbackBatch.set(
    doc(owner, 'road_reports/verified-report/feedback/owner'),
    { vote: 'incorrect', created_at: serverTimestamp() },
  );
  await assertFails(ownerFeedbackBatch.commit());

  const incorrectReport = doc(owner, 'road_reports/incorrect-report');
  await assertSucceeds(
    setDoc(incorrectReport, {
      user_id: 'owner',
      type: 'Yol çalışması',
      description: 'Çalışma tamamlandı',
      latitude: 41,
      longitude: 29,
      created_at: serverTimestamp(),
      expires_at: Timestamp.fromMillis(Date.now() + 60 * 60 * 1000),
      confirmation_count: 0,
      incorrect_count: 0,
    }),
  );
  const incorrectVoteBatch = writeBatch(voter);
  incorrectVoteBatch.update(doc(voter, 'road_reports/incorrect-report'), {
    incorrect_count: increment(1),
  });
  incorrectVoteBatch.set(
    doc(voter, 'road_reports/incorrect-report/feedback/voter'),
    { vote: 'incorrect', created_at: serverTimestamp() },
  );
  await assertSucceeds(incorrectVoteBatch.commit());
});

test('community places are authenticated, validated, and owner-managed', async () => {
  const owner = testEnvironment.authenticatedContext('owner').firestore();
  const visitor = testEnvironment.authenticatedContext('visitor').firestore();
  const place = {
    owner_uid: 'owner',
    name: 'Gizli seyir noktası',
    category: 'Doğa',
    description: 'Gün batımında güzel manzara.',
    address: 'İzmir',
    latitude: 38.4,
    longitude: 27.1,
    created_at: serverTimestamp(),
  };
  const placeReference = doc(owner, 'community_places/secret-viewpoint');

  await assertFails(
    setDoc(
      doc(
        testEnvironment.unauthenticatedContext().firestore(),
        'community_places/anonymous',
      ),
      place,
    ),
  );
  await assertSucceeds(setDoc(placeReference, place));
  await assertSucceeds(
    getDoc(doc(visitor, 'community_places/secret-viewpoint')),
  );
  await assertFails(
    updateDoc(doc(visitor, 'community_places/secret-viewpoint'), {
      description: 'Başka kullanıcı düzenledi',
    }),
  );
  await assertSucceeds(
    updateDoc(placeReference, { description: 'Sahibi düzenledi' }),
  );
  await assertSucceeds(
    updateDoc(placeReference, {
      photo_url: 'https://firebasestorage.googleapis.com/v0/b/test/o/cover',
    }),
  );
  await assertFails(updateDoc(placeReference, { photo_url: 'not-a-url' }));
  await assertFails(
    setDoc(doc(visitor, 'community_places/spoofed'), {
      ...place,
      owner_uid: 'owner',
    }),
  );
  await assertFails(
    setDoc(doc(owner, 'community_places/out-of-range'), {
      ...place,
      latitude: 95,
    }),
  );
  await assertFails(
    setDoc(doc(owner, 'community_places/extra-field'), {
      ...place,
      private_note: 'not in schema',
    }),
  );
});
