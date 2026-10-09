# Firestore data model

This document records the client-side Firestore paths used by Navora Map.

- `property_listings/{listingId}`: user-owned rental/sale submissions with full public address, exact geocoded coordinates, and up to five photo URLs. Owners create `pending_review` documents; only trusted admins/server processes can publish them by changing status to `active`.
- `property_listings/{uid}/{listingId}/{photoIndex}` in Cloud Storage: listing photos, with five fixed slots per pending listing; only the listing owner can upload, and active photos are readable by authenticated users.
- `lost_pet_reports/{reportId}`: authenticated lost/found pet reports with last-seen address/coordinates, time, an explicitly shared contact phone, and zero to three optional photo URLs. The owner can resolve or delete their own report; active reports appear on the community map.
- `pet_adoption_listings/{listingId}`: authenticated pet adoption listings with location, an explicitly shared contact phone, and zero to three optional photo URLs. Active listings appear on the community map; the owner can close or delete their own listing.
- `pet_adoption_listings/{uid}/{listingId}/{photoIndex}` in Cloud Storage: up to three adoption listing photos, readable by authenticated users while the listing is active and writable only by the listing owner.
- `explore_highlights/{highlightId}`: shared active Explore carousel cards containing a title, subtitle, HTTPS image/action URLs, icon key, display order, creator UID, active state, and timestamps. Signed-in users can read active cards; create, update, and delete require the Firebase Auth `admin: true` custom claim.

The Explore manager is shown only when the signed-in user's refreshed token has
the `admin: true` custom claim. A project administrator can grant or revoke it
with `node scripts/set_explore_admin_claim.cjs <firebase-auth-uid> grant|revoke`
after configuring Google Application Default Credentials with Firebase Auth
Admin permission. The mobile app cannot grant this claim to itself.

- `users/{uid}`: private profile, consent and quota metadata.
- `users/{uid}/saved_routes`: saved routes.
- `users/{uid}/saved_addresses`: saved addresses.
- `users/{uid}/driving_history`: driving history.
- `users/{uid}/route_history`: completed route history.
- `users/{uid}/sos_contacts`: emergency contacts.
- `users/{uid}/sos_alerts`: SOS records.
- `users/{uid}/point_ledger`: points transactions.
- `users/{uid}/ai_chats`: AI conversation history.
- `road_reports/{reportId}`: expiring shared road reports with community
	confirmation and incorrect-report counters.
- `road_reports/{reportId}/feedback/{uid}`: one immutable `confirmed` or
	`incorrect` vote per authenticated user, atomically paired with the matching
	parent counter increment.
- `community_places/{placeId}`: user-submitted map locations with a bounded
	name, category, optional description/address/photo URL, coordinates and owner UID.
- `chat_room_listings/{roomId}`: authenticated, non-sensitive room discovery data.
- `chat_rooms/{roomId}`: private room metadata and member UID list; no password or messages.
- `chat_rooms/{roomId}/members/{uid}`: member proof, readable only by that member or the owner.
- `chat_rooms/{roomId}/messages/{messageId}`: append-only room messages.
- `chat_rooms/{roomId}/private/access`: owner-readable salted password verifier.
- `public_chat_messages/{messageId}`: public authenticated chat messages.
- `chat_message_reports/{reportId}`: moderation reports.

The rules require authentication for shared data and restrict private paths to
the matching user UID or room membership. `chat_room_listings` must not contain
password verifiers, message history, email addresses, or phone numbers. Password
rooms publish only a random salt; the verifier stays in the owner-only access
document and membership creation must match it in the rules.

Legacy `chat_rooms` documents currently contain plaintext `password` and an
embedded `messages` array. They must be migrated before deploying rules that
deny reads of legacy room contents. Room discovery queries use
`chat_room_listings.orderBy(created_at)`; public chat and road report queries
remain authenticated and limited to the latest 80 and 100 records respectively.

Road reports expire within 24 hours. Authenticated users can record one
immutable `confirmed` or `incorrect` vote per report; vote creation and the
matching report counter increment must happen atomically. Report authors cannot
vote on their own reports.

User profile fields editable by the client are limited to identity/contact,
consent, biography, gender preference, and vehicle preferences. `is_pro`, `plan`,
reward points, and quota counters are server-owned and must not be client-writable.
For the current prototype, daily quotas and point balances are local convenience
state only and are not abuse-resistant or synchronized between devices.
