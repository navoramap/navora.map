import 'package:flutter/material.dart';

import '../../../services/explore_highlight_service.dart';

class ExploreHighlightManagerSheet extends StatelessWidget {
  final String adminUid;
  final ExploreHighlightService service;

  const ExploreHighlightManagerSheet({
    super.key,
    required this.adminUid,
    required this.service,
  });

  Future<void> _edit(
    BuildContext context,
    ExploreHighlight? highlight,
    int nextOrder,
  ) async {
    await showDialog<void>(
      context: context,
      builder: (context) => _ExploreHighlightEditorDialog(
        adminUid: adminUid,
        service: service,
        highlight: highlight,
        nextOrder: nextOrder,
      ),
    );
  }

  Future<void> _delete(BuildContext context, ExploreHighlight highlight) async {
    final shouldDelete = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF191919),
        titleTextStyle: const TextStyle(
          color: Colors.white,
          fontSize: 20,
          fontWeight: FontWeight.w700,
        ),
        contentTextStyle: const TextStyle(color: Color(0xFFD5D5D5)),
        title: const Text('Kartı sil?'),
        content: Text('“${highlight.title}” kartı kalıcı olarak silinecek.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFFE2E2E2),
            ),
            child: const Text('Vazgeç'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFB3261E),
            ),
            child: const Text('Sil'),
          ),
        ],
      ),
    );
    if (shouldDelete != true) return;

    try {
      await service.delete(highlight.id);
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Kart silinemedi. Tekrar dene.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.78,
      minChildSize: 0.5,
      maxChildSize: 0.94,
      builder: (context, scrollController) => Material(
        color: const Color(0xFF171717),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
        child: StreamBuilder<List<ExploreHighlight>>(
          stream: service.watchAll(),
          builder: (context, snapshot) {
            final highlights = snapshot.data ?? const <ExploreHighlight>[];
            return ListView(
              controller: scrollController,
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 28),
              children: [
                Center(
                  child: Container(
                    width: 38,
                    height: 4,
                    decoration: BoxDecoration(
                      color: const Color(0xFF686966),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Keşfet kartları',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 21,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    IconButton.filled(
                      tooltip: 'Kart ekle',
                      onPressed: () => _edit(context, null, highlights.length),
                      icon: const Icon(Icons.add_rounded),
                      style: IconButton.styleFrom(
                        backgroundColor: const Color(0xFFFF7A00),
                        foregroundColor: Colors.white,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (snapshot.hasError)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Text(
                      'Kartlar yüklenemedi. Firestore izinlerini kontrol et.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Color(0xFFFF8A80)),
                    ),
                  )
                else if (snapshot.connectionState == ConnectionState.waiting &&
                    highlights.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 28),
                    child: Center(
                      child: CircularProgressIndicator(
                        color: Color(0xFFFF7A00),
                      ),
                    ),
                  )
                else if (highlights.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Text(
                      'Henüz öne çıkan kart yok.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Color(0xFFBDBDBD)),
                    ),
                  )
                else
                  ...highlights.map(
                    (highlight) => _HighlightManagerTile(
                      highlight: highlight,
                      onEdit: () => _edit(context, highlight, highlight.order),
                      onDelete: () => _delete(context, highlight),
                      onToggleActive: (active) => service.update(
                        id: highlight.id,
                        title: highlight.title,
                        subtitle: highlight.subtitle,
                        imageUrl: highlight.imageUrl,
                        actionUrl: highlight.actionUrl,
                        iconName: highlight.iconName,
                        order: highlight.order,
                        isActive: active,
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _HighlightManagerTile extends StatelessWidget {
  final ExploreHighlight highlight;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final ValueChanged<bool> onToggleActive;

  const _HighlightManagerTile({
    required this.highlight,
    required this.onEdit,
    required this.onDelete,
    required this.onToggleActive,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF222222),
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.network(
                highlight.imageUrl,
                width: 64,
                height: 52,
                fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) => const SizedBox(
                  width: 64,
                  height: 52,
                  child: ColoredBox(
                    color: Color(0xFF343434),
                    child: Icon(Icons.image_not_supported_outlined),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    highlight.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    highlight.isActive
                        ? 'Yayında • Sıra ${highlight.order + 1}'
                        : 'Taslak',
                    style: const TextStyle(
                      color: Color(0xFFBDBDBD),
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            Switch.adaptive(
              value: highlight.isActive,
              activeThumbColor: const Color(0xFFFF7A00),
              onChanged: onToggleActive,
            ),
            IconButton(
              tooltip: 'Düzenle',
              onPressed: onEdit,
              icon: const Icon(Icons.edit_outlined),
              color: Colors.white70,
            ),
            IconButton(
              tooltip: 'Sil',
              onPressed: onDelete,
              icon: const Icon(Icons.delete_outline_rounded),
              color: const Color(0xFFFF8A80),
            ),
          ],
        ),
      ),
    );
  }
}

class _ExploreHighlightEditorDialog extends StatefulWidget {
  final String adminUid;
  final ExploreHighlightService service;
  final ExploreHighlight? highlight;
  final int nextOrder;

  const _ExploreHighlightEditorDialog({
    required this.adminUid,
    required this.service,
    required this.highlight,
    required this.nextOrder,
  });

  @override
  State<_ExploreHighlightEditorDialog> createState() =>
      _ExploreHighlightEditorDialogState();
}

class _ExploreHighlightEditorDialogState
    extends State<_ExploreHighlightEditorDialog> {
  static const _iconOptions = <String, IconData>{
    'new_releases': Icons.new_releases_rounded,
    'pedal_bike': Icons.pedal_bike_rounded,
    'route': Icons.route_rounded,
    'place': Icons.place_rounded,
    'event': Icons.event_rounded,
    'travel_explore': Icons.travel_explore_rounded,
    'local_offer': Icons.local_offer_rounded,
    'campaign': Icons.campaign_rounded,
  };

  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _titleController;
  late final TextEditingController _subtitleController;
  late final TextEditingController _imageUrlController;
  late final TextEditingController _actionUrlController;
  late final TextEditingController _orderController;
  late String _iconName;
  late bool _isActive;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    final highlight = widget.highlight;
    _titleController = TextEditingController(text: highlight?.title ?? '');
    _subtitleController = TextEditingController(
      text: highlight?.subtitle ?? '',
    );
    _imageUrlController = TextEditingController(
      text: highlight?.imageUrl ?? '',
    );
    _actionUrlController = TextEditingController(
      text: highlight?.actionUrl ?? '',
    );
    _orderController = TextEditingController(
      text: (highlight?.order ?? widget.nextOrder).toString(),
    );
    _iconName = highlight?.iconName ?? 'new_releases';
    _isActive = highlight?.isActive ?? true;
  }

  @override
  void dispose() {
    _titleController.dispose();
    _subtitleController.dispose();
    _imageUrlController.dispose();
    _actionUrlController.dispose();
    _orderController.dispose();
    super.dispose();
  }

  String? _httpsUrl(String? value, String label, {bool optional = false}) {
    final text = value?.trim() ?? '';
    if (optional && text.isEmpty) return null;
    final uri = Uri.tryParse(text);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
      return '$label https:// ile başlamalı.';
    }
    if (text.length > 2048) return '$label çok uzun.';
    return null;
  }

  Future<void> _save() async {
    if (_isSaving || !_formKey.currentState!.validate()) return;
    setState(() => _isSaving = true);
    try {
      final order = int.parse(_orderController.text.trim());
      if (widget.highlight == null) {
        await widget.service.create(
          ownerUid: widget.adminUid,
          title: _titleController.text,
          subtitle: _subtitleController.text,
          imageUrl: _imageUrlController.text,
          actionUrl: _actionUrlController.text,
          iconName: _iconName,
          order: order,
        );
      } else {
        await widget.service.update(
          id: widget.highlight!.id,
          title: _titleController.text,
          subtitle: _subtitleController.text,
          imageUrl: _imageUrlController.text,
          actionUrl: _actionUrlController.text,
          iconName: _iconName,
          order: order,
          isActive: _isActive,
        );
      }
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Kart kaydedilemedi. Yetkini kontrol et.'),
        ),
      );
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  InputDecoration _decoration(String label) => InputDecoration(
    labelText: label,
    labelStyle: const TextStyle(color: Color(0xFFBEBEBE)),
    floatingLabelStyle: const TextStyle(color: Color(0xFFFF9A3D)),
    filled: true,
    fillColor: const Color(0xFF242424),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: const BorderSide(color: Color(0xFF494949)),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: const BorderSide(color: Color(0xFFFF7A00), width: 1.5),
    ),
    errorStyle: const TextStyle(color: Color(0xFFFF8A80)),
  );

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.highlight != null;
    return AlertDialog(
      backgroundColor: const Color(0xFF191919),
      titleTextStyle: const TextStyle(
        color: Colors.white,
        fontSize: 21,
        fontWeight: FontWeight.w800,
      ),
      title: Text(isEditing ? 'Kartı düzenle' : 'Keşfet kartı ekle'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: _titleController,
                  style: const TextStyle(color: Color(0xFFF4F1EC)),
                  maxLength: 70,
                  decoration: _decoration('Başlık'),
                  validator: (value) => value == null || value.trim().isEmpty
                      ? 'Başlık gerekli.'
                      : null,
                ),
                const SizedBox(height: 10),
                TextFormField(
                  controller: _subtitleController,
                  style: const TextStyle(color: Color(0xFFF4F1EC)),
                  maxLength: 160,
                  maxLines: 2,
                  decoration: _decoration('Kısa açıklama'),
                ),
                const SizedBox(height: 10),
                TextFormField(
                  controller: _imageUrlController,
                  style: const TextStyle(color: Color(0xFFF4F1EC)),
                  keyboardType: TextInputType.url,
                  decoration: _decoration('Kapak görseli URL’si'),
                  validator: (value) => _httpsUrl(value, 'Görsel adresi'),
                ),
                const SizedBox(height: 10),
                TextFormField(
                  controller: _actionUrlController,
                  style: const TextStyle(color: Color(0xFFF4F1EC)),
                  keyboardType: TextInputType.url,
                  decoration: _decoration(
                    'Dokununca açılacak bağlantı (isteğe bağlı)',
                  ),
                  validator: (value) =>
                      _httpsUrl(value, 'Bağlantı', optional: true),
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  initialValue: _iconName,
                  style: const TextStyle(color: Color(0xFFF4F1EC)),
                  dropdownColor: const Color(0xFF252525),
                  decoration: _decoration('İkon'),
                  items: _iconOptions.entries
                      .map(
                        (entry) => DropdownMenuItem(
                          value: entry.key,
                          child: Row(
                            children: [
                              Icon(
                                entry.value,
                                size: 19,
                                color: const Color(0xFFFF9A3D),
                              ),
                              const SizedBox(width: 10),
                              Text(
                                entry.key.replaceAll('_', ' '),
                                style: const TextStyle(color: Colors.white),
                              ),
                            ],
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: _isSaving
                      ? null
                      : (value) {
                          if (value != null) setState(() => _iconName = value);
                        },
                ),
                const SizedBox(height: 10),
                TextFormField(
                  controller: _orderController,
                  style: const TextStyle(color: Color(0xFFF4F1EC)),
                  keyboardType: TextInputType.number,
                  decoration: _decoration('Sıra'),
                  validator: (value) {
                    final order = int.tryParse(value?.trim() ?? '');
                    if (order == null || order < 0 || order > 10000) {
                      return '0–10000 arasında bir sıra gir.';
                    }
                    return null;
                  },
                ),
                if (isEditing)
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    title: const Text(
                      'Yayında',
                      style: TextStyle(color: Color(0xFFF4F1EC)),
                    ),
                    value: _isActive,
                    activeThumbColor: const Color(0xFFFF7A00),
                    onChanged: _isSaving
                        ? null
                        : (value) => setState(() => _isActive = value),
                  ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isSaving ? null : () => Navigator.pop(context),
          style: TextButton.styleFrom(foregroundColor: const Color(0xFFE2E2E2)),
          child: const Text('Vazgeç'),
        ),
        FilledButton(
          onPressed: _isSaving ? null : _save,
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFFFF7A00),
            foregroundColor: Colors.white,
          ),
          child: Text(_isSaving ? 'Kaydediliyor' : 'Kaydet'),
        ),
      ],
    );
  }
}
