import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geocoding/geocoding.dart' as geo_coding;
import 'package:image_picker/image_picker.dart';

class CreateLostPetReportSheet extends StatefulWidget {
  final bool isAdoption;

  const CreateLostPetReportSheet({super.key, this.isAdoption = false});

  @override
  State<CreateLostPetReportSheet> createState() =>
      _CreateLostPetReportSheetState();
}

class _CreateLostPetReportSheetState extends State<CreateLostPetReportSheet> {
  static const _textColor = Color(0xFFF4F1EC);
  static const _mutedColor = Color(0xFFAAA9A5);
  static const _maxPhotos = 3;
  static const _maxPhotoBytes = 5 * 1024 * 1024;

  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _cityController = TextEditingController();
  final _districtController = TextEditingController();
  final _addressController = TextEditingController();
  final _phoneController = TextEditingController();
  final _imagePicker = ImagePicker();
  final List<XFile> _photos = [];
  final List<Uint8List> _photoBytes = [];

  String _petType = 'dog';
  DateTime _lastSeenAt = DateTime.now();
  bool _sharePhone = false;
  bool _isSubmitting = false;
  String? _errorMessage;

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    _cityController.dispose();
    _districtController.dispose();
    _addressController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  InputDecoration _decoration(String label) {
    return InputDecoration(
      labelText: label,
      labelStyle: const TextStyle(color: _mutedColor),
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

  Future<void> _pickPhotos() async {
    final remaining = _maxPhotos - _photos.length;
    if (remaining <= 0) return;
    try {
      final files = await _imagePicker.pickMultiImage(
        imageQuality: 82,
        maxWidth: 1500,
        limit: remaining,
      );
      final addedPhotos = <XFile>[];
      final addedBytes = <Uint8List>[];
      for (final file in files) {
        final extension = file.name.split('.').last.toLowerCase();
        if (!{'jpg', 'jpeg', 'png', 'webp'}.contains(extension)) continue;
        final bytes = await file.readAsBytes();
        if (bytes.isEmpty || bytes.length > _maxPhotoBytes) continue;
        addedPhotos.add(file);
        addedBytes.add(bytes);
      }
      if (!mounted) return;
      setState(() {
        _photos.addAll(addedPhotos);
        _photoBytes.addAll(addedBytes);
        _errorMessage = null;
      });
      if (addedPhotos.length != files.length) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'En fazla 5 MB JPG, PNG veya WebP fotoğraf eklenebilir.',
            ),
          ),
        );
      }
    } catch (error) {
      debugPrint('Kayıp dost fotoğrafları seçilemedi: $error');
      if (!mounted) return;
      setState(() => _errorMessage = 'Fotoğraflar seçilemedi. Tekrar dene.');
    }
  }

  Future<void> _pickLastSeenAt() async {
    final date = await showDatePicker(
      context: context,
      locale: const Locale('tr', 'TR'),
      initialDate: _lastSeenAt,
      firstDate: DateTime.now().subtract(const Duration(days: 60)),
      lastDate: DateTime.now(),
    );
    if (date == null || !mounted) {
      return;
    }
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_lastSeenAt),
    );
    if (time == null || !mounted) {
      return;
    }
    setState(() {
      _lastSeenAt = DateTime(
        date.year,
        date.month,
        date.day,
        time.hour,
        time.minute,
      );
    });
  }

  Future<void> _submit() async {
    if (_isSubmitting || !_formKey.currentState!.validate()) {
      return;
    }
    if (!_sharePhone) {
      setState(
        () => _errorMessage = 'Telefonunun paylaşılmasına izin vermelisin.',
      );
      return;
    }

    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
    });

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      setState(() {
        _isSubmitting = false;
        _errorMessage = 'Bildirim oluşturmak için giriş yapmalısın.';
      });
      return;
    }
    final collectionName = widget.isAdoption
        ? 'pet_adoption_listings'
        : 'lost_pet_reports';
    final reportReference = FirebaseFirestore.instance
        .collection(collectionName)
        .doc();
    final uploadedReferences = <Reference>[];
    var reportCreated = false;

    try {
      final locations = await geo_coding.locationFromAddress(
        '${_addressController.text.trim()}, '
        '${_districtController.text.trim()}, '
        '${_cityController.text.trim()}, Türkiye',
      );
      if (locations.isEmpty) {
        throw StateError(
          'Adres bulunamadı. Sokak ve bina numarasını kontrol et.',
        );
      }

      await reportReference.set({
        'owner_uid': user.uid,
        'pet_type': _petType,
        'pet_name': _nameController.text.trim(),
        'description': _descriptionController.text.trim(),
        'city': _cityController.text.trim(),
        'district': _districtController.text.trim(),
        'address': _addressController.text.trim(),
        'latitude': locations.first.latitude,
        'longitude': locations.first.longitude,
        if (!widget.isAdoption) 'last_seen_at': Timestamp.fromDate(_lastSeenAt),
        'contact_phone': _phoneController.text.trim(),
        'contact_phone_shared': true,
        'photo_urls': <String>[],
        'cover_image_url': '',
        'status': 'active',
        'created_at': FieldValue.serverTimestamp(),
        'updated_at': FieldValue.serverTimestamp(),
      });
      reportCreated = true;

      if (_photos.isNotEmpty) {
        final photoUrls = <String>[];
        for (var index = 0; index < _photos.length; index++) {
          final photo = _photos[index];
          final extension = photo.name.split('.').last.toLowerCase();
          final contentType = switch (extension) {
            'jpg' || 'jpeg' => 'image/jpeg',
            'png' => 'image/png',
            'webp' => 'image/webp',
            _ => throw StateError('JPG, PNG veya WebP fotoğraf seçmelisin.'),
          };
          final reference = FirebaseStorage.instance.ref().child(
            '$collectionName/${user.uid}/${reportReference.id}/$index',
          );
          uploadedReferences.add(reference);
          await reference.putData(
            _photoBytes[index],
            SettableMetadata(contentType: contentType),
          );
          photoUrls.add(await reference.getDownloadURL());
        }
        await reportReference.update({
          'photo_urls': photoUrls,
          'cover_image_url': photoUrls.first,
          'updated_at': FieldValue.serverTimestamp(),
        });
      }

      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } catch (error) {
      for (final reference in uploadedReferences) {
        try {
          await reference.delete();
        } catch (_) {
          // Continue cleanup for the remaining selected photos.
        }
      }
      if (reportCreated) {
        try {
          await reportReference.delete();
        } catch (_) {
          // A report can be removed manually if cleanup is denied.
        }
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _errorMessage = switch (error) {
          StateError() => error.message.toString(),
          FirebaseException(
            plugin: 'firebase_storage',
            code: 'bucket-not-found',
          ) =>
            'Fotoğraf depolama alanı kurulmamış. Fotoğrafsız gönderebilir veya fotoğrafları kaldırıp tekrar deneyebilirsin.',
          FirebaseException(plugin: 'firebase_storage') => 'Fotoğraflar yüklenemedi. Fotoğrafları kaldırıp fotoğrafsız gönderebilirsin.',
          _ => 'Bildirim gönderilemedi. Bağlantını kontrol edip tekrar dene.',
        };
      });
    } finally {
      if (mounted) {
        setState(() => _isSubmitting = false);
      }
    }
  }

  String? _required(String? value, String label, {int maxLength = 100}) {
    final text = value?.trim() ?? '';
    if (text.isEmpty) {
      return '$label gerekli.';
    }
    if (text.length > maxLength) {
      return '$label en fazla $maxLength karakter olabilir.';
    }
    return null;
  }

  String _formatLastSeenAt() {
    final date =
        '${_lastSeenAt.day.toString().padLeft(2, '0')}/'
        '${_lastSeenAt.month.toString().padLeft(2, '0')}/${_lastSeenAt.year}';
    final time =
        '${_lastSeenAt.hour.toString().padLeft(2, '0')}:'
        '${_lastSeenAt.minute.toString().padLeft(2, '0')}';
    return '$date • $time';
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.92,
          minChildSize: 0.65,
          maxChildSize: 0.96,
          builder: (context, controller) => Material(
            color: const Color(0xFF171817),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
            child: Form(
              key: _formKey,
              child: ListView(
                controller: controller,
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
                      Expanded(
                        child: Text(
                          widget.isAdoption
                              ? 'Sahiplendirme ilanı'
                              : 'Kayıp dost bildirimi',
                          style: TextStyle(
                            color: _textColor,
                            fontSize: 22,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Kapat',
                        onPressed: _isSubmitting
                            ? null
                            : () => Navigator.pop(context),
                        icon: const Icon(Icons.close_rounded),
                        color: Colors.white70,
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(
                        value: 'dog',
                        label: Text('Köpek'),
                        icon: Icon(Icons.pets_rounded),
                      ),
                      ButtonSegment(
                        value: 'cat',
                        label: Text('Kedi'),
                        icon: Icon(Icons.cruelty_free_rounded),
                      ),
                      ButtonSegment(
                        value: 'other',
                        label: Text('Diğer'),
                        icon: Icon(Icons.more_horiz_rounded),
                      ),
                    ],
                    selected: {_petType},
                    onSelectionChanged: _isSubmitting
                        ? null
                        : (selection) =>
                              setState(() => _petType = selection.first),
                    style: SegmentedButton.styleFrom(
                      foregroundColor: const Color(0xFFD7D7D7),
                      selectedForegroundColor: Colors.white,
                      selectedBackgroundColor: const Color(0xFFFF7A00),
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: _nameController,
                    maxLength: 60,
                    style: const TextStyle(color: _textColor),
                    decoration: _decoration('Hayvanın adı (varsa)'),
                  ),
                  TextFormField(
                    controller: _descriptionController,
                    minLines: 3,
                    maxLines: 5,
                    maxLength: 800,
                    style: const TextStyle(color: _textColor),
                    decoration: _decoration(
                      widget.isAdoption
                          ? 'Karakteri, sağlık durumu ve yuva beklentisi'
                          : 'Rengi, cinsi ve ayırt edici özellikleri',
                    ),
                    validator: (value) =>
                        _required(value, 'Açıklama', maxLength: 800),
                  ),
                  _buildPhotoPicker(),
                  const SizedBox(height: 12),
                  if (!widget.isAdoption) ...[
                    OutlinedButton.icon(
                      onPressed: _isSubmitting ? null : _pickLastSeenAt,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFFFFAB66),
                        side: const BorderSide(color: Color(0xFF8A4A20)),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      icon: const Icon(Icons.schedule_rounded),
                      label: Text('Son görüldü: ${_formatLastSeenAt()}'),
                    ),
                    const SizedBox(height: 16),
                  ],
                  Row(
                    children: [
                      Expanded(
                        child: TextFormField(
                          controller: _cityController,
                          maxLength: 60,
                          style: const TextStyle(color: _textColor),
                          decoration: _decoration('İl'),
                          validator: (value) =>
                              _required(value, 'İl', maxLength: 60),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextFormField(
                          controller: _districtController,
                          maxLength: 80,
                          style: const TextStyle(color: _textColor),
                          decoration: _decoration('İlçe'),
                          validator: (value) =>
                              _required(value, 'İlçe', maxLength: 80),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  TextFormField(
                    controller: _addressController,
                    maxLength: 250,
                    minLines: 2,
                    maxLines: 3,
                    style: const TextStyle(color: _textColor),
                    decoration: _decoration(
                      'Açık adres (mahalle, sokak, bina no)',
                    ),
                    validator: (value) =>
                        _required(value, 'Açık adres', maxLength: 250),
                  ),
                  TextFormField(
                    controller: _phoneController,
                    keyboardType: TextInputType.phone,
                    maxLength: 40,
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[0-9+() -]')),
                    ],
                    style: const TextStyle(color: _textColor),
                    decoration: _decoration('İletişim telefonu'),
                    validator: (value) =>
                        _required(value, 'Telefon', maxLength: 40),
                  ),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    value: _sharePhone,
                    activeColor: const Color(0xFFFF7A00),
                    checkColor: Colors.white,
                    onChanged: _isSubmitting
                        ? null
                        : (value) =>
                              setState(() => _sharePhone = value ?? false),
                    title: const Text(
                      'Telefonum giriş yapan kullanıcılara gösterilsin.',
                      style: TextStyle(
                        color: _textColor,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (_errorMessage != null) ...[
                    const SizedBox(height: 6),
                    Text(
                      _errorMessage!,
                      style: const TextStyle(
                        color: Color(0xFFFF8A80),
                        fontSize: 13,
                      ),
                    ),
                  ],
                  const SizedBox(height: 10),
                  SizedBox(
                    height: 50,
                    child: FilledButton.icon(
                      onPressed: _isSubmitting ? null : _submit,
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFFFF7A00),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      icon: _isSubmitting
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.pets_rounded),
                      label: Text(
                        _isSubmitting
                            ? 'Gönderiliyor'
                            : widget.isAdoption
                            ? 'Sahiplendirme ilanı oluştur'
                            : 'Haritada paylaş',
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPhotoPicker() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                'Fotoğraf (isteğe bağlı)',
                style: TextStyle(
                  color: _textColor,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            Text(
              '${_photos.length}/$_maxPhotos',
              style: const TextStyle(color: _mutedColor, fontSize: 12),
            ),
          ],
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 82,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: _photos.length + (_photos.length < _maxPhotos ? 1 : 0),
            separatorBuilder: (context, index) => const SizedBox(width: 8),
            itemBuilder: (context, index) {
              if (index == _photos.length) {
                return Material(
                  color: const Color(0xFF252624),
                  borderRadius: BorderRadius.circular(12),
                  child: InkWell(
                    onTap: _isSubmitting ? null : _pickPhotos,
                    borderRadius: BorderRadius.circular(12),
                    child: Container(
                      width: 82,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0xFF4A4B48)),
                      ),
                      child: const Icon(
                        Icons.add_photo_alternate_outlined,
                        color: Color(0xFFFFAB66),
                        size: 24,
                      ),
                    ),
                  ),
                );
              }
              return Stack(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Image.memory(
                      _photoBytes[index],
                      width: 82,
                      height: 82,
                      fit: BoxFit.cover,
                    ),
                  ),
                  Positioned(
                    top: 2,
                    right: 2,
                    child: IconButton(
                      tooltip: 'Fotoğrafı kaldır',
                      onPressed: _isSubmitting
                          ? null
                          : () => setState(() {
                              _photos.removeAt(index);
                              _photoBytes.removeAt(index);
                            }),
                      icon: const Icon(Icons.close_rounded, size: 16),
                      style: IconButton.styleFrom(
                        backgroundColor: const Color(0xCC111111),
                        foregroundColor: Colors.white,
                        padding: EdgeInsets.zero,
                        minimumSize: const Size(28, 28),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
        const SizedBox(height: 4),
        const Text(
          'En fazla 3 fotoğraf, her biri 5 MB altında. Fotoğrafsız da paylaşabilirsin.',
          style: TextStyle(color: _mutedColor, fontSize: 11),
        ),
      ],
    );
  }
}
