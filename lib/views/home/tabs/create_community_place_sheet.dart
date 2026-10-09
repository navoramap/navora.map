import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

class CreateCommunityPlaceSheet extends StatefulWidget {
  final double latitude;
  final double longitude;
  final String initialName;
  final String initialAddress;
  final Future<void> Function({
    required String name,
    required String category,
    required String description,
    required String address,
    required Uint8List? photoBytes,
    required String? photoExtension,
  }) onSubmit;

  const CreateCommunityPlaceSheet({
    super.key,
    required this.latitude,
    required this.longitude,
    required this.initialName,
    required this.initialAddress,
    required this.onSubmit,
  });

  @override
  State<CreateCommunityPlaceSheet> createState() =>
      _CreateCommunityPlaceSheetState();
}

class _CreateCommunityPlaceSheetState extends State<CreateCommunityPlaceSheet> {
  static const _categories = [
    'Kafe',
    'Restoran',
    'Doğa',
    'Tarih & kültür',
    'Alışveriş',
    'Market',
    'Etkinlik',
    'Diğer',
  ];

  final _formKey = GlobalKey<FormState>();
  late final _nameController = TextEditingController(text: widget.initialName);
  late final _addressController = TextEditingController(
    text: widget.initialAddress,
  );
  final _descriptionController = TextEditingController();
  final _imagePicker = ImagePicker();
  Uint8List? _photoBytes;
  String? _photoExtension;
  String _category = _categories.first;
  bool _isSubmitting = false;
  String? _errorMessage;

  @override
  void dispose() {
    _nameController.dispose();
    _addressController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  InputDecoration _decoration(String label) {
    return InputDecoration(
      labelText: label,
      filled: true,
      fillColor: const Color(0xFF222321),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFF3B3C39)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFFFF7A00), width: 1.5),
      ),
    );
  }

  Future<void> _pickPhoto() async {
    try {
      final photo = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 82,
        maxWidth: 1500,
      );
      if (photo == null) return;

      final extension = photo.name.split('.').last.toLowerCase();
      if (!{'jpg', 'jpeg', 'png', 'webp'}.contains(extension)) {
        if (mounted) {
          setState(() => _errorMessage = 'JPG, PNG veya WebP fotoğraf seç.');
        }
        return;
      }
      final bytes = await photo.readAsBytes();
      if (bytes.isEmpty || bytes.length > 5 * 1024 * 1024) {
        if (mounted) {
          setState(() => _errorMessage = 'Fotoğraf 5 MB veya daha küçük olmalı.');
        }
        return;
      }
      if (!mounted) return;
      setState(() {
        _photoBytes = bytes;
        _photoExtension = extension;
        _errorMessage = null;
      });
    } catch (error) {
      debugPrint('Mekân fotoğrafı seçilemedi: $error');
      if (mounted) {
        setState(() => _errorMessage = 'Fotoğraf seçilemedi. Tekrar dene.');
      }
    }
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate() || _isSubmitting) return;
    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
    });
    try {
      await widget.onSubmit(
        name: _nameController.text.trim(),
        category: _category,
        description: _descriptionController.text.trim(),
        address: _addressController.text.trim(),
        photoBytes: _photoBytes,
        photoExtension: _photoExtension,
      );
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      debugPrint('Topluluk mekanı eklenemedi: $error');
      if (mounted) {
        setState(() {
          _errorMessage = 'Mekân eklenemedi. Bağlantını kontrol edip tekrar dene.';
          _isSubmitting = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          20,
          22,
          20,
          MediaQuery.of(context).viewInsets.bottom + 20,
        ),
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Yeni mekân ekle',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '${widget.latitude.toStringAsFixed(5)}, ${widget.longitude.toStringAsFixed(5)}',
                  style: const TextStyle(color: Colors.white60, fontSize: 12),
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _nameController,
                  maxLength: 100,
                  decoration: _decoration('Mekân adı'),
                  validator: (value) {
                    final name = value?.trim() ?? '';
                    return name.length < 2 ? 'En az 2 karakter gir.' : null;
                  },
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  initialValue: _category,
                  decoration: _decoration('Kategori'),
                  dropdownColor: const Color(0xFF222321),
                  items: _categories
                      .map(
                        (category) => DropdownMenuItem(
                          value: category,
                          child: Text(category),
                        ),
                      )
                      .toList(growable: false),
                  onChanged: _isSubmitting
                      ? null
                      : (value) {
                          if (value != null) setState(() => _category = value);
                        },
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _addressController,
                  maxLength: 200,
                  decoration: _decoration('Adres (isteğe bağlı)'),
                ),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _descriptionController,
                  maxLength: 500,
                  maxLines: 3,
                  decoration: _decoration('Kısa not (isteğe bağlı)'),
                ),
                const SizedBox(height: 8),
                if (_photoBytes != null) ...[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Image.memory(
                      _photoBytes!,
                      width: double.infinity,
                      height: 160,
                      fit: BoxFit.cover,
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _photoBytes == null
                            ? 'Fotoğraf ekle (isteğe bağlı)'
                            : 'Mekân fotoğrafı seçildi',
                        style: const TextStyle(color: Colors.white70),
                      ),
                    ),
                    if (_photoBytes != null)
                      IconButton(
                        tooltip: 'Fotoğrafı kaldır',
                        onPressed: _isSubmitting
                            ? null
                            : () => setState(() {
                                _photoBytes = null;
                                _photoExtension = null;
                              }),
                        icon: const Icon(Icons.delete_outline_rounded),
                      ),
                    OutlinedButton.icon(
                      onPressed: _isSubmitting ? null : _pickPhoto,
                      icon: const Icon(Icons.add_photo_alternate_outlined),
                      label: Text(_photoBytes == null ? 'Seç' : 'Değiştir'),
                    ),
                  ],
                ),
                if (_errorMessage != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    _errorMessage!,
                    style: TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                ],
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: FilledButton.icon(
                    onPressed: _isSubmitting ? null : _submit,
                    icon: _isSubmitting
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.add_location_alt_outlined),
                    label: const Text('Keşfet’e ekle'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}