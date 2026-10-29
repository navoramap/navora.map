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

  Future<void> _reviewReport({
    required QueryDocumentSnapshot<Map<String, dynamic>> report,
    required String action,
  }) async {
    final data = report.data();
    final messageId = data['message_id']?.toString() ?? '';
    if (action == 'delete' && messageId.isEmpty) return;
    final title = switch (action) {
      'delete' => 'Mesaj silinsin mi?',
      'mute' => 'Kullanıcı 1 saat susturulsun mu?',
      _ => 'Şikayet kapatılsın mı?',
    };
    final description = switch (action) {
      'delete' => 'Mesaj kalıcı olarak silinir ve şikayet kapatılır.',
      'mute' => 'Kullanıcı 1 saat boyunca genel sohbete ve sohbet odalarına mesaj gönderemez. İşlem yönetici kaydına eklenir.',
      _ => 'Mesaj silinmeden şikayet kapatılır.',
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
              'delete' => 'Sil ve kapat',
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
      await FirebaseFunctions.instanceFor(region: 'europe-west1')
          .httpsCallable('reviewChatMessageReport')
          .call({'reportId': report.id, 'action': action});

      if (mounted) {
        AppNotificationService.show(switch (action) {
          'delete' => 'Mesaj silindi, şikayet kapatıldı.',
          'mute' => 'Kullanıcı 1 saat susturuldu, şikayet kapatıldı.',
          _ => 'Şikayet kapatıldı.',
        });
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
                        'report_dismissed' => 'Şikayet kapatıldı',
                        _ => 'Moderasyon işlemi',
                      };
                      return ListTile(
                        dense: true,
                        title: Text(action),
                        subtitle: Text(
                          'Yönetici: ${item['actorUid'] ?? '-'}\n'
                          'Kullanıcı: ${item['targetUid'] ?? '-'}\n'
                          '${item['createdAt'] ?? ''}',
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
        title: const Text('Sohbet şikayetleri'),
        actions: [
          IconButton(
            onPressed: _showAdminActions,
            tooltip: 'Yönetici işlem geçmişi',
            icon: const Icon(Icons.history_rounded),
          ),
        ],
      ),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance
            .collection('chat_message_reports')
            .where('status', isEqualTo: 'open')
            .orderBy('created_at')
            .limit(100)
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            debugPrint('Sohbet şikayetleri alınamadı: ${snapshot.error}');
            return const Center(
              child: Text(
                'Şikayetler yüklenemedi. Yönetici yetkini ve bağlantını kontrol et.',
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
          final reports = snapshot.data!.docs;
          if (reports.isEmpty) {
            return const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.mark_chat_read_outlined,
                    color: Color(0xFFFF9A3D),
                    size: 44,
                  ),
                  SizedBox(height: 12),
                  Text(
                    'Bekleyen sohbet şikayeti yok.',
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
                final messageId = data['message_id']?.toString() ?? '';
                final createdAt = data['created_at'];
                final dateText = createdAt is Timestamp
                    ? MaterialLocalizations.of(context)
                          .formatShortDate(createdAt.toDate().toLocal())
                    : 'Tarih yok';

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
                          data['text']?.toString() ?? '',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          '${data['message_type'] == 'public' ? 'Genel sohbet' : 'Oda: ${data['room_id'] ?? '-'}'}'
                          ' • Mesajı yazan: ${data['sender_id'] ?? '-'}',
                          style: const TextStyle(
                            color: Color(0xFFB8B8B8),
                            fontSize: 12,
                          ),
                        ),
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
                            if (messageId.isNotEmpty)
                              OutlinedButton(
                                onPressed: processing
                                    ? null
                                    : () => _reviewReport(
                                        report: report,
                                        action: 'mute',
                                      ),
                                child: const Text('1 saat sustur'),
                              ),
                            if (messageId.isNotEmpty)
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
                                    : const Text('Mesajı sil'),
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
