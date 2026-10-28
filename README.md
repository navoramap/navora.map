# Navora Map

Flutter app for maps, route planning, live room chat, driving history, and Navora AI.

Map search supports category and distance filters. Up to five recent searches can sync to the signed-in account; search-history saving can be disabled and stored entries can be deleted from the search privacy controls. Voice guidance can be switched on or off during navigation, and the setting is remembered on the device.

## Local Development

Requirements: Flutter/Dart from `pubspec.yaml`, Node.js for Firestore rule tests, and Java 17 or newer for the local Firestore emulator. Java 21 is recommended for current Firebase CLI releases.

```powershell
flutter pub get
flutter run
```

The app uses the Firebase project configured in `lib/firebase_options.dart` and the Android/iOS platform configuration files. Restrict Google Maps, Places, and Routes API keys by app identity and API; do not treat mobile API keys as secrets. Supply optional service keys with Dart defines, for example `--dart-define=GOOGLE_PLACES_API_KEY=...` and `--dart-define=GOOGLE_ROUTES_API_KEY=...`. iOS Places requests can use a separate key restricted to the `com.navora.app` bundle ID via `--dart-define=GOOGLE_PLACES_IOS_API_KEY=...`; include that define when building the iOS app.

## Tests

```powershell
flutter test
npm install
npm run test:migration
npm run test:migration:emulator
npm run test:rules
```

The rules test command runs against a local demo Firestore emulator and does not deploy rules or access the configured production project.

## Firestore Rooms

New rooms use schema version 2:

- `chat_room_listings/{roomId}` contains discovery-safe room metadata only.
- `chat_rooms/{roomId}` contains membership and private room metadata, without plaintext passwords or embedded messages.
- `chat_rooms/{roomId}/private/access` stores the salted PBKDF2 password verifier and is owner-readable only.
- `chat_rooms/{roomId}/members/{uid}` proves membership.
- `chat_rooms/{roomId}/messages/{messageId}` stores append-only message documents.

**Do not deploy the current rules until existing production rooms have been migrated.** Legacy room documents contain plaintext passwords and embedded message arrays. Migrate their metadata, hash each password with a new random salt, copy messages and member records to subcollections, create safe listing documents, verify the result, and only then deploy the rules. Never copy plaintext passwords into the new documents or logs.

The room migration tool defaults to a read-only dry run. It requires an explicit project ID and Application Default Credentials with Firestore read access. Reports contain room IDs, statuses, issue codes, non-sensitive warnings, and write counts; the tool never prints passwords, hashes, messages, or room names. The tool does not create a backup.

```powershell
# Authenticate in a trusted operator environment and make/verify a Firestore backup first.
gcloud auth application-default login

# Preview only.
npm run migrate:rooms -- --project navoramapa

# Apply only after a verified backup and review of the dry-run report.
npm run migrate:rooms -- --project navoramapa --apply --backup-confirmed
```

The apply mode uses one atomic batch per room, skips schema-v2 rooms and rooms with partial target data, and verifies migrated owner, salt, member IDs, message IDs, verifier, and document counts. It blocks expired rooms, short or malformed protected-room passwords, malformed fields/messages, invalid protection/member/location data, and rooms whose migration would exceed Firestore's 500-write batch limit. Blocked rooms need manual review/password reset. The script does not create backups or deploy security rules.

Legacy `is_pro` and `plan` profile values are not trusted because older clients could write them. Treat existing accounts as Standard until a trusted billing backend verifies their subscription; remove or quarantine unverified legacy values before restoring Pro access.

Room documents and listing documents expire after 24 hours. The scheduled `cleanupExpiredChatData` function runs hourly, recursively deleting expired rooms and their `messages`, `members`, and `private` subcollections, plus expired discovery listings. It also deletes general chat messages older than 30 days and user driving/route history after each record's `expires_at`. Deploy the function before relying on these retention periods.

## Account Deletion

The profile's **Hesabımı sil** action calls the `deleteAccount` Firebase callable. It requires recent authentication, recursively removes the user's private profile data, owned listings/reports/chat content, room memberships, and user-scoped Storage files, then deletes the Firebase Auth account. The operation is retryable if cleanup fails partway through.

The backend is deployed in `europe-west1`. The Firebase project uses the Blaze billing plan; monitor Functions, Scheduler, Firestore and Storage usage in Google Cloud Billing.

```powershell
npm ci --prefix functions
npm test --prefix functions
firebase deploy --only functions:deleteAccount --project navoramapa
```

## Chat Moderation

The current client sends public and room messages through `sendChatMessage`, which enforces a shared per-user limit of one message every three seconds and ten messages per minute. Firestore create triggers also check direct writes during the staged migration period, removing messages from muted users or messages over the rate limit. Administrator moderation requires the Firebase Auth `admin: true` custom claim. From the report queue, admins can dismiss a report, delete its message, or mute the author for one hour. Admin actions are recorded without message text and expire after 90 days.

The local Firestore rules deny direct client message creation. Do not deploy those rules until legacy production chat rooms have a verified backup and completed migration; server callables and message triggers are deployed independently of that rules migration.

```powershell
npm test --prefix functions
firebase deploy --only functions:sendChatMessage,functions:reviewChatMessageReport,functions:getChatAdminActions,functions:moderatePublicChatMessage,functions:moderateRoomChatMessage,functions:cleanupExpiredChatData --project navoramapa
```

## Crash Reports and Backups

Android and iOS release builds send fatal Flutter/framework errors to Firebase Crashlytics. Debug builds do not collect reports. Verify Crashlytics is enabled in the Firebase console before release. iOS dSYM symbol upload and physical-device validation require macOS/Xcode.

No scheduled Firestore backup is configured. Production currently has no listed managed Firestore backups. Choose a backup frequency and retention only after reviewing Firestore database size and the resulting storage/operation costs; do not treat data export as a substitute for a verified restorable backup.

## Important Limitations

- Pro purchase and cancellation are intentionally unavailable until app-store billing and trusted server-side receipt verification are implemented. Client writes cannot grant Pro.
- Authenticated room and AI requests reserve quotas through Cloud Functions; room creation also requires a server-issued reservation in Firestore rules. Guest AI usage remains device-local. Pro purchases are unavailable; only a trusted `pro` custom claim can raise server limits.
- Point balances and redemptions are server-managed. Completed GPS drive records award idempotent points, capped at 100 per Istanbul calendar day. Legacy local balances and unversioned ledger entries are intentionally not trusted or migrated. City-visit awards are not active because the app has no server-verifiable location proof.
- Protected-room admission uses an App Check-enforced callable, salted PBKDF2 verifiers, and a per-account/per-room lock after five failed attempts in a 15-minute window. `joinChatRoom` is deployed; verify Play Integrity and Apple App Attest/DeviceCheck registrations and enforcement in Firebase App Check before release.
- General chat reset runs through the `clearPublicChat` callable, which verifies the Firebase Auth `admin: true` custom claim and deletes messages in server-side batches. Deploy the callable before using the updated reset action.
- Public release is blocked until the legal operator name/address and public privacy-policy URL are supplied, the privacy notice and consent flow are legally reviewed, and Google Play Console and Apple Developer accounts are available. The current in-app notice describes implemented data flows but is not a substitute for the published policy or store privacy declarations.
- Pro is deferred; no store products or billing integration are configured. Keep purchases unavailable until product IDs/pricing and trusted receipt verification are ready.
- Firestore and Storage rules currently pass the local emulator suites, and the room migration passes both unit and emulator tests. Production rules must not be deployed until legacy production rooms have a verified backup, migration dry-run review, and completed migration; no production data has been changed by local tests.
- The installed Temurin JDK 17 can run the current emulator tests, but Firebase CLI warns that Java 21 will be required by a future CLI major version. Use JDK 21 for future emulator/toolchain upgrades.
