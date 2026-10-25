import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

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
    required bool deleteMessage,
  }) async {
    final data = report.data();
    final roomId = data['room_id']?.toString() ?? '';
    final messageId = data['message_id']?.toString() ?? '';
    final isPublicMessage = data['message_type'] == 'public';
    if (deleteMessage && (roomId.isEmpty || messageId.isEmpty)) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          deleteMessage ? 'Mesaj silinsin mi?' : 'Şikayet kapatılsın mı?',
        ),
        content: Text(
          deleteMessage
              ? 'Mesaj kalıcı olarak silinir ve şikayet kapatılır.'
              : 'Mesaj silinmeden şikayet kapatılır.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Vazgeç'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: FilledButton.styleFrom(
              backgroundColor: deleteMessage
                  ? Colors.redAccent
                  : const Color(0xFFFF7A00),
            ),
            child: Text(deleteMessage ? 'Sil ve kapat' : 'Kapat'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _processingReports.add(report.id));
    try {
      final firestore = FirebaseFirestore.instance;
      final batch = firestore.batch();
      if (deleteMessage) {
        final messageReference = isPublicMessage
            ? firestore.collection('public_chat_messages').doc(messageId)
            : firestore
                  .collection('chat_rooms')
                  .doc(roomId)
                  .collection('messages')
                  .doc(messageId);
        batch.delete(messageReference);
      }
      batch.update(report.reference, {
        'status': deleteMessage ? 'resolved' : 'dismissed',
        'reviewed_by': FirebaseAuth.instance.currentUser!.uid,
        'reviewed_at': FieldValue.serverTimestamp(),
      });
      await batch.commit();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              deleteMessage
                  ? 'Mesaj silindi, şikayet kapatıldı.'
                  : 'Şikayet kapatıldı.',
            ),
          ),
        );
      }
    } catch (error) {
      debugPrint('Sohbet şikayeti işlenemedi: $error');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('İşlem başarısız oldu. Tekrar deneyin.'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _processingReports.remove(report.id));
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
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton(
                                onPressed: processing
                                    ? null
                                    : () => _reviewReport(
                                        report: report,
                                        deleteMessage: false,
                                      ),
                                child: const Text('Kapat'),
                              ),
                            ),
                            if (messageId.isNotEmpty) ...[
                              const SizedBox(width: 10),
                              Expanded(
                                child: FilledButton(
                                  onPressed: processing
                                      ? null
                                      : () => _reviewReport(
                                          report: report,
                                          deleteMessage: true,
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
                              ),
                            ],
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
