import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

class _ListingCollectionResult {
  final List<Map<String, dynamic>> listings;
  final String? error;

  const _ListingCollectionResult({required this.listings, this.error});
}

class _ListingsLoadResult {
  final List<Map<String, dynamic>> listings;
  final List<String> failedCollections;

  const _ListingsLoadResult({
    required this.listings,
    required this.failedCollections,
  });
}

class MyPropertyListingsPage extends StatefulWidget {
  final Widget Function(Map<String, dynamic>, VoidCallback) listingBuilder;
  final VoidCallback onCreateListing;

  const MyPropertyListingsPage({
    super.key,
    required this.listingBuilder,
    required this.onCreateListing,
  });

  @override
  State<MyPropertyListingsPage> createState() => _MyPropertyListingsPageState();
}

class _MyPropertyListingsPageState extends State<MyPropertyListingsPage> {
  static const _listingFilters = [
    ('all', 'Tümü'),
    ('rental', 'Kiralık'),
    ('sale', 'Satılık'),
    ('lost_pet', 'Kayıp'),
    ('adoption', 'Sahiplendirme'),
    ('community_place', 'Mekânlar'),
  ];

  late Future<_ListingsLoadResult> _listingsFuture;
  String _selectedFilter = 'all';

  @override
  void initState() {
    super.initState();
    _loadListings();
  }

  void _loadListings() {
    final user = FirebaseAuth.instance.currentUser;
    _listingsFuture = user == null
        ? Future.value(
            const _ListingsLoadResult(listings: [], failedCollections: []),
          )
        : _loadListingsForUser(user.uid);
  }

  Future<_ListingsLoadResult> _loadListingsForUser(String userId) async {
    const collections = [
      'property_listings',
      'lost_pet_reports',
      'pet_adoption_listings',
      'community_places',
    ];
    final results = await Future.wait(
      collections.map(
        (collection) => _loadCollectionSafely(collection, userId),
      ),
    );
    final listings = results.expand((result) => result.listings).toList();
    listings.sort((left, right) {
      final leftDate = left['created_at'];
      final rightDate = right['created_at'];
      final leftMillis = leftDate is Timestamp
          ? leftDate.millisecondsSinceEpoch
          : 0;
      final rightMillis = rightDate is Timestamp
          ? rightDate.millisecondsSinceEpoch
          : 0;
      return rightMillis.compareTo(leftMillis);
    });
    return _ListingsLoadResult(
      listings: listings,
      failedCollections: [
        for (var index = 0; index < results.length; index++)
          if (results[index].error != null) collections[index],
      ],
    );
  }

  Future<_ListingCollectionResult> _loadCollectionSafely(
    String collection,
    String userId,
  ) async {
    try {
      return _ListingCollectionResult(
        listings: await _loadCollection(collection, userId),
      );
    } catch (error, stackTrace) {
      debugPrint('İlanlar yüklenemedi ($collection): $error\n$stackTrace');
      return _ListingCollectionResult(listings: const [], error: '$error');
    }
  }

  Future<List<Map<String, dynamic>>> _loadCollection(
    String collection,
    String userId,
  ) async {
    final QuerySnapshot<Map<String, dynamic>> snapshot;
    try {
      snapshot = await FirebaseFirestore.instance
          .collection(collection)
          .where('owner_uid', isEqualTo: userId)
          .limit(50)
          .get();
    } catch (error) {
      debugPrint('İlanlar yüklenemedi ($collection): $error');
      rethrow;
    }
    return Future.wait(
      snapshot.docs.map((document) async {
        int? viewCount;
        if (collection != 'property_listings' &&
            collection != 'community_places') {
          try {
            final count = await document.reference
                .collection('_views')
                .count()
                .get();
            viewCount = count.count;
          } catch (error) {
            debugPrint(
              'İlan görüntülenme sayısı alınamadı '
              '(${document.reference.path}): $error',
            );
          }
        }
        return <String, dynamic>{
          ...document.data(),
          'id': document.id,
          'listing_collection': collection,
          if (collection != 'property_listings' &&
              collection != 'community_places')
            'view_count': viewCount,
        };
      }),
    );
  }

  bool _matchesFilter(Map<String, dynamic> listing) {
    final collection = listing['listing_collection'];
    return switch (_selectedFilter) {
      'rental' =>
        collection == 'property_listings' &&
            listing['listing_type'] == 'kiralik',
      'sale' =>
        collection == 'property_listings' &&
            listing['listing_type'] == 'satilik',
      'lost_pet' => collection == 'lost_pet_reports',
      'adoption' => collection == 'pet_adoption_listings',
      'community_place' => collection == 'community_places',
      _ => true,
    };
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;

    return Scaffold(
      backgroundColor: const Color(0xFF111111),
      appBar: AppBar(
        backgroundColor: const Color(0xFF111111),
        foregroundColor: Colors.white,
        title: const Text('İlanlarım'),
      ),
      body: user == null
          ? const Center(
              child: Text(
                'İlanlarını görmek için giriş yapmalısın.',
                style: TextStyle(color: Color(0xFFB8B8B8)),
              ),
            )
          : FutureBuilder<_ListingsLoadResult>(
              future: _listingsFuture,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  debugPrint('İlan listesi yükleme hatası: ${snapshot.error}');
                  return Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text(
                          'İlanlar yüklenemedi. Bağlantını kontrol edip tekrar dene.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Color(0xFFB8B8B8)),
                        ),
                        const SizedBox(height: 12),
                        TextButton(
                          onPressed: () => setState(_loadListings),
                          child: const Text('Tekrar dene'),
                        ),
                      ],
                    ),
                  );
                }
                if (!snapshot.hasData) {
                  return const Center(
                    child: CircularProgressIndicator(color: Color(0xFFFF7A00)),
                  );
                }

                final result = snapshot.data!;
                final listings = result.listings;

                if (listings.isEmpty && result.failedCollections.isEmpty) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(28),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.home_work_outlined,
                            size: 42,
                            color: Color(0xFFFF9A3D),
                          ),
                          const SizedBox(height: 12),
                          const Text(
                            'Henüz bir ilanınız yok.',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 14),
                          FilledButton.icon(
                            onPressed: widget.onCreateListing,
                            icon: const Icon(Icons.add_home_work_rounded),
                            label: const Text('İlan ver'),
                            style: FilledButton.styleFrom(
                              backgroundColor: const Color(0xFFFF7A00),
                              foregroundColor: Colors.white,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                }

                final filteredListings = listings
                    .where(_matchesFilter)
                    .toList();
                final relevantFailedCollections = result.failedCollections
                    .where((collection) {
                      return switch (_selectedFilter) {
                        'rental' || 'sale' => collection == 'property_listings',
                        'lost_pet' => collection == 'lost_pet_reports',
                        'adoption' => collection == 'pet_adoption_listings',
                        'community_place' => collection == 'community_places',
                        _ => true,
                      };
                    })
                    .toList();

                return ListView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
                  children: [
                    if (relevantFailedCollections.isNotEmpty)
                      _buildLoadWarning(relevantFailedCollections),
                    Text(
                      '${filteredListings.length} '
                      '${_selectedFilter == 'community_place' ? 'mekân' : 'ilan'}',
                      style: const TextStyle(
                        color: Color(0xFFB8B8B8),
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: _listingFilters.map((filter) {
                        final isSelected = _selectedFilter == filter.$1;
                        return ChoiceChip(
                          label: Text(filter.$2),
                          selected: isSelected,
                          onSelected: (_) {
                            setState(() => _selectedFilter = filter.$1);
                          },
                          selectedColor: const Color(0xFFFF7A00),
                          backgroundColor: const Color(0xFF191919),
                          labelStyle: TextStyle(
                            color: isSelected
                                ? Colors.white
                                : const Color(0xFFB8B8B8),
                            fontWeight: FontWeight.w700,
                          ),
                          side: BorderSide(
                            color: isSelected
                                ? const Color(0xFFFF7A00)
                                : const Color(0xFF383838),
                          ),
                          showCheckmark: false,
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 12),
                    if (filteredListings.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 36),
                        child: Center(
                          child: Text(
                            'Bu kategoride henüz ilanınız yok.',
                            style: const TextStyle(
                              color: Color(0xFFB8B8B8),
                              fontSize: 14,
                            ),
                          ),
                        ),
                      ),
                    ...filteredListings.map((listing) {
                      return widget.listingBuilder(listing, () {
                        if (mounted) setState(_loadListings);
                      });
                    }),
                  ],
                );
              },
            ),
    );
  }

  Widget _buildLoadWarning(List<String> failedCollections) {
    final failedNames = failedCollections
        .map((collection) {
          return switch (collection) {
            'property_listings' => 'konut',
            'lost_pet_reports' => 'kayıp hayvan',
            'pet_adoption_listings' => 'sahiplendirme',
            'community_places' => 'topluluk mekânı',
            _ => 'ilan',
          };
        })
        .join(', ');
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF3A2D1B),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFFFC266)),
      ),
      child: Row(
        children: [
          const Icon(Icons.warning_amber_rounded, color: Color(0xFFFFC266)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '$failedNames ilanları yüklenemedi. Diğer ilanlar gösteriliyor.',
              style: const TextStyle(color: Color(0xFFFFD89A), fontSize: 12),
            ),
          ),
          TextButton(
            onPressed: () => setState(_loadListings),
            child: const Text('Yenile'),
          ),
        ],
      ),
    );
  }
}
