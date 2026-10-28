import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:geocoding/geocoding.dart' as geo_coding;
import 'package:geolocator/geolocator.dart' as geo;
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:speech_to_text/speech_to_text.dart';

import '../../services/places_service.dart';

List<Map<String, dynamic>> navoraFilterMapSearchResults(
  Iterable<Map<String, dynamic>> results, {
  required String category,
  required int? radiusKm,
}) {
  final categoryKeywords = switch (category) {
    'Kafe' => ['cafe', 'coffee'],
    'Restoran' => ['restaurant', 'fast_food', 'meal_takeaway', 'meal_delivery'],
    'Market' => ['supermarket', 'grocery', 'convenience', 'market'],
    'Benzinlik' => ['gas_station', 'fuel'],
    'Park' => ['park', 'garden'],
    'Hastane' => ['hospital', 'clinic', 'doctor', 'medical'],
    'Ulaşım' => [
      'bus_station',
      'bus_stop',
      'transit_station',
      'train_station',
      'subway_station',
    ],
    _ => const <String>[],
  };
  final radiusMeters = radiusKm == null ? null : radiusKm * 1000;

  return results.where((result) {
    if (categoryKeywords.isNotEmpty) {
      final values = [
        result['category']?.toString().toLowerCase() ?? '',
        result['type']?.toString().toLowerCase() ?? '',
      ];
      if (!values.any(
        (value) =>
            value.contains(category.toLowerCase()) ||
            categoryKeywords.any(value.contains),
      )) {
        return false;
      }
    }

    final distance = (result['distanceMeters'] as num?)?.toDouble();
    return radiusMeters == null || distance == null || distance <= radiusMeters;
  }).toList();
}

class MapSearchPage extends StatefulWidget {
  final String initialQuery;
  final List<Map<String, dynamic>> initialHistory;
  final LatLng? initialLocation;
  final bool isHistoryEnabled;
  final Future<bool> Function()? onClearHistory;
  final Future<void> Function(bool enabled)? onHistoryEnabledChanged;

  const MapSearchPage({
    super.key,
    this.initialQuery = '',
    required this.initialHistory,
    this.initialLocation,
    this.isHistoryEnabled = true,
    this.onClearHistory,
    this.onHistoryEnabledChanged,
  });

  @override
  State<MapSearchPage> createState() => _MapSearchPageState();
}

class _MapSearchPageState extends State<MapSearchPage> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  Timer? _debounce;
  int _requestId = 0;
  bool _isSearching = false;
  bool _isListening = false;
  Future<LatLng?>? _searchOriginFuture;
  late LatLng? _searchOrigin;
  final SpeechToText _speech = SpeechToText();
  List<Map<String, dynamic>> _history = [];
  List<Map<String, dynamic>> _suggestions = [];
  String _selectedCategory = 'Tümü';
  int _selectedRadiusKm = 15;

  @override
  void initState() {
    super.initState();
    _controller.text = widget.initialQuery;
    _searchOrigin = widget.initialLocation;
    _history = List<Map<String, dynamic>>.from(widget.initialHistory);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
    });
  }

  Future<LatLng?> _getSearchOrigin() async {
    if (_searchOrigin != null) return _searchOrigin;
    final pending = _searchOriginFuture;
    if (pending != null) return pending;

    final future = _loadSearchOrigin();
    _searchOriginFuture = future;
    try {
      return await future;
    } finally {
      if (identical(_searchOriginFuture, future)) {
        _searchOriginFuture = null;
      }
    }
  }

  Future<LatLng?> _loadSearchOrigin() async {
    try {
      var permission = await geo.Geolocator.checkPermission();
      if (permission == geo.LocationPermission.denied) {
        permission = await geo.Geolocator.requestPermission();
      }
      if (permission == geo.LocationPermission.denied ||
          permission == geo.LocationPermission.deniedForever ||
          !await geo.Geolocator.isLocationServiceEnabled()) {
        return null;
      }

      final position = await geo.Geolocator.getCurrentPosition(
        locationSettings: const geo.LocationSettings(
          accuracy: geo.LocationAccuracy.medium,
        ),
      ).timeout(const Duration(seconds: 12));
      final origin = LatLng(position.latitude, position.longitude);
      if (mounted) setState(() => _searchOrigin = origin);
      return origin;
    } catch (error) {
      debugPrint('Search result distance location unavailable: $error');
      return _searchOrigin;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _handleSubmitted(String value) async {
    final query = value.trim();
    if (query.isEmpty) return;

    final visibleSuggestions = navoraFilterMapSearchResults(
      _suggestions,
      category: _selectedCategory,
      radiusKm: _selectedRadiusKm == 0 ? null : _selectedRadiusKm,
    );
    if (visibleSuggestions.isNotEmpty) {
      await _selectSuggestion(visibleSuggestions.first);
      return;
    }

    setState(() => _isSearching = true);
    try {
      final locations = await geo_coding.locationFromAddress(query);
      if (!mounted || locations.isEmpty) {
        setState(() => _isSearching = false);
        return;
      }
      final location = locations.first;
      final item = <String, dynamic>{
        'name': query,
        'subtitle': query,
        'query': query,
        'type': 'place',
        'category': 'Konum',
        'coordinate': LatLng(location.latitude, location.longitude),
      };
      if (!mounted) return;
      setState(() => _isSearching = false);
      Navigator.pop(context, item);
    } catch (_) {
      if (mounted) setState(() => _isSearching = false);
    }
  }

  void _handleSearchChanged(String value) {
    _debounce?.cancel();
    final query = value.trim();
    if (query.isEmpty) {
      setState(() => _suggestions = []);
      return;
    }

    _debounce = Timer(const Duration(milliseconds: 400), () async {
      await _loadSuggestions(query);
    });
  }

  Future<void> _loadSuggestions(String query) async {
    final requestId = ++_requestId;
    try {
      final searchOrigin = await _getSearchOrigin();
      if (!mounted || requestId != _requestId) return;
      if (NavoraPlacesService.isBusinessQuery(query)) {
        try {
          final businesses = await NavoraPlacesService.searchText(
            query,
            location: searchOrigin,
          );
          if (businesses.isNotEmpty) {
            if (!mounted || requestId != _requestId) return;
            setState(() => _suggestions = businesses);
            return;
          }
        } catch (error) {
          debugPrint('Google Places text search failed: $error');
        }
      } else {
        try {
          final googleResults = await NavoraPlacesService.searchText(
            query,
            location: searchOrigin,
          );
          if (googleResults.isNotEmpty) {
            if (!mounted || requestId != _requestId) return;
            setState(() => _suggestions = googleResults);
            return;
          }
        } catch (error) {
          debugPrint('Google Places text search failed: $error');
        }
        try {
          final googleSuggestions = await NavoraPlacesService.autocomplete(
            query,
            location: searchOrigin,
          );
          if (googleSuggestions.isNotEmpty) {
            if (!mounted || requestId != _requestId) return;
            setState(() => _suggestions = googleSuggestions);
            return;
          }
        } catch (error) {
          debugPrint('Google Places autocomplete failed: $error');
        }
      }

      final uri = Uri.https('nominatim.openstreetmap.org', '/search', {
        'q': query,
        'format': 'jsonv2',
        'addressdetails': '1',
        'namedetails': '1',
        'extratags': '1',
        'dedupe': '1',
        'limit': '8',
        'countrycodes': 'tr',
      });

      final response = await http.get(
        uri,
        headers: const {
          'User-Agent': 'NavoraMap/1.0 (search)',
          'Accept-Language': 'tr',
        },
      );

      if (response.statusCode != 200 || !mounted || requestId != _requestId) {
        return;
      }

      final results = jsonDecode(response.body) as List<dynamic>;
      final suggestions = results.map((result) {
        final item = result as Map<String, dynamic>;
        final displayName = item['display_name']?.toString() ?? query;
        final address = item['address'] as Map<String, dynamic>? ?? {};
        final parts = displayName.split(',');
        final name = item['name']?.toString().trim();
        final namedetails = item['namedetails'] as Map<String, dynamic>?;
        final title = (name != null && name.isNotEmpty)
            ? name
            : (namedetails?['name']?.toString().trim().isNotEmpty == true
                  ? namedetails!['name'].toString().trim()
                  : parts.first.trim());

        final subtitleParts = <String>[];
        for (final part in [
          address['road'],
          address['neighbourhood'],
          address['suburb'],
          address['city_district'],
          address['city'] ?? address['town'] ?? address['village'],
          address['state'],
        ]) {
          final value = part?.toString().trim();
          if (value != null &&
              value.isNotEmpty &&
              !subtitleParts.contains(value)) {
            subtitleParts.add(value);
          }
        }

        final coordinate = LatLng(
          double.parse(item['lat'].toString()),
          double.parse(item['lon'].toString()),
        );
        final currentLocation = searchOrigin;
        final distanceMeters = currentLocation == null
            ? null
            : geo.Geolocator.distanceBetween(
                currentLocation.latitude,
                currentLocation.longitude,
                coordinate.latitude,
                coordinate.longitude,
              );
        return <String, dynamic>{
          'name': title,
          'subtitle': subtitleParts.isEmpty
              ? parts.skip(1).join(', ').trim()
              : subtitleParts.join(', '),
          'type': item['type']?.toString() ?? 'place',
          'category': item['type']?.toString() == 'amenity'
              ? 'İşletme'
              : 'Konum',
          'query': displayName,
          'coordinate': coordinate,
          'distanceMeters': distanceMeters,
          'distanceText': distanceMeters == null
              ? null
              : _formatDistance(distanceMeters),
        };
      }).toList();

      if (searchOrigin != null) {
        suggestions.sort(
          (first, second) =>
              ((first['distanceMeters'] as double?) ?? double.infinity)
                  .compareTo(
                    (second['distanceMeters'] as double?) ?? double.infinity,
                  ),
        );
      }
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _suggestions = suggestions;
      });
    } catch (error) {
      debugPrint('Search suggestions failed: $error');
      if (mounted) setState(() => _suggestions = []);
    }
  }

  String _formatDistance(double meters) {
    return '${(meters / 1000).toStringAsFixed(1)} km';
  }

  void _cancelSearch() {
    Navigator.pop(context);
  }

  IconData _resultIcon(String? type) {
    switch (type) {
      case 'amenity':
        return Icons.home_work_rounded;
      case 'road':
        return Icons.route_rounded;
      case 'building':
        return Icons.business_rounded;
      case 'station':
        return Icons.train_rounded;
      default:
        return Icons.location_on_rounded;
    }
  }

  Future<void> _clearHistory() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Arama geçmişi silinsin mi?'),
        content: const Text(
          'Bu işlem hesabınızda kayıtlı arama geçmişini de siler.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Vazgeç'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Geçmişi sil'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    final cleared = await widget.onClearHistory?.call() ?? true;
    if (!cleared || !mounted) return;
    setState(() {
      _history.clear();
      _suggestions = [];
    });
  }

  Future<void> _showHistoryPrivacySheet() async {
    var isEnabled = widget.isHistoryEnabled;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF191919),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Arama gizliliği',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Arama geçmişiniz hesabınızla eşitlenir. Kaydı kapatırsanız yeni aramalar saklanmaz; mevcut geçmişi ayrıca silebilirsiniz.',
                  style: TextStyle(color: Colors.white70, height: 1.4),
                ),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text(
                    'Arama geçmişini kaydet',
                    style: TextStyle(color: Colors.white),
                  ),
                  value: isEnabled,
                  onChanged: (enabled) async {
                    setSheetState(() => isEnabled = enabled);
                    await widget.onHistoryEnabledChanged?.call(enabled);
                  },
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: _history.isEmpty
                        ? null
                        : () async {
                            Navigator.pop(sheetContext);
                            await _clearHistory();
                          },
                    icon: const Icon(Icons.delete_outline_rounded),
                    label: const Text('Kayıtlı geçmişi sil'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _toggleVoiceSearch() async {
    if (_isListening) {
      await _speech.stop();
      if (mounted) setState(() => _isListening = false);
      return;
    }

    final available = await _speech.initialize(
      onStatus: (status) {
        if ((status == 'done' || status == 'notListening') && mounted) {
          setState(() => _isListening = false);
        }
      },
      onError: (error) {
        debugPrint('Sesli arama hatası: ${error.errorMsg}');
        if (mounted) setState(() => _isListening = false);
      },
    );
    if (!available || !mounted) return;

    setState(() => _isListening = true);
    await _speech.listen(
      listenOptions: SpeechListenOptions(
        localeId: 'tr_TR',
        listenMode: ListenMode.search,
      ),
      onResult: (result) {
        if (!mounted) return;
        setState(() {
          _controller.text = result.recognizedWords;
          _controller.selection = TextSelection.fromPosition(
            TextPosition(offset: _controller.text.length),
          );
        });
        _handleSearchChanged(result.recognizedWords);
        if (result.finalResult) {
          _speech.stop();
          setState(() => _isListening = false);
          _handleSubmitted(result.recognizedWords);
        }
      },
    );
  }

  Future<void> _selectSuggestion(Map<String, dynamic> item) async {
    var resolvedItem = item;
    final placeId = item['placeId']?.toString();
    if (placeId != null && placeId.isNotEmpty) {
      try {
        final details = await NavoraPlacesService.getPlaceDetails(placeId);
        if (details != null) resolvedItem = {...item, ...details};
      } catch (_) {
        return;
      }
    }
    if (!mounted || resolvedItem['coordinate'] == null) return;
    Navigator.pop(context, resolvedItem);
  }

  @override
  Widget build(BuildContext context) {
    final isShowingSuggestions = _suggestions.isNotEmpty;
    final results = isShowingSuggestions
        ? navoraFilterMapSearchResults(
            _suggestions,
            category: _selectedCategory,
            radiusKm: _selectedRadiusKm == 0 ? null : _selectedRadiusKm,
          )
        : _history;
    final filters = const [
      'Tümü',
      'Kafe',
      'Restoran',
      'Market',
      'Benzinlik',
      'Park',
      'Hastane',
      'Ulaşım',
    ];

    return Scaffold(
      backgroundColor: const Color(0xFF191919),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
              child: Row(
                children: [
                  IconButton(
                    onPressed: _cancelSearch,
                    icon: const Icon(Icons.arrow_back_rounded),
                    color: Colors.white,
                  ),
                  Expanded(
                    child: Container(
                      height: 48,
                      decoration: BoxDecoration(
                        color: const Color(0xFF1B1B1B),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: Colors.black.withValues(alpha: 0.06),
                          width: 0.8,
                        ),
                      ),
                      child: Row(
                        children: [
                          const SizedBox(width: 12),
                          const Icon(
                            Icons.search_rounded,
                            color: Color(0xFFFF7A00),
                          ),
                          Expanded(
                            child: TextField(
                              controller: _controller,
                              focusNode: _focusNode,
                              textInputAction: TextInputAction.search,
                              onChanged: _handleSearchChanged,
                              onSubmitted: _handleSubmitted,
                              style: const TextStyle(color: Colors.white),
                              decoration: const InputDecoration(
                                hintText: 'Ara',
                                hintStyle: TextStyle(color: Color(0xFFBDBDBD)),
                                border: InputBorder.none,
                                enabledBorder: InputBorder.none,
                                focusedBorder: InputBorder.none,
                                contentPadding: EdgeInsets.symmetric(
                                  vertical: 13,
                                ),
                              ),
                            ),
                          ),
                          if (_controller.text.trim().isNotEmpty)
                            IconButton(
                              onPressed: () {
                                _controller.clear();
                                setState(() => _suggestions = []);
                              },
                              icon: const Icon(Icons.close_rounded),
                              color: const Color(0xFFB8B8B8),
                              splashRadius: 18,
                            )
                          else
                            const SizedBox(width: 8),
                          IconButton(
                            onPressed: _toggleVoiceSearch,
                            tooltip: _isListening
                                ? 'Sesli aramayı durdur'
                                : 'Sesli ara',
                            icon: Icon(
                              _isListening
                                  ? Icons.mic_rounded
                                  : Icons.mic_none_rounded,
                              color: _isListening
                                  ? Colors.redAccent
                                  : const Color(0xFFFF7A00),
                            ),
                            splashRadius: 18,
                          ),
                          if (_isSearching)
                            const Padding(
                              padding: EdgeInsets.only(right: 12),
                              child: SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                            )
                          else
                            IconButton(
                              onPressed: () =>
                                  _handleSubmitted(_controller.text),
                              icon: const Icon(Icons.search_rounded),
                              color: const Color(0xFFFF6B00),
                              splashRadius: 18,
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (_history.isNotEmpty && !isShowingSuggestions)
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 4, 14, 2),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: const Text(
                    'Son aramalar',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            if (isShowingSuggestions)
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 2, 14, 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      height: 38,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        children: [
                          for (final category in filters)
                            Padding(
                              padding: const EdgeInsets.only(right: 7),
                              child: ChoiceChip(
                                label: Text(category),
                                selected: _selectedCategory == category,
                                onSelected: (_) => setState(
                                  () => _selectedCategory = category,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    Row(
                      children: [
                        Text(
                          '${results.length} sonuç',
                          style: const TextStyle(color: Colors.white70),
                        ),
                        const Spacer(),
                        const Icon(
                          Icons.tune_rounded,
                          color: Colors.white70,
                          size: 18,
                        ),
                        const SizedBox(width: 6),
                        DropdownButton<int>(
                          value: _selectedRadiusKm,
                          dropdownColor: const Color(0xFF242424),
                          underline: const SizedBox.shrink(),
                          style: const TextStyle(color: Colors.white),
                          items: const [
                            DropdownMenuItem(value: 2, child: Text('2 km')),
                            DropdownMenuItem(value: 5, child: Text('5 km')),
                            DropdownMenuItem(value: 10, child: Text('10 km')),
                            DropdownMenuItem(value: 15, child: Text('15 km')),
                            DropdownMenuItem(value: 0, child: Text('Sınırsız')),
                          ],
                          onChanged: (radius) {
                            if (radius != null) {
                              setState(() => _selectedRadiusKm = radius);
                            }
                          },
                        ),
                      ],
                    ),
                    if (_searchOrigin == null && _selectedRadiusKm != 0)
                      const Padding(
                        padding: EdgeInsets.only(top: 2),
                        child: Text(
                          'Uzaklık filtresi için konum izni gerekli.',
                          style: TextStyle(
                            color: Color(0xFFFFB36B),
                            fontSize: 12,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            Expanded(
              child: ListView.separated(
                padding: const EdgeInsets.fromLTRB(10, 4, 10, 20),
                itemCount:
                    results.length +
                    (isShowingSuggestions && results.isEmpty ? 1 : 0) +
                    (!isShowingSuggestions && results.isNotEmpty ? 1 : 0),
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  if (isShowingSuggestions && results.isEmpty) {
                    return const Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(
                        child: Text(
                          'Bu filtrelerle eşleşen sonuç bulunamadı.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.white70),
                        ),
                      ),
                    );
                  }
                  if (!isShowingSuggestions && index == results.length) {
                    return Container(
                      alignment: Alignment.center,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          TextButton.icon(
                            onPressed: _showHistoryPrivacySheet,
                            icon: const Icon(Icons.privacy_tip_outlined),
                            label: const Text('Gizlilik'),
                          ),
                          TextButton.icon(
                            onPressed: _clearHistory,
                            icon: const Icon(Icons.delete_outline_rounded),
                            label: const Text('Geçmişi temizle'),
                          ),
                        ],
                      ),
                    );
                  }

                  final item = results[index];
                  final isHistory = !isShowingSuggestions;
                  return ListTile(
                    dense: true,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 2,
                    ),
                    leading: SizedBox(
                      width: 52,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 32,
                            height: 32,
                            decoration: BoxDecoration(
                              color: const Color(0xFF2A180D),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Icon(
                              isHistory
                                  ? Icons.history_rounded
                                  : _resultIcon(item['type'] as String?),
                              color: const Color(0xFFFF6B00),
                              size: 18,
                            ),
                          ),
                          if (!isHistory) ...[
                            const SizedBox(height: 2),
                            Text(
                              item['distanceText'] as String? ??
                                  'Konum gerekli',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: Color(0xFFFFB36B),
                                fontSize: 8,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    title: Text(
                      item['name'] as String,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 15,
                        color: Colors.white,
                      ),
                    ),
                    subtitle: Text(
                      isHistory
                          ? item['query'] as String
                          : item['subtitle'] as String? ?? 'Konum önerisi',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.grey.shade600,
                        fontSize: 12,
                      ),
                    ),
                    trailing: const Icon(
                      Icons.chevron_right_rounded,
                      color: Color(0xFF888888),
                    ),
                    onTap: () {
                      if (isHistory) {
                        final historyQuery =
                            item['query']?.toString() ??
                            item['name']?.toString() ??
                            '';
                        _controller.text = historyQuery;
                        _controller.selection = TextSelection.collapsed(
                          offset: historyQuery.length,
                        );
                        _handleSubmitted(historyQuery);
                        return;
                      }
                      _selectSuggestion(item);
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
