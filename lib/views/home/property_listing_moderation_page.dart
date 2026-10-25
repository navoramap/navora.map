import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

class PropertyListingModerationPage extends StatefulWidget {
  const PropertyListingModerationPage({super.key});

  @override
  State<PropertyListingModerationPage> createState() =>
      _PropertyListingModerationPageState();
}

class _PropertyListingModerationPageState
    extends State<PropertyListingModerationPage> {
  final Set<String> _processingListingIds = {};

  String _formatSubmissionDate(dynamic value) {
    final submittedAt = switch (value) {
      Timestamp timestamp => timestamp.toDate().toLocal(),
      DateTime dateTime => dateTime.toLocal(),
      _ => null,
    };
    if (submittedAt == null) return 'Gönderim zamanı bulunamadı';

    String twoDigits(int number) => number.toString().padLeft(2, '0');
    return 'Gönderildi: ${twoDigits(submittedAt.day)}.'
        '${twoDigits(submittedAt.month)}.${submittedAt.year} '
        '${twoDigits(submittedAt.hour)}:${twoDigits(submittedAt.minute)}';
  }

  Future<void> _reviewListing({
    required String listingId,
    required String decision,
  }) async {
    final approving = decision == 'approve';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          approving ? 'İlan yayınlansın mı?' : 'İlan reddedilsin mi?',
        ),
        content: Text(
          approving ? 'Onaylanan ilan diğer kullanıcılara gösterilecek.' : 'İlan sahibi ilanını düzenleyip tekrar incelemeye gönderebilir.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Vazgeç'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: FilledButton.styleFrom(
              backgroundColor: approving
                  ? const Color(0xFFFF7A00)
                  : const Color(0xFFB94D4D),
            ),
            child: Text(approving ? 'Yayınla' : 'Reddet'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _processingListingIds.add(listingId));
    try {
      await FirebaseFirestore.instance
          .collection('property_listings')
          .doc(listingId)
          .update({
            'status': approving ? 'active' : 'rejected',
            'updated_at': FieldValue.serverTimestamp(),
          });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(approving ? 'İlan yayınlandı.' : 'İlan reddedildi.'),
        ),
      );
    } on FirebaseException catch (error) {
      debugPrint('İlan incelenemedi (${error.code}): ${error.message}');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              error.code == 'permission-denied'
                  ? 'Bu ilan artık inceleme beklemiyor.'
                  : 'İşlem başarısız oldu. Daha sonra tekrar deneyin.',
            ),
          ),
        );
      }
    } catch (error) {
      debugPrint('İlan inceleme işlemi başarısız: $error');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('İşlem başarısız oldu. Daha sonra tekrar deneyin.'),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _processingListingIds.remove(listingId));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF111111),
      appBar: AppBar(
        backgroundColor: const Color(0xFF111111),
        foregroundColor: Colors.white,
        title: const Text('İlan inceleme'),
      ),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance
            .collection('property_listings')
            .where('status', isEqualTo: 'pending_review')
            .limit(50)
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            debugPrint('İnceleme ilanları alınamadı: ${snapshot.error}');
            return const Center(
              child: Text(
                'İlanlar yüklenemedi. Yönetici yetkini ve bağlantını kontrol et.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Color(0xFFB8B8B8)),
              ),
            );
          }
          if (!snapshot.hasData) {
            return const Center(
              child: CircularProgressIndicator(color: Color(0xFFFF7A00)),
            );
          }

          final listings = snapshot.data!.docs.toList()
            ..sort((left, right) {
              final leftDate = left.data()['created_at'];
              final rightDate = right.data()['created_at'];
              final leftMillis = leftDate is Timestamp
                  ? leftDate.millisecondsSinceEpoch
                  : 0;
              final rightMillis = rightDate is Timestamp
                  ? rightDate.millisecondsSinceEpoch
                  : 0;
              return leftMillis.compareTo(rightMillis);
            });

          if (listings.isEmpty) {
            return const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.fact_check_outlined,
                    color: Color(0xFFFF9A3D),
                    size: 44,
                  ),
                  SizedBox(height: 12),
                  Text(
                    'İnceleme bekleyen ilan yok.',
                    style: TextStyle(color: Colors.white70),
                  ),
                ],
              ),
            );
          }

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                '${listings.length} ilan inceleme bekliyor'
                '${listings.length == 50 ? ' (en fazla 50 gösteriliyor)' : ''}',
                style: const TextStyle(
                  color: Color(0xFFB8B8B8),
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 12),
              ...listings.map((document) {
                final listing = document.data();
                final photoUrls =
                    (listing['photo_urls'] as List<dynamic>?)
                        ?.whereType<String>()
                        .toList() ??
                    const <String>[];
                final coverUrl = listing['cover_image_url']?.toString() ?? '';
                final images = [...photoUrls];
                if (coverUrl.isNotEmpty && !images.contains(coverUrl)) {
                  images.insert(0, coverUrl);
                }
                final processing = _processingListingIds.contains(document.id);

                return Card(
                  color: const Color(0xFF191919),
                  margin: const EdgeInsets.only(bottom: 14),
                  shape: RoundedRectangleBorder(
                    side: const BorderSide(color: Color(0xFF303030)),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (images.isNotEmpty)
                          ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            child: SizedBox(
                              height: 190,
                              child: PageView(
                                children: images
                                    .map(
                                      (imageUrl) => Image.network(
                                        imageUrl,
                                        width: double.infinity,
                                        fit: BoxFit.cover,
                                        errorBuilder:
                                            (context, error, stackTrace) =>
                                                const Center(
                                                  child: Icon(
                                                    Icons.broken_image_outlined,
                                                    color: Color(0xFFB8B8B8),
                                                  ),
                                                ),
                                      ),
                                    )
                                    .toList(),
                              ),
                            ),
                          ),
                        const SizedBox(height: 12),
                        Text(
                          listing['title']?.toString() ?? 'Konut ilanı',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 17,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '${listing['listing_type'] == 'kiralik' ? 'Kiralık' : 'Satılık'}'
                          ' • ${listing['price'] ?? 0} ${listing['currency'] ?? 'TRY'}'
                          ' • ${listing['area_sqm'] ?? '-'} m²'
                          ' • ${listing['rooms'] ?? '-'}',
                          style: const TextStyle(color: Color(0xFFFFA052)),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '${listing['address'] ?? ''}, '
                          '${listing['district'] ?? ''}, ${listing['city'] ?? ''}',
                          style: const TextStyle(color: Color(0xFFB8B8B8)),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          listing['description']?.toString() ?? '',
                          style: const TextStyle(color: Colors.white70),
                        ),
                        if (images.length > 1) ...[
                          const SizedBox(height: 8),
                          Text(
                            '${images.length} fotoğraf • görmek için kaydır',
                            style: const TextStyle(
                              color: Color(0xFFB8B8B8),
                              fontSize: 12,
                            ),
                          ),
                        ],
                        const SizedBox(height: 12),
                        Text(
                          'İlan sahibi UID: ${listing['owner_uid'] ?? '-'}',
                          style: const TextStyle(
                            color: Color(0xFF858585),
                            fontSize: 11,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            const Icon(
                              Icons.schedule_rounded,
                              color: Color(0xFFB8B8B8),
                              size: 15,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              _formatSubmissionDate(listing['created_at']),
                              style: const TextStyle(
                                color: Color(0xFFB8B8B8),
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton(
                                onPressed: processing
                                    ? null
                                    : () => _reviewListing(
                                        listingId: document.id,
                                        decision: 'reject',
                                      ),
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: const Color(0xFFFF8A80),
                                  side: const BorderSide(
                                    color: Color(0xFFB94D4D),
                                  ),
                                ),
                                child: const Text('Reddet'),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: FilledButton(
                                onPressed: processing
                                    ? null
                                    : () => _reviewListing(
                                        listingId: document.id,
                                        decision: 'approve',
                                      ),
                                style: FilledButton.styleFrom(
                                  backgroundColor: const Color(0xFFFF7A00),
                                  foregroundColor: Colors.white,
                                ),
                                child: processing
                                    ? const SizedBox(
                                        width: 18,
                                        height: 18,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: Colors.white,
                                        ),
                                      )
                                    : const Text('Onayla ve yayınla'),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              }),
            ],
          );
        },
      ),
    );
  }
}
