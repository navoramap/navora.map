import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:image_picker/image_picker.dart';

class PropertyListingService {
  static const int maxPhotoBytes = 5 * 1024 * 1024;
  static const int maxPhotos = 5;

  Future<void> submit({
    required String listingType,
    required String title,
    required int price,
    required String city,
    required String district,
    required String address,
    required int areaSquareMeters,
    required String rooms,
    required String description,
    required double latitude,
    required double longitude,
    required List<XFile> photos,
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) throw StateError('İlan göndermek için giriş yapmalısın.');
    if (listingType != 'kiralik' && listingType != 'satilik') {
      throw ArgumentError.value(listingType, 'listingType');
    }
    if (photos.isEmpty || photos.length > maxPhotos) {
      throw StateError('Bir ile beş arasında fotoğraf eklemelisin.');
    }
    if (latitude < -90 ||
        latitude > 90 ||
        longitude < -180 ||
        longitude > 180) {
      throw ArgumentError('Geçerli bir konum seçilemedi.');
    }

    final listingReference = FirebaseFirestore.instance
        .collection('property_listings')
        .doc();
    final listingId = listingReference.id;
    final uploadedReferences = <Reference>[];

    await listingReference.set({
      'owner_uid': user.uid,
      'listing_type': listingType,
      'title': title.trim(),
      'price': price,
      'currency': 'TRY',
      'city': city.trim(),
      'district': district.trim(),
      'address': address.trim(),
      'latitude': latitude,
      'longitude': longitude,
      'area_sqm': areaSquareMeters,
      'rooms': rooms,
      'description': description.trim(),
      'photo_urls': <String>[],
      'cover_image_url': '',
      'status': 'pending_review',
      'created_at': FieldValue.serverTimestamp(),
      'updated_at': FieldValue.serverTimestamp(),
    });

    try {
      final imageUrls = <String>[];
      for (var index = 0; index < photos.length; index++) {
        final photo = photos[index];
        final extension = photo.name.split('.').last.toLowerCase();
        final contentType = switch (extension) {
          'jpg' || 'jpeg' => 'image/jpeg',
          'png' => 'image/png',
          'webp' => 'image/webp',
          _ => throw StateError('JPG, PNG veya WebP fotoğraf seçmelisin.'),
        };
        final bytes = await photo.readAsBytes();
        if (bytes.isEmpty || bytes.length > maxPhotoBytes) {
          throw StateError('Fotoğraflar 5 MB veya daha küçük olmalı.');
        }

        final reference = FirebaseStorage.instance.ref().child(
          'property_listings/${user.uid}/$listingId/$index',
        );
        uploadedReferences.add(reference);
        await reference.putData(
          bytes,
          SettableMetadata(contentType: contentType),
        );
        imageUrls.add(await reference.getDownloadURL());
      }

      await listingReference.update({
        'photo_urls': imageUrls,
        'cover_image_url': imageUrls.first,
        'updated_at': FieldValue.serverTimestamp(),
      });
    } catch (_) {
      for (final reference in uploadedReferences) {
        try {
          await reference.delete();
        } catch (_) {
          // Keep cleaning up other uploaded files if one delete fails.
        }
      }
      try {
        await listingReference.delete();
      } catch (_) {
        // The pending document can be removed manually if cleanup is denied.
      }
      rethrow;
    }
  }
}
