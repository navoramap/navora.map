import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;

class NavoraPlacesService {
  static const _identityChannel = MethodChannel(
    'navora/google_places_client_identity',
  );
  static const _businessSearchTerms = [
    'kafe', 'kahve', 'coffee', 'cafe', 'benzin', 'akaryakıt', 'fuel',
    'petrol', 'restoran', 'lokanta', 'yemek', 'restaurant', 'market',
    'bakkal', 'süpermarket', 'supermarket', 'park', 'bahçe', 'garden',
    'hastane', 'klinik', 'hospital', 'clinic', 'otobüs', 'durak', 'bus',
    'tramvay', 'metro',
  ];

  static const String apiKey = String.fromEnvironment(
    'GOOGLE_PLACES_API_KEY',
    defaultValue: 'AIzaSyAgDEdDHf08ePqpkCJBTx0oaCzJetyhawg',
  );
  static final Future<Map<String, String>> _clientIdentityHeaders =
      _loadClientIdentityHeaders();

  static Future<Map<String, String>> _loadClientIdentityHeaders() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return const {};
    }

    final identity = await _identityChannel.invokeMapMethod<String, String>(
      'getIdentity',
    );
    final packageName = identity?['packageName'];
    final certificateSha1 = identity?['sha1'];
    if (packageName == null || certificateSha1 == null) {
      throw StateError('Android Places client identity is unavailable.');
    }

    return {
      'X-Android-Package': packageName,
      'X-Android-Cert': certificateSha1,
    };
  }

  static bool isBusinessQuery(String query) {
    final normalized = query.trim().toLowerCase();
    return _businessSearchTerms.any(normalized.contains);
  }

  static Future<List<Map<String, dynamic>>> searchText(
    String query, {
    LatLng? location,
  }) async {
    final trimmedQuery = query.trim();
    if (trimmedQuery.isEmpty || apiKey.isEmpty) return [];

    final body = <String, dynamic>{
      'textQuery': trimmedQuery,
      'languageCode': 'tr',
      'regionCode': 'TR',
      'pageSize': 10,
    };
    if (location != null) {
      body['locationBias'] = {
        'circle': {
          'center': {
            'latitude': location.latitude,
            'longitude': location.longitude,
          },
          'radius': 15000.0,
        },
      };
    }
    final clientIdentityHeaders = await _clientIdentityHeaders;

    final response = await http.post(
      Uri.parse('https://places.googleapis.com/v1/places:searchText'),
      headers: {
        ...clientIdentityHeaders,
        'Content-Type': 'application/json',
        'X-Goog-Api-Key': apiKey,
        'X-Goog-FieldMask': [
          'places.id',
          'places.displayName',
          'places.formattedAddress',
          'places.location',
          'places.types',
          'places.primaryType',
          'places.rating',
          'places.userRatingCount',
        ].join(','),
      },
      body: jsonEncode(body),
    ).timeout(const Duration(seconds: 8));

    if (response.statusCode != 200) {
      throw Exception('Places API HTTP ${response.statusCode}: ${response.body}');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final places = data['places'] as List<dynamic>? ?? const [];
    return places.map((rawPlace) {
      final place = rawPlace as Map<String, dynamic>;
      final displayName = place['displayName'] as Map<String, dynamic>? ?? {};
      final rawLocation = place['location'] as Map<String, dynamic>? ?? {};
      final latitude = (rawLocation['latitude'] as num?)?.toDouble();
      final longitude = (rawLocation['longitude'] as num?)?.toDouble();
      if (latitude == null || longitude == null) {
        return <String, dynamic>{};
      }

      final types = (place['types'] as List<dynamic>? ?? const [])
          .map((type) => type.toString())
          .toList();
      final primaryType = place['primaryType']?.toString();
      final rating = (place['rating'] as num?)?.toDouble();
      final ratingCount = (place['userRatingCount'] as num?)?.toInt();
      final subtitle = place['formattedAddress']?.toString() ?? 'Konum';
      final ratingText = rating == null
          ? null
          : '${rating.toStringAsFixed(1)}${ratingCount == null ? '' : ' ($ratingCount)'}';

      return <String, dynamic>{
        'name': displayName['text']?.toString() ?? trimmedQuery,
        'subtitle': subtitle,
        'query': '$trimmedQuery, $subtitle',
        'placeId': place['id']?.toString(),
        'type': primaryType ?? (types.isEmpty ? 'place' : types.first),
        'category': 'Google işletmesi',
        'coordinate': LatLng(latitude, longitude),
        'ratingText': ratingText,
        'source': 'google_places',
      };
    }).where((place) => place.isNotEmpty).toList();
  }

  static Future<List<Map<String, dynamic>>> autocomplete(
    String query, {
    LatLng? location,
  }) async {
    final trimmedQuery = query.trim();
    if (trimmedQuery.isEmpty || apiKey.isEmpty) return [];

    final body = <String, dynamic>{
      'input': trimmedQuery,
      'languageCode': 'tr',
      'includedRegionCodes': ['tr'],
    };
    if (location != null) {
      body['locationBias'] = {
        'circle': {
          'center': {
            'latitude': location.latitude,
            'longitude': location.longitude,
          },
          'radius': 25000.0,
        },
      };
    }
    final clientIdentityHeaders = await _clientIdentityHeaders;

    final response = await http.post(
      Uri.parse('https://places.googleapis.com/v1/places:autocomplete'),
      headers: {
        ...clientIdentityHeaders,
        'Content-Type': 'application/json',
        'X-Goog-Api-Key': apiKey,
        'X-Goog-FieldMask': [
          'suggestions.placePrediction.placeId',
          'suggestions.placePrediction.text',
          'suggestions.placePrediction.structuredFormat',
        ].join(','),
      },
      body: jsonEncode(body),
    ).timeout(const Duration(seconds: 8));

    if (response.statusCode != 200) {
      throw Exception('Places autocomplete HTTP ${response.statusCode}');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final suggestions = data['suggestions'] as List<dynamic>? ?? const [];
    return suggestions.map((rawSuggestion) {
      final suggestion = rawSuggestion as Map<String, dynamic>;
      final prediction = suggestion['placePrediction'] as Map<String, dynamic>?;
      if (prediction == null) return <String, dynamic>{};
      final text = prediction['text'] as Map<String, dynamic>? ?? {};
      final structured =
          prediction['structuredFormat'] as Map<String, dynamic>? ?? {};
      final mainText = structured['mainText'] as Map<String, dynamic>? ?? {};
      final secondaryText =
          structured['secondaryText'] as Map<String, dynamic>? ?? {};
      final name = mainText['text']?.toString() ?? text['text']?.toString();
      final subtitle = secondaryText['text']?.toString() ?? '';
      final placeId = prediction['placeId']?.toString();
      if (name == null || name.isEmpty || placeId == null || placeId.isEmpty) {
        return <String, dynamic>{};
      }
      return <String, dynamic>{
        'name': name,
        'subtitle': subtitle,
        'query': text['text']?.toString() ?? name,
        'type': 'place',
        'category': 'Google önerisi',
        'placeId': placeId,
        'source': 'google_autocomplete',
      };
    }).where((item) => item.isNotEmpty).toList();
  }

  static Future<Map<String, dynamic>?> getPlaceDetails(String placeId) async {
    if (placeId.isEmpty || apiKey.isEmpty) return null;
    final clientIdentityHeaders = await _clientIdentityHeaders;
    final response = await http.get(
      Uri.parse('https://places.googleapis.com/v1/places/$placeId'),
      headers: {
        ...clientIdentityHeaders,
        'X-Goog-Api-Key': apiKey,
        'X-Goog-FieldMask': [
          'displayName',
          'formattedAddress',
          'location',
          'types',
          'primaryType',
          'rating',
          'userRatingCount',
          'nationalPhoneNumber',
          'websiteUri',
          'regularOpeningHours.weekdayDescriptions',
          'currentOpeningHours.openNow',
        ].join(','),
      },
    ).timeout(const Duration(seconds: 8));
    if (response.statusCode != 200) {
      throw Exception('Places details HTTP ${response.statusCode}');
    }

    final place = jsonDecode(response.body) as Map<String, dynamic>;
    final location = place['location'] as Map<String, dynamic>? ?? {};
    final latitude = (location['latitude'] as num?)?.toDouble();
    final longitude = (location['longitude'] as num?)?.toDouble();
    if (latitude == null || longitude == null) return null;
    final displayName = place['displayName'] as Map<String, dynamic>? ?? {};
    final types = (place['types'] as List<dynamic>? ?? const [])
        .map((type) => type.toString())
        .toList();
    final rating = (place['rating'] as num?)?.toDouble();
    final ratingCount = (place['userRatingCount'] as num?)?.toInt();
    final regularHours =
        place['regularOpeningHours'] as Map<String, dynamic>? ?? {};
    final currentHours =
        place['currentOpeningHours'] as Map<String, dynamic>? ?? {};
    final openingHours = (regularHours['weekdayDescriptions'] as List<dynamic>? ?? const [])
        .map((day) => day.toString())
        .toList(growable: false);

    return <String, dynamic>{
      'placeId': placeId,
      'name': displayName['text']?.toString() ?? 'Konum',
      'subtitle': place['formattedAddress']?.toString() ?? 'Konum',
      'query': place['formattedAddress']?.toString() ?? displayName['text']?.toString(),
      'type': place['primaryType']?.toString() ?? (types.isEmpty ? 'place' : types.first),
      'category': 'Google işletmesi',
      'coordinate': LatLng(latitude, longitude),
      'ratingText': rating == null
          ? null
          : '${rating.toStringAsFixed(1)}${ratingCount == null ? '' : ' ($ratingCount)'}',
        'phoneNumber': place['nationalPhoneNumber']?.toString(),
        'websiteUri': place['websiteUri']?.toString(),
        'openingHours': openingHours,
        'isOpenNow': currentHours['openNow'] as bool?,
      'source': 'google_places',
    };
  }
}

