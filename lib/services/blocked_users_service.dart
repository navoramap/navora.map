import 'package:cloud_firestore/cloud_firestore.dart';

class BlockedUser {
  final String uid;
  final String displayName;

  const BlockedUser({required this.uid, required this.displayName});
}

class BlockedUsersService {
  final FirebaseFirestore _firestore;

  BlockedUsersService({FirebaseFirestore? firestore})
    : _firestore = firestore ?? FirebaseFirestore.instance;

  CollectionReference<Map<String, dynamic>> _collection(String uid) {
    return _firestore.collection('users').doc(uid).collection('blocked_users');
  }

  Stream<List<BlockedUser>> watchBlockedUsers(String uid) {
    return _collection(uid).snapshots().map(
      (snapshot) => snapshot.docs
          .map(
            (document) => BlockedUser(
              uid: document.id,
              displayName:
                  document.data()['display_name']?.toString() ?? 'Kullanıcı',
            ),
          )
          .toList(),
    );
  }

  Future<void> blockUser({
    required String uid,
    required String blockedUid,
    required String displayName,
  }) async {
    if (uid.isEmpty || blockedUid.isEmpty || uid == blockedUid) {
      throw ArgumentError('Geçersiz kullanıcı engelleme isteği.');
    }
    final normalizedName = displayName.trim();
    final safeName = normalizedName.isEmpty
        ? 'Kullanıcı'
        : normalizedName.substring(
            0,
            normalizedName.length > 120 ? 120 : normalizedName.length,
          );

    await _collection(uid).doc(blockedUid).set({
      'display_name': safeName,
      'blocked_at': FieldValue.serverTimestamp(),
    });
  }

  Future<void> unblockUser({
    required String uid,
    required String blockedUid,
  }) async {
    if (uid.isEmpty || blockedUid.isEmpty || uid == blockedUid) {
      throw ArgumentError('Geçersiz kullanıcı engelini kaldırma isteği.');
    }
    await _collection(uid).doc(blockedUid).delete();
  }
}
