import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../services/chat_room_service.dart';

Future<void> navoraDeleteChatRoom(
  FirebaseFirestore firestore,
  String roomId,
) async {
  final roomReference = firestore.collection('chat_rooms').doc(roomId);
  final collections = <CollectionReference<Map<String, dynamic>>>[
    roomReference.collection('messages'),
    roomReference.collection('members'),
    roomReference.collection('private'),
  ];
  final documents = <DocumentReference<Map<String, dynamic>>>[];
  for (final collection in collections) {
    final snapshot = await collection.get();
    documents.addAll(snapshot.docs.map((document) => document.reference));
  }

  for (var offset = 0; offset < documents.length; offset += 450) {
    final batch = firestore.batch();
    for (final reference in documents.skip(offset).take(450)) {
      batch.delete(reference);
    }
    await batch.commit();
  }

  await roomReference.delete();
  await firestore.collection('chat_room_listings').doc(roomId).delete();
}

class RoomChatPage extends StatefulWidget {
  final String roomId;
  final String roomName;
  final String userName;
  final String userId;
  final String ownerId;
  final List<String> moderatorIds;

  const RoomChatPage({
    super.key,
    required this.roomId,
    required this.roomName,
    required this.userName,
    required this.userId,
    required this.ownerId,
    required this.moderatorIds,
  });

  @override
  State<RoomChatPage> createState() => _RoomChatPageState();
}

class _RoomChatPageState extends State<RoomChatPage> {
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  bool _isSending = false;
  bool _showScrollToBottom = false;
  bool _roomChatWasAtBottom = true;
  final List<Map<String, dynamic>> _pendingRoomMessages = [];

  bool get _canModerate =>
      widget.userId == widget.ownerId ||
      widget.moderatorIds.contains(widget.userId);

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_handleRoomChatScroll);
  }

  bool _isRoomChatNearBottom() {
    if (!_scrollController.hasClients) return true;
    final maxScroll = _scrollController.position.maxScrollExtent;
    final current = _scrollController.offset;
    return current >= maxScroll - 32;
  }

  void _handleRoomChatScroll() {
    if (!_scrollController.hasClients) return;
    _roomChatWasAtBottom = _isRoomChatNearBottom();
    final shouldShow = !_roomChatWasAtBottom;
    if (shouldShow != _showScrollToBottom) {
      setState(() => _showScrollToBottom = shouldShow);
    }
  }

  Future<void> _scrollRoomChatToBottom() async {
    if (!_scrollController.hasClients) return;
    final maxScroll = _scrollController.position.maxScrollExtent;
    await _scrollController.animateTo(
      maxScroll,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _sendMessage() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _isSending) return;
    setState(() => _isSending = true);
    final roomReference = FirebaseFirestore.instance
        .collection('chat_rooms')
        .doc(widget.roomId);
    final localTempId = 'local-${DateTime.now().microsecondsSinceEpoch}';
    final optimisticMessage = <String, dynamic>{
      'sender': widget.userName,
      'sender_id': widget.userId,
      'text': text,
      'time': 'Şimdi',
      'created_at': Timestamp.now(),
      '_localTempId': localTempId,
    };

    setState(() {
      _pendingRoomMessages.add(optimisticMessage);
      _showScrollToBottom = false;
    });
    _controller.clear();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_roomChatWasAtBottom) {
        _scrollRoomChatToBottom();
      }
    });

    try {
      await roomReference.collection('messages').add({
        'sender': widget.userName,
        'sender_id': widget.userId,
        'text': text,
        'time': 'Şimdi',
        'created_at': FieldValue.serverTimestamp(),
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _pendingRoomMessages.removeWhere((message) {
            return message['_localTempId'] == localTempId;
          });
        });
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Mesaj gönderilemedi.')));
      }
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  Future<void> _deleteMessage(String messageId) async {
    if (!_canModerate) return;
    final reference = FirebaseFirestore.instance
        .collection('chat_rooms')
        .doc(widget.roomId)
        .collection('messages')
        .doc(messageId);
    await reference.delete();
  }

  Future<void> _reportMessage(Map<String, dynamic> message) async {
    await FirebaseFirestore.instance.collection('chat_message_reports').add({
      'room_id': widget.roomId,
      'reported_by': widget.userId,
      'sender_id': message['sender_id'],
      'text': message['text']?.toString() ?? '',
      'created_at': FieldValue.serverTimestamp(),
      'status': 'open',
    });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Mesaj moderasyona bildirildi.')),
      );
    }
  }

  Future<void> _showRoomManagement() async {
    if (widget.userId != widget.ownerId) return;
    final baseContext = context;
    final reference = FirebaseFirestore.instance
        .collection('chat_rooms')
        .doc(widget.roomId);
    final snapshot = await reference.get();
    final data = snapshot.data() ?? <String, dynamic>{};
    final nameController = TextEditingController(
      text: data['name']?.toString() ?? widget.roomName,
    );
    final passwordController = TextEditingController();
    var protected = (data['is_protected'] as bool?) ?? false;
    var showPassword = false;

    if (!baseContext.mounted) {
      nameController.dispose();
      passwordController.dispose();
      return;
    }

    await showModalBottomSheet<void>(
      context: baseContext,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF171717),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
      ),
      builder: (sheetContext) => StatefulBuilder(
        builder: (builderContext, setSheetState) {
          final sheetNavigator = Navigator.of(
            builderContext,
            rootNavigator: true,
          );

          void closeSheet() {
            if (sheetNavigator.canPop()) {
              sheetNavigator.pop();
            }
          }

          return Padding(
            padding: EdgeInsets.fromLTRB(
              20,
              20,
              20,
              MediaQuery.of(builderContext).viewInsets.bottom + 24,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 42,
                    height: 4,
                    decoration: BoxDecoration(
                      color: const Color(0xFF4A4A4A),
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                const Text(
                  'Oda yönetimi',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: nameController,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    labelText: 'Sohbet adı',
                    labelStyle: const TextStyle(color: Color(0xFFBDBDBD)),
                    hintStyle: const TextStyle(color: Color(0xFFBDBDBD)),
                    prefixIcon: const Icon(
                      Icons.edit_rounded,
                      color: Color(0xFFFF8A3D),
                    ),
                    filled: true,
                    fillColor: const Color(0xFF1B1B1B),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide(color: const Color(0xFF2D2D2D)),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide(color: const Color(0xFFFF8A3D)),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1B1B1B),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: const Color(0xFF2D2D2D)),
                  ),
                  child: SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    title: const Text(
                      'Şifreli oda',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    subtitle: const Text(
                      'Katılım için şifre iste',
                      style: TextStyle(color: Color(0xFFBDBDBD)),
                    ),
                    value: protected,
                    activeTrackColor: const Color(0xFFFF6B00),
                    activeThumbColor: Colors.white,
                    onChanged: (value) =>
                        setSheetState(() => protected = value),
                  ),
                ),
                if (protected) ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: passwordController,
                    obscureText: !showPassword,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      labelText: 'Oda şifresi',
                      labelStyle: const TextStyle(color: Color(0xFFBDBDBD)),
                      hintStyle: const TextStyle(color: Color(0xFFBDBDBD)),
                      prefixIcon: const Icon(
                        Icons.lock_outline_rounded,
                        color: Color(0xFFFF8A3D),
                      ),
                      suffixIcon: IconButton(
                        onPressed: () {
                          setSheetState(() {
                            showPassword = !showPassword;
                          });
                        },
                        icon: Icon(
                          showPassword
                              ? Icons.visibility_off_rounded
                              : Icons.visibility_rounded,
                          color: const Color(0xFFFF8A3D),
                        ),
                      ),
                      filled: true,
                      fillColor: const Color(0xFF1B1B1B),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide(color: const Color(0xFF2D2D2D)),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide(color: const Color(0xFFFF8A3D)),
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 18),
                SizedBox(
                  width: double.infinity,
                  height: 46,
                  child: FilledButton.icon(
                    onPressed: () async {
                      final name = nameController.text.trim();
                      if (name.isEmpty) return;

                      final enteredPassword = passwordController.text.trim();
                      final wasProtected = data['is_protected'] == true;
                      if (protected &&
                          !wasProtected &&
                          enteredPassword.length < 12) {
                        if (!baseContext.mounted) return;
                        ScaffoldMessenger.maybeOf(baseContext)?.showSnackBar(
                          const SnackBar(
                            content: Text(
                              'Yeni şifre en az 12 karakter olmalı.',
                            ),
                          ),
                        );
                        return;
                      }

                      try {
                        final batch = FirebaseFirestore.instance.batch();
                        final listingReference = FirebaseFirestore.instance
                            .collection('chat_room_listings')
                            .doc(widget.roomId);
                        final roomUpdates = <String, dynamic>{
                          'name': name,
                          'is_protected': protected,
                          'updated_at': FieldValue.serverTimestamp(),
                        };
                        final listingUpdates = <String, dynamic>{
                          'name': name,
                          'is_protected': protected,
                          'updated_at': FieldValue.serverTimestamp(),
                        };
                        if (protected && enteredPassword.isNotEmpty) {
                          final salt = navoraGenerateRoomPasswordSalt();
                          final derivedPasswordHash =
                              await navoraHashRoomPassword(
                                enteredPassword,
                                salt,
                              );
                          roomUpdates['password_salt'] = salt;
                          listingUpdates['password_salt'] = salt;
                          batch.set(
                            reference.collection('private').doc('access'),
                            {
                              'password_hash': derivedPasswordHash,
                              'updated_at': FieldValue.serverTimestamp(),
                            },
                          );
                        } else if (!protected) {
                          roomUpdates['password_salt'] = '';
                          listingUpdates['password_salt'] = '';
                          batch.delete(
                            reference.collection('private').doc('access'),
                          );
                        }
                        batch.update(reference, roomUpdates);
                        batch.update(listingReference, listingUpdates);
                        await batch.commit();
                      } catch (_) {
                        if (!baseContext.mounted) return;
                        ScaffoldMessenger.maybeOf(baseContext)?.showSnackBar(
                          const SnackBar(
                            content: Text('Oda bilgileri kaydedilemedi.'),
                          ),
                        );
                        return;
                      }

                      if (!baseContext.mounted) return;
                      closeSheet();
                    },
                    icon: const Icon(Icons.save_rounded),
                    label: const Text('Değişiklikleri kaydet'),
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFFFF6B00),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      final confirmed = await showDialog<bool>(
                        context: builderContext,
                        builder: (dialogContext) => AlertDialog(
                          backgroundColor: const Color(0xFF171717),
                          title: const Text(
                            'Odayı sil?',
                            style: TextStyle(color: Colors.white),
                          ),
                          content: const Text(
                            'Bu işlem geri alınamaz.',
                            style: TextStyle(color: Color(0xFFBDBDBD)),
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.of(
                                dialogContext,
                                rootNavigator: true,
                              ).pop(false),
                              child: const Text('Vazgeç'),
                            ),
                            FilledButton(
                              style: FilledButton.styleFrom(
                                backgroundColor: Colors.redAccent,
                              ),
                              onPressed: () => Navigator.of(
                                dialogContext,
                                rootNavigator: true,
                              ).pop(true),
                              child: const Text('Sil'),
                            ),
                          ],
                        ),
                      );
                      if (confirmed != true) return;

                      try {
                        await navoraDeleteChatRoom(
                          FirebaseFirestore.instance,
                          widget.roomId,
                        );
                      } catch (_) {
                        if (!baseContext.mounted) return;
                        ScaffoldMessenger.maybeOf(baseContext)?.showSnackBar(
                          const SnackBar(content: Text('Oda silinemedi.')),
                        );
                        return;
                      }

                      if (!baseContext.mounted) return;
                      closeSheet();
                    },
                    icon: const Icon(Icons.delete_sweep_rounded),
                    label: const Text('Odayı sil'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.redAccent,
                      side: const BorderSide(color: Colors.redAccent),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );

    if (mounted) {
      nameController.dispose();
      passwordController.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final roomReference = FirebaseFirestore.instance
        .collection('chat_rooms')
        .doc(widget.roomId);
    return Scaffold(
      backgroundColor: const Color(0xFF101010),
      appBar: AppBar(
        backgroundColor: const Color(0xFFFF6B00),
        foregroundColor: Colors.white,
        title: Text(widget.roomName),
        elevation: 0,
        actions: [
          if (widget.userId == widget.ownerId)
            IconButton(
              tooltip: 'Oda yönetimi',
              onPressed: _showRoomManagement,
              icon: const Icon(Icons.tune_rounded),
            ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                stream: roomReference
                    .collection('messages')
                    .orderBy('created_at')
                    .snapshots(),
                builder: (context, snapshot) {
                  final serverMessages =
                      <MapEntry<int, Map<String, dynamic>>>[];
                  final documents =
                      snapshot.data?.docs ??
                      const <QueryDocumentSnapshot<Map<String, dynamic>>>[];
                  for (var index = 0; index < documents.length; index++) {
                    final document = documents[index];
                    serverMessages.add(
                      MapEntry(index, {
                        ...document.data(),
                        '_document_id': document.id,
                      }),
                    );
                  }

                  final pendingMessages = _pendingRoomMessages.where((message) {
                    final localTempId = message['_localTempId']?.toString();
                    if (localTempId == null || localTempId.isEmpty) {
                      return false;
                    }
                    final senderId = message['sender_id']?.toString() ?? '';
                    final text = message['text']?.toString() ?? '';
                    return !serverMessages.any((entry) {
                      final incoming = entry.value;
                      return (incoming['sender_id']?.toString() ?? '') ==
                              senderId &&
                          (incoming['text']?.toString() ?? '') == text;
                    });
                  }).toList();

                  final validMessages = <MapEntry<int, Map<String, dynamic>>>[
                    ...serverMessages,
                    ...pendingMessages.asMap().entries.map((entry) {
                      return MapEntry(
                        entry.key + serverMessages.length,
                        Map<String, dynamic>.from(entry.value),
                      );
                    }),
                  ];

                  if (validMessages.isEmpty) {
                    return const Center(
                      child: Text('Bu odada henüz mesaj yok.'),
                    );
                  }

                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (_roomChatWasAtBottom || validMessages.isEmpty) {
                      _scrollRoomChatToBottom();
                    }
                  });

                  return Stack(
                    children: [
                      ListView.builder(
                        controller: _scrollController,
                        padding: const EdgeInsets.fromLTRB(16, 18, 16, 18),
                        itemCount: validMessages.length,
                        itemBuilder: (context, index) {
                          final entry = validMessages[index];
                          final message = entry.value;
                          final isPendingLocalMessage =
                              message['_localTempId'] != null;
                          final isMe = message['sender'] == widget.userName;
                          final senderName =
                              message['sender']?.toString() ?? 'Kullanıcı';
                          return Align(
                            alignment: isMe
                                ? Alignment.centerRight
                                : Alignment.centerLeft,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Flexible(
                                  child: Container(
                                    constraints: const BoxConstraints(
                                      maxWidth: 320,
                                    ),
                                    margin: const EdgeInsets.only(bottom: 10),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 14,
                                      vertical: 11,
                                    ),
                                    decoration: BoxDecoration(
                                      color: isMe
                                          ? const Color(0xFFFF6B00)
                                          : const Color(0xFF1B1B1B),
                                      borderRadius: BorderRadius.circular(16),
                                      boxShadow: [
                                        BoxShadow(
                                          color: Colors.black.withValues(
                                            alpha: 0.05,
                                          ),
                                          blurRadius: 8,
                                          offset: const Offset(0, 2),
                                        ),
                                      ],
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Text(
                                              senderName,
                                              style: TextStyle(
                                                color: isMe
                                                    ? Colors.white70
                                                    : const Color(0xFFFF6B00),
                                                fontSize: 11,
                                                fontWeight: FontWeight.w700,
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          message['text']?.toString() ?? '',
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 14,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                if (!isPendingLocalMessage)
                                  PopupMenuButton<String>(
                                    icon: const Icon(
                                      Icons.more_horiz_rounded,
                                      size: 20,
                                    ),
                                    onSelected: (action) async {
                                      if (action == 'delete') {
                                        await _deleteMessage(
                                          message['_document_id'].toString(),
                                        );
                                      }
                                      if (action == 'report') {
                                        await _reportMessage(message);
                                      }
                                    },
                                    itemBuilder: (_) => [
                                      if (_canModerate)
                                        const PopupMenuItem(
                                          value: 'delete',
                                          child: Text('Mesajı sil'),
                                        ),
                                      const PopupMenuItem(
                                        value: 'report',
                                        child: Text('Şikayet et'),
                                      ),
                                    ],
                                  ),
                              ],
                            ),
                          );
                        },
                      ),
                    ],
                  );
                },
              ),
            ),
            AnimatedPadding(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOut,
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).viewInsets.bottom > 0
                    ? 4.0
                    : 0.0,
              ),
              child: Container(
                padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
                color: const Color(0xFF111111),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _controller,
                        textInputAction: TextInputAction.send,
                        onSubmitted: (_) => _sendMessage(),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                        ),
                        decoration: InputDecoration(
                          hintText: 'Mesaj yaz...',
                          hintStyle: const TextStyle(
                            color: Color(0xFFBDBDBD),
                            fontSize: 14,
                          ),
                          filled: true,
                          fillColor: const Color(0xFF191919),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(22),
                            borderSide: BorderSide.none,
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    CircleAvatar(
                      radius: 22,
                      backgroundColor: const Color(0xFFFF6B00),
                      child: IconButton(
                        tooltip: 'Gönder',
                        splashRadius: 20,
                        onPressed: _sendMessage,
                        icon: _isSending
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(
                                Icons.send_rounded,
                                color: Colors.white,
                              ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
