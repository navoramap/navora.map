import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import 'google_maps_proxy_service.dart';

class NavoraPlacesService {
  static const _businessSearchTerms = [
    'kafe',
    'kahve',
    'coffee',
    'cafe',
    'benzin',
    'akaryakıt',
    'fuel',
    'petrol',
    'restoran',
    'lokanta',
    'yemek',
    'restaurant',
    'market',
    'bakkal',
    'süpermarket',
    'supermarket',
    'park',
    'bahçe',
    'garden',
    'hastane',
    'klinik',
    'hospital',
    'clinic',
    'otobüs',
    'durak',
    'bus',
    'tramvay',
    'metro',
  ];

  static bool isBusinessQuery(String query) {
    final normalized = query.trim().toLowerCase();
    return _businessSearchTerms.any(normalized.contains);
  }

  static Future<List<Map<String, dynamic>>> searchText(
    String query, {
    LatLng? location,
  }) async {
    final trimmedQuery = query.trim();
    if (trimmedQuery.isEmpty) return [];

    final data = await NavoraGoogleMapsProxyService.call('searchText', {
      'query': trimmedQuery,
      if (location != null)
        'location': {
          'latitude': location.latitude,
          'longitude': location.longitude,
        },
    });
    final places = data['places'] as List<dynamic>? ?? const [];
    final results = places
        .map((rawPlace) {
          final place = rawPlace as Map<String, dynamic>;
          final displayName =
              place['displayName'] as Map<String, dynamic>? ?? {};
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
            'coordinate': LatLng(latitude, longitude),
            'ratingText': ratingText,
            'source': 'google_places',
          };
        })
        .where((place) => place.isNotEmpty)
        .toList();

    if (location == null) return results;

    for (final result in results) {
      final coordinate = result['coordinate'] as LatLng;
      final distanceMeters = Geolocator.distanceBetween(
        location.latitude,
        location.longitude,
        coordinate.latitude,
        coordinate.longitude,
      );
      result['distanceMeters'] = distanceMeters;
      result['distanceText'] = _formatDistance(distanceMeters);
    }
    results.sort(
      (first, second) => (first['distanceMeters'] as double).compareTo(
        second['distanceMeters'] as double,
      ),
    );
    return results;
  }

  static String _formatDistance(double meters) {
    return '${(meters / 1000).toStringAsFixed(1)} km';
  }

  static String _translateOpeningHours(String hours) {
    const dayNames = {
      'Monday': 'Pazartesi',
      'Tuesday': 'Salı',
      'Wednesday': 'Çarşamba',
      'Thursday': 'Perşembe',
      'Friday': 'Cuma',
      'Saturday': 'Cumartesi',
      'Sunday': 'Pazar',
    };
    var translated = hours;
    for (final entry in dayNames.entries) {
      translated = translated.replaceFirst(
        RegExp(entry.key, caseSensitive: false),
        entry.value,
      );
    }
    return translated
        .replaceAll('Closed', 'Kapalı')
        .replaceAll('closed', 'Kapalı')
        .replaceAll('Open 24 hours', '24 saat açık');
  }

  static Future<Map<String, dynamic>?> findNearestPlace(
    LatLng location, {
    double radiusMeters = 50,
  }) async {
    final data = await NavoraGoogleMapsProxyService.call('searchNearby', {
      'location': {
        'latitude': location.latitude,
        'longitude': location.longitude,
      },
      'radiusMeters': radiusMeters,
    });
    final places = data['places'] as List<dynamic>? ?? const [];
    for (final rawPlace in places) {
      final place = rawPlace as Map<String, dynamic>;
      final displayName = place['displayName'] as Map<String, dynamic>? ?? {};
      final rawLocation = place['location'] as Map<String, dynamic>? ?? {};
      final latitude = (rawLocation['latitude'] as num?)?.toDouble();
      final longitude = (rawLocation['longitude'] as num?)?.toDouble();
      if (latitude == null || longitude == null) continue;

      final name = displayName['text']?.toString() ?? 'İşletme';
      final address = place['formattedAddress']?.toString() ?? 'Konum';
      final types = (place['types'] as List<dynamic>? ?? const [])
          .map((type) => type.toString())
          .toList();
      final rating = (place['rating'] as num?)?.toDouble();
      final ratingCount = (place['userRatingCount'] as num?)?.toInt();
      return <String, dynamic>{
        'name': name,
        'subtitle': address,
        'query': '$name, $address',
        'placeId': place['id']?.toString(),
        'type':
            place['primaryType']?.toString() ??
            (types.isEmpty ? 'place' : types.first),
        'coordinate': LatLng(latitude, longitude),
        'ratingText': rating == null
            ? null
            : '${rating.toStringAsFixed(1)}${ratingCount == null ? '' : ' ($ratingCount)'}',
        'source': 'google_places',
      };
    }
    return null;
  }

  static Future<List<Map<String, dynamic>>> autocomplete(
    String query, {
    LatLng? location,
  }) async {
    final trimmedQuery = query.trim();
    if (trimmedQuery.isEmpty) return [];

    final data = await NavoraGoogleMapsProxyService.call('autocomplete', {
      'query': trimmedQuery,
      if (location != null)
        'location': {
          'latitude': location.latitude,
          'longitude': location.longitude,
        },
    });
    final suggestions = data['suggestions'] as List<dynamic>? ?? const [];
    return suggestions
        .map((rawSuggestion) {
          final suggestion = rawSuggestion as Map<String, dynamic>;
          final prediction =
              suggestion['placePrediction'] as Map<String, dynamic>?;
          if (prediction == null) return <String, dynamic>{};
          final text = prediction['text'] as Map<String, dynamic>? ?? {};
          final structured =
              prediction['structuredFormat'] as Map<String, dynamic>? ?? {};
          final mainText =
              structured['mainText'] as Map<String, dynamic>? ?? {};
          final secondaryText =
              structured['secondaryText'] as Map<String, dynamic>? ?? {};
          final name = mainText['text']?.toString() ?? text['text']?.toString();
          final subtitle = secondaryText['text']?.toString() ?? '';
          final placeId = prediction['placeId']?.toString();
          final distanceMeters = (prediction['distanceMeters'] as num?)
              ?.toDouble();
          if (name == null ||
              name.isEmpty ||
              placeId == null ||
              placeId.isEmpty) {
            return <String, dynamic>{};
          }
          return <String, dynamic>{
            'name': name,
            'subtitle': subtitle,
            'query': text['text']?.toString() ?? name,
            'type': 'place',
            'category': 'Konum',
            'placeId': placeId,
            'source': 'google_autocomplete',
            if (distanceMeters != null) ...{
              'distanceMeters': distanceMeters,
              'distanceText': _formatDistance(distanceMeters),
            },
          };
        })
        .where((item) => item.isNotEmpty)
        .toList();
  }

  static Future<Map<String, dynamic>?> getPlaceDetails(String placeId) async {
    if (placeId.isEmpty) return null;

    final place = await NavoraGoogleMapsProxyService.call('details', {
      'placeId': placeId,
    });
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
    final openingHours =
        (regularHours['weekdayDescriptions'] as List<dynamic>? ?? const [])
            .map((day) => _translateOpeningHours(day.toString()))
            .toList(growable: false);

    return <String, dynamic>{
      'placeId': placeId,
      'name': displayName['text']?.toString() ?? 'Konum',
      'subtitle': place['formattedAddress']?.toString() ?? 'Konum',
      'query':
          place['formattedAddress']?.toString() ??
          displayName['text']?.toString(),
      'type':
          place['primaryType']?.toString() ??
          (types.isEmpty ? 'place' : types.first),
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
