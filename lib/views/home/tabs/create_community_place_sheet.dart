import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:image_picker/image_picker.dart';

class CreateCommunityPlaceSheet extends StatefulWidget {
  final double latitude;
  final double longitude;
  final String initialName;
  final String initialAddress;
  final String initialCategory;
  final String initialDescription;
  final List<String> initialPhotoUrls;
  final bool isEditing;
  final Future<void> Function({
    required String name,
    required String category,
    required String description,
    required String address,
    required List<Uint8List> photoBytes,
    required List<String> photoExtensions,
    required LatLng coordinate,
  })
  onSubmit;

  const CreateCommunityPlaceSheet({
    super.key,
    required this.latitude,
    required this.longitude,
    required this.initialName,
    required this.initialAddress,
    this.initialCategory = 'Kafe',
    this.initialDescription = '',
    this.initialPhotoUrls = const [],
    this.isEditing = false,
    required this.onSubmit,
  });

  @override
  State<CreateCommunityPlaceSheet> createState() =>
      _CreateCommunityPlaceSheetState();
}

class _CreateCommunityPlaceSheetState extends State<CreateCommunityPlaceSheet> {
  static const _locationMapStyle = '''
    [
      {"featureType":"all","elementType":"geometry","stylers":[{"color":"#101010"}]},
      {"featureType":"all","elementType":"labels.text.fill","stylers":[{"color":"#d6d6d6"}]},
      {"featureType":"all","elementType":"labels.text.stroke","stylers":[{"color":"#101010"}]},
      {"featureType":"water","elementType":"geometry","stylers":[{"color":"#080808"}]},
      {"featureType":"road","elementType":"geometry","stylers":[{"color":"#242424"}]},
      {"featureType":"transit","stylers":[{"visibility":"off"}]}
    ]
  ''';

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
  late final _descriptionController = TextEditingController(
    text: widget.initialDescription,
  );
  final _imagePicker = ImagePicker();
  late final List<String> _existingPhotoUrls = List<String>.from(
    widget.initialPhotoUrls.take(3),
  );
  final List<Uint8List> _photoBytes = [];
  final List<String> _photoExtensions = [];
  late LatLng _coordinate = LatLng(widget.latitude, widget.longitude);
  late String _category = _categories.contains(widget.initialCategory)
      ? widget.initialCategory
      : _categories.first;
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

  Future<void> _selectLocation() async {
    final selectedCoordinate = await showModalBottomSheet<LatLng>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      enableDrag: false,
      backgroundColor: const Color(0xFF171717),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        var coordinate = _coordinate;
        return StatefulBuilder(
          builder: (context, setMapState) => SizedBox(
            height: MediaQuery.sizeOf(context).height * 0.78,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 18, 12, 12),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Mekân konumunu seç',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Kapat',
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.close, color: Colors.white70),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      GoogleMap(
                        initialCameraPosition: CameraPosition(
                          target: coordinate,
                          zoom: 15,
                        ),
                        style: _locationMapStyle,
                        markers: {
                          Marker(
                            markerId: const MarkerId(
                              'community-place-selection',
                            ),
                            position: coordinate,
                            icon: BitmapDescriptor.defaultMarkerWithHue(
                              BitmapDescriptor.hueOrange,
                            ),
                          ),
                        },
                        myLocationButtonEnabled: false,
                        zoomControlsEnabled: false,
                        zoomGesturesEnabled: true,
                        scrollGesturesEnabled: true,
                        compassEnabled: false,
                        mapToolbarEnabled: false,
                        onTap: (tappedCoordinate) {
                          setMapState(() => coordinate = tappedCoordinate);
                        },
                        onCameraMove: (cameraPosition) {
                          coordinate = cameraPosition.target;
                        },
                        onCameraIdle: () => setMapState(() {}),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
                  child: SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: FilledButton.icon(
                      onPressed: () => Navigator.pop(context, coordinate),
                      icon: const Icon(Icons.check_rounded),
                      label: const Text('Bu konumu seç'),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (selectedCoordinate != null && mounted) {
      setState(() {
        _coordinate = selectedCoordinate;
        _errorMessage = null;
      });
    }
  }

  Future<void> _pickPhotos(ImageSource source) async {
    try {
      final remaining = 3 - _existingPhotoUrls.length - _photoBytes.length;
      if (remaining <= 0) {
        setState(() => _errorMessage = 'En fazla 3 fotoğraf ekleyebilirsin.');
        return;
      }

      final List<XFile> photos;
      if (source == ImageSource.gallery) {
        photos = await _imagePicker.pickMultiImage(
          imageQuality: 82,
          maxWidth: 1500,
        );
      } else {
        final photo = await _imagePicker.pickImage(
          source: source,
          imageQuality: 82,
          maxWidth: 1500,
        );
        photos = photo == null ? const [] : [photo];
      }
      if (photos.isEmpty) return;
      if (photos.length > remaining) {
        if (mounted) {
          setState(() {
            _errorMessage =
                'En fazla 3 fotoğraf ekleyebilirsin. $remaining fotoğraf yeri kaldı.';
          });
        }
        return;
      }

      final selectedBytes = <Uint8List>[];
      final selectedExtensions = <String>[];
      for (final photo in photos) {
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
            setState(
              () => _errorMessage = 'Her fotoğraf 5 MB veya daha küçük olmalı.',
            );
          }
          return;
        }
        selectedBytes.add(bytes);
        selectedExtensions.add(extension);
      }
      if (!mounted) return;
      setState(() {
        _photoBytes.addAll(selectedBytes);
        _photoExtensions.addAll(selectedExtensions);
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
        photoBytes: List.unmodifiable(_photoBytes),
        photoExtensions: List.unmodifiable(_photoExtensions),
        coordinate: _coordinate,
      );
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      debugPrint(
        'Topluluk mekanı ${widget.isEditing ? 'düzenlenemedi' : 'eklenemedi'}: $error',
      );
      if (mounted) {
        setState(() {
          _errorMessage = widget.isEditing
              ? 'Mekân düzenlenemedi. Bağlantını kontrol edip tekrar dene.'
              : 'Mekân eklenemedi. Bağlantını kontrol edip tekrar dene.';
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
                Text(
                  widget.isEditing ? 'Mekânı düzenle' : 'Yeni mekân ekle',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '${_coordinate.latitude.toStringAsFixed(5)}, ${_coordinate.longitude.toStringAsFixed(5)}',
                  style: const TextStyle(color: Colors.white60, fontSize: 12),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _isSubmitting ? null : _selectLocation,
                  icon: const Icon(Icons.location_on_outlined),
                  label: const Text('Haritadan konum seç'),
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
                if (_existingPhotoUrls.isNotEmpty ||
                    _photoBytes.isNotEmpty) ...[
                  SizedBox(
                    height: 160,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: _existingPhotoUrls.length + _photoBytes.length,
                      separatorBuilder: (context, index) =>
                          const SizedBox(width: 8),
                      itemBuilder: (context, index) {
                        final isExisting = index < _existingPhotoUrls.length;
                        final photoIndex = index - _existingPhotoUrls.length;
                        return Stack(
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(12),
                              child: isExisting
                                  ? Image.network(
                                      _existingPhotoUrls[index],
                                      width: 220,
                                      height: 160,
                                      fit: BoxFit.cover,
                                      errorBuilder:
                                          (context, error, stackTrace) =>
                                              const SizedBox(
                                                width: 220,
                                                height: 160,
                                                child: ColoredBox(
                                                  color: Color(0xFF252525),
                                                  child: Icon(
                                                    Icons.broken_image_outlined,
                                                    color: Colors.white60,
                                                  ),
                                                ),
                                              ),
                                    )
                                  : Image.memory(
                                      _photoBytes[photoIndex],
                                      width: 220,
                                      height: 160,
                                      fit: BoxFit.cover,
                                    ),
                            ),
                            if (!isExisting)
                              Positioned(
                                top: 6,
                                right: 6,
                                child: IconButton.filled(
                                  tooltip: 'Fotoğrafı kaldır',
                                  onPressed: _isSubmitting
                                      ? null
                                      : () => setState(() {
                                          _photoBytes.removeAt(photoIndex);
                                          _photoExtensions.removeAt(photoIndex);
                                        }),
                                  icon: const Icon(
                                    Icons.close_rounded,
                                    size: 18,
                                  ),
                                  style: IconButton.styleFrom(
                                    backgroundColor: Colors.black54,
                                    foregroundColor: Colors.white,
                                    minimumSize: const Size(32, 32),
                                  ),
                                ),
                              ),
                          ],
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Fotoğraflar (${_existingPhotoUrls.length + _photoBytes.length}/3)',
                        style: const TextStyle(color: Colors.white70),
                      ),
                    ),
                    OutlinedButton.icon(
                      onPressed:
                          _isSubmitting ||
                              _existingPhotoUrls.length + _photoBytes.length ==
                                  3
                          ? null
                          : () => _pickPhotos(ImageSource.gallery),
                      icon: const Icon(Icons.photo_library_outlined),
                      label: const Text('Galeri'),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      onPressed:
                          _isSubmitting ||
                              _existingPhotoUrls.length + _photoBytes.length ==
                                  3
                          ? null
                          : () => _pickPhotos(ImageSource.camera),
                      icon: const Icon(Icons.photo_camera_outlined),
                      label: const Text('Kamera'),
                    ),
                  ],
                ),
                if (_errorMessage != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    _errorMessage!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
                const SizedBox(height: 20),
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
                    label: Text(
                      widget.isEditing
                          ? 'Değişiklikleri kaydet'
                          : 'Keşfet’e ekle',
                    ),
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
