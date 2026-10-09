import 'package:cloud_firestore/cloud_firestore.dart';

class ExploreHighlight {
  final String id;
  final String title;
  final String subtitle;
  final String imageUrl;
  final String actionUrl;
  final String iconName;
  final int order;
  final bool isActive;

  const ExploreHighlight({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.imageUrl,
    required this.actionUrl,
    required this.iconName,
    required this.order,
    required this.isActive,
  });

  factory ExploreHighlight.fromDocument(
    QueryDocumentSnapshot<Map<String, dynamic>> document,
  ) {
    final data = document.data();
    return ExploreHighlight(
      id: document.id,
      title: data['title']?.toString() ?? '',
      subtitle: data['subtitle']?.toString() ?? '',
      imageUrl: data['image_url']?.toString() ?? '',
      actionUrl: data['action_url']?.toString() ?? '',
      iconName: data['icon_name']?.toString() ?? 'new_releases',
      order: (data['order'] as num?)?.toInt() ?? 0,
      isActive: data['is_active'] == true,
    );
  }
}

class ExploreHighlightService {
  ExploreHighlightService({FirebaseFirestore? firestore})
    : _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _firestore;
  CollectionReference<Map<String, dynamic>> get _highlights =>
      _firestore.collection('explore_highlights');

  Stream<List<ExploreHighlight>> watchActive() {
    return _highlights
        .where('is_active', isEqualTo: true)
        .orderBy('order')
        .snapshots()
        .map(
          (snapshot) => snapshot.docs
              .map(ExploreHighlight.fromDocument)
              .toList(growable: false),
        );
  }

  Stream<List<ExploreHighlight>> watchAll() {
    return _highlights
        .orderBy('order')
        .snapshots()
        .map(
          (snapshot) => snapshot.docs
              .map(ExploreHighlight.fromDocument)
              .toList(growable: false),
        );
  }

  Future<void> create({
    required String ownerUid,
    required String title,
    required String subtitle,
    required String imageUrl,
    required String actionUrl,
    required String iconName,
    required int order,
  }) async {
    final reference = _highlights.doc();
    await reference.set({
      'title': title.trim(),
      'subtitle': subtitle.trim(),
      'image_url': imageUrl.trim(),
      'action_url': actionUrl.trim(),
      'icon_name': iconName,
      'order': order,
      'is_active': true,
      'created_by': ownerUid,
      'created_at': FieldValue.serverTimestamp(),
      'updated_at': FieldValue.serverTimestamp(),
    });
  }

  Future<void> update({
    required String id,
    required String title,
    required String subtitle,
    required String imageUrl,
    required String actionUrl,
    required String iconName,
    required int order,
    required bool isActive,
  }) async {
    await _highlights.doc(id).update({
      'title': title.trim(),
      'subtitle': subtitle.trim(),
      'image_url': imageUrl.trim(),
      'action_url': actionUrl.trim(),
      'icon_name': iconName,
      'order': order,
      'is_active': isActive,
      'updated_at': FieldValue.serverTimestamp(),
    });
  }

  Future<void> delete(String id) => _highlights.doc(id).delete();
}
