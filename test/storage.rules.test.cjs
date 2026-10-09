const fs = require('node:fs');
const path = require('node:path');
const { after, before, test } = require('node:test');
const {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} = require('@firebase/rules-unit-testing');
const { doc, setDoc, updateDoc } = require('firebase/firestore');
const { getMetadata, ref, uploadBytes } = require('firebase/storage');

const projectId = 'demo-navora';
let testEnvironment;

before(async () => {
  testEnvironment = await initializeTestEnvironment({
    projectId,
    firestore: {
      rules: fs.readFileSync(path.join(__dirname, '..', 'firestore.rules'), 'utf8'),
    },
    storage: {
      rules: fs.readFileSync(path.join(__dirname, '..', 'storage.rules'), 'utf8'),
    },
  });
});

after(async () => {
  await testEnvironment?.cleanup();
});

async function seedListing(listingId, status = 'pending_review') {
  await testEnvironment.withSecurityRulesDisabled(async (context) => {
    await setDoc(doc(context.firestore(), `property_listings/${listingId}`), {
      owner_uid: 'owner',
      listing_type: 'kiralik',
      title: 'Test ilanı',
      price: 20000,
      currency: 'TRY',
      city: 'İstanbul',
      district: 'Kadıköy',
      address: 'Moda Mahallesi, Kadıköy, İstanbul',
      latitude: 41,
      longitude: 29,
      area_sqm: 80,
      rooms: '2+1',
      description: 'Test ilanı açıklaması.',
      photo_urls: [],
      cover_image_url: '',
      status,
      created_at: new Date(),
      updated_at: new Date(),
    });
  });
}

async function seedLostPetReport(reportId) {
  await testEnvironment.withSecurityRulesDisabled(async (context) => {
    await setDoc(doc(context.firestore(), `lost_pet_reports/${reportId}`), {
      owner_uid: 'owner',
      pet_type: 'dog',
      pet_name: 'Boncuk',
      description: 'Kahverengi tasmalı küçük köpek.',
      city: 'İstanbul',
      district: 'Kadıköy',
      address: 'Moda Mahallesi, Kadıköy, İstanbul',
      latitude: 41,
      longitude: 29,
      last_seen_at: new Date(),
      contact_phone: '+90 555 000 0000',
      contact_phone_shared: true,
      photo_urls: [],
      cover_image_url: '',
      status: 'active',
      created_at: new Date(),
      updated_at: new Date(),
    });
  });
}

async function seedPetAdoptionListing(listingId, status = 'active') {
  await testEnvironment.withSecurityRulesDisabled(async (context) => {
    await setDoc(
      doc(context.firestore(), `pet_adoption_listings/${listingId}`),
      {
        owner_uid: 'owner',
        pet_type: 'cat',
        pet_name: 'Misket',
        description: 'Uysal, aşıları tamam ve sevgi dolu bir yuva arıyor.',
        city: 'İstanbul',
        district: 'Kadıköy',
        address: 'Moda Mahallesi, Kadıköy, İstanbul',
        latitude: 41,
        longitude: 29,
        contact_phone: '+90 555 000 0000',
        contact_phone_shared: true,
        photo_urls: [],
        cover_image_url: '',
        status,
        created_at: new Date(),
        updated_at: new Date(),
      },
    );
  });
}

async function seedCommunityPlace(placeId) {
  await testEnvironment.withSecurityRulesDisabled(async (context) => {
    await setDoc(doc(context.firestore(), `community_places/${placeId}`), {
      owner_uid: 'owner',
      name: 'Test mekânı',
      category: 'Kafe',
      description: '',
      address: '',
      latitude: 41,
      longitude: 29,
      created_at: new Date(),
    });
  });
}

test('lost pet owners upload optional photos and signed-in users can read them', async () => {
  const reportId = `lost-${Date.now()}`;
  await seedLostPetReport(reportId);
  const ownerStorage = testEnvironment.authenticatedContext('owner').storage();
  const photo = ref(ownerStorage, `lost_pet_reports/owner/${reportId}/0`);
  await assertSucceeds(
    uploadBytes(photo, new Uint8Array([1, 2, 3]), { contentType: 'image/jpeg' }),
  );
  await assertFails(
    uploadBytes(
      ref(ownerStorage, `lost_pet_reports/owner/${reportId}/3`),
      new Uint8Array([1, 2, 3]),
      { contentType: 'image/jpeg' },
    ),
  );
  await assertFails(
    uploadBytes(
      ref(ownerStorage, `lost_pet_reports/owner/${reportId}/1`),
      new Uint8Array([1, 2, 3]),
      { contentType: 'image/gif' },
    ),
  );
  const visitorStorage = testEnvironment.authenticatedContext('visitor').storage();
  await assertSucceeds(getMetadata(ref(visitorStorage, photo.fullPath)));
  const signedOutStorage = testEnvironment.unauthenticatedContext().storage();
  await assertFails(getMetadata(ref(signedOutStorage, photo.fullPath)));
});

test('adoption listing owners upload limited photos and signed-in users can read them', async () => {
  const listingId = `adoption-${Date.now()}`;
  await seedPetAdoptionListing(listingId);
  const ownerStorage = testEnvironment.authenticatedContext('owner').storage();
  const photo = ref(
    ownerStorage,
    `pet_adoption_listings/owner/${listingId}/0`,
  );
  await assertSucceeds(
    uploadBytes(photo, new Uint8Array([1, 2, 3]), { contentType: 'image/jpeg' }),
  );
  await assertFails(
    uploadBytes(
      ref(ownerStorage, `pet_adoption_listings/owner/${listingId}/3`),
      new Uint8Array([1, 2, 3]),
      { contentType: 'image/jpeg' },
    ),
  );
  await assertFails(
    uploadBytes(
      ref(ownerStorage, `pet_adoption_listings/owner/${listingId}/1`),
      new Uint8Array([1, 2, 3]),
      { contentType: 'image/gif' },
    ),
  );
  const visitorStorage = testEnvironment.authenticatedContext('visitor').storage();
  await assertSucceeds(getMetadata(ref(visitorStorage, photo.fullPath)));
  const signedOutStorage = testEnvironment.unauthenticatedContext().storage();
  await assertFails(getMetadata(ref(signedOutStorage, photo.fullPath)));
});

test('listing owner uploads limited image files to pending listing slots', async () => {
  const listingId = `pending-${Date.now()}`;
  await seedListing(listingId);
  const ownerStorage = testEnvironment.authenticatedContext('owner').storage();
  const photo = ref(ownerStorage, `property_listings/owner/${listingId}/0`);
  await assertSucceeds(
    uploadBytes(photo, new Uint8Array([1, 2, 3]), { contentType: 'image/jpeg' }),
  );

  await assertFails(
    uploadBytes(
      ref(ownerStorage, `property_listings/owner/${listingId}/5`),
      new Uint8Array([1, 2, 3]),
      { contentType: 'image/jpeg' },
    ),
  );
  await assertFails(
    uploadBytes(
      ref(ownerStorage, `property_listings/owner/${listingId}/1`),
      new Uint8Array([1, 2, 3]),
      { contentType: 'image/gif' },
    ),
  );
  await assertFails(
    uploadBytes(
      ref(ownerStorage, `property_listings/other/${listingId}/0`),
      new Uint8Array([1, 2, 3]),
      { contentType: 'image/jpeg' },
    ),
  );

  const otherStorage = testEnvironment.authenticatedContext('other').storage();
  await assertFails(getMetadata(ref(otherStorage, photo.fullPath)));
});

test('active listing images are readable by signed-in users only', async () => {
  const listingId = `active-${Date.now()}`;
  await seedListing(listingId, 'pending_review');
  const ownerStorage = testEnvironment.authenticatedContext('owner').storage();
  const photo = ref(ownerStorage, `property_listings/owner/${listingId}/0`);
  await assertSucceeds(
    uploadBytes(photo, new Uint8Array([1, 2, 3]), { contentType: 'image/png' }),
  );

  await testEnvironment.withSecurityRulesDisabled(async (context) => {
    await updateDoc(doc(context.firestore(), `property_listings/${listingId}`), {
      status: 'active',
    });
  });

  const visitorStorage = testEnvironment.authenticatedContext('visitor').storage();
  await assertSucceeds(getMetadata(ref(visitorStorage, photo.fullPath)));
  const signedOutStorage = testEnvironment.unauthenticatedContext().storage();
  await assertFails(getMetadata(ref(signedOutStorage, photo.fullPath)));
});

test('community place owners upload photos and signed-in users can read them', async () => {
  const placeId = `place-${Date.now()}`;
  await seedCommunityPlace(placeId);
  const ownerStorage = testEnvironment.authenticatedContext('owner').storage();
  const photo = ref(
    ownerStorage,
    `community_places/owner/${placeId}/cover`,
  );
  await assertSucceeds(
    uploadBytes(photo, new Uint8Array([1, 2, 3]), {
      contentType: 'image/jpeg',
    }),
  );
  await assertFails(
    uploadBytes(
      ref(
        testEnvironment.authenticatedContext('visitor').storage(),
        `community_places/visitor/${placeId}/cover`,
      ),
      new Uint8Array([1, 2, 3]),
      { contentType: 'image/jpeg' },
    ),
  );
  const visitorStorage = testEnvironment.authenticatedContext('visitor').storage();
  await assertSucceeds(getMetadata(ref(visitorStorage, photo.fullPath)));
  const signedOutStorage = testEnvironment.unauthenticatedContext().storage();
  await assertFails(getMetadata(ref(signedOutStorage, photo.fullPath)));
});