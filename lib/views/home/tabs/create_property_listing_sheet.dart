import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:geocoding/geocoding.dart' as geo_coding;
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:image_picker/image_picker.dart';

import '../../../services/property_listing_service.dart';

class CreatePropertyListingSheet extends StatefulWidget {
  const CreatePropertyListingSheet({super.key});

  @override
  State<CreatePropertyListingSheet> createState() =>
      _CreatePropertyListingSheetState();
}

class _CreatePropertyListingSheetState
    extends State<CreatePropertyListingSheet> {
  static const _textColor = Color(0xFFF4F1EC);
  static const _mutedColor = Color(0xFFAAA9A5);

  final _formKey = GlobalKey<FormState>();
  final _titleController = TextEditingController();
  final _priceController = TextEditingController();
  final _cityController = TextEditingController();
  final _districtController = TextEditingController();
  final _addressController = TextEditingController();
  final _areaController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _picker = ImagePicker();
  final _listingService = PropertyListingService();
  final List<XFile> _photos = [];
  final List<Uint8List> _photoBytes = [];

  String _listingType = 'kiralik';
  String _rooms = '2+1';
  LatLng? _selectedLocation;
  bool _shareExactAddress = false;
  bool _isLocatingAddress = false;
  bool _isSubmitting = false;
  String? _errorMessage;

  @override
  void dispose() {
    _titleController.dispose();
    _priceController.dispose();
    _cityController.dispose();
    _districtController.dispose();
    _addressController.dispose();
    _areaController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  InputDecoration _decoration(String label, {String? suffixText}) {
    return InputDecoration(
      labelText: label,
      suffixText: suffixText,
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
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFFE56A60)),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFFE56A60), width: 1.5),
      ),
    );
  }

  Future<void> _pickPhotos() async {
    final remaining = PropertyListingService.maxPhotos - _photos.length;
    if (remaining <= 0) return;
    try {
      final files = await _picker.pickMultiImage(
        imageQuality: 82,
        maxWidth: 1600,
        limit: remaining,
      );
      final addedPhotos = <XFile>[];
      final addedBytes = <Uint8List>[];
      for (final file in files) {
        final extension = file.name.split('.').last.toLowerCase();
        if (!{'jpg', 'jpeg', 'png', 'webp'}.contains(extension)) {
          continue;
        }
        final bytes = await file.readAsBytes();
        if (bytes.isEmpty ||
            bytes.length > PropertyListingService.maxPhotoBytes) {
          continue;
        }
        addedPhotos.add(file);
        addedBytes.add(bytes);
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _photos.addAll(addedPhotos);
        _photoBytes.addAll(addedBytes);
        _errorMessage = null;
      });
      if (addedPhotos.length != files.length) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Yalnızca JPG, PNG veya WebP ve 5 MB altı fotoğraflar eklenebilir.',
            ),
          ),
        );
      }
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() => _errorMessage = 'Fotoğraflar seçilemedi. Tekrar dene.');
    }
  }

  Future<void> _submit() async {
    if (_isSubmitting || !_formKey.currentState!.validate()) {
      return;
    }
    final selectedLocation = _selectedLocation;
    if (selectedLocation == null) {
      setState(() {
        _errorMessage = 'Önce açık adresi haritada pin ile doğrulamalısın.';
      });
      return;
    }
    if (!_shareExactAddress) {
      setState(() {
        _errorMessage = 'Açık adresinin ilanda gösterilmesini onaylamalısın.';
      });
      return;
    }
    if (_photos.isEmpty) {
      setState(() => _errorMessage = 'En az bir fotoğraf eklemelisin.');
      return;
    }

    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
    });

    try {
      final areaSquareMeters = int.parse(_areaController.text.trim());
      await _listingService.submit(
        listingType: _listingType,
        title: _titleController.text,
        price: int.parse(_priceController.text),
        city: _cityController.text,
        district: _districtController.text,
        address: _addressController.text,
        areaSquareMeters: areaSquareMeters,
        rooms: _rooms,
        description: _descriptionController.text,
        latitude: selectedLocation.latitude,
        longitude: selectedLocation.longitude,
        photos: _photos,
      );
      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      var message = 'İlan gönderilemedi. Bağlantını kontrol edip tekrar dene.';
      if (error is FirebaseException) {
        debugPrint(
          'İlan gönderme Firebase hatası: '
          '${error.plugin}/${error.code}: ${error.message}',
        );
        if (error.plugin == 'firebase_storage') {
          message = switch (error.code) {
            'unauthenticated' =>
              'Oturumun sona ermiş. Tekrar giriş yapıp dene.',
            'unauthorized' || 'permission-denied' =>
              'Fotoğraf yükleme izni yok. Storage kurallarının yayınlandığını kontrol et.',
            'bucket-not-found' || 'no-default-bucket' || 'unknown' =>
              'Firebase Storage alanı henüz kurulmamış. Firebase Console’da Storage > Get Started adımını tamamla.',
            _ => 'Fotoğraf yüklenemedi (Storage/${error.code}).',
          };
        } else {
          message = switch (error.code) {
            'permission-denied' =>
              'Firebase güvenlik kuralları ilan göndermeye izin vermiyor. Firestore kurallarının yayınlandığını kontrol et.',
            'unauthenticated' =>
              'Oturumun sona ermiş. Tekrar giriş yapıp dene.',
            _ => 'Firebase hatası (${error.plugin}/${error.code}). Biraz sonra tekrar dene.',
          };
        }
      } else if (error is StateError) {
        message = error.message.toString();
      } else {
        debugPrint('İlan gönderme hatası: $error');
      }
      setState(() {
        _errorMessage = message;
      });
    } finally {
      if (mounted) {
        setState(() => _isSubmitting = false);
      }
    }
  }

  void _clearSelectedLocation() {
    if (_selectedLocation == null) return;
    setState(() => _selectedLocation = null);
  }

  Future<void> _confirmListingLocation() async {
    final address = _addressController.text.trim();
    final district = _districtController.text.trim();
    final city = _cityController.text.trim();
    if (address.isEmpty || district.isEmpty || city.isEmpty) {
      setState(() {
        _errorMessage = 'Önce il, ilçe ve açık adresi doldurmalısın.';
      });
      return;
    }

    setState(() {
      _isLocatingAddress = true;
      _errorMessage = null;
    });
    try {
      final matches = await geo_coding.locationFromAddress(
        '$address, $district, $city, Türkiye',
      );
      if (matches.isEmpty) {
        throw StateError(
          'Adres bulunamadı. Sokak ve bina numarasını kontrol et.',
        );
      }
      if (!mounted) return;
      final selectedLocation = await showModalBottomSheet<LatLng>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        backgroundColor: const Color(0xFF171817),
        builder: (context) => _ListingLocationPicker(
          initialPosition: LatLng(
            matches.first.latitude,
            matches.first.longitude,
          ),
        ),
      );
      if (selectedLocation != null && mounted) {
        setState(() => _selectedLocation = selectedLocation);
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _errorMessage = error is StateError
            ? error.message.toString()
            : 'Adresin konumu bulunamadı. Adresi kontrol edip tekrar dene.';
      });
    } finally {
      if (mounted) setState(() => _isLocatingAddress = false);
    }
  }

  String? _requiredText(String? value, String label, {int maxLength = 100}) {
    final text = value?.trim() ?? '';
    if (text.isEmpty) {
      return '$label gerekli.';
    }
    if (text.length > maxLength) {
      return '$label en fazla $maxLength karakter olabilir.';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: bottomInset),
        child: DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.92,
          minChildSize: 0.65,
          maxChildSize: 0.96,
          builder: (context, scrollController) => Material(
            color: const Color(0xFF171817),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
            child: Form(
              key: _formKey,
              child: CustomScrollView(
                controller: scrollController,
                slivers: [
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(20, 10, 20, 28),
                    sliver: SliverList(
                      delegate: SliverChildListDelegate([
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
                        const SizedBox(height: 20),
                        Row(
                          children: [
                            const Expanded(
                              child: Text(
                                'İlan ver',
                                style: TextStyle(
                                  color: _textColor,
                                  fontSize: 23,
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
                        const SizedBox(height: 18),
                        _buildListingTypeSelector(),
                        const SizedBox(height: 18),
                        _buildPhotoPicker(),
                        const SizedBox(height: 19),
                        TextFormField(
                          controller: _titleController,
                          maxLength: 100,
                          style: const TextStyle(color: _textColor),
                          decoration: _decoration('İlan başlığı'),
                          validator: (value) => _requiredText(
                            value,
                            'İlan başlığı',
                            maxLength: 100,
                          ),
                        ),
                        const SizedBox(height: 8),
                        TextFormField(
                          controller: _priceController,
                          keyboardType: TextInputType.number,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                          ],
                          style: const TextStyle(color: _textColor),
                          decoration: _decoration('Fiyat', suffixText: 'TL'),
                          validator: (value) {
                            final price = int.tryParse(value ?? '');
                            if (price == null ||
                                price < 1 ||
                                price > 5000000000) {
                              return 'Geçerli bir fiyat gir.';
                            }
                            return null;
                          },
                        ),
                        const SizedBox(height: 14),
                        Row(
                          children: [
                            Expanded(
                              child: TextFormField(
                                controller: _cityController,
                                maxLength: 60,
                                style: const TextStyle(color: _textColor),
                                decoration: _decoration('İl'),
                                onChanged: (_) => _clearSelectedLocation(),
                                validator: (value) =>
                                    _requiredText(value, 'İl', maxLength: 60),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: TextFormField(
                                controller: _districtController,
                                maxLength: 80,
                                style: const TextStyle(color: _textColor),
                                decoration: _decoration('İlçe'),
                                onChanged: (_) => _clearSelectedLocation(),
                                validator: (value) =>
                                    _requiredText(value, 'İlçe', maxLength: 80),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        TextFormField(
                          controller: _addressController,
                          maxLength: 250,
                          minLines: 2,
                          maxLines: 3,
                          style: const TextStyle(color: _textColor),
                          onChanged: (_) => _clearSelectedLocation(),
                          decoration: _decoration(
                            'Açık adres (mahalle, sokak, bina no)',
                          ),
                          validator: (value) => _requiredText(
                            value,
                            'Açık adres',
                            maxLength: 250,
                          ),
                        ),
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            onPressed: _isLocatingAddress || _isSubmitting
                                ? null
                                : _confirmListingLocation,
                            style: OutlinedButton.styleFrom(
                              foregroundColor: const Color(0xFFFFAB66),
                              side: const BorderSide(color: Color(0xFF8A4A20)),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              padding: const EdgeInsets.symmetric(vertical: 13),
                            ),
                            icon: _isLocatingAddress
                                ? const SizedBox.square(
                                    dimension: 17,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Color(0xFFFFAB66),
                                    ),
                                  )
                                : Icon(
                                    _selectedLocation == null
                                        ? Icons.location_searching_rounded
                                        : Icons.location_on_rounded,
                                  ),
                            label: Text(
                              _isLocatingAddress
                                  ? 'Adres aranıyor'
                                  : _selectedLocation == null
                                  ? 'Adresi haritada doğrula'
                                  : 'Konum seçildi · değiştir',
                            ),
                          ),
                        ),
                        CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          controlAffinity: ListTileControlAffinity.leading,
                          value: _shareExactAddress,
                          activeColor: const Color(0xFFFF7A00),
                          checkColor: Colors.white,
                          onChanged: _isSubmitting
                              ? null
                              : (value) => setState(
                                  () => _shareExactAddress = value ?? false,
                                ),
                          title: const Text(
                            'Açık adresim ve tam konumum ilan detayında herkese gösterilsin.',
                            style: TextStyle(
                              color: _textColor,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          subtitle: const Text(
                            'Harita pini girdiğin açık adrese göre yerleştirilir.',
                            style: TextStyle(color: _mutedColor, fontSize: 12),
                          ),
                        ),
                        const SizedBox(height: 18),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: TextFormField(
                                controller: _areaController,
                                keyboardType: TextInputType.number,
                                inputFormatters: [
                                  FilteringTextInputFormatter.digitsOnly,
                                ],
                                style: const TextStyle(color: _textColor),
                                decoration: _decoration(
                                  'Alan',
                                  suffixText: 'm²',
                                ),
                                validator: (value) {
                                  final area = int.tryParse(value ?? '');
                                  if (area == null ||
                                      area < 1 ||
                                      area > 10000) {
                                    return '1–10.000 m² gir.';
                                  }
                                  return null;
                                },
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(child: _buildRoomSelector()),
                          ],
                        ),
                        const SizedBox(height: 18),
                        TextFormField(
                          controller: _descriptionController,
                          minLines: 3,
                          maxLines: 5,
                          maxLength: 1000,
                          style: const TextStyle(color: _textColor),
                          decoration: _decoration('Açıklama'),
                          validator: (value) =>
                              _requiredText(value, 'Açıklama', maxLength: 1000),
                        ),
                        if (_errorMessage != null) ...[
                          const SizedBox(height: 8),
                          Text(
                            _errorMessage!,
                            style: const TextStyle(
                              color: Color(0xFFFF8A80),
                              fontSize: 13,
                            ),
                          ),
                        ],
                        const SizedBox(height: 12),
                        SizedBox(
                          height: 52,
                          child: FilledButton.icon(
                            onPressed: _isSubmitting ? null : _submit,
                            style: FilledButton.styleFrom(
                              backgroundColor: const Color(0xFFFF7A00),
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(13),
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
                                : const Icon(Icons.send_rounded),
                            label: Text(
                              _isSubmitting
                                  ? 'Gönderiliyor'
                                  : 'İncelemeye gönder',
                              style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                      ]),
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

  Widget _buildListingTypeSelector() {
    return Row(
      children: [
        Expanded(child: _typeButton('Kiralık', 'kiralik')),
        const SizedBox(width: 10),
        Expanded(child: _typeButton('Satılık', 'satilik')),
      ],
    );
  }

  Widget _typeButton(String label, String value) {
    final selected = _listingType == value;
    return Material(
      color: selected ? const Color(0xFFFF7A00) : const Color(0xFF262725),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: _isSubmitting
            ? null
            : () => setState(() => _listingType = value),
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          height: 46,
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                color: selected ? Colors.white : const Color(0xFFD3D2CE),
                fontSize: 14,
                fontWeight: FontWeight.w700,
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
                'Fotoğraflar',
                style: TextStyle(
                  color: _textColor,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            Text(
              '${_photos.length}/${PropertyListingService.maxPhotos}',
              style: const TextStyle(color: _mutedColor, fontSize: 12),
            ),
          ],
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 96,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount:
                _photos.length +
                (_photos.length < PropertyListingService.maxPhotos ? 1 : 0),
            separatorBuilder: (context, index) => const SizedBox(width: 9),
            itemBuilder: (context, index) {
              if (index == _photos.length) {
                return Material(
                  color: const Color(0xFF252624),
                  borderRadius: BorderRadius.circular(12),
                  child: InkWell(
                    onTap: _isSubmitting ? null : _pickPhotos,
                    borderRadius: BorderRadius.circular(12),
                    child: Container(
                      width: 96,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0xFF4A4B48)),
                      ),
                      child: const Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.add_photo_alternate_outlined,
                            color: Color(0xFFFF9A3D),
                            size: 25,
                          ),
                          SizedBox(height: 5),
                          Text(
                            'Ekle',
                            style: TextStyle(color: _mutedColor, fontSize: 12),
                          ),
                        ],
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
                      width: 96,
                      height: 96,
                      fit: BoxFit.cover,
                    ),
                  ),
                  Positioned(
                    top: 3,
                    right: 3,
                    child: Material(
                      color: const Color(0xCC111111),
                      shape: const CircleBorder(),
                      child: IconButton(
                        tooltip: 'Fotoğrafı kaldır',
                        onPressed: _isSubmitting
                            ? null
                            : () => setState(() {
                                _photos.removeAt(index);
                                _photoBytes.removeAt(index);
                              }),
                        icon: const Icon(Icons.close_rounded, size: 17),
                        color: Colors.white,
                        visualDensity: VisualDensity.compact,
                        constraints: const BoxConstraints.tightFor(
                          width: 30,
                          height: 30,
                        ),
                        padding: EdgeInsets.zero,
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
        const SizedBox(height: 5),
        const Text(
          'En fazla 5 fotoğraf, her biri 5 MB altında.',
          style: TextStyle(color: _mutedColor, fontSize: 12),
        ),
      ],
    );
  }

  Widget _buildRoomSelector() {
    const options = ['1+0', '1+1', '2+1', '3+1', '4+1', '5+'];
    return DropdownButtonFormField<String>(
      initialValue: _rooms,
      dropdownColor: const Color(0xFF252624),
      style: const TextStyle(color: _textColor, fontSize: 14),
      decoration: _decoration('Oda'),
      items: options
          .map((rooms) => DropdownMenuItem(value: rooms, child: Text(rooms)))
          .toList(),
      onChanged: _isSubmitting
          ? null
          : (value) {
              if (value != null) {
                setState(() => _rooms = value);
              }
            },
    );
  }
}

class _ListingLocationPicker extends StatefulWidget {
  final LatLng initialPosition;

  const _ListingLocationPicker({required this.initialPosition});

  @override
  State<_ListingLocationPicker> createState() => _ListingLocationPickerState();
}

class _ListingLocationPickerState extends State<_ListingLocationPicker> {
  late LatLng _selectedPosition = widget.initialPosition;

  @override
  Widget build(BuildContext context) {
    final mapHeight = MediaQuery.sizeOf(context).height * 0.78;
    return SizedBox(
      height: mapHeight,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 12, 8, 10),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    'İlan konumu',
                    style: TextStyle(
                      color: Color(0xFFF4F1EC),
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Kapat',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close_rounded),
                  color: Colors.white70,
                ),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(18, 0, 18, 10),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Pini bina üzerine sürükle veya haritaya dokun.',
                style: TextStyle(color: Color(0xFFAAA9A5), fontSize: 12),
              ),
            ),
          ),
          Expanded(
            child: GoogleMap(
              initialCameraPosition: CameraPosition(
                target: widget.initialPosition,
                zoom: 18,
              ),
              markers: {
                Marker(
                  markerId: const MarkerId('listing-exact-location'),
                  position: _selectedPosition,
                  draggable: true,
                  onDragEnd: (position) =>
                      setState(() => _selectedPosition = position),
                ),
              },
              onTap: (position) => setState(() => _selectedPosition = position),
              myLocationButtonEnabled: false,
              myLocationEnabled: false,
              mapToolbarEnabled: false,
              zoomControlsEnabled: true,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 16),
            child: SizedBox(
              width: double.infinity,
              height: 48,
              child: FilledButton.icon(
                onPressed: () => Navigator.pop(context, _selectedPosition),
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFFF7A00),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                icon: const Icon(Icons.check_rounded),
                label: const Text('Bu konumu kullan'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
