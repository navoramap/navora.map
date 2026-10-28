# Firestore data model

This document records the client-side Firestore paths used by Navora Map.

- `property_listings/{listingId}`: user-owned rental/sale submissions with full public address, exact geocoded coordinates, up to five photo URLs, and a server-maintained unique `view_count`. Owners create `pending_review` documents; admins can change only the status of a pending listing to `active` or `rejected` under Firestore rules. Owners can edit rejected listings to send them back for review; owner deletion runs through a cleanup callable.
- `property_listings/{listingId}/_views/{viewerUid}`: private unique-view records written by the `recordPropertyListingView` callable; clients cannot read or write this subcollection.
- `property_listings/{uid}/{listingId}/{photoIndex}` in Cloud Storage: listing photos, with five fixed slots per pending listing; only the listing owner can upload, and active photos are readable by authenticated users.
- `lost_pet_reports/{reportId}`: authenticated lost/found pet reports with last-seen address/coordinates, time, an explicitly shared contact phone, and zero to three optional photo URLs. The owner can resolve or delete their own report; active reports appear on the community map.
- `pet_adoption_listings/{listingId}`: authenticated pet adoption listings with location, an explicitly shared contact phone, and zero to three optional photo URLs. Active listings appear on the community map; the owner can close or delete their own listing.
- `pet_adoption_listings/{uid}/{listingId}/{photoIndex}` in Cloud Storage: up to three adoption listing photos, readable by authenticated users while the listing is active and writable only by the listing owner.
- `explore_highlights/{highlightId}`: shared active Explore carousel cards containing a title, subtitle, HTTPS image/action URLs, icon key, display order, creator UID, active state, and timestamps. Signed-in users can read active cards; create, update, and delete require the Firebase Auth `admin: true` custom claim.

The Explore manager and property review page are shown only when the signed-in
user's refreshed token has the `admin: true` custom claim. A project
administrator can grant or revoke it with
`node scripts/set_admin_claim.cjs <firebase-auth-uid> grant|revoke` after
configuring Google Application Default Credentials with Firebase Auth Admin
permission. The mobile app cannot grant this claim to itself. Property
approval/rejection is enforced by Firestore rules: only admins can transition
pending listings, and they may change only the status and update timestamp.
Chat admins can create rooms without daily quota, join protected rooms without
their password (including one additional member slot when a room is full), clear
general chat messages, and delete any chat room, including its messages,
members, password document, and discovery listing.
Room admission runs through the App Check-enforced `joinChatRoom` callable. It
verifies protected-room hashes server-side, updates membership and discovery
counts atomically, and locks an account out of a room for 15 minutes after five
failed password attempts in a 15-minute window.

Public and room chat messages are created through the `sendChatMessage`
callable, which enforces one message per three seconds and ten messages per
minute across both chat types. Message-create triggers apply the same policy to
direct writes during the staged rules rollout and remove messages from users
with an active administrator mute. Chat-report review, one-hour mutes and
administrator action-history reads are server-side callables; action records
expire after 90 days.

- `users/{uid}`: private profile, consent and quota metadata.
- `users/{uid}/saved_routes`: saved routes.
- `users/{uid}/saved_addresses`: saved addresses.
- `users/{uid}/driving_history`: driving history.
- `users/{uid}/route_history`: completed route history.
- `users/{uid}/sos_contacts`: emergency contacts.
- `users/{uid}/sos_alerts`: SOS records.
- `users/{uid}/point_ledger`: versioned, append-only points transactions; only Cloud Functions may write.
- `users/{uid}/daily_usage/{yyyy-MM-dd}`: server-maintained room, AI and daily points counters. Signed-in clients can read but cannot write.
- `users/{uid}/quota_reservations/{reservationId}`: short-lived, server-created quota reservations for room creation and AI requests; clients cannot read or write.
- `users/{uid}/room_join_attempts/{roomId}`: server-managed, unreadable protected-room password failure counters and temporary lock state.
- `chat_message_rate_limits/{uid}`: server-managed shared public/room chat rate-limit state.
- `chat_user_moderation/{uid}`: server-managed temporary chat mute state.
- `chat_admin_actions/{actionId}`: server-managed moderation audit records with no copied message text; retained for 90 days.
- `chat_message_moderation_events/{eventId}`: short-lived server-managed idempotency records for message moderation triggers.
- `users/{uid}/ai_chats`: AI conversation history.
- `community_places/{placeId}`: user-submitted map locations with a bounded
	name, category, optional description/address/photo URL, coordinates and owner UID.
- `chat_room_listings/{roomId}`: authenticated, non-sensitive room discovery data.
- `chat_rooms/{roomId}`: private room metadata and member UID list; no password or messages.
- `chat_rooms/{roomId}/members/{uid}`: member proof, readable only by that member or the owner.
- `chat_message_reports/{reportId}`: validated chat-message reports. Only admins can read the open queue; report actions run through server callables.
- `chat_rooms/{roomId}/messages/{messageId}`: append-only room messages created through the moderation callable.
- `chat_rooms/{roomId}/private/access`: owner-readable salted password verifier.
- `public_chat_messages/{messageId}`: authenticated public chat messages created through the moderation callable.
- `chat_message_reports/{reportId}`: moderation reports.

The rules require authentication for shared data and restrict private paths to
the matching user UID or room membership. `chat_room_listings` must not contain
password verifiers, message history, email addresses, or phone numbers. Password
rooms publish only a random salt; the verifier stays in the owner-only access
document and only the trusted room-join callable may add non-owner members.

Legacy `chat_rooms` documents currently contain plaintext `password` and an
embedded `messages` array. They must be migrated before deploying rules that
deny reads of legacy room contents. Room discovery queries use
`chat_room_listings.orderBy(created_at)`; public chat queries remain
authenticated and limited to the latest 80 records.

Signed-in room creation and Navora AI requests reserve daily quota through
Cloud Functions in `europe-west1`; a room write requires its server-created
reservation. Point balances, redeemed benefits and the append-only point ledger
are server-managed. Completed-drive history earns idempotent points through
Firestore triggers, capped at 100 points per Istanbul calendar day. City-visit
points are inactive until a server-verifiable location proof is available.
The Firebase Storage bucket `navoramapa.firebasestorage.app` is in
`europe-west1`, with access controlled by `storage.rules`.

User profile fields editable by the client are limited to identity/contact,
consent, biography, gender preference, and vehicle preferences. `is_pro`, `plan`,
reward points, reward entitlements, and quota counters are server-owned and
must not be client-writable. Points with `points_version: 1` are trusted; older
local balances and unversioned ledger entries are deliberately ignored. Pro
quota limits require a trusted Firebase Auth `pro` custom claim; legacy profile
flags are not used to grant Pro access.
