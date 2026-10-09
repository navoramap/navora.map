import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:geocoding/geocoding.dart' as geo_coding;
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:speech_to_text/speech_to_text.dart';

import '../../services/places_service.dart';

class MapSearchPage extends StatefulWidget {
  final String initialQuery;
  final List<Map<String, dynamic>> initialHistory;
  final LatLng? initialLocation;

  const MapSearchPage({
    super.key,
    this.initialQuery = '',
    required this.initialHistory,
    this.initialLocation,
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
  final SpeechToText _speech = SpeechToText();
  List<Map<String, dynamic>> _history = [];
  List<Map<String, dynamic>> _suggestions = [];

  @override
  void initState() {
    super.initState();
    _controller.text = widget.initialQuery;
    _history = List<Map<String, dynamic>>.from(widget.initialHistory);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
    });
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

    if (_suggestions.isNotEmpty) {
      await _selectSuggestion(_suggestions.first);
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
      if (NavoraPlacesService.isBusinessQuery(query)) {
        try {
          final businesses = await NavoraPlacesService.searchText(
            query,
            location: widget.initialLocation,
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
          final googleResults = await NavoraPlacesService.autocomplete(query);
          if (googleResults.isNotEmpty) {
            if (!mounted || requestId != _requestId) return;
            setState(() => _suggestions = googleResults);
            return;
          }
        } catch (error) {
          debugPrint('Google Places autocomplete failed: $error');
        }
      }

      final uri = Uri.https(
        'nominatim.openstreetmap.org',
        '/search',
        {
          'q': query,
          'format': 'jsonv2',
          'addressdetails': '1',
          'namedetails': '1',
          'extratags': '1',
          'dedupe': '1',
          'limit': '8',
          'countrycodes': 'tr',
        },
      );

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
          if (value != null && value.isNotEmpty && !subtitleParts.contains(value)) {
            subtitleParts.add(value);
          }
        }

        return <String, dynamic>{
          'name': title,
          'subtitle': subtitleParts.isEmpty
              ? parts.skip(1).join(', ').trim()
              : subtitleParts.join(', '),
          'type': item['type']?.toString() ?? 'place',
          'category': item['type']?.toString() == 'amenity' ? 'İşletme' : 'Konum',
          'query': displayName,
          'coordinate': LatLng(
            double.parse(item['lat'].toString()),
            double.parse(item['lon'].toString()),
          ),
        };
      }).toList();

      if (!mounted || requestId != _requestId) return;
      setState(() {
        _suggestions = suggestions;
      });
    } catch (error) {
      debugPrint('Search suggestions failed: $error');
      if (mounted) setState(() => _suggestions = []);
    }
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

  void _clearHistory() {
    setState(() {
      _history.clear();
      _suggestions = [];
    });
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
    final results = _suggestions.isNotEmpty ? _suggestions : _history;

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
                                contentPadding: EdgeInsets.symmetric(vertical: 13),
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
                                child: CircularProgressIndicator(strokeWidth: 2),
                              ),
                            )
                          else
                            IconButton(
                              onPressed: () => _handleSubmitted(_controller.text),
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
            Expanded(
              child: ListView.separated(
                padding: const EdgeInsets.fromLTRB(10, 4, 10, 20),
                itemCount: results.length + (_suggestions.isEmpty && results.isNotEmpty ? 1 : 0),
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  if (_suggestions.isEmpty && index == results.length) {
                    return Container(
                      alignment: Alignment.center,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: TextButton.icon(
                        onPressed: _clearHistory,
                        icon: const Icon(Icons.delete_outline_rounded),
                        label: const Text('Geçmişi temizle'),
                      ),
                    );
                  }

                  final item = results[index];
                  final isHistory = _suggestions.isEmpty;
                  return ListTile(
                    dense: true,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 2,
                    ),
                    leading: Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: const Color(0xFF2A180D),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(
                        isHistory ? Icons.history_rounded : _resultIcon(item['type'] as String?),
                        color: const Color(0xFFFF6B00),
                        size: 18,
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
                          : '${item['category'] ?? 'Konum'} • ${item['subtitle'] as String? ?? 'Konum önerisi'}',
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
                        final historyQuery = item['query']?.toString() ?? item['name']?.toString() ?? '';
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

