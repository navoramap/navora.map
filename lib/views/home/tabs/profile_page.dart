import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../../main.dart';

class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  final List<Map<String, String>> _savedRoutes = [];
  final List<Map<String, String>> _savedLocations = [];
  final List<Map<String, String>> _drivingHistory = [];
  bool _isDeletingAccount = false;

  @override
  void initState() {
    super.initState();
    _loadProfileData();
  }

  Future<void> _loadProfileData() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    try {
      final userReference = FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid);
      final routeSnapshot = await userReference
          .collection('saved_routes')
          .orderBy('created_at', descending: true)
          .limit(4)
          .get();
      final historySnapshot = await userReference
          .collection('driving_history')
          .orderBy('completed_at', descending: true)
          .limit(3)
          .get();
      final locationSnapshot = await userReference
          .collection('saved_addresses')
          .limit(4)
          .get();

      final routes = routeSnapshot.docs.map((document) {
        final data = document.data();
        final destination = data['destination']?.toString();
        final distance = data['distance_km']?.toString() ?? '0';
        return <String, String>{
          'title': data['title']?.toString() ?? 'Kayıtlı rota',
          'detail': destination == null || destination.isEmpty
              ? 'Kayıtlı rota'
              : '$distance km • $destination',
        };
      }).toList();
      final history = historySnapshot.docs.map((document) {
        final data = document.data();
        return <String, String>{
          'title': data['route']?.toString() ?? 'Rota',
          'detail':
              '${data['distance_km'] ?? 0} km • '
              '${data['duration_minutes'] ?? 0} dk • '
              'Skor ${data['score'] ?? 0}',
        };
      }).toList();
      final locations = locationSnapshot.docs.map((document) {
        final data = document.data();
        return <String, String>{
          'title': data['title']?.toString() ?? 'Kayıtlı konum',
          'detail': data['address']?.toString() ?? 'Konum bilgisi yok',
        };
      }).toList();

      if (!mounted) return;
      setState(() {
        _savedRoutes
          ..clear()
          ..addAll(routes);
        _savedLocations
          ..clear()
          ..addAll(locations);
        _drivingHistory
          ..clear()
          ..addAll(history);
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _savedRoutes.clear();
        _savedLocations.clear();
        _drivingHistory.clear();
      });
    }
  }

  Future<void> _deleteAccount() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Hesap kalıcı olarak silinsin mi?'),
        content: const Text(
          'Profilin, kayıtların, ilanların, mesajların ve hesabına bağlı dosyalar silinecek. Bu işlem geri alınamaz.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Vazgeç'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Hesabımı sil'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;

    setState(() => _isDeletingAccount = true);
    try {
      await FirebaseFunctions.instance
          .httpsCallable('deleteAccount')
          .call<Map<String, dynamic>>();
      await FirebaseAuth.instance.signOut();
      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const MainWrapper()),
        (route) => false,
      );
    } on FirebaseFunctionsException catch (error) {
      if (!mounted) return;
      final message = error.code == 'failed-precondition'
          ? 'Güvenlik için çıkış yapıp tekrar giriş yaptıktan sonra hesabını silebilirsin.'
          : 'Hesap silinemedi. Lütfen tekrar deneyin.';
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Hesap silinemedi. Lütfen tekrar deneyin.'),
        ),
      );
    } finally {
      if (mounted) setState(() => _isDeletingAccount = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentUser = FirebaseAuth.instance.currentUser;
    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final profileStream = currentUser == null
        ? null
        : FirebaseFirestore.instance
              .collection('users')
              .doc(currentUser.uid)
              .snapshots();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Kullanıcı Profili'),
        actions: [
          IconButton(
            tooltip: 'Çıkış yap',
            icon: Icon(Icons.logout, color: colors.error),
            onPressed: () async {
              try {
                await FirebaseAuth.instance.signOut();
                if (!context.mounted) return;
                Navigator.of(context).pushAndRemoveUntil(
                  MaterialPageRoute(builder: (_) => const MainWrapper()),
                  (route) => false,
                );
              } catch (_) {
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Çıkış yapılırken bir hata oluştu.')),
                );
              }
            },
          ),
        ],
      ),
      body: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: profileStream,
        builder: (context, snapshot) {
          if (currentUser != null &&
              snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final userData = snapshot.data?.data() ?? const <String, dynamic>{};
          final userName = userData['display_name'] ?? 'Navora Kaşifi';
          final userEmail =
              userData['email'] ??
              currentUser?.email ??
              'navora.demo@navora.app';
          final userPhoto = userData['photo_url'] as String?;

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: ListTile(
                    leading: CircleAvatar(
                      radius: 28,
                      backgroundColor: colors.primary,
                      backgroundImage: userPhoto != null && userPhoto.isNotEmpty
                          ? NetworkImage(userPhoto)
                          : null,
                      child: userPhoto == null || userPhoto.isEmpty
                          ? Icon(
                              Icons.person,
                              color: colors.onPrimary,
                              size: 30,
                            )
                          : null,
                    ),
                    title: Text(
                      userName.toString(),
                      style: textTheme.titleLarge,
                    ),
                    subtitle: Text(
                      userEmail.toString(),
                      style: textTheme.bodyMedium?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: _buildQuickStatCard(
                      'Toplam Rota',
                      '${_savedRoutes.length}',
                      Icons.route_rounded,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _buildQuickStatCard(
                      'Adres',
                      '${_savedLocations.length}',
                      Icons.location_on_rounded,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _buildQuickStatCard(
                      'Sürüş',
                      '${_drivingHistory.length}',
                      Icons.timeline_rounded,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _buildMembershipCard(context),
              const SizedBox(height: 24),
              OutlinedButton.icon(
                onPressed: _isDeletingAccount ? null : _deleteAccount,
                icon: _isDeletingAccount
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.delete_outline),
                label: Text(
                  _isDeletingAccount ? 'Hesap siliniyor...' : 'Hesabımı sil',
                ),
                style: OutlinedButton.styleFrom(
                  foregroundColor: colors.error,
                  side: BorderSide(color: colors.error),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildQuickStatCard(String label, String value, IconData icon) {
    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: colors.primary, size: 18),
            const SizedBox(height: 10),
            Text(value, style: textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(
              label,
              style: textTheme.labelSmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMembershipCard(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final primaryTextColor = colors.onPrimaryContainer;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.primaryContainer,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: colors.primary.withValues(alpha: 0.55)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: primaryTextColor.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  'Standart',
                  style: textTheme.labelMedium?.copyWith(
                    color: primaryTextColor,
                  ),
                ),
              ),
              const Spacer(),
              Icon(Icons.stars_rounded, color: primaryTextColor, size: 22),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'Üyelik Durumu',
            style: textTheme.labelMedium?.copyWith(
              color: primaryTextColor.withValues(alpha: 0.78),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Standart plan',
            style: textTheme.headlineSmall?.copyWith(color: primaryTextColor),
          ),
          const SizedBox(height: 12),
          Text(
            '• Kayıtlı rota ve adres yönetimi\n'
            '• Temel sürüş analizi\n'
            '• Acil durum kişileri\n'
            '• Premium özellikler satın alma doğrulaması bekliyor',
            style: textTheme.bodyMedium?.copyWith(
              color: primaryTextColor,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: colors.secondaryContainer,
                foregroundColor: colors.onSecondaryContainer,
              ),
              onPressed: () => showDialog<void>(
                context: context,
                builder: (dialogContext) => AlertDialog(
                  title: const Text('Pro üyelik'),
                  content: const Text(
                    'Pro satın alma şu anda etkin değil. Mağaza ürünleri ve '
                    'sunucu doğrulaması tamamlandığında burada açılacak.',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(dialogContext),
                      child: const Text('Kapat'),
                    ),
                  ],
                ),
              ),
              child: const Text('Pro üyelik al'),
            ),
          ),
        ],
      ),
    );
  }
}
