import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

class MyPropertyListingsPage extends StatefulWidget {
  final Widget Function(Map<String, dynamic>) listingBuilder;
  final VoidCallback onCreateListing;
  final Future<void> Function(Map<String, dynamic>) onClosePetListing;

  const MyPropertyListingsPage({
    super.key,
    required this.listingBuilder,
    required this.onCreateListing,
    required this.onClosePetListing,
  });

  @override
  State<MyPropertyListingsPage> createState() => _MyPropertyListingsPageState();
}

class _MyPropertyListingsPageState extends State<MyPropertyListingsPage> {
  late Future<List<Map<String, dynamic>>> _listingsFuture;

  @override
  void initState() {
    super.initState();
    _loadListings();
  }

  void _loadListings() {
    final user = FirebaseAuth.instance.currentUser;
    _listingsFuture = user == null
        ? Future.value(const [])
        : Future.wait([
            _loadCollection('property_listings', user.uid),
            _loadCollection('lost_pet_reports', user.uid),
            _loadCollection('pet_adoption_listings', user.uid),
          ]).then((collections) {
            final listings = collections.expand((items) => items).toList();
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
            return listings;
          });
  }

  Future<List<Map<String, dynamic>>> _loadCollection(
    String collection,
    String userId,
  ) async {
    final snapshot = await FirebaseFirestore.instance
        .collection(collection)
        .where('owner_uid', isEqualTo: userId)
        .limit(50)
        .get();
    return snapshot.docs
        .map(
          (document) => <String, dynamic>{
            ...document.data(),
            'id': document.id,
            'listing_collection': collection,
          },
        )
        .toList();
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
          : FutureBuilder<List<Map<String, dynamic>>>(
              future: _listingsFuture,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return const Center(
                    child: Text(
                      'İlanlar yüklenemedi. Daha sonra tekrar deneyin.',
                      style: TextStyle(color: Color(0xFFB8B8B8)),
                    ),
                  );
                }
                if (!snapshot.hasData) {
                  return const Center(
                    child: CircularProgressIndicator(color: Color(0xFFFF7A00)),
                  );
                }

                final listings = snapshot.data!;

                if (listings.isEmpty) {
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

                return ListView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
                  children: [
                    Text(
                      '${listings.length} ilan',
                      style: const TextStyle(
                        color: Color(0xFFB8B8B8),
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 12),
                    ...listings.map((listing) {
                      return Column(
                        children: [
                          widget.listingBuilder(listing),
                          if (listing['listing_collection'] !=
                                  'property_listings' &&
                              listing['status'] == 'active')
                            Align(
                              alignment: Alignment.centerRight,
                              child: TextButton.icon(
                                onPressed: () async {
                                  await widget.onClosePetListing(listing);
                                  if (mounted) {
                                    setState(_loadListings);
                                  }
                                },
                                icon: const Icon(
                                  Icons.check_circle_outline_rounded,
                                  size: 18,
                                ),
                                label: const Text('İlanı kapat'),
                                style: TextButton.styleFrom(
                                  foregroundColor: const Color(0xFFFFA052),
                                ),
                              ),
                            ),
                        ],
                      );
                    }),
                  ],
                );
              },
            ),
    );
  }
}
