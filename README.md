# Navora Map

Flutter app for maps, route planning, live room chat, road reports, driving history, and Navora AI.

## Local Development

Requirements: Flutter/Dart from `pubspec.yaml`, Node.js for Firestore rule tests, and Java 17 or newer for the local Firestore emulator. Java 21 is recommended for current Firebase CLI releases.

```powershell
flutter pub get
flutter run
```

The app uses the Firebase project configured in `lib/firebase_options.dart` and the Android/iOS platform configuration files. Restrict Google Maps and Places API keys by app identity and API; do not treat mobile API keys as secrets. Supply optional service keys with Dart defines, for example `--dart-define=GOOGLE_PLACES_API_KEY=...` and `--dart-define=TOMTOM_API_KEY=...`.

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

Room documents and listing documents expire after 24 hours. Firestore TTL can remove expired documents asynchronously, but deleting a parent document does not recursively delete its subcollections. Configure TTL on both `chat_rooms` and `chat_room_listings`, and add a scheduled cleanup for each expired room's `messages`, `members`, and `private` subcollections.

## Important Limitations

- Pro purchase and cancellation are intentionally unavailable until app-store billing and trusted server-side receipt verification are implemented. Client writes cannot grant Pro.
- Daily AI/room quotas and Navora points are currently device-local convenience state. They are not authoritative, do not sync across devices, and must not be used for billing, rewards with monetary value, or abuse prevention. Enforce quotas and point rewards in a trusted backend before launch.
- Protected-room password checks use salted PBKDF2 verifiers, but joining has no server-side attempt throttling. Add a trusted join endpoint/rate limiter before exposing password-protected rooms to abuse.
- Firestore security rules are prototypes. Run the emulator suite, migrate existing data, review the rules, and deploy only after confirming the migration and cleanup jobs in the target project.
- Account deletion with complete cleanup of owned/shared data is not implemented yet.
