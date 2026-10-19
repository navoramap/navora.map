import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

class MyPropertyListingsPage extends StatelessWidget {
  final Widget Function(Map<String, dynamic>) listingBuilder;
  final VoidCallback onCreateListing;

  const MyPropertyListingsPage({
    super.key,
    required this.listingBuilder,
    required this.onCreateListing,
  });

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
          : StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: FirebaseFirestore.instance
                  .collection('property_listings')
                  .where('owner_uid', isEqualTo: user.uid)
                  .limit(50)
                  .snapshots(),
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
                    child: CircularProgressIndicator(
                      color: Color(0xFFFF7A00),
                    ),
                  );
                }

                final listings = snapshot.data!.docs.map((document) {
                  return <String, dynamic>{...document.data(), 'id': document.id};
                }).toList();
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
                            onPressed: onCreateListing,
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
                    ...listings.map(listingBuilder),
                  ],
                );
              },
            ),
    );
  }
}