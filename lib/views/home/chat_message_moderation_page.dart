import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../services/app_notification_service.dart';

class ChatMessageModerationPage extends StatefulWidget {
  const ChatMessageModerationPage({super.key});

  @override
  State<ChatMessageModerationPage> createState() =>
      _ChatMessageModerationPageState();
}

class _ChatMessageModerationPageState extends State<ChatMessageModerationPage> {
  final Set<String> _processingReports = {};
  int _selectedQueue = 0;

  Future<void> _reviewReport({
    required QueryDocumentSnapshot<Map<String, dynamic>> report,
    required String action,
  }) async {
    final data = report.data();
    final isContentReport = report.reference.parent.id == 'content_reports';
    final messageId = data['message_id']?.toString() ?? '';
    final contentId = data['content_id']?.toString() ?? '';
    if (action == 'delete' &&
        (isContentReport ? contentId.isEmpty : messageId.isEmpty)) {
      return;
    }
    final title = switch (action) {
      'delete' =>
        isContentReport ? 'İçerik silinsin mi?' : 'Mesaj silinsin mi?',
      'mute' => 'Kullanıcı 1 saat susturulsun mu?',
      _ => 'Şikayet kapatılsın mı?',
    };
    final description = switch (action) {
      'delete' =>
        isContentReport
            ? 'Bildirilen içerik kalıcı olarak silinir ve şikayet kapatılır.'
            : 'Mesaj kalıcı olarak silinir ve şikayet kapatılır.',
      'mute' => 'Kullanıcı 1 saat boyunca genel sohbete ve sohbet odalarına mesaj gönderemez. İşlem yönetici kaydına eklenir.',
      _ =>
        isContentReport
            ? 'İçerik silinmeden şikayet kapatılır.'
            : 'Mesaj silinmeden şikayet kapatılır.',
    };

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(description),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Vazgeç'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: FilledButton.styleFrom(
              backgroundColor: action == 'dismiss'
                  ? const Color(0xFFFF7A00)
                  : Colors.redAccent,
            ),
            child: Text(switch (action) {
              'delete' => isContentReport ? 'İçeriği sil' : 'Sil ve kapat',
              'mute' => 'Sustur ve kapat',
              _ => 'Kapat',
            }),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _processingReports.add(report.id));
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        throw FirebaseFunctionsException(
          code: 'unauthenticated',
          message: 'Yönetici oturumu bulunamadı.',
        );
      }
      await user.getIdToken(true);
      final result = await FirebaseFunctions.instanceFor(region: 'europe-west1')
          .httpsCallable(
            isContentReport ? 'reviewContentReport' : 'reviewChatMessageReport',
          )
          .call({'reportId': report.id, 'action': action});

      if (mounted) {
        final cleanupFailed =
            isContentReport &&
            result.data is Map &&
            result.data['storageCleanupFailed'] == true;
        AppNotificationService.show(
          cleanupFailed
              ? 'İçerik kaldırıldı ancak fotoğrafları temizlenemedi.'
              : switch (action) {
                  'delete' =>
                    isContentReport
                        ? 'İçerik silindi, şikayet kapatıldı.'
                        : 'Mesaj silindi, şikayet kapatıldı.',
                  'mute' => 'Kullanıcı 1 saat susturuldu, şikayet kapatıldı.',
                  _ => 'Şikayet kapatıldı.',
                },
        );
      }
    } on FirebaseFunctionsException catch (error) {
      debugPrint(
        'Sohbet şikayeti işlenemedi (${error.code}): ${error.message}',
      );
      if (mounted) {
        AppNotificationService.show(
          error.code == 'permission-denied'
              ? 'Bu işlem için yönetici yetkisi gerekiyor.'
              : 'İşlem başarısız oldu. Bağlantını kontrol edip tekrar dene.',
        );
      }
    } catch (error) {
      debugPrint('Sohbet şikayeti işlenemedi: $error');
      if (mounted) {
        AppNotificationService.show('İşlem başarısız oldu. Tekrar deneyin.');
      }
    } finally {
      if (mounted) setState(() => _processingReports.remove(report.id));
    }
  }

  Future<void> _showAdminActions() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    try {
      await user.getIdToken(true);
      final result = await FirebaseFunctions.instanceFor(region: 'europe-west1')
          .httpsCallable('getChatAdminActions')
          .call();
      final data = result.data;
      final actions = data is Map && data['actions'] is List
          ? (data['actions'] as List)
          : const [];
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Yönetici işlem geçmişi'),
          content: SizedBox(
            width: 420,
            child: actions.isEmpty
                ? const Text('Son 90 günde kayıtlı işlem yok.')
                : ListView.separated(
                    shrinkWrap: true,
                    itemCount: actions.length,
                    separatorBuilder: (_, _) => const Divider(),
                    itemBuilder: (context, index) {
                      final item = actions[index];
                      if (item is! Map) return const SizedBox.shrink();
                      final action = switch (item['action']) {
                        'user_muted_1_hour' => 'Kullanıcı 1 saat susturuldu',
                        'message_deleted' => 'Sohbet mesajı silindi',
                        'content_deleted' => 'Şikayet edilen içerik silindi',
                        'report_dismissed' => 'Şikayet kapatıldı',
                        _ => 'Moderasyon işlemi',
                      };
                      final createdAt = DateTime.tryParse(
                        item['createdAt']?.toString() ?? '',
                      )?.toLocal();
                      final dateText = createdAt == null
                          ? 'Tarih yok'
                          : '${MaterialLocalizations.of(context).formatShortDate(createdAt)} • '
                                '${MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(createdAt))}';
                      return ListTile(
                        dense: true,
                        title: Text(action),
                        subtitle: Text(
                          'Yönetici: ${item['actorUid'] ?? '-'}\n'
                          'Kullanıcı: ${item['targetUid'] ?? '-'}\n'
                          '$dateText',
                        ),
                      );
                    },
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Kapat'),
            ),
          ],
        ),
      );
    } on FirebaseFunctionsException catch (error) {
      debugPrint(
        'Yönetici işlem kayıtları alınamadı (${error.code}): ${error.message}',
      );
      if (mounted) {
        AppNotificationService.show('İşlem geçmişi yüklenemedi.');
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
        title: const Text('Şikayetler'),
        actions: [
          IconButton(
            onPressed: _showAdminActions,
            tooltip: 'Yönetici işlem geçmişi',
            icon: const Icon(Icons.history_rounded),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Row(
              children: [
                ChoiceChip(
                  label: const Text('Sohbet'),
                  selected: _selectedQueue == 0,
                  onSelected: (_) => setState(() => _selectedQueue = 0),
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  label: const Text('İlan ve mekân'),
                  selected: _selectedQueue == 1,
                  onSelected: (_) => setState(() => _selectedQueue = 1),
                ),
              ],
            ),
          ),
          Expanded(
            child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: FirebaseFirestore.instance
                  .collection(
                    _selectedQueue == 0
                        ? 'chat_message_reports'
                        : 'content_reports',
                  )
                  .where('status', isEqualTo: 'open')
                  .orderBy('created_at')
                  .limit(100)
                  .snapshots(),
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  final error = snapshot.error!;
                  debugPrint('Şikayetler alınamadı: $error');
                  final message = error is FirebaseException
                      ? switch (error.code) {
                          'permission-denied' =>
                            'Firestore bu şikayetleri okumaya izin vermedi. '
                                'Güncel güvenlik kurallarının Firebase’e '
                                'dağıtıldığını kontrol et.',
                          'failed-precondition' =>
                            'Şikayet sorgusu için gereken Firestore indeksi '
                                'hazır değil. firestore.indexes.json dosyasını '
                                'Firebase’e dağıt.',
                          'unavailable' || 'deadline-exceeded' =>
                            'Firestore bağlantısı şu anda kullanılamıyor. '
                                'Bağlantını kontrol edip tekrar dene.',
                          _ =>
                            'Şikayetler yüklenemedi '
                                '(Firestore/${error.code}).',
                        }
                      : 'Şikayetler yüklenemedi. Tekrar deneyin.';
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        message,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Color(0xFFB8B8B8)),
                      ),
                    ),
                  );
                }
                if (!snapshot.hasData) {
                  return const Center(
                    child: CircularProgressIndicator(color: Color(0xFFFF7A00)),
                  );
                }
                final reports = snapshot.data!.docs;
                if (reports.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.mark_chat_read_outlined,
                          color: Color(0xFFFF9A3D),
                          size: 44,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          _selectedQueue == 0
                              ? 'Bekleyen sohbet şikayeti yok.'
                              : 'Bekleyen ilan veya mekân şikayeti yok.',
                          style: const TextStyle(color: Colors.white70),
                        ),
                      ],
                    ),
                  );
                }

                return ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Text(
                      '${reports.length} açık şikayet'
                      '${reports.length == 100 ? ' (en fazla 100 gösteriliyor)' : ''}',
                      style: const TextStyle(
                        color: Color(0xFFB8B8B8),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 12),
                    ...reports.map((report) {
                      final data = report.data();
                      final processing = _processingReports.contains(report.id);
                      final isContentReport =
                          report.reference.parent.id == 'content_reports';
                      final messageId = data['message_id']?.toString() ?? '';
                      final contentId = data['content_id']?.toString() ?? '';
                      final createdAt = data['created_at'];
                      final localCreatedAt = createdAt is Timestamp
                          ? createdAt.toDate().toLocal()
                          : null;
                      final dateText = localCreatedAt == null
                          ? 'Tarih yok'
                          : '${MaterialLocalizations.of(context).formatShortDate(localCreatedAt)} • '
                                '${MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(localCreatedAt))}';

                      return Card(
                        color: const Color(0xFF191919),
                        margin: const EdgeInsets.only(bottom: 12),
                        shape: RoundedRectangleBorder(
                          side: const BorderSide(color: Color(0xFF303030)),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(14),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                isContentReport
                                    ? (data['content_title']
                                                  ?.toString()
                                                  .isNotEmpty ==
                                              true
                                          ? data['content_title'].toString()
                                          : 'Kayıp hayvan ilanı')
                                    : data['text']?.toString() ?? '',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 10),
                              Text(
                                isContentReport
                                    ? '${switch (data['content_type']) {
                                        'property_listing' => 'Emlak ilanı',
                                        'lost_pet' => 'Kayıp hayvan',
                                        'community_place' => 'Kayıtlı yer',
                                        _ => 'İçerik',
                                      }} • İçerik sahibi: ${data['content_owner_uid'] ?? '-'}'
                                    : '${data['message_type'] == 'public' ? 'Genel sohbet' : 'Oda: ${data['room_id'] ?? '-'}'}'
                                          ' • Mesajı yazan: ${data['sender_id'] ?? '-'}',
                                style: const TextStyle(
                                  color: Color(0xFFB8B8B8),
                                  fontSize: 12,
                                ),
                              ),
                              if (isContentReport &&
                                  (data['reason']?.toString().isNotEmpty ??
                                      false)) ...[
                                const SizedBox(height: 4),
                                Text(
                                  'Neden: ${data['reason']}',
                                  style: const TextStyle(
                                    color: Color(0xFFB8B8B8),
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                              if (isContentReport &&
                                  (data['content_description']
                                          ?.toString()
                                          .isNotEmpty ??
                                      false)) ...[
                                const SizedBox(height: 6),
                                Text(
                                  data['content_description'].toString(),
                                  maxLines: 4,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Color(0xFFB8B8B8),
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                              const SizedBox(height: 4),
                              Text(
                                'Bildiren: ${data['reported_by'] ?? '-'} • $dateText',
                                style: const TextStyle(
                                  color: Color(0xFF858585),
                                  fontSize: 11,
                                ),
                              ),
                              const SizedBox(height: 12),
                              Wrap(
                                spacing: 8,
                                runSpacing: 4,
                                alignment: WrapAlignment.end,
                                children: [
                                  OutlinedButton(
                                    onPressed: processing
                                        ? null
                                        : () => _reviewReport(
                                            report: report,
                                            action: 'dismiss',
                                          ),
                                    child: const Text('Kapat'),
                                  ),
                                  if (!isContentReport && messageId.isNotEmpty)
                                    OutlinedButton(
                                      onPressed: processing
                                          ? null
                                          : () => _reviewReport(
                                              report: report,
                                              action: 'mute',
                                            ),
                                      child: const Text('1 saat sustur'),
                                    ),
                                  if (isContentReport
                                      ? contentId.isNotEmpty
                                      : messageId.isNotEmpty)
                                    FilledButton(
                                      onPressed: processing
                                          ? null
                                          : () => _reviewReport(
                                              report: report,
                                              action: 'delete',
                                            ),
                                      style: FilledButton.styleFrom(
                                        backgroundColor: Colors.redAccent,
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
                                          : Text(
                                              isContentReport
                                                  ? 'İçeriği sil'
                                                  : 'Mesajı sil',
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
          ),
        ],
      ),
    );
  }
}
