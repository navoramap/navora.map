// ignore_for_file: avoid_types_as_parameter_names

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:http/http.dart' as http;
import 'package:share_plus/share_plus.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_ai/firebase_ai.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:geocoding/geocoding.dart' as geo_coding;
import 'package:image_picker/image_picker.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:sensors_plus/sensors_plus.dart' as sensors;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'search_page.dart';
import 'room_chat_page.dart';
import 'tabs/create_property_listing_sheet.dart';
import 'tabs/create_lost_pet_report_sheet.dart';
import 'tabs/create_community_place_sheet.dart';
import 'tabs/explore_page.dart';
import 'my_property_listings_page.dart';
import 'property_listing_moderation_page.dart';
import 'chat_message_moderation_page.dart';
import '../../services/places_service.dart';
import '../../services/chat_room_service.dart';
import '../../services/blocked_users_service.dart';
import '../../services/property_listing_service.dart';
import '../../services/app_notification_service.dart';
import '../navora_loading_screen.dart';

class NavoraTrafficService {
  static const String _googleRoutesApiKey = String.fromEnvironment(
    'GOOGLE_ROUTES_API_KEY',
  );

  static String get googleRoutesApiKey => _googleRoutesApiKey.trim().isEmpty
      ? NavoraPlacesService.apiKey
      : _googleRoutesApiKey.trim();

  static Color? colorForSpeed(String speed) => switch (speed) {
    'SLOW' => const Color(0xFFFFC107),
    'TRAFFIC_JAM' => const Color(0xFFE53935),
    _ => null,
  };

  static List<Polyline> buildRouteTrafficPolylines(
    List<LatLng> routePoints,
    List<dynamic> intervals,
  ) {
    if (routePoints.length < 2) return const [];
    final polylines = <Polyline>[];
    for (var index = 0; index < intervals.length; index++) {
      final interval = intervals[index];
      if (interval is! Map<String, dynamic>) continue;
      final color = colorForSpeed(interval['speed']?.toString() ?? '');
      if (color == null) continue;

      final start = (interval['startPolylinePointIndex'] as num?)?.toInt() ?? 0;
      final end =
          (interval['endPolylinePointIndex'] as num?)?.toInt() ??
          routePoints.length - 1;
      final boundedStart = start.clamp(0, routePoints.length - 1);
      final boundedEnd = end.clamp(0, routePoints.length - 1);
      if (boundedEnd <= boundedStart) continue;

      polylines.add(
        Polyline(
          polylineId: PolylineId('route-traffic-$index'),
          points: routePoints.sublist(boundedStart, boundedEnd + 1),
          color: color,
          width: 5,
          zIndex: 1,
        ),
      );
    }

    return polylines;
  }

  static String statusForIntervals(List<dynamic> intervals) {
    final speeds = intervals
        .whereType<Map<String, dynamic>>()
        .map((interval) => interval['speed']?.toString())
        .toSet();
    if (speeds.contains('TRAFFIC_JAM')) return 'Yoğun';
    if (speeds.contains('SLOW')) return 'Orta';
    return intervals.isEmpty ? 'Trafik bilgisi yok' : 'Açık';
  }
}

double navoraSafeDistanceKm(geo.Position previous, geo.Position current) {
  final deltaMeters = geo.Geolocator.distanceBetween(
    previous.latitude,
    previous.longitude,
    current.latitude,
    current.longitude,
  );

  if (deltaMeters.isNaN || deltaMeters.isInfinite || deltaMeters <= 0) {
    return 0;
  }

  if (deltaMeters > 5000) {
    return 0;
  }

  return deltaMeters / 1000;
}

int navoraWalkingDurationMinutes({
  required double distanceKm,
  required int routeDurationMinutes,
}) {
  if (!distanceKm.isFinite || distanceKm <= 0) return routeDurationMinutes;
  final walkingMinutes = (distanceKm / 4 * 60).ceil();
  return math.max(routeDurationMinutes, walkingMinutes);
}

String navoraFormatNavigationDuration(
  int? durationMinutes, {
  bool isWalking = false,
}) {
  if (durationMinutes == null) return '-';
  final walkingDays = isWalking ? durationMinutes ~/ (8 * 60) : 0;
  final remainingMinutes = isWalking
      ? durationMinutes % (8 * 60)
      : durationMinutes;
  final hours = remainingMinutes ~/ 60;
  final minutes = remainingMinutes % 60;

  if (walkingDays > 0) {
    final dayLabel = '$walkingDays gün';
    if (hours == 0 && minutes == 0) return dayLabel;
    if (minutes == 0) return '$dayLabel $hours sa';
    return '$dayLabel $hours sa $minutes dk';
  }
  if (hours == 0) return '$minutes dk';
  return minutes == 0 ? '$hours sa' : '$hours sa $minutes dk';
}

double navoraScaleRemainingDurationSeconds({
  required double durationSeconds,
  required double remainingDistanceKm,
  required double previousDistanceKm,
}) {
  if (!durationSeconds.isFinite ||
      durationSeconds < 0 ||
      !remainingDistanceKm.isFinite ||
      remainingDistanceKm < 0 ||
      !previousDistanceKm.isFinite ||
      previousDistanceKm <= 0) {
    return durationSeconds;
  }
  return durationSeconds *
      (remainingDistanceKm / previousDistanceKm).clamp(0.0, 1.0);
}

int navoraDurationMinutesFromSeconds(double durationSeconds) =>
    !durationSeconds.isFinite || durationSeconds <= 0
    ? 0
    : (durationSeconds / 60).ceil();

String? navoraFormatArrivalTime(DateTime now, int? durationMinutes) {
  if (durationMinutes == null || durationMinutes < 0) return null;
  final arrival = now.add(Duration(minutes: durationMinutes)).toLocal();
  return '${arrival.hour.toString().padLeft(2, '0')}:'
      '${arrival.minute.toString().padLeft(2, '0')}';
}

double navoraRouteLengthKm(List<LatLng> routePoints) {
  var distanceMeters = 0.0;
  for (var index = 1; index < routePoints.length; index++) {
    final start = routePoints[index - 1];
    final end = routePoints[index];
    final segmentDistance = geo.Geolocator.distanceBetween(
      start.latitude,
      start.longitude,
      end.latitude,
      end.longitude,
    );
    if (segmentDistance.isFinite) distanceMeters += segmentDistance;
  }
  return distanceMeters / 1000;
}

double navoraNavigationZoomForManeuverDistance(double? distanceMeters) {
  if (distanceMeters == null || !distanceMeters.isFinite) return 17;
  if (distanceMeters <= 100) return 19;
  if (distanceMeters <= 300) return 18;
  return 17;
}

double navoraNavigationZoomForSpeedAndManeuver(
  double? distanceMeters,
  double speedMetersPerSecond,
) {
  final maneuverZoom = navoraNavigationZoomForManeuverDistance(distanceMeters);
  if (!speedMetersPerSecond.isFinite || speedMetersPerSecond < 0) {
    return maneuverZoom;
  }
  final speedAdjustment = speedMetersPerSecond >= 25
      ? 1.0
      : speedMetersPerSecond >= 16
      ? 0.5
      : 0.0;
  return (maneuverZoom - speedAdjustment).clamp(16.0, 19.0);
}

double navoraOffRouteThresholdMeters({
  required String vehicle,
  required double accuracyMeters,
}) {
  final vehicleThreshold = switch (vehicle) {
    'Yürüyüş' => 20.0,
    'Bisiklet' => 30.0,
    'Motosiklet' => 45.0,
    _ => 55.0,
  };
  final accuracyAllowance = accuracyMeters.isFinite && accuracyMeters > 0
      ? (accuracyMeters * 0.5).clamp(0.0, 25.0)
      : 0.0;
  return vehicleThreshold + accuracyAllowance;
}

bool navoraShouldRefetchRouteFromLatestPosition({
  required double movedMeters,
  required double speedMetersPerSecond,
}) {
  if (!movedMeters.isFinite || movedMeters < 0) return false;
  final speedAllowance =
      speedMetersPerSecond.isFinite && speedMetersPerSecond > 0
      ? speedMetersPerSecond * 3
      : 0.0;
  return movedMeters >= math.max(18.0, speedAllowance);
}

List<List<Map<String, dynamic>>> navoraClusterChatRooms(
  List<Map<String, dynamic>> rooms, {
  required double zoom,
  double cellSize = 64,
}) => navoraClusterMapItems(rooms, zoom: zoom, cellSize: cellSize);

List<List<Map<String, dynamic>>> navoraClusterMapItems(
  List<Map<String, dynamic>> items, {
  required double zoom,
  double cellSize = 64,
}) {
  final clusters = <String, List<Map<String, dynamic>>>{};
  for (final item in items) {
    final latitude = (item['latitude'] as num?)?.toDouble();
    final longitude = (item['longitude'] as num?)?.toDouble();
    if (latitude == null ||
        longitude == null ||
        !latitude.isFinite ||
        !longitude.isFinite ||
        latitude < -90 ||
        latitude > 90 ||
        longitude < -180 ||
        longitude > 180) {
      continue;
    }

    final key = zoom >= 14
        ? 'item-${item['id'] ?? identityHashCode(item)}'
        : _navoraChatRoomGridKey(latitude, longitude, zoom, cellSize);
    clusters.putIfAbsent(key, () => []).add(item);
  }
  return clusters.values.toList(growable: false);
}

String _navoraChatRoomGridKey(
  double latitude,
  double longitude,
  double zoom,
  double cellSize,
) {
  final worldSize = 256 * math.pow(2, zoom);
  final x = (longitude + 180) / 360 * worldSize;
  final clampedLatitude = latitude.clamp(-85.05112878, 85.05112878);
  final sinLatitude = math.sin(clampedLatitude * math.pi / 180);
  final y =
      (0.5 - math.log((1 + sinLatitude) / (1 - sinLatitude)) / (4 * math.pi)) *
      worldSize;
  return '${(x / cellSize).floor()}:${(y / cellSize).floor()}';
}

bool navoraIsNetworkDegraded(Duration latency, int statusCode) =>
    (statusCode != 200 && statusCode != 204) ||
    latency > const Duration(seconds: 3);

double navoraSpeedKmh(double metersPerSecond) =>
    metersPerSecond.isFinite && metersPerSecond >= 0
    ? metersPerSecond * 3.6
    : 0;

bool navoraShouldFollowCurrentPosition({
  required bool isNavigationActive,
  required bool isDriveTracking,
  bool isLocationTracking = false,
  bool isFollowing = true,
}) {
  return (isNavigationActive || isDriveTracking || isLocationTracking) &&
      isFollowing;
}

bool navoraHasReliableNavigationPosition(double accuracyMeters) =>
    accuracyMeters.isFinite && accuracyMeters >= 0 && accuracyMeters <= 50;

bool navoraIsWithinArrivalRadius(double distanceMeters) =>
    distanceMeters.isFinite && distanceMeters <= 300;

bool navoraIsWithinNavigationCompletionRadius(double distanceMeters) =>
    distanceMeters.isFinite && distanceMeters <= 50;

String navoraFormatDistance(double distanceMeters) {
  if (distanceMeters < 1000) return '${distanceMeters.round()} m';
  return '${(distanceMeters / 1000).toStringAsFixed(1)} km';
}

bool navoraHasCompletedRouteProgress({
  required double traveledDistanceKm,
  required double startDistanceToDestinationMeters,
  required double completionDistanceToDestinationMeters,
}) =>
    traveledDistanceKm.isFinite &&
    traveledDistanceKm >= 0.05 &&
    startDistanceToDestinationMeters.isFinite &&
    completionDistanceToDestinationMeters.isFinite &&
    startDistanceToDestinationMeters - completionDistanceToDestinationMeters >=
        25;

bool navoraShouldSaveDriveHistory({
  required bool startedForNavigation,
  required bool hasCompletedNavigationProgress,
}) => !startedForNavigation || hasCompletedNavigationProgress;

List<Map<String, String>> navoraCombineDrivingHistory(
  List<Map<String, String>> drivingHistory,
  List<Map<String, String>> routeHistory,
) {
  final gpsDrives = drivingHistory.where((drive) {
    if (drive['route'] != 'GPS sürüşü') return true;
    return !routeHistory.any(
      (route) =>
          route['date'] == drive['date'] &&
          route['duration'] == drive['duration'] &&
          route['km'] == drive['km'],
    );
  });
  return [...gpsDrives, ...routeHistory];
}

double navoraSmoothBearing(
  double currentBearing,
  double nextBearing, {
  double factor = 0.35,
}) {
  final current = currentBearing % 360;
  final next = nextBearing % 360;
  final shortestDelta = (next - current + 540) % 360 - 180;
  final smoothing = factor.clamp(0.0, 1.0).toDouble();
  return (current + shortestDelta * smoothing + 360) % 360;
}

double? navoraCalculateCompassHeading({
  required double accelerationX,
  required double accelerationY,
  required double accelerationZ,
  required double magneticX,
  required double magneticY,
  required double magneticZ,
}) {
  final accelerationMagnitude = math.sqrt(
    accelerationX * accelerationX +
        accelerationY * accelerationY +
        accelerationZ * accelerationZ,
  );
  final magneticMagnitude = math.sqrt(
    magneticX * magneticX + magneticY * magneticY + magneticZ * magneticZ,
  );
  if (!accelerationMagnitude.isFinite ||
      !magneticMagnitude.isFinite ||
      accelerationMagnitude < 1e-6 ||
      magneticMagnitude < 1e-6) {
    return null;
  }

  final gravityX = accelerationX / accelerationMagnitude;
  final gravityY = accelerationY / accelerationMagnitude;
  final gravityZ = accelerationZ / accelerationMagnitude;
  final fieldX = magneticX / magneticMagnitude;
  final fieldY = magneticY / magneticMagnitude;
  final fieldZ = magneticZ / magneticMagnitude;

  final eastX = fieldY * gravityZ - fieldZ * gravityY;
  final eastY = fieldZ * gravityX - fieldX * gravityZ;
  final eastZ = fieldX * gravityY - fieldY * gravityX;
  final eastMagnitude = math.sqrt(
    eastX * eastX + eastY * eastY + eastZ * eastZ,
  );
  if (eastMagnitude < 1e-6) return null;

  final northY = gravityZ * eastX - gravityX * eastZ;
  final azimuth = math.atan2(eastY, northY);
  return (azimuth * 180 / math.pi + 360) % 360;
}

LatLng navoraOffsetCameraTarget(
  LatLng position,
  double bearingDegrees,
  double distanceMeters,
) {
  const earthRadiusMeters = 6371008.8;
  final latitude = position.latitude * math.pi / 180;
  final longitude = position.longitude * math.pi / 180;
  final bearing = bearingDegrees * math.pi / 180;
  final angularDistance = distanceMeters / earthRadiusMeters;
  final targetLatitude = math.asin(
    math.sin(latitude) * math.cos(angularDistance) +
        math.cos(latitude) * math.sin(angularDistance) * math.cos(bearing),
  );
  final targetLongitude =
      longitude +
      math.atan2(
        math.sin(bearing) * math.sin(angularDistance) * math.cos(latitude),
        math.cos(angularDistance) -
            math.sin(latitude) * math.sin(targetLatitude),
      );

  return LatLng(
    targetLatitude * 180 / math.pi,
    (targetLongitude * 180 / math.pi + 540) % 360 - 180,
  );
}

double navoraDistanceToRouteMeters(LatLng position, List<LatLng> route) {
  if (route.isEmpty) return double.infinity;

  const earthRadiusMeters = 6371008.8;
  final latitudeRadians = position.latitude * math.pi / 180;
  final longitudeScale = earthRadiusMeters * math.cos(latitudeRadians);
  final projectedPoints = route.map((point) {
    return (
      (point.longitude - position.longitude) * math.pi / 180 * longitudeScale,
      (point.latitude - position.latitude) * math.pi / 180 * earthRadiusMeters,
    );
  }).toList();

  if (projectedPoints.length == 1) {
    final point = projectedPoints.first;
    return math.sqrt(point.$1 * point.$1 + point.$2 * point.$2);
  }

  var nearestDistance = double.infinity;
  for (var index = 0; index < projectedPoints.length - 1; index++) {
    final start = projectedPoints[index];
    final end = projectedPoints[index + 1];
    final segmentX = end.$1 - start.$1;
    final segmentY = end.$2 - start.$2;
    final segmentLengthSquared = segmentX * segmentX + segmentY * segmentY;
    final projection = segmentLengthSquared == 0
        ? 0.0
        : (-(start.$1 * segmentX + start.$2 * segmentY) / segmentLengthSquared)
              .clamp(0.0, 1.0)
              .toDouble();
    final nearestX = start.$1 + segmentX * projection;
    final nearestY = start.$2 + segmentY * projection;
    nearestDistance = math.min(
      nearestDistance,
      math.sqrt(nearestX * nearestX + nearestY * nearestY),
    );
  }

  return nearestDistance;
}

double navoraRouteTrimToleranceMeters(String vehicle) {
  switch (vehicle) {
    case 'Yürüyüş':
      return 20;
    case 'Bisiklet':
      return 28;
    case 'Motosiklet':
      return 45;
    case 'Araba':
    default:
      return 60;
  }
}

List<LatLng> navoraTrimRouteToRemainingPath(
  List<LatLng> routePoints,
  LatLng currentPosition, {
  String vehicle = 'Araba',
}) {
  if (routePoints.length < 2) {
    return routePoints;
  }

  final maxDistanceMeters = navoraRouteTrimToleranceMeters(vehicle);
  const earthRadiusMeters = 6371008.8;
  final latitudeRadians = currentPosition.latitude * math.pi / 180;
  final longitudeScale = earthRadiusMeters * math.cos(latitudeRadians);
  var nearestSegmentIndex = 0;
  var nearestDistance = double.infinity;
  var nearestX = 0.0;
  var nearestY = 0.0;

  for (var index = 0; index < routePoints.length - 1; index++) {
    final start = routePoints[index];
    final end = routePoints[index + 1];
    final startX =
        (start.longitude - currentPosition.longitude) *
        math.pi /
        180 *
        longitudeScale;
    final startY =
        (start.latitude - currentPosition.latitude) *
        math.pi /
        180 *
        earthRadiusMeters;
    final endX =
        (end.longitude - currentPosition.longitude) *
        math.pi /
        180 *
        longitudeScale;
    final endY =
        (end.latitude - currentPosition.latitude) *
        math.pi /
        180 *
        earthRadiusMeters;
    final segmentX = endX - startX;
    final segmentY = endY - startY;
    final segmentLengthSquared = segmentX * segmentX + segmentY * segmentY;
    final projection = segmentLengthSquared == 0
        ? 0.0
        : (-(startX * segmentX + startY * segmentY) / segmentLengthSquared)
              .clamp(0.0, 1.0)
              .toDouble();
    final projectedX = startX + segmentX * projection;
    final projectedY = startY + segmentY * projection;
    final distance = math.sqrt(
      projectedX * projectedX + projectedY * projectedY,
    );

    if (distance < nearestDistance) {
      nearestDistance = distance;
      nearestSegmentIndex = index;
      nearestX = projectedX;
      nearestY = projectedY;
    }
  }

  if (nearestDistance > maxDistanceMeters) {
    return routePoints;
  }

  final projectedPoint = LatLng(
    currentPosition.latitude + nearestY / earthRadiusMeters * 180 / math.pi,
    currentPosition.longitude + nearestX / longitudeScale * 180 / math.pi,
  );
  return [
    currentPosition,
    if (nearestDistance > 1) projectedPoint,
    ...routePoints.sublist(nearestSegmentIndex + 1),
  ];
}

String navoraResolveSearchTitle(
  Map<String, dynamic> item,
  String fallbackQuery,
) {
  final namedDetails = item['namedetails'];
  final nameCandidates = <String>[];

  if (item['name'] is String) {
    nameCandidates.add(item['name'] as String);
  }
  if (namedDetails is Map && namedDetails['name'] is String) {
    nameCandidates.add(namedDetails['name'] as String);
  }
  if (item['display_name'] is String) {
    final displayName = item['display_name'] as String;
    final firstPart = displayName.split(',').first.trim();
    if (firstPart.isNotEmpty) {
      nameCandidates.add(firstPart);
    }
  }

  for (final candidate in nameCandidates) {
    final normalized = candidate.trim();
    if (normalized.isEmpty) continue;
    final lowered = normalized.toLowerCase();
    final fallbackLower = fallbackQuery.trim().toLowerCase();

    if (fallbackLower.isNotEmpty &&
        (lowered.contains(fallbackLower) || fallbackLower.contains(lowered))) {
      return normalized;
    }

    if (!normalized.contains('Mahallesi') &&
        !normalized.contains('Caddesi') &&
        !normalized.contains('Sokak') &&
        !normalized.contains('Bulvarı') &&
        !normalized.contains('Avenue') &&
        !normalized.contains('Street')) {
      return normalized;
    }
  }

  final fallback = fallbackQuery.trim();
  if (fallback.isNotEmpty) return fallback;
  return 'Konum';
}

String navoraResolveSearchSubtitle(Map<String, dynamic> item) {
  final address = item['address'] is Map ? item['address'] as Map : const {};
  final candidateParts = <String>[];

  for (final key in [
    'amenity',
    'road',
    'street',
    'neighbourhood',
    'suburb',
    'city_district',
    'district',
    'city',
    'town',
    'village',
    'county',
    'state',
    'country',
  ]) {
    final value = address[key]?.toString().trim();
    if (value != null && value.isNotEmpty && !candidateParts.contains(value)) {
      candidateParts.add(value);
    }
  }

  if (candidateParts.isNotEmpty) {
    return candidateParts.join(', ');
  }

  final displayName = item['display_name']?.toString() ?? '';
  if (displayName.isNotEmpty) {
    final parts = displayName.split(',');
    if (parts.length > 1) {
      return parts.sublist(1).join(', ').trim();
    }
    return displayName;
  }

  return 'Konum';
}

class HomePage extends StatefulWidget {
  final String userName;
  final String userEmail;
  final VoidCallback onLogout;

  const HomePage({
    super.key,
    required this.userName,
    required this.userEmail,
    required this.onLogout,
  });

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  final PropertyListingService _propertyListingService =
      PropertyListingService();
  bool _isRefreshingVerifiedEmail = false;

  Future<void> _recordPetListingView(Map<String, dynamic> listing) async {
    final user = FirebaseAuth.instance.currentUser;
    final collection = switch (listing['collection']) {
      'lost_pet_reports' => 'lost_pet_reports',
      'pet_adoption_listings' => 'pet_adoption_listings',
      _ => null,
    };
    final listingId = listing['id']?.toString();
    if (user == null || collection == null || listingId == null) return;

    try {
      final viewReference = FirebaseFirestore.instance
          .collection(collection)
          .doc(listingId)
          .collection('_views')
          .doc(user.uid);
      final existingView = await viewReference.get();
      if (!existingView.exists) {
        await viewReference.set({'created_at': FieldValue.serverTimestamp()});
      }
    } catch (error) {
      debugPrint('Hayvan ilanı görüntülenmesi kaydedilemedi: $error');
    }
  }

  static const Duration _chatRoomLifetime = Duration(hours: 24);
  static const double _bottomNavigationBarHeight = 68;
  static const double _bottomNavigationGap = 16;
  static const double _navigationDockHeight = 132;
  static const String _darkGoogleMapStyle = '''[
    {"featureType":"all","elementType":"geometry","stylers":[{"color":"#22282c"}]},
    {"featureType":"all","elementType":"labels.text.fill","stylers":[{"color":"#f5f5f5"}]},
    {"featureType":"all","elementType":"labels.text.stroke","stylers":[{"color":"#141414"}]},
    {"featureType":"water","elementType":"geometry","stylers":[{"color":"#173344"}]},
    {"featureType":"road","elementType":"geometry","stylers":[{"color":"#46535a"}]},
    {"featureType":"road","elementType":"labels.text.fill","stylers":[{"color":"#d9d9d9"}]},
    {"featureType":"transit","stylers":[{"visibility":"off"}]},
    {"featureType":"administrative","elementType":"geometry","stylers":[{"visibility":"off"}]}
  ]''';

  int _selectedIndex = 1;
  final MapType _mapType = MapType.normal;
  GoogleMapController? _mapController;
  bool _isMapLoaded = false;
  Timer? _mapLoadingTimer;
  CameraPosition? _mapCameraPosition;
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  Timer? _searchDebounce;
  List<Marker> _searchMarkers = const [];
  List<Polyline> _routePolylines = const [];
  List<Polyline> _alternativeRoutePolylines = const [];
  List<Polyline> _navigationTrafficPolylines = const [];
  final Map<String, bool> _mapLayerVisibility = {
    'rooms': true,
    'community': true,
    'properties': true,
    'lostPets': true,
    'adoptions': true,
  };
  List<Map<String, dynamic>> _navigationSteps = [];
  double? _navigationDistanceKm;
  int? _navigationDurationMinutes;
  double? _navigationDurationSeconds;
  bool _isNavigationActive = false;
  LatLng? _navigationStartPosition;
  bool _isOpeningDirections = false;
  bool _isMapTilted = false;
  bool _isFollowingCurrentPosition = true;
  bool _isProgrammaticCameraMove = false;
  geo.Position? _pendingNavigationCameraPosition;
  double? _smoothedVehicleHeading;
  final Set<int> _activeMapPointers = {};
  bool _isLocationTracking = false;
  bool _hasMapBearing = false;
  bool _isOffRoute = false;
  bool _isCompletingNavigation = false;
  double? _navigationStartDistanceToDestinationMeters;
  bool _isNetworkDegraded = false;
  bool _isCheckingNavigationNetwork = false;
  bool _isCheckingFasterRoute = false;
  bool _hasShownRouteUpdateError = false;
  BitmapDescriptor? _navigationEndpointMarkerIcon;
  BitmapDescriptor? _lostPetMarkerIcon;
  BitmapDescriptor? _adoptionMarkerIcon;
  BitmapDescriptor? _communityPlaceMarkerIcon;
  BitmapDescriptor? _rentalPropertyMarkerIcon;
  BitmapDescriptor? _salePropertyMarkerIcon;
  bool _isSearchHistoryEnabled = true;
  bool _hasAnnouncedArrival = false;
  int _offRouteReadings = 0;
  int _navigationStepIndex = 0;
  double _mapBearing = 0;
  double? _deviceHeading;
  double? _gravityX;
  double? _gravityY;
  double? _gravityZ;
  sensors.MagnetometerEvent? _magneticField;
  Timer? _compassCameraUpdateTimer;
  Timer? _navigationCameraUpdateTimer;
  Timer? _navigationConnectivityTimer;
  String? _activeNavigationTitle;
  String? _activeNavigationDestination;
  final SpeechToText _speech = SpeechToText();
  bool _isListening = false;
  final List<Map<String, dynamic>> _liveRooms = [];
  final List<Map<String, dynamic>> _communityPlaces = [];
  final List<Map<String, dynamic>> _propertyListings = [];
  final List<Map<String, dynamic>> _lostPetReports = [];
  String? _activePropertyListingType;
  final Set<String> _propertyRoomFilters = {};
  int? _propertyMinimumPrice;
  int? _propertyMaximumPrice;
  String? _propertyCityFilter;
  String? _propertyDistrictFilter;
  bool _isLostPetMapActive = false;
  bool _isPetAdoptionMode = false;
  bool _isPropertyListingsLoading = false;
  String? _propertyListingsError;
  bool _isLoadingLostPetReports = false;
  String? _lostPetReportsError;
  final Set<String> _loadedPetLayerCollections = {};
  LatLng? _selectedDestinationCoordinate;
  String? _selectedDestinationName;
  Map<String, dynamic>? _selectedPlaceDetails;
  final List<Map<String, dynamic>> _searchHistory = [];
  List<Map<String, dynamic>> _searchSuggestions = [];
  int _searchRequestId = 0;
  String? _searchResultName;
  bool _isSearching = false;
  Future<geo.Position?>? _searchPositionFuture;
  bool _isSearchMode = false;
  String? _activeCategory;
  bool _showSearchPanel = false;
  String? _routeSelectionTarget;
  LatLng? _routeDraftStart;
  LatLng? _routeDraftDestination;
  StreamSubscription<geo.Position>? _positionSubscription;
  StreamSubscription<geo.Position>? _locationPositionSubscription;
  StreamSubscription<sensors.AccelerometerEvent>? _accelerometerSubscription;
  StreamSubscription<sensors.MagnetometerEvent>? _magnetometerSubscription;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>?
  _communityPlacesSubscription;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _roomsSubscription;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>?
  _mapPropertyListingsSubscription;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>?
  _mapLostPetReportsSubscription;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>?
  _mapAdoptionListingsSubscription;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>?
  _publicChatSubscription;
  StreamSubscription<List<BlockedUser>>? _blockedUsersSubscription;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>?
  _searchHistorySubscription;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _aiChatsSubscription;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>?
  _dailyQuotaSubscription;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>?
  _userProfileSubscription;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>?
  _savedRoutesSubscription;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>?
  _savedAddressesSubscription;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>?
  _drivingHistorySubscription;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>?
  _routeHistorySubscription;
  Timer? _roomExpiryTimer;
  geo.Position? _currentPosition;
  String? _currentAddress;
  String? _currentRoadName;
  DateTime? _lastAddressLookupAt;
  DateTime? _lastNavigationRefreshAt;
  DateTime? _lastFasterRouteCheckAt;
  Map<String, dynamic>? _fasterAlternativeRoute;
  int? _fasterRouteMinutesSaved;
  bool _isRefreshingNavigation = false;
  geo.Position? _lastDrivePosition;
  DateTime? _driveStartedAt;
  bool _isDriveTracking = false;
  Future<void> _screenWakeLockQueue = Future<void>.value();
  bool _isStartingDriveTracking = false;
  bool _driveStartedForNavigation = false;
  double _driveDistanceKm = 0;

  late String _userName;
  late String _userEmail;
  String _userPhone = '';
  String _userGender = 'Belirtmek istemiyorum';
  String _selectedVehicle = 'Araba';

  // Pro & Oda Sınırı Değişkenleri
  bool _isProUser = false;
  bool _isDeletingAccount = false;
  bool _isUploadingProfilePhoto = false;
  String? _profilePhotoUrl;
  bool _canManageExploreHighlights = false;
  BitmapDescriptor? _chatRoomMarkerIcon;
  final Map<int, BitmapDescriptor> _chatRoomMarkerIcons = {};
  final Map<int, BitmapDescriptor> _mapClusterMarkerIcons = {};
  final Set<int> _loadingRoomMarkerIconCounts = {};
  final Set<int> _loadingMapClusterIconCounts = {};
  double? _lastClusteredMapZoom;
  BitmapDescriptor? _navigationDestinationMarkerIcon;
  bool _locationPermissionGranted = false;
  static const int _dailyRoomLimit = 3;
  static const int _freeAiQueriesPerDay = 3;
  static const int _proRoomLimit = 10;
  static const int _proAiQueriesPerDay = 10;
  int _roomsCreatedToday = 0;
  int _freeAiQueriesUsedToday = 0;
  String? _dailyQuotaDate;

  final List<String> _visitedCities = [];
  final List<Map<String, String>> _savedRoutes = [];

  final List<Map<String, String>> _savedAddresses = [];

  final List<Map<String, String>> _drivingHistory = [];
  final List<Map<String, String>> _liveDrivingHistory = [];
  final List<Map<String, String>> _liveRouteHistory = [];
  final Set<String> _deletingHistoryEntryKeys = {};

  final TextEditingController _aiController = TextEditingController();
  bool _isAiResponding = false;
  bool _isClearingAiChats = false;
  final TextEditingController _routeTitleController = TextEditingController();
  final TextEditingController _routeStartController = TextEditingController();
  final TextEditingController _routeDestinationController =
      TextEditingController();
  final TextEditingController _routeDistanceController =
      TextEditingController();
  final List<Map<String, String>> _aiMessages = [
    {
      'sender': 'ai',
      'text': 'Merhaba! Ben Navora AI. Rotan, yakındaki mekanlar veya trafik hakkında ne öğrenmek istersin?',
    },
  ];

  // Sohbet Sekmesi İçi Durumlar ve Veriler
  int _chatSubTab = 0;
  final TextEditingController _chatController = TextEditingController();
  final TextEditingController _roomSearchController = TextEditingController();
  final ScrollController _publicChatScrollController = ScrollController();
  bool _showPublicChatScrollToBottom = false;
  bool _publicChatWasAtBottom = true;
  bool _isResettingPublicChat = false;

  // Yakındaki Herkese Açık Mesajlar
  final List<Map<String, dynamic>> _publicFeedMessages = [];
  final Set<String> _blockedUserIds = {};
  final BlockedUsersService _blockedUsersService = BlockedUsersService();

  @override
  void initState() {
    super.initState();
    _scheduleMapLoadingFallback(const Duration(seconds: 8));
    WidgetsBinding.instance.addObserver(this);
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
      SystemChrome.setSystemUIOverlayStyle(
        const SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: Brightness.light,
          systemNavigationBarColor: Colors.transparent,
          systemNavigationBarDividerColor: Colors.transparent,
          systemNavigationBarIconBrightness: Brightness.light,
          systemNavigationBarContrastEnforced: false,
        ),
      );
    }
    _userName = widget.userName;
    _userEmail = widget.userEmail;
    _profilePhotoUrl = FirebaseAuth.instance.currentUser?.photoURL;
    _loadNavigationEndpointMarkerIcon();
    _loadLostPetMarkerIcon();
    _loadListingMarkerIcons();
    _loadCommunityPlaceMarkerIcon();
    _loadChatRoomMarkerIcon();
    _loadLocationPermissionState();
    _loadProfileData();
    _loadMapPreferences();
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser != null) {
      _subscribeToAiChats(currentUser.uid);
    }
    unawaited(_subscribeToSearchHistory());
    _loadExploreAdminClaim();
    _listenToCommunityPlaces();
    _subscribeToLiveRooms();
    _subscribeToBlockedUsers();
    _subscribeToPublicChat();
    _publicChatScrollController.addListener(_handlePublicChatScroll);
    _roomExpiryTimer = Timer.periodic(
      const Duration(minutes: 1),
      (_) => _removeExpiredRoomsFromView(),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => _initializeLocation());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_refreshVerifiedEmail());
      unawaited(_updateScreenWakeLock());
    }
  }

  void _finishMapLoading() {
    _mapLoadingTimer?.cancel();
    _mapLoadingTimer = null;
    if (!mounted || _isMapLoaded) return;
    setState(() => _isMapLoaded = true);
  }

  void _scheduleMapLoadingFallback(Duration duration) {
    _mapLoadingTimer?.cancel();
    _mapLoadingTimer = Timer(duration, _finishMapLoading);
  }

  void _selectMainTab(int index) {
    setState(() => _selectedIndex = index);
    if (index == 1 && !_isMapLoaded) {
      _scheduleMapLoadingFallback(const Duration(seconds: 6));
    }
  }

  List<Map<String, dynamic>> get _visiblePublicFeedMessages =>
      _publicFeedMessages.where((message) {
        final senderId = message['senderId']?.toString() ?? '';
        return !_blockedUserIds.contains(senderId);
      }).toList();

  List<Map<String, dynamic>> get _visibleRooms => _liveRooms
      .where((room) => !_blockedUserIds.contains(room['ownerId']?.toString()))
      .toList();

  List<Map<String, dynamic>> get _visibleCommunityPlaces => _communityPlaces
      .where(
        (place) => !_blockedUserIds.contains(place['ownerUid']?.toString()),
      )
      .toList();

  List<Map<String, dynamic>> get _visiblePropertyListings => _propertyListings
      .where(
        (listing) =>
            !_blockedUserIds.contains(listing['owner_uid']?.toString()),
      )
      .toList();

  List<Map<String, dynamic>> get _visibleLostPetReports => _lostPetReports
      .where(
        (report) => !_blockedUserIds.contains(report['owner_uid']?.toString()),
      )
      .toList();

  void _subscribeToBlockedUsers() {
    final userId = FirebaseAuth.instance.currentUser?.uid;
    if (userId == null) return;
    _blockedUsersSubscription = _blockedUsersService
        .watchBlockedUsers(userId)
        .listen(
          (blockedUsers) {
            if (!mounted || FirebaseAuth.instance.currentUser?.uid != userId) {
              return;
            }
            setState(() {
              _blockedUserIds
                ..clear()
                ..addAll(blockedUsers.map((blockedUser) => blockedUser.uid));
            });
          },
          onError: (Object error) {
            debugPrint('Engellenen kullanıcılar yüklenemedi: $error');
            if (mounted) {
              _showTrackingMessage('Engellenen kullanıcılar yüklenemedi.');
            }
          },
        );
  }

  Future<void> _blockUser(String blockedUid, String displayName) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || blockedUid.isEmpty || blockedUid == user.uid) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Kullanıcıyı engelle'),
        content: Text(
          '$displayName kullanıcısını engellemek istiyor musun? Bu kişinin sohbet mesajları sana gösterilmez.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Vazgeç'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Engelle'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await _blockedUsersService.blockUser(
        uid: user.uid,
        blockedUid: blockedUid,
        displayName: displayName,
      );
      if (mounted) _showTrackingMessage('$displayName engellendi.');
    } on FirebaseException catch (error) {
      debugPrint('Kullanıcı engellenemedi: ${error.code}');
      if (mounted) {
        _showTrackingMessage('Kullanıcı engellenemedi. Tekrar deneyin.');
      }
    } on ArgumentError catch (error) {
      debugPrint('Kullanıcı engelleme isteği geçersiz: $error');
      if (mounted) _showTrackingMessage('Bu kullanıcı engellenemiyor.');
    }
  }

  void _showBlockedUsersSheet() {
    final userId = FirebaseAuth.instance.currentUser?.uid;
    if (userId == null) return;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF191919),
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(sheetContext).height * 0.6,
          child: Column(
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 8, 20, 16),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Engellenen Kullanıcılar',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
              Expanded(
                child: StreamBuilder<List<BlockedUser>>(
                  stream: _blockedUsersService.watchBlockedUsers(userId),
                  builder: (context, snapshot) {
                    if (snapshot.hasError) {
                      return const Center(
                        child: Text('Liste yüklenemedi. Tekrar deneyin.'),
                      );
                    }
                    if (!snapshot.hasData) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    final blockedUsers = snapshot.data!;
                    if (blockedUsers.isEmpty) {
                      return const Center(
                        child: Text(
                          'Engellediğin kullanıcı bulunmuyor.',
                          style: TextStyle(color: Colors.white70),
                        ),
                      );
                    }
                    return ListView.builder(
                      itemCount: blockedUsers.length,
                      itemBuilder: (context, index) {
                        final blockedUser = blockedUsers[index];
                        return ListTile(
                          leading: const CircleAvatar(
                            backgroundColor: Color(0xFF2A180D),
                            child: Icon(
                              Icons.person_off_outlined,
                              color: Color(0xFFFF9A3D),
                            ),
                          ),
                          title: Text(
                            blockedUser.displayName,
                            style: const TextStyle(color: Colors.white),
                          ),
                          trailing: TextButton(
                            onPressed: () async {
                              try {
                                await _blockedUsersService.unblockUser(
                                  uid: userId,
                                  blockedUid: blockedUser.uid,
                                );
                                if (mounted) {
                                  _showTrackingMessage(
                                    '${blockedUser.displayName} engeli kaldırıldı.',
                                  );
                                }
                              } on FirebaseException catch (error) {
                                debugPrint(
                                  'Kullanıcı engeli kaldırılamadı: ${error.code}',
                                );
                                if (mounted) {
                                  _showTrackingMessage(
                                    'Engel kaldırılamadı. Tekrar deneyin.',
                                  );
                                }
                              }
                            },
                            child: const Text('Engeli kaldır'),
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  bool _isPublicChatNearBottom() {
    if (!_publicChatScrollController.hasClients) return true;
    final maxScroll = _publicChatScrollController.position.maxScrollExtent;
    final current = _publicChatScrollController.offset;
    return current >= maxScroll - 32;
  }

  void _handlePublicChatScroll() {
    if (!_publicChatScrollController.hasClients) return;
    _publicChatWasAtBottom = _isPublicChatNearBottom();
    final shouldShow = !_publicChatWasAtBottom;
    if (shouldShow != _showPublicChatScrollToBottom) {
      setState(() => _showPublicChatScrollToBottom = shouldShow);
    }
  }

  Future<void> _openPropertyMap(String listingType) async {
    setState(() {
      _selectedIndex = 1;
      _activePropertyListingType = listingType;
      _isLostPetMapActive = false;
    });
    final listings = _visiblePropertyListings
        .where((listing) => listing['listing_type'] == listingType)
        .toList();
    if (listings.isNotEmpty && _mapController != null) {
      final firstListing = listings.first;
      await _moveMapTo(
        LatLng(
          (firstListing['latitude'] as num).toDouble(),
          (firstListing['longitude'] as num).toDouble(),
        ),
        13,
      );
    }
  }

  Future<void> _closePropertyMap() async {
    if (!mounted) return;
    setState(() {
      _selectedIndex = 0;
      _activePropertyListingType = null;
    });
  }

  Future<void> _openLostPetMap({bool adoptionMode = false}) async {
    setState(() {
      _selectedIndex = 1;
      _activePropertyListingType = null;
      _isLostPetMapActive = true;
      _isPetAdoptionMode = adoptionMode;
      if (FirebaseAuth.instance.currentUser == null) {
        _isLoadingLostPetReports = false;
        _lostPetReportsError =
            'Hayvan ilanlarını görmek için giriş yapmalısın.';
      }
    });
    final targetCollection = adoptionMode
        ? 'pet_adoption_listings'
        : 'lost_pet_reports';
    final reports = _visibleLostPetReports
        .where((report) => report['collection'] == targetCollection)
        .toList();
    if (reports.isNotEmpty && _mapController != null) {
      final firstReport = reports.first;
      await _moveMapTo(
        LatLng(
          (firstReport['latitude'] as num).toDouble(),
          (firstReport['longitude'] as num).toDouble(),
        ),
        13,
      );
    }
  }

  Future<void> _closeLostPetMap() async {
    if (!mounted) return;
    setState(() {
      _selectedIndex = 0;
      _isLostPetMapActive = false;
      _isPetAdoptionMode = false;
    });
  }

  void _subscribeToMapLayers() {
    final userId = FirebaseAuth.instance.currentUser?.uid;
    if (userId == null) {
      setState(() {
        _propertyListingsError = 'İlanları görmek için giriş yapmalısın.';
        _lostPetReportsError =
            'Hayvan ilanlarını görmek için giriş yapmalısın.';
      });
      return;
    }

    setState(() {
      _isPropertyListingsLoading = true;
      _propertyListingsError = null;
      _isLoadingLostPetReports = true;
      _lostPetReportsError = null;
      _loadedPetLayerCollections.clear();
    });

    _mapPropertyListingsSubscription = FirebaseFirestore.instance
        .collection('property_listings')
        .where('status', isEqualTo: 'active')
        .orderBy('created_at', descending: true)
        .limit(100)
        .snapshots()
        .listen(
          (snapshot) {
            if (!mounted || FirebaseAuth.instance.currentUser?.uid != userId) {
              return;
            }
            final listings = snapshot.docs
                .map(
                  (document) => <String, dynamic>{
                    ...document.data(),
                    'id': document.id,
                  },
                )
                .where((listing) {
                  final latitude = listing['latitude'];
                  final longitude = listing['longitude'];
                  return latitude is num &&
                      latitude >= -90 &&
                      latitude <= 90 &&
                      longitude is num &&
                      longitude >= -180 &&
                      longitude <= 180;
                })
                .toList();
            setState(() {
              _propertyListings
                ..clear()
                ..addAll(listings);
              _isPropertyListingsLoading = false;
              _propertyListingsError = null;
            });
          },
          onError: (Object error) {
            debugPrint('Emlak ilanları alınamadı: $error');
            if (!mounted) return;
            setState(() {
              _isPropertyListingsLoading = false;
              _propertyListingsError =
                  'İlanlar şu anda yüklenemiyor. Daha sonra tekrar dene.';
            });
          },
        );

    _subscribeToPetMapLayer('lost_pet_reports');
    _subscribeToPetMapLayer('pet_adoption_listings');
  }

  void _subscribeToPetMapLayer(String collectionName) {
    final userId = FirebaseAuth.instance.currentUser?.uid;
    if (userId == null) return;
    final subscription = FirebaseFirestore.instance
        .collection(collectionName)
        .where('status', isEqualTo: 'active')
        .orderBy('created_at', descending: true)
        .limit(100)
        .snapshots()
        .listen(
          (snapshot) {
            if (!mounted || FirebaseAuth.instance.currentUser?.uid != userId) {
              return;
            }
            final reports = snapshot.docs
                .map(
                  (document) => <String, dynamic>{
                    ...document.data(),
                    'id': document.id,
                    'collection': collectionName,
                  },
                )
                .where((report) {
                  final latitude = report['latitude'];
                  final longitude = report['longitude'];
                  return latitude is num &&
                      latitude >= -90 &&
                      latitude <= 90 &&
                      longitude is num &&
                      longitude >= -180 &&
                      longitude <= 180;
                })
                .toList();
            setState(() {
              _lostPetReports.removeWhere(
                (report) => report['collection'] == collectionName,
              );
              _lostPetReports.addAll(reports);
              _loadedPetLayerCollections.add(collectionName);
              _isLoadingLostPetReports = _loadedPetLayerCollections.length < 2;
              _lostPetReportsError = null;
            });
          },
          onError: (Object error) {
            debugPrint('$collectionName harita katmanı yüklenemedi: $error');
            if (!mounted || FirebaseAuth.instance.currentUser?.uid != userId) {
              return;
            }
            setState(() {
              _loadedPetLayerCollections.add(collectionName);
              _isLoadingLostPetReports = _loadedPetLayerCollections.length < 2;
              _lostPetReportsError = 'Hayvan ilanları şu anda yüklenemiyor. Daha sonra tekrar dene.';
            });
          },
        );
    if (collectionName == 'lost_pet_reports') {
      _mapLostPetReportsSubscription = subscription;
    } else {
      _mapAdoptionListingsSubscription = subscription;
    }
  }

  Future<void> _loadMapPreferences() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.remove('map.avoidTolls');
      if (!mounted) return;
      setState(() {
        _isSearchHistoryEnabled =
            preferences.getBool('search.history.enabled') ?? true;
        for (final layer in _mapLayerVisibility.keys.toList()) {
          _mapLayerVisibility[layer] =
              preferences.getBool('map.layer.$layer') ?? true;
        }
      });
    } catch (error) {
      debugPrint('Harita tercihleri yüklenemedi: $error');
      if (mounted) _showTrackingMessage('Harita tercihleri yüklenemedi.');
    }
  }

  Future<void> _setMapLayerVisibility(String layer, bool isVisible) async {
    setState(() => _mapLayerVisibility[layer] = isVisible);
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setBool('map.layer.$layer', isVisible);
    } catch (error) {
      debugPrint('Harita katmanı tercihi kaydedilemedi: $error');
      if (mounted) {
        _showTrackingMessage('Harita katmanı tercihi kaydedilemedi.');
      }
    }
  }

  Future<void> _setSearchHistoryEnabled(bool enabled) async {
    setState(() => _isSearchHistoryEnabled = enabled);
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setBool('search.history.enabled', enabled);
    } catch (error) {
      debugPrint('Arama geçmişi tercihi kaydedilemedi: $error');
      if (mounted) {
        _showTrackingMessage('Arama geçmişi tercihi kaydedilemedi.');
      }
    }
  }

  void _showMapLayersSheet() {
    const layers = [
      ('rooms', 'Sohbet odaları', Icons.forum_rounded),
      ('community', 'Topluluk mekânları', Icons.place_rounded),
      ('properties', 'Emlak ilanları', Icons.home_work_rounded),
      ('lostPets', 'Kayıp hayvanlar', Icons.pets_rounded),
      ('adoptions', 'Sahiplendirme ilanları', Icons.volunteer_activism_rounded),
    ];
    final sheetVisibility = Map<String, bool>.from(_mapLayerVisibility);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF191919),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Harita katmanları',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 14),
                for (final (key, title, icon) in layers)
                  Builder(
                    builder: (context) {
                      final isVisible = sheetVisibility[key] ?? true;
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Material(
                          color: isVisible
                              ? const Color(0xFF251A12)
                              : const Color(0xFF202020),
                          borderRadius: BorderRadius.circular(14),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(14),
                            onTap: () {
                              final visible = !isVisible;
                              setSheetState(
                                () => sheetVisibility[key] = visible,
                              );
                              unawaited(_setMapLayerVisibility(key, visible));
                            },
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 10,
                              ),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(
                                  color: isVisible
                                      ? const Color(0xFF684022)
                                      : const Color(0xFF383838),
                                ),
                              ),
                              child: Row(
                                children: [
                                  Container(
                                    width: 36,
                                    height: 36,
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFFF9A3D)
                                          .withValues(alpha: 0.13),
                                      borderRadius: BorderRadius.circular(11),
                                    ),
                                    child: Icon(
                                      icon,
                                      color: const Color(0xFFFF9A3D),
                                      size: 20,
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Text(
                                      title,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 14,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                  Semantics(
                                    button: true,
                                    toggled: isVisible,
                                    label: '$title katmanı',
                                    value: isVisible ? 'Açık' : 'Kapalı',
                                    child: AnimatedContainer(
                                      duration: const Duration(
                                        milliseconds: 180,
                                      ),
                                      width: 82,
                                      height: 34,
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 4,
                                      ),
                                      decoration: BoxDecoration(
                                        color: isVisible
                                            ? const Color(0xFFFF7A00)
                                            : const Color(0xFF3A3A3A),
                                        borderRadius: BorderRadius.circular(20),
                                      ),
                                      child: Row(
                                        mainAxisAlignment: isVisible
                                            ? MainAxisAlignment.end
                                            : MainAxisAlignment.start,
                                        children: [
                                          if (isVisible)
                                            const Text(
                                              'Açık',
                                              style: TextStyle(
                                                color: Colors.white,
                                                fontSize: 11,
                                                fontWeight: FontWeight.w700,
                                              ),
                                            ),
                                          const SizedBox(width: 4),
                                          Container(
                                            width: 26,
                                            height: 26,
                                            decoration: const BoxDecoration(
                                              color: Colors.white,
                                              shape: BoxShape.circle,
                                            ),
                                            child: Icon(
                                              isVisible
                                                  ? Icons.check_rounded
                                                  : Icons.close_rounded,
                                              size: 15,
                                              color: isVisible
                                                  ? const Color(0xFFFF7A00)
                                                  : const Color(0xFF666666),
                                            ),
                                          ),
                                          if (!isVisible) ...[
                                            const SizedBox(width: 4),
                                            const Text(
                                              'Kapalı',
                                              style: TextStyle(
                                                color: Colors.white,
                                                fontSize: 10,
                                                fontWeight: FontWeight.w700,
                                              ),
                                            ),
                                          ],
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  bool _isMapLayerVisible(String layer) => _mapLayerVisibility[layer] ?? true;

  Future<void> _showCreateLostPetReportSheet({
    bool isAdoption = false,
    Map<String, dynamic>? listing,
  }) async {
    if (FirebaseAuth.instance.currentUser == null) {
      AppNotificationService.show(
        'Bildirim vermek için önce giriş yapmalısın.',
      );
      return;
    }
    final submitted = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: false,
      showDragHandle: false,
      backgroundColor: const Color(0xFF171817),
      builder: (context) =>
          CreateLostPetReportSheet(isAdoption: isAdoption, listing: listing),
    );
    if (submitted == true && mounted) {
      AppNotificationService.show(
        listing != null
            ? 'İlanın güncellendi.'
            : isAdoption
            ? 'Sahiplendirme ilanı haritaya eklendi.'
            : 'Kayıp dost bildirimin haritaya eklendi.',
      );
    }
  }

  String _lostPetTypeLabel(String? type) {
    switch (type) {
      case 'dog':
        return 'Köpek';
      case 'cat':
        return 'Kedi';
      default:
        return 'Diğer hayvan';
    }
  }

  void _showLostPetReport(Map<String, dynamic> report) {
    final isAdoption = report['collection'] == 'pet_adoption_listings';
    final rawPhotoUrls = report['photo_urls'];
    final imageUrls = rawPhotoUrls is List
        ? rawPhotoUrls
              .whereType<String>()
              .where((url) => url.isNotEmpty)
              .toSet()
              .toList()
        : <String>[];
    final coverImageUrl = report['cover_image_url']?.toString() ?? '';
    if (coverImageUrl.isNotEmpty && !imageUrls.contains(coverImageUrl)) {
      imageUrls.insert(0, coverImageUrl);
    }
    var currentPhotoIndex = 0;
    final phone = report['contact_phone']?.toString() ?? '';
    final isOwner =
        report['owner_uid'] == FirebaseAuth.instance.currentUser?.uid;
    if (!isOwner && report['status'] == 'active') {
      unawaited(_recordPetListingView(report));
    }
    final petName = report['pet_name']?.toString() ?? '';
    final type = _lostPetTypeLabel(report['pet_type']?.toString());
    final title = petName.isEmpty
        ? isAdoption
              ? 'Sahiplendirme ilanı'
              : 'Kayıp ${type.toLowerCase()}'
        : petName;
    final address = [
      report['address']?.toString() ?? '',
      report['district']?.toString() ?? '',
      report['city']?.toString() ?? '',
    ].where((part) => part.trim().isNotEmpty).join(', ');
    final lastSeen = report['last_seen_at'];
    final lastSeenText = lastSeen is Timestamp
        ? _formatReportTime(lastSeen.toDate())
        : 'Zaman bilgisi yok';

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF171817),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (sheetContext) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (imageUrls.isNotEmpty)
                ClipRRect(
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(22),
                  ),
                  child: StatefulBuilder(
                    builder: (context, setSheetState) => SizedBox(
                      height: 220,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          PageView.builder(
                            itemCount: imageUrls.length,
                            onPageChanged: (index) {
                              setSheetState(() => currentPhotoIndex = index);
                            },
                            itemBuilder: (context, index) => Image.network(
                              imageUrls[index],
                              width: double.infinity,
                              fit: BoxFit.cover,
                              errorBuilder: (context, error, stackTrace) =>
                                  const Center(
                                    child: Icon(
                                      Icons.broken_image_outlined,
                                      color: Colors.white70,
                                      size: 36,
                                    ),
                                  ),
                            ),
                          ),
                          if (imageUrls.length > 1)
                            Positioned(
                              right: 12,
                              bottom: 12,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: Colors.black54,
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 5,
                                  ),
                                  child: Text(
                                    '${currentPhotoIndex + 1}/${imageUrls.length}',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(
                          Icons.pets_rounded,
                          color: Color(0xFFA9C5B0),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            title,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 20,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Kapat',
                          onPressed: () => Navigator.pop(sheetContext),
                          icon: const Icon(Icons.close_rounded),
                          color: Colors.white70,
                        ),
                      ],
                    ),
                    Text(
                      isAdoption
                          ? 'Sahiplendiriliyor • $type'
                          : '$type • Son görüldü: $lastSeenText',
                      style: const TextStyle(
                        color: Color(0xFFB8C2BA),
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      report['description']?.toString() ?? '',
                      style: const TextStyle(
                        color: Color(0xFFE5E5E5),
                        height: 1.4,
                      ),
                    ),
                    if (address.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          const Icon(
                            Icons.place_rounded,
                            color: Color(0xFFA9C5B0),
                            size: 18,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              address,
                              style: const TextStyle(
                                color: Color(0xFFCACFCA),
                                fontSize: 13,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 16),
                    if (isOwner)
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: () => unawaited(_closePetListing(report)),
                          icon: const Icon(Icons.check_circle_outline_rounded),
                          label: Text(
                            isAdoption
                                ? 'İlanı kapat'
                                : 'Bulundu olarak işaretle',
                          ),
                        ),
                      )
                    else ...[
                      if (phone.isNotEmpty)
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton.icon(
                            onPressed: () =>
                                unawaited(_callLostPetContact(phone)),
                            style: FilledButton.styleFrom(
                              backgroundColor: const Color(0xFF55765D),
                              foregroundColor: Colors.white,
                            ),
                            icon: const Icon(Icons.call_rounded),
                            label: Text(
                              isAdoption ? 'İletişime geç' : 'Sahibi ara',
                            ),
                          ),
                        ),
                      if (!isAdoption &&
                          report['status'] == 'active' &&
                          report['id'] != null) ...[
                        const SizedBox(height: 8),
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            onPressed: () => unawaited(
                              _reportCommunityContent(
                                contentType: 'lost_pet',
                                contentId: report['id'].toString(),
                                ownerUid: report['owner_uid']?.toString() ?? '',
                                title: petName,
                                description:
                                    report['description']?.toString() ?? '',
                              ),
                            ),
                            icon: const Icon(Icons.flag_outlined),
                            label: const Text('Şikayet et'),
                          ),
                        ),
                      ],
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _callLostPetContact(String phone) async {
    try {
      final launched = await launchUrl(Uri(scheme: 'tel', path: phone));
      if (!launched && mounted) {
        AppNotificationService.show('Arama uygulaması açılamadı.');
      }
    } catch (error) {
      debugPrint('İletişim numarası açılamadı: $error');
    }
  }

  Future<void> _closePetListing(Map<String, dynamic> report) async {
    try {
      final isAdoption = report['collection'] == 'pet_adoption_listings';
      final collectionName =
          report['collection'] as String? ?? 'lost_pet_reports';
      await FirebaseFirestore.instance
          .collection(collectionName)
          .doc(report['id'] as String)
          .update({
            'status': 'resolved',
            'updated_at': FieldValue.serverTimestamp(),
          });
      if (!mounted) return;
      Navigator.of(context).pop();
      AppNotificationService.show(
        isAdoption
            ? 'Sahiplendirme ilanı kapatıldı.'
            : 'Bildirim bulundu olarak kapatıldı.',
      );
    } catch (error) {
      debugPrint('Kayıp dost bildirimi kapatılamadı: $error');
      if (!mounted) return;
      AppNotificationService.show('Bildirim kapatılamadı. Tekrar dene.');
    }
  }

  String _formatListingPrice(dynamic value) {
    if (value is! num) return 'Fiyat belirtilmemiş';
    final digits = value.round().toString();
    final groups = <String>[];
    for (var end = digits.length; end > 0; end -= 3) {
      final start = math.max(0, end - 3);
      groups.insert(0, digits.substring(start, end));
    }
    return '${groups.join('.')} TL';
  }

  void _showPropertyListing(Map<String, dynamic> listing) {
    final listingId = listing['id']?.toString();
    if (listingId != null &&
        listing['status'] == 'active' &&
        listing['owner_uid'] != FirebaseAuth.instance.currentUser?.uid) {
      unawaited(_recordPropertyListingView(listingId));
    }

    final imageUrl = listing['cover_image_url']?.toString() ?? '';
    final district = listing['district']?.toString() ?? '';
    final city = listing['city']?.toString() ?? '';
    final address = listing['address']?.toString().trim() ?? '';
    final location = address.isNotEmpty
        ? address
        : [district, city].where((part) => part.trim().isNotEmpty).join(', ');

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF171717),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (imageUrl.isNotEmpty)
                ClipRRect(
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(22),
                  ),
                  child: Image.network(
                    imageUrl,
                    width: double.infinity,
                    height: 210,
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stackTrace) =>
                        const SizedBox(
                          height: 150,
                          child: Center(
                            child: Icon(
                              Icons.home_work_rounded,
                              color: Color(0xFFFF7A00),
                              size: 42,
                            ),
                          ),
                        ),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 17, 20, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            listing['title']?.toString() ?? 'Konut ilanı',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 20,
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
                    const SizedBox(height: 5),
                    Text(
                      _formatListingPrice(listing['price']),
                      style: const TextStyle(
                        color: Color(0xFFFF9A3D),
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    if (location.isNotEmpty) ...[
                      const SizedBox(height: 9),
                      Row(
                        children: [
                          const Icon(
                            Icons.place_rounded,
                            color: Color(0xFFBDBDBD),
                            size: 17,
                          ),
                          const SizedBox(width: 5),
                          Expanded(
                            child: Text(
                              location,
                              style: const TextStyle(
                                color: Color(0xFFBDBDBD),
                                fontSize: 13,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                    if ((listing['description']?.toString() ?? '')
                        .isNotEmpty) ...[
                      const SizedBox(height: 14),
                      Text(
                        listing['description'].toString(),
                        style: const TextStyle(
                          color: Color(0xFFE0E0E0),
                          height: 1.45,
                          fontSize: 14,
                        ),
                      ),
                    ],
                    if (listing['status'] == 'active' &&
                        listing['owner_uid'] !=
                            FirebaseAuth.instance.currentUser?.uid &&
                        listingId != null) ...[
                      const SizedBox(height: 14),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: () => unawaited(
                            _reportCommunityContent(
                              contentType: 'property_listing',
                              contentId: listingId,
                              ownerUid: listing['owner_uid']?.toString() ?? '',
                              title:
                                  listing['title']?.toString() ?? 'Konut ilanı',
                              description:
                                  listing['description']?.toString() ?? '',
                            ),
                          ),
                          icon: const Icon(Icons.flag_outlined),
                          label: const Text('Şikayet et'),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _recordPropertyListingView(String listingId) async {
    try {
      await _propertyListingService.recordView(listingId);
    } catch (error) {
      debugPrint('İlan görüntülenmesi kaydedilemedi: $error');
    }
  }

  Future<void> _scrollPublicChatToBottom() async {
    if (!_publicChatScrollController.hasClients) return;
    final maxScroll = _publicChatScrollController.position.maxScrollExtent;
    await _publicChatScrollController.animateTo(
      maxScroll,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
    );
  }

  void _listenToCommunityPlaces() {
    _communityPlacesSubscription = FirebaseFirestore.instance
        .collection('community_places')
        .orderBy('created_at', descending: true)
        .limit(100)
        .snapshots()
        .listen(
          (snapshot) {
            if (!mounted) return;
            final places = snapshot.docs
                .map((document) {
                  final data = document.data();
                  final rawPhotoUrls = data['photo_urls'];
                  final photoUrls = rawPhotoUrls is List
                      ? rawPhotoUrls
                            .whereType<String>()
                            .where((url) => url.isNotEmpty)
                            .toList()
                      : <String>[];
                  final legacyPhotoUrl = data['photo_url']?.toString() ?? '';
                  if (photoUrls.isEmpty && legacyPhotoUrl.isNotEmpty) {
                    photoUrls.add(legacyPhotoUrl);
                  }
                  return <String, dynamic>{
                    'id': document.id,
                    'ownerUid': data['owner_uid']?.toString() ?? '',
                    'name': data['name']?.toString() ?? '',
                    'category': data['category']?.toString() ?? 'Diğer',
                    'description': data['description']?.toString() ?? '',
                    'address': data['address']?.toString() ?? '',
                    'photoUrls': photoUrls,
                    'photoUrl': photoUrls.isEmpty ? '' : photoUrls.first,
                    'latitude': (data['latitude'] as num?)?.toDouble(),
                    'longitude': (data['longitude'] as num?)?.toDouble(),
                  };
                })
                .where((place) {
                  return place['name'] is String &&
                      (place['name'] as String).isNotEmpty &&
                      place['latitude'] is double &&
                      place['longitude'] is double;
                })
                .toList();
            setState(() {
              _communityPlaces
                ..clear()
                ..addAll(places);
            });
          },
          onError: (error) =>
              debugPrint('Topluluk mekânları alınamadı: $error'),
        );
  }

  void _subscribeToLiveRooms() {
    _roomsSubscription = FirebaseFirestore.instance
        .collection('chat_room_listings')
        .orderBy('created_at', descending: true)
        .snapshots()
        .listen((snapshot) {
          if (!mounted) return;
          final now = DateTime.now();
          final rooms = snapshot.docs
              .map((document) {
                final data = document.data();
                final expiresAtValue = data['expires_at'];
                final expiresAt = expiresAtValue is Timestamp
                    ? expiresAtValue.toDate()
                    : null;
                if (expiresAt != null && !expiresAt.isAfter(now)) return null;
                final latitude = (data['latitude'] as num?)?.toDouble();
                final longitude = (data['longitude'] as num?)?.toDouble();
                final distance = latitude == null || longitude == null
                    ? data['distance']?.toString() ?? 'Yakınınızda'
                    : _distanceFromCurrentPosition(latitude, longitude) ??
                          data['distance']?.toString() ??
                          'Konum mevcut';
                return <String, dynamic>{
                  'id': document.id,
                  'ownerId': data['owner_id']?.toString() ?? '',
                  'name': data['name']?.toString() ?? 'Sohbet Odası',
                  'type': data['type']?.toString() ?? 'Canlı Oda',
                  'category': data['category']?.toString() ?? 'Genel',
                  'distance': distance,
                  'activeUsers':
                      data['active_users']?.toString() ?? '1 kişi aktif',
                  'activeUsersCount':
                      (data['active_users_count'] as num?)?.toInt() ?? 1,
                  'maxUsers': (data['max_users'] as num?)?.toInt() ?? 50,
                  'moderatorIds': List<String>.from(
                    data['moderator_ids'] ?? const <String>[],
                  ),
                  'icon': Icons.forum_rounded,
                  'latitude': latitude,
                  'longitude': longitude,
                  'isProtected': (data['is_protected'] as bool?) ?? false,
                  'passwordSalt': data['password_salt']?.toString() ?? '',
                  'updatedAt': data['updated_at'] is Timestamp
                      ? (data['updated_at'] as Timestamp).toDate()
                      : null,
                  'expiresAt': expiresAt,
                };
              })
              .whereType<Map<String, dynamic>>()
              .toList();

          setState(() {
            _liveRooms
              ..clear()
              ..addAll(rooms);
          });
        }, onError: (error) => debugPrint('Canlı odalar alınamadı: $error'));
  }

  void _subscribeToPublicChat() {
    _publicChatSubscription = FirebaseFirestore.instance
        .collection('public_chat_messages')
        .orderBy('createdAt', descending: true)
        .limit(80)
        .snapshots()
        .listen(
          (snapshot) {
            if (!mounted) return;
            final wasAtBottom = _publicChatWasAtBottom;
            final messages = snapshot.docs
                .map((document) {
                  final data = document.data();
                  final createdAt = data['createdAt'];
                  final time = createdAt is Timestamp
                      ? _formatChatTime(createdAt.toDate())
                      : 'Şimdi';
                  final latitude = (data['latitude'] as num?)?.toDouble();
                  final longitude = (data['longitude'] as num?)?.toDouble();
                  final storedDistance = data['distance']?.toString();
                  final resolvedDistance = latitude == null || longitude == null
                      ? (storedDistance != null &&
                                storedDistance.toLowerCase() != 'navora'
                            ? storedDistance
                            : null)
                      : (_distanceFromCurrentPosition(latitude, longitude) ??
                            (storedDistance != null &&
                                    storedDistance.toLowerCase() != 'navora'
                                ? storedDistance
                                : null));
                  return <String, dynamic>{
                    '_document_id': document.id,
                    'senderId': data['senderId']?.toString() ?? '',
                    'sender': data['senderName']?.toString() ?? 'Kullanıcı',
                    'text': data['text']?.toString() ?? '',
                    'time': time,
                    'distance': resolvedDistance,
                    'latitude': latitude,
                    'longitude': longitude,
                  };
                })
                .toList()
                .reversed
                .toList();

            final pendingOptimisticMessages = _publicFeedMessages.where((
              message,
            ) {
              final tempId = message['_localTempId']?.toString();
              if (tempId == null || tempId.isEmpty) return false;
              final senderId = message['senderId']?.toString() ?? '';
              final text = message['text']?.toString() ?? '';
              return !messages.any((incoming) {
                return (incoming['senderId']?.toString() ?? '') == senderId &&
                    (incoming['text']?.toString() ?? '') == text;
              });
            }).toList();

            final shouldFollowBottom = wasAtBottom || messages.isEmpty;

            setState(() {
              _publicFeedMessages
                ..clear()
                ..addAll(messages)
                ..addAll(pendingOptimisticMessages);
            });

            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (shouldFollowBottom) {
                _scrollPublicChatToBottom();
              }
            });
          },
          onError: (Object error) {
            debugPrint('Genel sohbet akışı alınamadı: $error');
          },
        );
  }

  void _removeExpiredRoomsFromView() {
    if (!mounted) return;
    final now = DateTime.now();
    final hadExpiredRoom = _liveRooms.any((room) {
      final expiresAt = room['expiresAt'];
      return expiresAt is DateTime && !expiresAt.isAfter(now);
    });
    if (!hadExpiredRoom) return;
    setState(() {
      _liveRooms.removeWhere((room) {
        final expiresAt = room['expiresAt'];
        return expiresAt is DateTime && !expiresAt.isAfter(now);
      });
    });
  }

  String _formatChatTime(DateTime dateTime) {
    final hour = dateTime.hour.toString().padLeft(2, '0');
    final minute = dateTime.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  Future<void> _sendPublicChatMessage() async {
    final text = _chatController.text.trim();
    if (text.isEmpty) return;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      _showTrackingMessage('Sohbete katılmak için giriş yapmalısınız.');
      return;
    }

    final optimisticMessage = <String, dynamic>{
      'senderId': user.uid,
      'sender': _userName,
      'text': text,
      'time': 'Şimdi',
      'distance': null,
      'latitude': _currentPosition?.latitude,
      'longitude': _currentPosition?.longitude,
      '_localTempId': 'local-${DateTime.now().microsecondsSinceEpoch}',
    };

    setState(() {
      _showPublicChatScrollToBottom = false;
      _publicFeedMessages.add(optimisticMessage);
    });
    _chatController.clear();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollPublicChatToBottom();
    });

    try {
      await FirebaseFunctions.instanceFor(region: 'europe-west1')
          .httpsCallable('sendChatMessage')
          .call({
            'messageType': 'public',
            'senderName': _userName,
            'text': text,
            'latitude': _currentPosition?.latitude,
            'longitude': _currentPosition?.longitude,
          });
    } on FirebaseFunctionsException catch (error) {
      debugPrint(
        'Genel sohbet mesajı gönderilemedi (${error.code}): ${error.message}',
      );
      setState(() {
        _publicFeedMessages.removeWhere((message) {
          return message['_localTempId'] == optimisticMessage['_localTempId'];
        });
      });
      if (mounted) {
        final message = switch (error.code) {
          'permission-denied' =>
            error.message ?? 'Bu sohbete mesaj gönderme yetkin bulunmuyor.',
          'resource-exhausted' =>
            error.message ??
                'Çok sık mesaj gönderiyorsun. Biraz bekleyip tekrar dene.',
          _ => 'Mesaj gönderilemedi. Tekrar deneyin.',
        };
        _showTrackingMessage(message);
      }
    } catch (error) {
      debugPrint('Genel sohbet mesajı gönderilemedi: $error');
      setState(() {
        _publicFeedMessages.removeWhere((message) {
          return message['_localTempId'] == optimisticMessage['_localTempId'];
        });
      });
      if (mounted) {
        _showTrackingMessage('Mesaj gönderilemedi. Tekrar deneyin.');
      }
    }
  }

  Future<void> _reportPublicChatMessage(Map<String, dynamic> message) async {
    final user = FirebaseAuth.instance.currentUser;
    final messageId = message['_document_id']?.toString() ?? '';
    final senderId = message['senderId']?.toString() ?? '';
    final text = message['text']?.toString() ?? '';
    if (user == null || messageId.isEmpty || senderId.isEmpty || text.isEmpty) {
      _showTrackingMessage('Mesaj şikayet edilemedi. Tekrar deneyin.');
      return;
    }
    if (senderId == user.uid) return;

    try {
      await FirebaseFirestore.instance.collection('chat_message_reports').add({
        'message_type': 'public',
        'room_id': 'public',
        'message_id': messageId,
        'reported_by': user.uid,
        'sender_id': senderId,
        'text': text,
        'created_at': FieldValue.serverTimestamp(),
        'status': 'open',
      });
      if (mounted) {
        _showTrackingMessage('Mesaj yöneticilere şikayet edildi.');
      }
    } catch (error) {
      debugPrint('Genel sohbet mesajı şikayet edilemedi: $error');
      if (mounted) {
        _showTrackingMessage('Şikayet gönderilemedi. Tekrar deneyin.');
      }
    }
  }

  Future<void> _reportCommunityContent({
    required String contentType,
    required String contentId,
    required String ownerUid,
    required String title,
    required String description,
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      _showTrackingMessage('Şikayet etmek için hesabına giriş yap.');
      return;
    }
    if (contentId.isEmpty ||
        ownerUid.isEmpty ||
        (contentType != 'lost_pet' && title.trim().isEmpty)) {
      _showTrackingMessage('İçerik şikayet edilemedi. Tekrar deneyin.');
      return;
    }
    if (ownerUid == user.uid) {
      _showTrackingMessage('Kendi içeriğini şikayet edemezsin.');
      return;
    }

    final reason = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Şikayet nedeni'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final option in const [
              'Yanıltıcı veya yanlış bilgi',
              'Uygunsuz içerik',
              'Spam veya tekrar eden ilan',
              'Başka bir sorun',
            ])
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(option),
                onTap: () => Navigator.pop(dialogContext, option),
              ),
          ],
        ),
      ),
    );
    if (reason == null || !mounted) return;

    try {
      await FirebaseFirestore.instance.collection('content_reports').add({
        'content_type': contentType,
        'content_id': contentId,
        'content_owner_uid': ownerUid,
        'content_title': title.trim(),
        'content_description': description.trim(),
        'reason': reason,
        'reported_by': user.uid,
        'created_at': FieldValue.serverTimestamp(),
        'status': 'open',
      });
      if (mounted) {
        _showTrackingMessage('Şikayetin yöneticilere iletildi.');
      }
    } catch (error) {
      debugPrint('İçerik şikayeti gönderilemedi: $error');
      if (mounted) {
        _showTrackingMessage('Şikayet gönderilemedi. Tekrar deneyin.');
      }
    }
  }

  Future<void> _resetPublicChat() async {
    if (!_canManageExploreHighlights || _isResettingPublicChat) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Genel sohbet sıfırlansın mı?'),
        content: const Text(
          'Genel sohbetteki tüm mevcut mesajlar kalıcı olarak silinecek. '
          'Sohbet odaları ve oda mesajları etkilenmez.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Vazgeç'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Mesajları sil'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _isResettingPublicChat = true);
    var deletedCount = 0;
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        throw FirebaseFunctionsException(
          code: 'unauthenticated',
          message: 'Oturum açmanız gerekiyor.',
        );
      }
      await user.getIdToken(true);
      final result = await FirebaseFunctions.instanceFor(region: 'europe-west1')
          .httpsCallable('clearPublicChat')
          .call();
      final response = result.data;
      if (response is Map && response['deletedCount'] is num) {
        deletedCount = (response['deletedCount'] as num).toInt();
      }
      if (mounted) {
        _showTrackingMessage('$deletedCount genel sohbet mesajı silindi.');
      }
    } on FirebaseFunctionsException catch (error) {
      debugPrint(
        'Genel sohbet sıfırlanamadı ($deletedCount mesaj silindi): '
        '${error.code} ${error.message}',
      );
      if (mounted) {
        final message = switch (error.code) {
          'permission-denied' => 'Genel sohbeti sıfırlama yetkin yok. Yönetici hesabıyla tekrar giriş yap.',
          'unauthenticated' =>
            'Oturum doğrulanamadı. Tekrar giriş yapıp yeniden dene.',
          'unavailable' || 'deadline-exceeded' =>
            'Sunucuya ulaşılamadı. Bağlantını kontrol edip yeniden dene.',
          _ =>
            deletedCount == 0
                ? 'Genel sohbet sıfırlanamadı. Biraz sonra tekrar dene.'
                : '$deletedCount mesaj silindi, işlem tamamlanamadı.',
        };
        _showTrackingMessage(message);
      }
    } catch (error) {
      debugPrint(
        'Genel sohbet sıfırlanamadı ($deletedCount mesaj silindi): $error',
      );
      if (mounted) {
        _showTrackingMessage(
          deletedCount == 0
              ? 'Genel sohbet sıfırlanamadı. Yetkini ve bağlantını kontrol et.'
              : '$deletedCount mesaj silindi, ancak işlem tamamlanamadı. Tekrar dene.',
        );
      }
    } finally {
      if (mounted) setState(() => _isResettingPublicChat = false);
    }
  }

  double? _roomDistanceInMeters(Map<String, dynamic> room) {
    final latitude = (room['latitude'] as num?)?.toDouble();
    final longitude = (room['longitude'] as num?)?.toDouble();
    final currentPosition = _currentPosition;

    if (latitude != null && longitude != null && currentPosition != null) {
      return geo.Geolocator.distanceBetween(
        currentPosition.latitude,
        currentPosition.longitude,
        latitude,
        longitude,
      );
    }

    final distanceText = room['distance']?.toString() ?? '';
    final normalizedLower = distanceText.toLowerCase();
    if (normalizedLower.isEmpty) {
      return null;
    }

    switch (normalizedLower) {
      case 'yakınınızda':
      case 'konum mevcut':
        return null;
      default:
        break;
    }

    final normalized = distanceText
        .replaceAll(',', '.')
        .replaceAll(RegExp(r'[^0-9.]'), ' ')
        .trim();
    if (normalized.isEmpty) return null;

    final parts = normalized.split(RegExp(r'\s+'));
    if (parts.isEmpty || parts.first.isEmpty) return null;

    final value = double.tryParse(parts.first);
    if (value == null) return null;

    return distanceText.toLowerCase().contains('km') ? value * 1000 : value;
  }

  String? _distanceFromCurrentPosition(double latitude, double longitude) {
    final currentPosition = _currentPosition;
    if (currentPosition == null) return null;
    final distance = geo.Geolocator.distanceBetween(
      currentPosition.latitude,
      currentPosition.longitude,
      latitude,
      longitude,
    );
    return _formatNearbyDistance(distance);
  }

  void _refreshLiveRoomDistances() {
    for (final room in _liveRooms) {
      final latitude = (room['latitude'] as num?)?.toDouble();
      final longitude = (room['longitude'] as num?)?.toDouble();
      if (latitude == null || longitude == null) continue;
      room['distance'] =
          _distanceFromCurrentPosition(latitude, longitude) ?? room['distance'];
    }
    for (final message in _visiblePublicFeedMessages) {
      final latitude = (message['latitude'] as num?)?.toDouble();
      final longitude = (message['longitude'] as num?)?.toDouble();
      if (latitude == null || longitude == null) continue;
      message['distance'] =
          _distanceFromCurrentPosition(latitude, longitude) ??
          message['distance'];
    }
  }

  String _formatReportTime(DateTime time) {
    final difference = DateTime.now().difference(time);
    if (difference.inMinutes < 1) return 'Şimdi';
    if (difference.inHours < 1) return '${difference.inMinutes} dk önce';
    if (difference.inDays < 1) return '${difference.inHours} sa önce';
    return '${difference.inDays} gün önce';
  }

  Future<void> _initializeLocation() async {
    try {
      if (!await _ensureLocationPermission()) return;
      geo.Position? position;
      if (!kIsWeb) {
        position =
            await geo.Geolocator.getLastKnownPosition() ??
            await geo.Geolocator.getCurrentPosition(
              locationSettings: const geo.LocationSettings(
                accuracy: geo.LocationAccuracy.medium,
              ),
            ).timeout(const Duration(seconds: 20));
      } else {
        position = await geo.Geolocator.getCurrentPosition(
          locationSettings: const geo.LocationSettings(
            accuracy: geo.LocationAccuracy.medium,
          ),
        ).timeout(const Duration(seconds: 20));
      }
      if (!mounted) return;
      setState(() {
        _currentPosition = position;
      });
      await _updateCurrentAddress(position, force: true);
      await _centerOnPosition(position);
    } on TimeoutException {
      debugPrint('Başlangıç konumu alınamadı: GPS zaman aşımı');
    } on geo.LocationServiceDisabledException {
      debugPrint('Başlangıç konumu alınamadı: GPS kapalı');
    } on geo.PermissionDeniedException {
      debugPrint('Başlangıç konumu alınamadı: izin reddedildi');
    } catch (error) {
      debugPrint('Başlangıç konumu alınırken hata: $error');
    }
  }

  Future<void> _searchPlace({bool showPanel = false}) async {
    final query = _searchController.text.trim();
    if (query.isEmpty || _isSearching) return;

    _searchDebounce?.cancel();
    final requestId = ++_searchRequestId;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _isSearching = true);
    try {
      final locations = await geo_coding.locationFromAddress(query);
      if (!mounted || requestId != _searchRequestId) return;
      if (locations.isEmpty) {
        _showTrackingMessage('Bu arama için konum bulunamadı.');
        return;
      }

      final location = locations.first;
      final coordinate = LatLng(location.latitude, location.longitude);
      final placemarks = await geo_coding.placemarkFromCoordinates(
        location.latitude,
        location.longitude,
      );
      if (!mounted || requestId != _searchRequestId) return;
      final placemark = placemarks.isEmpty ? null : placemarks.first;
      final resultName = _formatPlacemark(placemark) ?? query;

      setState(() {
        _clearRouteState();
        _searchResultName = resultName.isEmpty ? query : resultName;
        _selectedDestinationCoordinate = coordinate;
        _selectedDestinationName = _searchResultName;
        _selectedPlaceDetails = null;
        _searchMarkers = [
          Marker(
            markerId: const MarkerId('selected-search-result'),
            position: coordinate,
            icon: BitmapDescriptor.defaultMarkerWithHue(
              BitmapDescriptor.hueOrange,
            ),
            onTap: _showSelectedPlaceActionSheet,
          ),
        ];
        _showSearchPanel = showPanel;
      });
      unawaited(
        _recordSearchHistory(
          query: query,
          name: _searchResultName ?? resultName,
          coordinate: coordinate,
        ),
      );
      await _moveMapTo(coordinate, 15);
      if (mounted) {
        Future.microtask(() async {
          await Future<void>.delayed(const Duration(milliseconds: 300));
          if (mounted && requestId == _searchRequestId) {
            _showSelectedPlaceActionSheet();
          }
        });
      }
    } on PlatformException catch (error) {
      debugPrint('Yer araması başarısız: $error');
      if (mounted && requestId == _searchRequestId) {
        _showTrackingMessage('Yer araması şu anda kullanılamıyor.');
      }
    } catch (error) {
      debugPrint('Yer araması başarısız: $error');
      if (mounted && requestId == _searchRequestId) {
        _showTrackingMessage(
          'Yer bulunamadı. İnternet bağlantınızı kontrol edin.',
        );
      }
    } finally {
      if (mounted && requestId == _searchRequestId) {
        setState(() => _isSearching = false);
      }
    }
  }

  Future<void> _applySelectedSearchResult(Map<String, dynamic> item) async {
    final coordinate = item['coordinate'] as LatLng?;
    final name = item['name']?.toString().trim();
    if (coordinate == null || name == null || name.isEmpty) return;

    final query = item['query']?.toString() ?? name;
    FocusManager.instance.primaryFocus?.unfocus();

    if (_routeSelectionTarget != null) {
      final target = _routeSelectionTarget;
      setState(() {
        if (target == 'start') {
          _routeDraftStart = coordinate;
          _routeStartController.text = name;
          _routeSelectionTarget = 'destination';
        } else {
          _routeDraftDestination = coordinate;
          _routeDestinationController.text = name;
          _routeSelectionTarget = 'start';
        }
        _selectedDestinationCoordinate = null;
        _selectedDestinationName = null;
        _selectedPlaceDetails = null;
        _searchSuggestions = [];
        _showSearchPanel = false;
        _isSearchMode = false;
        _searchController.clear();
      });
      await _moveMapTo(coordinate, 15);
      return;
    }

    setState(() {
      _clearRouteState();
      _searchResultName = name;
      _selectedDestinationCoordinate = coordinate;
      _selectedDestinationName = name;
      _selectedPlaceDetails = item;
      _searchSuggestions = [item];
      _showSearchPanel = false;
      _searchMarkers = [
        Marker(
          markerId: const MarkerId('selected-search-result'),
          position: coordinate,
          icon: BitmapDescriptor.defaultMarkerWithHue(
            BitmapDescriptor.hueOrange,
          ),
          onTap: _showSelectedPlaceActionSheet,
        ),
      ];
    });
    unawaited(
      _recordSearchHistory(query: query, name: name, coordinate: coordinate),
    );
    await _moveMapTo(coordinate, 17);
    if (mounted) {
      Future.microtask(() async {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        if (mounted) _showSelectedPlaceActionSheet();
      });
    }
  }

  Future<void> _selectSearchSuggestion(Map<String, dynamic> item) async {
    var resolvedItem = item;
    final placeId = item['placeId']?.toString();
    if (placeId != null && placeId.isNotEmpty) {
      try {
        final details = await NavoraPlacesService.getPlaceDetails(placeId);
        if (details != null) resolvedItem = {...item, ...details};
      } catch (error) {
        debugPrint('Google yer detayı alınamadı: $error');
      }
    }
    await _applySelectedSearchResult(resolvedItem);
  }

  Future<void> _showSelectedPlaceActionSheet() async {
    if (!mounted || _selectedDestinationCoordinate == null) return;
    final selectedCoordinate = _selectedDestinationCoordinate!;
    await Future<void>.delayed(const Duration(milliseconds: 150));
    if (!mounted || _selectedDestinationCoordinate != selectedCoordinate) {
      return;
    }

    var didChoosePlaceAction = false;
    final placeDetails = _selectedPlaceDetails ?? const <String, dynamic>{};
    final communityPhotoUrls = placeDetails['source'] == 'community_place'
        ? ((placeDetails['photoUrls'] as List?)?.whereType<String>().toList() ??
              [
                (placeDetails['photoUrl'] ?? placeDetails['photo_url'])
                        ?.toString()
                        .trim() ??
                    '',
              ].where((url) => url.isNotEmpty).toList())
        : <String>[];
    final ratingText = placeDetails['ratingText']?.toString();
    final phoneNumber = placeDetails['phoneNumber']?.toString();
    final websiteUri = Uri.tryParse(
      placeDetails['websiteUri']?.toString() ?? '',
    );
    final openingHours =
        (placeDetails['openingHours'] as List<dynamic>? ?? const [])
            .map((day) => day.toString())
            .toList(growable: false);
    final isOpenNow = placeDetails['isOpenNow'] as bool?;
    final currentPosition = _currentPosition;
    final distanceText = currentPosition == null
        ? null
        : _formatSearchDistance(
            geo.Geolocator.distanceBetween(
              currentPosition.latitude,
              currentPosition.longitude,
              _selectedDestinationCoordinate!.latitude,
              _selectedDestinationCoordinate!.longitude,
            ),
          );

    await showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF171717),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 44,
                height: 5,
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: const Color(0xFF4A4A4A),
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: const Color(0xFF2A180D),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(
                      Icons.storefront_rounded,
                      color: Color(0xFFFF7A00),
                      size: 26,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _selectedDestinationName ?? 'Seçilen konum',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xFF2A180D),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Text(
                                distanceText ?? 'Uzaklık bilinmiyor',
                                style: const TextStyle(
                                  color: Color(0xFFFF6B00),
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              if (communityPhotoUrls.isNotEmpty) ...[
                const SizedBox(height: 16),
                Builder(
                  builder: (context) {
                    var currentPhotoIndex = 0;
                    return StatefulBuilder(
                      builder: (context, setGalleryState) {
                        return Column(
                          children: [
                            SizedBox(
                              height: 190,
                              child: PageView.builder(
                                itemCount: communityPhotoUrls.length,
                                onPageChanged: (index) {
                                  setGalleryState(
                                    () => currentPhotoIndex = index,
                                  );
                                },
                                itemBuilder: (context, index) => ClipRRect(
                                  borderRadius: BorderRadius.circular(14),
                                  child: Image.network(
                                    communityPhotoUrls[index],
                                    width: double.infinity,
                                    fit: BoxFit.cover,
                                    errorBuilder: (context, error, stackTrace) {
                                      debugPrint(
                                        'Topluluk mekânı fotoğrafı açılamadı: $error',
                                      );
                                      return const Center(
                                        child: Icon(
                                          Icons.broken_image_outlined,
                                          color: Colors.white54,
                                          size: 32,
                                        ),
                                      );
                                    },
                                  ),
                                ),
                              ),
                            ),
                            if (communityPhotoUrls.length > 1) ...[
                              const SizedBox(height: 8),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Text(
                                    '${currentPhotoIndex + 1}/${communityPhotoUrls.length}',
                                    style: const TextStyle(
                                      color: Colors.white70,
                                      fontSize: 12,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  ...List.generate(
                                    communityPhotoUrls.length,
                                    (index) => Container(
                                      width: 6,
                                      height: 6,
                                      margin: const EdgeInsets.symmetric(
                                        horizontal: 3,
                                      ),
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: index == currentPhotoIndex
                                            ? const Color(0xFFFF7A00)
                                            : Colors.white30,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ],
                        );
                      },
                    );
                  },
                ),
              ],
              const SizedBox(height: 16),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF101010),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.location_searching_rounded,
                      color: Color(0xFFFF7A00),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _searchController.text.trim().isNotEmpty
                            ? _searchController.text.trim()
                            : _selectedDestinationName ??
                                  'Haritada işaretlenen konum',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: Colors.white70),
                      ),
                    ),
                  ],
                ),
              ),
              if (ratingText != null || isOpenNow != null) ...[
                const SizedBox(height: 10),
                Row(
                  children: [
                    if (ratingText != null) ...[
                      const Icon(
                        Icons.star_rounded,
                        color: Color(0xFFFFC247),
                        size: 19,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        ratingText,
                        style: const TextStyle(color: Colors.white),
                      ),
                    ],
                    if (ratingText != null && isOpenNow != null)
                      const SizedBox(width: 14),
                    if (isOpenNow != null)
                      Text(
                        isOpenNow ? 'Açık' : 'Kapalı',
                        style: TextStyle(
                          color: isOpenNow
                              ? const Color(0xFF75D49A)
                              : const Color(0xFFE68D83),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                  ],
                ),
              ],
              if (phoneNumber != null || (websiteUri?.hasScheme ?? false)) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    if (phoneNumber != null && phoneNumber.isNotEmpty)
                      TextButton.icon(
                        onPressed: () =>
                            launchUrl(Uri(scheme: 'tel', path: phoneNumber)),
                        icon: const Icon(Icons.call_outlined, size: 18),
                        label: Text(phoneNumber),
                      ),
                    if (websiteUri?.hasScheme ?? false)
                      TextButton.icon(
                        onPressed: () => launchUrl(
                          websiteUri!,
                          mode: LaunchMode.externalApplication,
                        ),
                        icon: const Icon(Icons.open_in_new_rounded, size: 18),
                        label: const Text('Web sitesi'),
                      ),
                  ],
                ),
              ],
              if (openingHours.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  openingHours.take(2).join('\n'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ],
              if (placeDetails['source'] == 'community_place' &&
                  (placeDetails['description']?.toString().isNotEmpty ??
                      false)) ...[
                const SizedBox(height: 10),
                Text(
                  placeDetails['description'].toString(),
                  style: const TextStyle(color: Colors.white70, height: 1.4),
                ),
              ],
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () async {
                        didChoosePlaceAction = true;
                        Navigator.pop(sheetContext);
                        await _saveSelectedPlace();
                      },
                      icon: const Icon(Icons.bookmark_border_rounded),
                      label: const Text('Kaydet'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFFFF7A00),
                        side: const BorderSide(color: Color(0xFFFF7A00)),
                        padding: const EdgeInsets.symmetric(vertical: 15),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(26),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: () async {
                        didChoosePlaceAction = true;
                        Navigator.pop(sheetContext);
                        await _showDirectionsSheet();
                      },
                      icon: const Icon(Icons.navigation_rounded),
                      label: const Text('Yola çık'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFFF7A00),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 15),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(26),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              if (placeDetails['source'] == 'community_place' &&
                  placeDetails['id'] != null &&
                  placeDetails['ownerUid'] !=
                      FirebaseAuth.instance.currentUser?.uid) ...[
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.center,
                  child: TextButton.icon(
                    onPressed: () async {
                      didChoosePlaceAction = true;
                      Navigator.pop(sheetContext);
                      await _reportCommunityContent(
                        contentType: 'community_place',
                        contentId: placeDetails['id'].toString(),
                        ownerUid: placeDetails['ownerUid']?.toString() ?? '',
                        title:
                            placeDetails['name']?.toString() ??
                            _selectedDestinationName ??
                            '',
                        description:
                            placeDetails['description']?.toString() ?? '',
                      );
                    },
                    icon: const Icon(Icons.flag_outlined),
                    label: const Text('Şikayet et'),
                  ),
                ),
              ],
              if (placeDetails['source'] != 'community_place') ...[
                const SizedBox(height: 4),
                Align(
                  alignment: Alignment.center,
                  child: TextButton.icon(
                    onPressed: () async {
                      final coordinate = _selectedDestinationCoordinate;
                      if (coordinate == null) return;
                      didChoosePlaceAction = true;
                      Navigator.pop(sheetContext);
                      await _createCommunityPlace(
                        initialCoordinate: coordinate,
                        initialName: _selectedDestinationName ?? '',
                        initialAddress: _searchController.text.trim(),
                      );
                    },
                    icon: const Icon(Icons.add_location_alt_outlined),
                    label: const Text('Bu yeri topluluğa ekle'),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
    if (!didChoosePlaceAction &&
        mounted &&
        _selectedDestinationCoordinate == selectedCoordinate) {
      setState(() {
        _searchMarkers = const [];
        _selectedDestinationCoordinate = null;
        _selectedDestinationName = null;
        _selectedPlaceDetails = null;
        _searchResultName = null;
        _searchSuggestions = [];
        _searchController.clear();
      });
    }
  }

  Future<void> _selectMapLocation(LatLng coordinate) async {
    if (!mounted) return;

    try {
      final nearbyPlace = await NavoraPlacesService.findNearestPlace(
        coordinate,
      );
      if (!mounted) return;
      if (nearbyPlace != null) {
        await _selectSearchSuggestion(nearbyPlace);
        return;
      }
    } catch (error) {
      debugPrint('Basılı tutulan konumdaki işletme bulunamadı: $error');
    }

    var label = 'Haritada seçilen konum';
    try {
      final placemarks = await geo_coding.placemarkFromCoordinates(
        coordinate.latitude,
        coordinate.longitude,
      );
      label =
          _formatPlacemark(placemarks.isEmpty ? null : placemarks.first) ??
          label;
    } catch (error) {
      debugPrint('Harita konumu adresi alınamadı: $error');
    }

    if (!mounted) return;
    setState(() {
      _selectedDestinationCoordinate = coordinate;
      _selectedDestinationName = label;
      _selectedPlaceDetails = null;
      _searchResultName = label;
      _searchController.text = label;
      _searchMarkers = [
        Marker(
          markerId: const MarkerId('selected-map-location'),
          position: coordinate,
          icon: BitmapDescriptor.defaultMarkerWithHue(
            BitmapDescriptor.hueOrange,
          ),
          onTap: _showSelectedPlaceActionSheet,
        ),
      ];
    });
    await _showSelectedPlaceActionSheet();
  }

  String? _formatPlacemark(geo_coding.Placemark? placemark) {
    if (placemark == null) return null;
    final parts =
        [
              placemark.name,
              placemark.street,
              placemark.subLocality,
              placemark.locality,
              placemark.administrativeArea,
            ]
            .whereType<String>()
            .map((part) => part.trim())
            .where((part) => part.isNotEmpty)
            .toList();
    final uniqueParts = <String>[];
    for (final part in parts) {
      if (!uniqueParts.contains(part)) uniqueParts.add(part);
    }
    return uniqueParts.isEmpty ? null : uniqueParts.join(', ');
  }

  Future<void> _updateCurrentAddress(
    geo.Position position, {
    bool force = false,
  }) async {
    final now = DateTime.now();
    if (!force &&
        _lastAddressLookupAt != null &&
        now.difference(_lastAddressLookupAt!) < const Duration(seconds: 20)) {
      return;
    }
    _lastAddressLookupAt = now;
    try {
      final placemarks = await geo_coding.placemarkFromCoordinates(
        position.latitude,
        position.longitude,
      );
      final placemark = placemarks.isEmpty ? null : placemarks.first;
      final address = _formatPlacemark(placemark);
      final roadName = [placemark?.thoroughfare, placemark?.street]
          .whereType<String>()
          .map((part) => part.trim())
          .firstWhere((part) => part.isNotEmpty, orElse: () => '');
      if (!mounted) return;
      setState(() {
        _currentAddress = address;
        _currentRoadName = roadName.isEmpty ? null : roadName;
      });
      await _recordVisitedCity(placemark);
    } catch (error) {
      debugPrint('Anlık adres alınamadı: $error');
    }
  }

  Future<void> _recordVisitedCity(geo_coding.Placemark? placemark) async {
    final city = placemark?.administrativeArea?.trim().isNotEmpty == true
        ? placemark!.administrativeArea!.trim()
        : placemark?.locality?.trim();
    final user = FirebaseAuth.instance.currentUser;
    if (city == null || city.isEmpty || user == null) return;
    if (_visitedCities.any(
      (visitedCity) => visitedCity.toLowerCase() == city.toLowerCase(),
    )) {
      return;
    }

    try {
      await FirebaseFirestore.instance.collection('users').doc(user.uid).set({
        'visited_cities': FieldValue.arrayUnion([city]),
        'updated_at': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      if (!mounted || FirebaseAuth.instance.currentUser?.uid != user.uid) {
        return;
      }
      setState(() {
        if (!_visitedCities.any(
          (visitedCity) => visitedCity.toLowerCase() == city.toLowerCase(),
        )) {
          _visitedCities.add(city);
        }
      });
    } catch (error) {
      debugPrint('Ziyaret edilen şehir kaydedilemedi: $error');
      if (mounted) {
        _showTrackingMessage('Ziyaret edilen şehir kaydedilemedi.');
      }
    }
  }

  Future<void> _refreshNavigationRouteIfNeeded(geo.Position position) async {
    final destination = _selectedDestinationCoordinate;
    if (!_isNavigationActive ||
        destination == null ||
        !navoraHasReliableNavigationPosition(position.accuracy)) {
      return;
    }

    final currentPosition = LatLng(position.latitude, position.longitude);
    final liveRoute = _routePolylines.isEmpty
        ? const <LatLng>[]
        : _routePolylines.first.points;
    final effectiveRouteThresholdMeters = navoraOffRouteThresholdMeters(
      vehicle: _selectedVehicle,
      accuracyMeters: position.accuracy,
    );
    final recoveryThresholdMeters = effectiveRouteThresholdMeters * 0.65;
    final distanceToRoute = navoraDistanceToRouteMeters(
      currentPosition,
      liveRoute,
    );
    final hasLiveRoute = liveRoute.length > 1;
    final exceedsRouteThreshold =
        hasLiveRoute &&
        distanceToRoute >
            (_isOffRoute
                ? recoveryThresholdMeters
                : effectiveRouteThresholdMeters);
    if (exceedsRouteThreshold) {
      _offRouteReadings++;
    } else {
      _offRouteReadings = 0;
    }
    final isOffRoute =
        hasLiveRoute &&
        (_isOffRoute ? exceedsRouteThreshold : _offRouteReadings >= 2);
    if (hasLiveRoute && isOffRoute != _isOffRoute) {
      _isOffRoute = isOffRoute;
      if (mounted) setState(() {});
    }

    if (!isOffRoute && hasLiveRoute) {
      final remainingRoute = navoraTrimRouteToRemainingPath(
        liveRoute,
        currentPosition,
        vehicle: _selectedVehicle,
      );
      if (remainingRoute.length > 1 &&
          (remainingRoute.length != liveRoute.length ||
              remainingRoute.first != liveRoute.first)) {
        final activePolyline = _routePolylines.first;
        final previousDistanceKm = _navigationDistanceKm;
        final remainingDistanceKm = navoraRouteLengthKm(remainingRoute);
        if (mounted) {
          setState(() {
            _routePolylines = [
              Polyline(
                polylineId: activePolyline.polylineId,
                points: remainingRoute,
                color: activePolyline.color,
                width: activePolyline.width,
                zIndex: activePolyline.zIndex,
              ),
            ];
            if (previousDistanceKm != null && previousDistanceKm > 0) {
              _navigationDistanceKm = remainingDistanceKm;
              final previousDurationSeconds = _navigationDurationSeconds;
              if (previousDurationSeconds != null) {
                _navigationDurationSeconds =
                    navoraScaleRemainingDurationSeconds(
                      durationSeconds: previousDurationSeconds,
                      remainingDistanceKm: remainingDistanceKm,
                      previousDistanceKm: previousDistanceKm,
                    );
                _navigationDurationMinutes = navoraDurationMinutesFromSeconds(
                  _navigationDurationSeconds!,
                );
              }
            }
          });
        }
      }
    }

    if (!isOffRoute) return;
    if (_isRefreshingNavigation) return;
    final now = DateTime.now();
    if (_lastNavigationRefreshAt != null &&
        now.difference(_lastNavigationRefreshAt!) <
            const Duration(seconds: 12)) {
      return;
    }
    _lastNavigationRefreshAt = now;
    _isRefreshingNavigation = true;
    try {
      var routeOrigin = currentPosition;
      Map<String, dynamic>? route;
      for (var attempt = 0; attempt < 2; attempt++) {
        route = await _fetchRoadRoute(
          routeOrigin,
          destination,
          vehicle: _selectedVehicle,
        );
        if (!mounted ||
            !_isNavigationActive ||
            !_isOffRoute ||
            _selectedDestinationCoordinate != destination) {
          return;
        }

        final latestPosition = _currentPosition;
        if (attempt == 1 ||
            latestPosition == null ||
            !navoraHasReliableNavigationPosition(latestPosition.accuracy)) {
          break;
        }
        final latestCoordinate = LatLng(
          latestPosition.latitude,
          latestPosition.longitude,
        );
        final movedMeters = geo.Geolocator.distanceBetween(
          routeOrigin.latitude,
          routeOrigin.longitude,
          latestCoordinate.latitude,
          latestCoordinate.longitude,
        );
        if (!navoraShouldRefetchRouteFromLatestPosition(
          movedMeters: movedMeters,
          speedMetersPerSecond: latestPosition.speed,
        )) {
          break;
        }
        routeOrigin = latestCoordinate;
      }

      if (route == null ||
          !mounted ||
          !_isNavigationActive ||
          !_isOffRoute ||
          _selectedDestinationCoordinate != destination) {
        return;
      }
      final routeOptions =
          route['options'] as List<Map<String, dynamic>>? ?? [route];
      final selectedRoute = routeOptions.first;
      final routePoints = selectedRoute['points'] as List<LatLng>;
      final latestPosition = _currentPosition;
      final latestRoutePosition =
          latestPosition != null &&
              navoraHasReliableNavigationPosition(latestPosition.accuracy)
          ? LatLng(latestPosition.latitude, latestPosition.longitude)
          : currentPosition;
      final remainingRoute = navoraTrimRouteToRemainingPath(
        routePoints,
        latestRoutePosition,
        vehicle: _selectedVehicle,
      );
      final trafficPolylines =
          selectedRoute['trafficPolylines'] as List<Polyline>? ?? const [];
      final remainingDistanceKm = navoraRouteLengthKm(remainingRoute);
      final refreshedDurationMinutes = selectedRoute['durationMinutes'] as int;
      final refreshedDurationSeconds = refreshedDurationMinutes * 60.0;
      setState(() {
        _navigationTrafficPolylines = trafficPolylines;
        _alternativeRoutePolylines = const [];
        _routePolylines = [
          Polyline(
            polylineId: const PolylineId('route-live'),
            points: remainingRoute,
            color: const Color(0xFF4285F4),
            width: 7,
          ),
        ];
        _navigationSteps = List<Map<String, dynamic>>.from(
          selectedRoute['steps'],
        );
        _navigationStepIndex = 0;
        _navigationDistanceKm = remainingDistanceKm;
        _navigationDurationSeconds = refreshedDurationSeconds;
        _navigationDurationMinutes = navoraDurationMinutesFromSeconds(
          refreshedDurationSeconds,
        );
        _isOffRoute = false;
        _offRouteReadings = 0;
        _hasShownRouteUpdateError = false;
      });
      final cameraPosition = latestPosition ?? _currentPosition;
      if (cameraPosition != null &&
          _isFollowingCurrentPosition &&
          navoraShouldFollowCurrentPosition(
            isNavigationActive: _isNavigationActive,
            isDriveTracking: _isDriveTracking,
            isLocationTracking: _isLocationTracking,
            isFollowing: _isFollowingCurrentPosition,
          )) {
        unawaited(_centerOnPosition(cameraPosition));
      }
    } catch (error) {
      debugPrint('Canlı rota güncellenemedi: $error');
      if (mounted && !_hasShownRouteUpdateError) {
        _hasShownRouteUpdateError = true;
        _showTrackingMessage(
          'Rota güncellenemedi. İnternet bağlantınızı kontrol edin.',
        );
      }
    } finally {
      _isRefreshingNavigation = false;
    }
  }

  Future<void> _subscribeToSearchHistory() async {
    await _searchHistorySubscription?.cancel();
    _searchHistorySubscription = null;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      if (mounted) setState(_searchHistory.clear);
      return;
    }

    _searchHistorySubscription = FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .collection('search_history')
        .orderBy('created_at', descending: true)
        .limit(5)
        .snapshots()
        .listen(
          (snapshot) {
            if (!mounted ||
                FirebaseAuth.instance.currentUser?.uid != user.uid) {
              return;
            }
            final history = snapshot.docs
                .map((document) {
                  final data = document.data();
                  final latitude = (data['latitude'] as num?)?.toDouble();
                  final longitude = (data['longitude'] as num?)?.toDouble();
                  return <String, dynamic>{
                    'id': document.id,
                    'query': data['query']?.toString() ?? '',
                    'name': data['name']?.toString() ?? '',
                    if (latitude != null && longitude != null)
                      'coordinate': LatLng(latitude, longitude),
                  };
                })
                .where((entry) => (entry['query'] as String).isNotEmpty)
                .toList();
            setState(() {
              _searchHistory
                ..clear()
                ..addAll(history);
            });
          },
          onError: (Object error) {
            debugPrint('Arama geçmişi dinlenemedi: $error');
            if (mounted) {
              _showTrackingMessage('Arama geçmişi yüklenemedi.');
            }
          },
        );
  }

  Future<void> _recordSearchHistory({
    required String query,
    required String name,
    required LatLng coordinate,
  }) async {
    final normalizedQuery = query.trim();
    if (normalizedQuery.isEmpty || !_isSearchHistoryEnabled) return;

    final entry = <String, dynamic>{
      'query': normalizedQuery,
      'name': name,
      'coordinate': coordinate,
    };
    if (mounted) {
      setState(() {
        _searchHistory.removeWhere((item) => item['query'] == normalizedQuery);
        _searchHistory.insert(0, entry);
        if (_searchHistory.length > 5) _searchHistory.removeLast();
      });
    }

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    try {
      final historyCollection = FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .collection('search_history');
      final matchingEntries = await historyCollection
          .where('query', isEqualTo: normalizedQuery)
          .get();
      final document = historyCollection.doc();
      final batch = FirebaseFirestore.instance.batch();
      for (final duplicate in matchingEntries.docs) {
        batch.delete(duplicate.reference);
      }
      batch.set(document, {
        'query': normalizedQuery,
        'name': name,
        'latitude': coordinate.latitude,
        'longitude': coordinate.longitude,
        'created_at': FieldValue.serverTimestamp(),
      });
      await batch.commit();

      final oldEntries = await historyCollection
          .orderBy('created_at', descending: true)
          .limit(20)
          .get();
      if (oldEntries.docs.length > 5) {
        final cleanupBatch = FirebaseFirestore.instance.batch();
        for (final oldEntry in oldEntries.docs.skip(5)) {
          cleanupBatch.delete(oldEntry.reference);
        }
        await cleanupBatch.commit();
      }
    } catch (error) {
      debugPrint('Arama geçmişi Firestore’a kaydedilemedi: $error');
      if (mounted) {
        _showTrackingMessage('Arama geçmişi kaydedilemedi.');
      }
    }
  }

  Future<bool> _clearSearchHistory() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      if (mounted) {
        setState(() {
          _searchHistory.clear();
          _showSearchPanel = false;
        });
      }
      return true;
    }

    try {
      final historyCollection = FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .collection('search_history');
      final entries = await historyCollection.get();
      for (var offset = 0; offset < entries.docs.length; offset += 450) {
        final batch = FirebaseFirestore.instance.batch();
        for (final entry in entries.docs.skip(offset).take(450)) {
          batch.delete(entry.reference);
        }
        await batch.commit();
      }
      if (mounted) {
        setState(() {
          _searchHistory.clear();
          _showSearchPanel = false;
        });
      }
      return true;
    } catch (error) {
      debugPrint('Arama geçmişi Firestore’dan silinemedi: $error');
      if (mounted) {
        _showTrackingMessage('Arama geçmişi silinemedi.');
      }
      return false;
    }
  }

  Future<void> _confirmAndClearSearchHistory() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Arama geçmişi silinsin mi?'),
        content: const Text(
          'Bu işlem hesabınızda kayıtlı son aramaları da siler.',
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
    await _clearSearchHistory();
  }

  void _handleSearchChanged(String value) {
    _searchDebounce?.cancel();
    final requestId = ++_searchRequestId;
    final query = value.trim();
    if (mounted && !_isSearchMode) {
      setState(() => _isSearchMode = true);
    }
    if (query.isEmpty) {
      if (mounted) {
        setState(() {
          _searchSuggestions = [];
          _showSearchPanel = false;
          _isSearching = false;
        });
      }
      return;
    }

    if (mounted) {
      setState(() {
        _showSearchPanel = true;
        _isSearching = false;
      });
    }

    _searchDebounce = Timer(const Duration(milliseconds: 450), () {
      if (mounted && requestId == _searchRequestId) {
        _loadSearchSuggestions(query, requestId: requestId);
      }
    });
  }

  Future<geo.Position?> _getPositionForSearch() async {
    if (_currentPosition != null) return _currentPosition;
    final pending = _searchPositionFuture;
    if (pending != null) return pending;

    final future = _loadPositionForSearch();
    _searchPositionFuture = future;
    try {
      return await future;
    } finally {
      if (identical(_searchPositionFuture, future)) {
        _searchPositionFuture = null;
      }
    }
  }

  Future<geo.Position?> _loadPositionForSearch() async {
    if (!await _ensureLocationPermission()) return null;
    try {
      final position = await geo.Geolocator.getCurrentPosition(
        locationSettings: const geo.LocationSettings(
          accuracy: geo.LocationAccuracy.medium,
        ),
      ).timeout(const Duration(seconds: 12));
      if (mounted) setState(() => _currentPosition = position);
      return position;
    } catch (error) {
      debugPrint('Arama uzaklığı için konum alınamadı: $error');
      return _currentPosition;
    }
  }

  Future<void> _openSearchPage() async {
    final selected = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(
        builder: (_) => MapSearchPage(
          initialQuery: _searchController.text,
          initialHistory: _searchHistory,
          initialLocation: _currentPosition == null
              ? null
              : LatLng(_currentPosition!.latitude, _currentPosition!.longitude),
          isHistoryEnabled: _isSearchHistoryEnabled,
          onClearHistory: _clearSearchHistory,
          onHistoryEnabledChanged: _setSearchHistoryEnabled,
        ),
      ),
    );
    if (!mounted) return;
    _searchFocusNode.unfocus();
    await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
    if (selected == null) return;
    await _selectSearchSuggestion(selected);
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
    if (!available || !mounted) {
      _showTrackingMessage('Bu cihazda sesli arama kullanılamıyor.');
      return;
    }

    setState(() => _isListening = true);
    await _speech.listen(
      listenOptions: SpeechListenOptions(
        localeId: 'tr_TR',
        listenMode: ListenMode.search,
      ),
      onResult: (result) {
        if (!mounted) return;
        setState(() {
          _searchController.text = result.recognizedWords;
          _searchController.selection = TextSelection.fromPosition(
            TextPosition(offset: _searchController.text.length),
          );
        });
        _handleSearchChanged(result.recognizedWords);
        if (result.finalResult) {
          _speech.stop();
          setState(() => _isListening = false);
          _searchPlace();
        }
      },
    );
  }

  String? _matchNearbyCategory(String query) {
    final normalized = query.trim().toLowerCase();
    if (normalized.isEmpty) return null;

    final matches = <Map<String, String>>[
      {'label': 'Kafeler', 'keywords': 'kafe|kahve|coffee|cafe'},
      {'label': 'Benzinlik', 'keywords': 'benzin|akaryakıt|gas|fuel|petrol'},
      {'label': 'Restoran', 'keywords': 'restoran|lokanta|yemek|restaurant'},
      {
        'label': 'Market',
        'keywords': 'market|bakkal|migros|süpermarket|supermarket',
      },
      {'label': 'Park', 'keywords': 'park|bahçe|garden'},
      {'label': 'Hastane', 'keywords': 'hastane|klinik|hospital|clinic'},
      {'label': 'Otobüs', 'keywords': 'otobüs|durak|bus|tramvay|metro'},
    ];

    for (final item in matches) {
      final keywords = item['keywords']!.split('|');
      if (keywords.any((keyword) => normalized.contains(keyword))) {
        return item['label'];
      }
    }
    return null;
  }

  Future<void> _loadSearchSuggestions(String query, {int? requestId}) async {
    final activeRequestId = requestId ?? ++_searchRequestId;
    try {
      final currentPosition = await _getPositionForSearch();
      if (!mounted || activeRequestId != _searchRequestId) return;
      final searchLocation = currentPosition == null
          ? null
          : LatLng(currentPosition.latitude, currentPosition.longitude);
      final isBusinessQuery = NavoraPlacesService.isBusinessQuery(query);
      if (isBusinessQuery) {
        var businesses = <Map<String, dynamic>>[];
        try {
          businesses = await NavoraPlacesService.searchText(
            query,
            location: searchLocation,
          );
        } catch (error) {
          debugPrint('Google Places text search failed: $error');
        }
        if (businesses.isNotEmpty) {
          if (!mounted || activeRequestId != _searchRequestId) return;
          setState(() {
            _searchSuggestions = businesses;
            _showSearchPanel = true;
          });
          return;
        }
        final category = _matchNearbyCategory(query);
        if (category != null && currentPosition != null) {
          await _loadNearbyCategoryResults(
            category,
            currentPosition,
            _nearbyBusinessConfig()[category]!,
            requestId: activeRequestId,
          );
          return;
        }
      } else {
        var googleResults = <Map<String, dynamic>>[];
        try {
          googleResults = await NavoraPlacesService.searchText(
            query,
            location: searchLocation,
          );
        } catch (error) {
          debugPrint('Google Places text search failed: $error');
        }
        if (googleResults.isNotEmpty) {
          if (!mounted || activeRequestId != _searchRequestId) return;
          setState(() {
            _searchSuggestions = googleResults;
            _showSearchPanel = true;
          });
          return;
        }

        var googleSuggestions = <Map<String, dynamic>>[];
        try {
          googleSuggestions = await NavoraPlacesService.autocomplete(
            query,
            location: searchLocation,
          );
        } catch (error) {
          debugPrint('Google Places autocomplete failed: $error');
        }
        if (googleSuggestions.isNotEmpty) {
          if (!mounted || activeRequestId != _searchRequestId) return;
          setState(() {
            _searchSuggestions = googleSuggestions;
            _showSearchPanel = true;
          });
          return;
        }
      }

      final searchParams = <String, String>{
        'q': query,
        'format': 'jsonv2',
        'addressdetails': '1',
        'namedetails': '1',
        'extratags': '1',
        'dedupe': '1',
        'limit': '12',
        'countrycodes': 'tr',
      };
      if (_activeCategory != null && currentPosition != null) {
        const radius = 0.18;
        searchParams['viewbox'] = [
          currentPosition.longitude - radius,
          currentPosition.latitude + radius,
          currentPosition.longitude + radius,
          currentPosition.latitude - radius,
        ].join(',');
      }
      final uri = Uri.https(
        'nominatim.openstreetmap.org',
        '/search',
        searchParams,
      );
      final response = await http
          .get(
            uri,
            headers: const {
              'User-Agent': 'NavoraMap/1.0 (search)',
              'Accept-Language': 'tr',
            },
          )
          .timeout(const Duration(seconds: 8));

      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}');
      }

      final results = jsonDecode(response.body) as List<dynamic>;
      var suggestions = results.map((result) {
        final item = result as Map<String, dynamic>;
        final displayName = item['display_name']?.toString() ?? query;
        final namedPlace = navoraResolveSearchTitle(item, query);
        final coordinate = LatLng(
          double.parse(item['lat'].toString()),
          double.parse(item['lon'].toString()),
        );
        double? distanceMeters;
        if (currentPosition != null) {
          distanceMeters = geo.Geolocator.distanceBetween(
            currentPosition.latitude,
            currentPosition.longitude,
            coordinate.latitude,
            coordinate.longitude,
          );
        }
        final title = namedPlace;
        final subtitle = navoraResolveSearchSubtitle(item);
        final categoryName = _searchResultCategory(item);
        return <String, dynamic>{
          'name': title,
          'subtitle': subtitle,
          'type': item['type']?.toString() ?? 'place',
          'category': categoryName,
          'query': displayName,
          'coordinate': coordinate,
          'distanceMeters': distanceMeters,
          'distanceText': distanceMeters == null
              ? null
              : _formatSearchDistance(distanceMeters),
        };
      }).toList();

      if (currentPosition != null) {
        suggestions.sort((first, second) {
          final firstDistance =
              (first['distanceMeters'] as double?) ?? double.infinity;
          final secondDistance =
              (second['distanceMeters'] as double?) ?? double.infinity;
          return firstDistance.compareTo(secondDistance);
        });
      }

      if (!mounted || activeRequestId != _searchRequestId) return;
      if (suggestions.isEmpty && currentPosition != null) {
        final fallbackCategory = _matchNearbyCategory(query);
        if (fallbackCategory != null) {
          final config = _nearbyBusinessConfig()[fallbackCategory]!;
          await _loadNearbyCategoryResults(
            fallbackCategory,
            currentPosition,
            config,
            requestId: activeRequestId,
          );
          return;
        }
      }

      if (suggestions.isEmpty) {
        final locations = await geo_coding.locationFromAddress(query);
        if (!mounted || activeRequestId != _searchRequestId) return;
        if (locations.isNotEmpty && mounted) {
          final location = locations.first;
          final placemark = (await geo_coding.placemarkFromCoordinates(
            location.latitude,
            location.longitude,
          )).firstOrNull;
          suggestions = [
            <String, dynamic>{
              'name': placemark?.locality ?? query,
              'subtitle': placemark != null
                  ? [
                      placemark.street,
                      placemark.subLocality,
                      placemark.locality,
                    ].where((part) => (part ?? '').isNotEmpty).join(', ')
                  : query,
              'type': 'place',
              'category': 'Konum',
              'query': query,
              'coordinate': LatLng(location.latitude, location.longitude),
              'distanceMeters': currentPosition == null
                  ? null
                  : geo.Geolocator.distanceBetween(
                      currentPosition.latitude,
                      currentPosition.longitude,
                      location.latitude,
                      location.longitude,
                    ),
              'distanceText': currentPosition == null
                  ? null
                  : _formatSearchDistance(
                      geo.Geolocator.distanceBetween(
                        currentPosition.latitude,
                        currentPosition.longitude,
                        location.latitude,
                        location.longitude,
                      ),
                    ),
            },
          ];
        }
      }

      if (!mounted || activeRequestId != _searchRequestId) return;
      setState(() {
        _searchSuggestions = suggestions;
        _showSearchPanel = suggestions.isNotEmpty;
      });
      if (_activeCategory != null && suggestions.isNotEmpty) {
        await _showCategoryResultsOnMap(
          suggestions,
          requestId: activeRequestId,
        );
      }
    } catch (error) {
      debugPrint('Arama önerileri alınamadı: $error');
      if (!mounted || activeRequestId != _searchRequestId) return;
      final fallback = await _buildFallbackLocationSuggestion(query);
      if (!mounted || activeRequestId != _searchRequestId) return;
      if (fallback != null) {
        setState(() {
          _searchSuggestions = [fallback];
          _showSearchPanel = true;
        });
      } else {
        setState(() {
          _searchSuggestions = [];
          _showSearchPanel = false;
        });
      }
    }
  }

  Future<Map<String, dynamic>?> _buildFallbackLocationSuggestion(
    String query,
  ) async {
    try {
      final locations = await geo_coding.locationFromAddress(query);
      if (locations.isEmpty) return null;
      final location = locations.first;
      final placemarks = await geo_coding.placemarkFromCoordinates(
        location.latitude,
        location.longitude,
      );
      final placemark = placemarks.isNotEmpty ? placemarks.first : null;
      final currentPosition = _currentPosition;
      final distanceMeters = currentPosition == null
          ? null
          : geo.Geolocator.distanceBetween(
              currentPosition.latitude,
              currentPosition.longitude,
              location.latitude,
              location.longitude,
            );
      return <String, dynamic>{
        'name': placemark?.locality ?? query,
        'subtitle': placemark != null
            ? [
                placemark.street,
                placemark.subLocality,
                placemark.locality,
              ].where((part) => (part ?? '').isNotEmpty).join(', ')
            : query,
        'type': 'place',
        'category': 'Konum',
        'query': query,
        'coordinate': LatLng(location.latitude, location.longitude),
        'distanceMeters': distanceMeters,
        'distanceText': distanceMeters == null
            ? null
            : _formatSearchDistance(distanceMeters),
      };
    } catch (_) {
      return null;
    }
  }

  Future<void> _showCategoryResultsOnMap(
    List<Map<String, dynamic>> suggestions, {
    required int requestId,
  }) async {
    final markers = <Marker>[];
    final points = <LatLng>[];
    for (var index = 0; index < suggestions.length; index++) {
      final item = suggestions[index];
      final coordinate = item['coordinate'] as LatLng?;
      if (coordinate == null) continue;
      points.add(coordinate);
      markers.add(
        Marker(
          markerId: MarkerId('category-${index.toString()}'),
          position: coordinate,
          icon: BitmapDescriptor.defaultMarkerWithHue(
            BitmapDescriptor.hueOrange,
          ),
          onTap: () => _selectSearchSuggestion(item),
        ),
      );
    }
    if (!mounted || requestId != _searchRequestId || points.isEmpty) return;
    setState(() => _searchMarkers = markers);
    if (points.length == 1) {
      await _moveMapTo(points.first, 14);
      return;
    }
    await _fitMapToPoints(points);
  }

  String? _searchResultCategory(Map<String, dynamic> item) {
    final category = item['category']?.toString();
    final type = item['type']?.toString();
    final osmClass = item['class']?.toString();
    if (category == 'amenity' ||
        category == 'shop' ||
        category == 'tourism' ||
        osmClass == 'amenity' ||
        osmClass == 'shop' ||
        osmClass == 'tourism' ||
        type == 'cafe' ||
        type == 'restaurant' ||
        type == 'bakery' ||
        type == 'supermarket' ||
        type == 'hotel') {
      return null;
    }
    if (type == 'road' || type == 'street') return 'Cadde veya sokak';
    if (type == 'city' || type == 'town' || type == 'village') {
      return 'Şehir veya ilçe';
    }
    return 'Konum';
  }

  Future<void> _moveMapTo(LatLng coordinate, double zoom) async {
    final controller = _mapController;
    if (controller == null) return;
    await controller.animateCamera(
      CameraUpdate.newLatLngZoom(coordinate, zoom),
    );
  }

  Future<void> _fitMapToPoints(
    List<LatLng> points, {
    double padding = 70,
  }) async {
    final controller = _mapController;
    if (controller == null || points.isEmpty) return;

    final southwest = LatLng(
      points.map((point) => point.latitude).reduce(math.min),
      points.map((point) => point.longitude).reduce(math.min),
    );
    final northeast = LatLng(
      points.map((point) => point.latitude).reduce(math.max),
      points.map((point) => point.longitude).reduce(math.max),
    );

    try {
      await controller.animateCamera(
        CameraUpdate.newLatLngBounds(
          LatLngBounds(southwest: southwest, northeast: northeast),
          padding,
        ),
      );
    } catch (error) {
      debugPrint('Rota haritası kadraja alınamadı: $error');
      await controller.animateCamera(CameraUpdate.newLatLng(points.last));
    }
  }

  void _clearRouteState() {
    _routePolylines = const <Polyline>[];
    _alternativeRoutePolylines = const <Polyline>[];
    _navigationTrafficPolylines = const <Polyline>[];
    _navigationSteps = [];
    _navigationStepIndex = 0;
    _navigationDistanceKm = null;
    _navigationDurationMinutes = null;
    _navigationDurationSeconds = null;
    _isNavigationActive = false;
    unawaited(_updateScreenWakeLock());
    _isMapTilted = false;
    _isFollowingCurrentPosition = true;
    _hasMapBearing = false;
    _mapBearing = 0;
    _isOffRoute = false;
    _isCompletingNavigation = false;
    _navigationStartDistanceToDestinationMeters = null;
    _navigationStartPosition = null;
    _isNetworkDegraded = false;
    _isCheckingNavigationNetwork = false;
    _navigationConnectivityTimer?.cancel();
    _navigationConnectivityTimer = null;
    _navigationCameraUpdateTimer?.cancel();
    _navigationCameraUpdateTimer = null;
    _pendingNavigationCameraPosition = null;
    _lastFasterRouteCheckAt = null;
    _fasterAlternativeRoute = null;
    _fasterRouteMinutesSaved = null;
    _hasAnnouncedArrival = false;
    _offRouteReadings = 0;
  }

  void _cancelSearch() {
    _searchRequestId++;
    _searchDebounce?.cancel();
    _searchController.clear();
    FocusManager.instance.primaryFocus?.unfocus();
    if (!mounted) return;
    setState(() {
      _searchSuggestions = [];
      _showSearchPanel = false;
      _isSearching = false;
      _isSearchMode = false;
      _activeCategory = null;
      _searchMarkers = const <Marker>[];
      _searchResultName = null;
      _selectedDestinationCoordinate = null;
      _selectedDestinationName = null;
      _clearRouteState();
    });
  }

  Map<String, Map<String, String>> _nearbyBusinessConfig() {
    return {
      'Kafeler': {'key': 'amenity', 'value': 'cafe', 'kind': 'Kafe'},
      'Benzinlik': {'key': 'amenity', 'value': 'fuel', 'kind': 'Benzinlik'},
      'Restoran': {'key': 'amenity', 'value': 'restaurant', 'kind': 'Restoran'},
      'Market': {'key': 'shop', 'value': 'supermarket', 'kind': 'Market'},
      'Park': {'key': 'leisure', 'value': 'park', 'kind': 'Park'},
      'Hastane': {'key': 'amenity', 'value': 'hospital', 'kind': 'Hastane'},
      'Otobüs': {
        'key': 'amenity',
        'value': 'bus_station',
        'kind': 'Otobüs Durağı',
      },
    };
  }

  Future<void> _searchCategory(String label, String query) async {
    _searchDebounce?.cancel();
    final requestId = ++_searchRequestId;
    FocusManager.instance.primaryFocus?.unfocus();
    var position = _currentPosition;
    if (position == null) {
      if (!await _ensureLocationPermission()) return;
      try {
        position = await geo.Geolocator.getCurrentPosition(
          locationSettings: const geo.LocationSettings(
            accuracy: geo.LocationAccuracy.medium,
          ),
        );
        if (!mounted || requestId != _searchRequestId) return;
        if (mounted) setState(() => _currentPosition = position);
      } catch (error) {
        if (!mounted || requestId != _searchRequestId) return;
        debugPrint('Yakın kategori konumu alınamadı: $error');
        _showTrackingMessage('Yakındaki yerleri göstermek için konum gerekli.');
        return;
      }
    }
    if (!mounted || requestId != _searchRequestId) return;
    setState(() {
      _activeCategory = label;
      _isSearchMode = true;
      _searchController.text = query;
      _searchController.selection = TextSelection.fromPosition(
        TextPosition(offset: query.length),
      );
      _searchSuggestions = [];
      _showSearchPanel = true;
    });
    final nearbyCategories = _nearbyBusinessConfig();
    if (nearbyCategories.containsKey(label)) {
      await _loadNearbyCategoryResults(
        label,
        position,
        nearbyCategories[label]!,
        requestId: requestId,
      );
    } else {
      await _loadSearchSuggestions(query, requestId: requestId);
    }
  }

  Future<void> _loadNearbyCategoryResults(
    String label,
    geo.Position? position,
    Map<String, String> config, {
    required int requestId,
  }) async {
    if (position == null) return;
    final key = config['key'] ?? 'amenity';
    final value = config['value'] ?? 'cafe';
    final query =
        '''
[out:json][timeout:15];
(
  nwr["$key"="$value"](around:15000,${position.latitude},${position.longitude});
);
out center tags;
''';
    try {
      final response = await http
          .post(
            Uri.parse('https://overpass-api.de/api/interpreter'),
            headers: const {
              'User-Agent': 'NavoraMap/1.0 (nearby search)',
              'Content-Type': 'application/x-www-form-urlencoded',
            },
            body: {'data': query},
          )
          .timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) {
        throw Exception('Overpass HTTP ${response.statusCode}');
      }
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final elements = data['elements'] as List<dynamic>? ?? [];
      final origin = LatLng(position.latitude, position.longitude);
      final suggestions = elements
          .map((element) {
            final item = element as Map<String, dynamic>;
            final tags = item['tags'] as Map<String, dynamic>? ?? {};
            final latitude =
                (item['lat'] ?? (item['center'] as Map?)?['lat']) as num?;
            final longitude =
                (item['lon'] ?? (item['center'] as Map?)?['lon']) as num?;
            if (latitude == null || longitude == null) return null;
            final coordinate = LatLng(
              latitude.toDouble(),
              longitude.toDouble(),
            );
            final distance = geo.Geolocator.distanceBetween(
              origin.latitude,
              origin.longitude,
              coordinate.latitude,
              coordinate.longitude,
            );
            final name = tags['name']?.toString().trim();
            if (name == null || name.isEmpty) return null;
            final address =
                [
                      tags['addr:street'],
                      tags['addr:housenumber'],
                      tags['addr:suburb'],
                    ]
                    .whereType<Object>()
                    .map((part) => part.toString().trim())
                    .where((part) => part.isNotEmpty)
                    .join(' ');
            final kind = config['kind'] ?? label;
            return <String, dynamic>{
              'name': name,
              'subtitle': address.isEmpty ? 'Yakınınızda' : address,
              'category': kind,
              'type': value,
              'query': address.isEmpty ? name : '$name, $address',
              'coordinate': coordinate,
              'distanceMeters': distance,
              'distanceText': _formatSearchDistance(distance),
            };
          })
          .whereType<Map<String, dynamic>>()
          .toList();
      suggestions.sort(
        (first, second) => (first['distanceMeters'] as double).compareTo(
          second['distanceMeters'] as double,
        ),
      );
      final nearbySuggestions = suggestions.take(15).toList();
      if (!mounted || requestId != _searchRequestId) return;
      setState(() {
        _searchSuggestions = nearbySuggestions;
        _showSearchPanel = nearbySuggestions.isNotEmpty;
      });
      await _showCategoryResultsOnMap(nearbySuggestions, requestId: requestId);
    } catch (error) {
      if (!mounted || requestId != _searchRequestId) return;
      debugPrint('Yakındaki $label sonuçları alınamadı: $error');
      _showTrackingMessage('Yakındaki $label sonuçları şu anda alınamıyor.');
    }
  }

  String _formatNearbyDistance(double meters) {
    return navoraFormatDistance(meters);
  }

  String _formatSearchDistance(double meters) => navoraFormatDistance(meters);

  Future<Map<String, String>> _resolveAddressCoordinates(
    Map<String, String> address,
  ) async {
    final latitude = address['latitude'];
    final longitude = address['longitude'];
    if (latitude != null && longitude != null) {
      return address;
    }
    final query = address['address']?.trim();
    if (query == null || query.isEmpty) return address;

    try {
      final matches = await geo_coding.locationFromAddress(query);
      if (matches.isEmpty) return address;
      final location = matches.first;
      address['latitude'] = location.latitude.toString();
      address['longitude'] = location.longitude.toString();
    } catch (error) {
      debugPrint('Adres koordinatı çözümlenemedi: $error');
    }
    return address;
  }

  void _upsertSavedAddress(Map<String, String> address) {
    final addressId = address['id'];
    if (addressId == null || addressId.isEmpty || !mounted) return;
    setState(() {
      _savedAddresses
        ..removeWhere((savedAddress) => savedAddress['id'] == addressId)
        ..insert(0, address);
    });
  }

  Future<void> _saveSelectedPlace() async {
    final title = _selectedDestinationName?.trim();
    if (title == null || title.isEmpty) return;
    final address = await _showAddAddressDialog(
      initialTitle: title,
      initialAddress: _searchController.text.trim(),
      initialCoordinate: _selectedDestinationCoordinate,
    );
    if (address == null || !mounted) return;
    final resolvedAddress = await _resolveAddressCoordinates(address);

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      _showTrackingMessage('Adres kaydetmek için hesabına giriş yap.');
      return;
    }
    try {
      final document = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .collection('saved_addresses')
          .add(resolvedAddress);
      resolvedAddress['id'] = document.id;
      _upsertSavedAddress(resolvedAddress);
      _showTrackingMessage('${resolvedAddress['title']} adreslere kaydedildi.');
    } catch (error) {
      debugPrint('Adres kaydedilemedi: $error');
      _showTrackingMessage('Adres kaydedilemedi. Lütfen tekrar deneyin.');
    }
  }

  Widget _buildSearchResultsPanel() {
    if (!_showSearchPanel ||
        (_searchSuggestions.isEmpty && _searchHistory.isEmpty)) {
      return const SizedBox.shrink();
    }

    final items = _searchSuggestions.isNotEmpty
        ? _searchSuggestions
        : _searchHistory;

    return Container(
      margin: const EdgeInsets.only(top: 8),
      constraints: const BoxConstraints(maxHeight: 460),
      decoration: BoxDecoration(
        color: const Color(0xFF151515),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: const Color(0xFF333333)),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(22),
        child: Material(
          color: Colors.transparent,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  physics: const ClampingScrollPhysics(),
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  itemCount: items.length,
                  separatorBuilder: (_, _) =>
                      const Divider(height: 1, color: Color(0xFF2B2B2B)),
                  itemBuilder: (context, index) {
                    final item = items[index];
                    final isSuggestion = _searchSuggestions.isNotEmpty;
                    final subtitle = isSuggestion
                        ? (item['subtitle'] as String? ?? 'Konum önerisi')
                        : (item['query'] as String? ?? 'Arama geçmişi');
                    final distanceText = item['distanceText'] as String?;

                    return Container(
                      margin: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1D1D1D),
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(
                          color: Colors.black.withValues(alpha: 0.04),
                          width: 1,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.05),
                            blurRadius: 8,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(18),
                        onTap: () async {
                          if (isSuggestion) {
                            await _selectSearchSuggestion(item);
                          } else {
                            _searchController.text = item['query'] as String;
                            await _searchPlace(showPanel: true);
                          }
                        },
                        child: Column(
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                SizedBox(
                                  width: 52,
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Container(
                                        width: 38,
                                        height: 38,
                                        decoration: BoxDecoration(
                                          color: const Color(0xFF2A180D),
                                          borderRadius: BorderRadius.circular(
                                            12,
                                          ),
                                        ),
                                        child: Icon(
                                          isSuggestion
                                              ? _searchResultIcon(
                                                  item['type'] as String?,
                                                )
                                              : Icons.history_rounded,
                                          color: const Color(0xFFFF6B00),
                                          size: 18,
                                        ),
                                      ),
                                      if (isSuggestion) ...[
                                        const SizedBox(height: 4),
                                        Text(
                                          distanceText?.isNotEmpty == true
                                              ? distanceText!
                                              : 'Konum gerekli',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          textAlign: TextAlign.center,
                                          style: const TextStyle(
                                            color: Color(0xFFFFB36B),
                                            fontSize: 9,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        item['name'] as String,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w700,
                                          fontSize: 14,
                                          color: Colors.white,
                                          letterSpacing: -0.1,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        subtitle,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: Colors.white70,
                                          fontSize: 11.5,
                                          height: 1.3,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                            if (isSuggestion) ...[
                              const SizedBox(height: 10),
                              Row(
                                children: [
                                  Expanded(
                                    child: TextButton.icon(
                                      onPressed: () async {
                                        await _selectSearchSuggestion(item);
                                        if (mounted) {
                                          _showDirectionsSheet();
                                        }
                                      },
                                      icon: const Icon(
                                        Icons.directions_rounded,
                                        size: 15,
                                      ),
                                      label: const Text(
                                        'Yol tarifi',
                                        style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                      style: TextButton.styleFrom(
                                        foregroundColor: const Color(
                                          0xFFFF6B00,
                                        ),
                                        backgroundColor: const Color(
                                          0xFF2A180D,
                                        ),
                                        side: const BorderSide(
                                          color: Color(0xFFFF6B00),
                                        ),
                                        padding: const EdgeInsets.symmetric(
                                          vertical: 8,
                                          horizontal: 10,
                                        ),
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(
                                            12,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: TextButton.icon(
                                      onPressed: () async {
                                        await _selectSearchSuggestion(item);
                                        await _saveSelectedPlace();
                                      },
                                      icon: const Icon(
                                        Icons.bookmark_add_rounded,
                                        size: 15,
                                      ),
                                      label: const Text(
                                        'Kaydet',
                                        style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                      style: TextButton.styleFrom(
                                        foregroundColor: const Color(
                                          0xFFFF6B00,
                                        ),
                                        backgroundColor: const Color(
                                          0xFF2A180D,
                                        ),
                                        side: const BorderSide(
                                          color: Color(0xFFFF6B00),
                                        ),
                                        padding: const EdgeInsets.symmetric(
                                          vertical: 8,
                                          horizontal: 10,
                                        ),
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(
                                            12,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
              if (_searchSuggestions.isEmpty && _searchHistory.isNotEmpty) ...[
                const Divider(height: 1, color: Color(0xFF2B2B2B)),
                SizedBox(
                  height: 46,
                  child: TextButton.icon(
                    onPressed: _confirmAndClearSearchHistory,
                    icon: const Icon(
                      Icons.delete_outline_rounded,
                      size: 18,
                      color: Colors.white70,
                    ),
                    label: const Text(
                      'Geçmişi temizle',
                      style: TextStyle(
                        color: Colors.white70,
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ),
              ],
              if (_selectedDestinationCoordinate != null) ...[
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.route_rounded,
                        color: Color(0xFFFF6B00),
                        size: 22,
                      ),
                      const SizedBox(width: 10),
                      const Expanded(
                        child: Text(
                          'Bu konuma gitmeye hazır mısın?',
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 13,
                          ),
                        ),
                      ),
                      ElevatedButton.icon(
                        onPressed: _showDirectionsSheet,
                        icon: const Icon(Icons.navigation_rounded, size: 16),
                        label: const Text('Yola çık'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFFF7A00),
                          foregroundColor: Colors.white,
                          elevation: 0,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  IconData _searchResultIcon(String? type) {
    switch (type) {
      case 'amenity':
      case 'cafe':
        return Icons.local_cafe_rounded;
      case 'restaurant':
        return Icons.restaurant_rounded;
      case 'fuel':
        return Icons.local_gas_station_rounded;
      case 'supermarket':
      case 'shop':
        return Icons.local_grocery_store_rounded;
      case 'park':
        return Icons.park_rounded;
      case 'hospital':
        return Icons.local_hospital_rounded;
      case 'bus_station':
        return Icons.directions_bus_rounded;
      case 'road':
        return Icons.turn_right_rounded;
      case 'building':
        return Icons.business_rounded;
      case 'station':
        return Icons.train_rounded;
      default:
        return Icons.location_on_rounded;
    }
  }

  Future<void> _showDirectionsSheet() async {
    if (!mounted || _isOpeningDirections) return;
    _isOpeningDirections = true;
    await Future<void>.delayed(const Duration(milliseconds: 220));
    if (!mounted) {
      _isOpeningDirections = false;
      return;
    }

    if (!await _ensureLocationPermission()) {
      _isOpeningDirections = false;
      return;
    }

    late final geo.Position currentPosition;
    try {
      currentPosition = await geo.Geolocator.getCurrentPosition(
        locationSettings: const geo.LocationSettings(
          accuracy: geo.LocationAccuracy.medium,
        ),
      ).timeout(const Duration(seconds: 20));
    } catch (error) {
      debugPrint('Rota başlangıcı için güncel konum alınamadı: $error');
      if (mounted) {
        _showTrackingMessage(
          'Rota için güncel konum alınamadı. Konum servislerini kontrol edin.',
        );
      }
      _isOpeningDirections = false;
      return;
    }
    if (!mounted) {
      _isOpeningDirections = false;
      return;
    }
    setState(() => _currentPosition = currentPosition);

    final destination = _selectedDestinationCoordinate;
    if (destination == null) {
      _isOpeningDirections = false;
      return;
    }
    final start = LatLng(currentPosition.latitude, currentPosition.longitude);
    final routeVehicle = _selectedVehicle == 'Bisiklet'
        ? 'Araba'
        : _selectedVehicle;
    final shouldPersistSelectedVehicle = routeVehicle != _selectedVehicle;
    if (mounted) {
      setState(() {
        _clearRouteState();
      });
    }

    Map<String, dynamic> route;
    try {
      route = await _fetchRoadRoute(
        start,
        destination,
        vehicle: routeVehicle,
        includeAlternativeRoutes: true,
      );
    } catch (error) {
      debugPrint('Yol rotası alınamadı: $error');
      _showTrackingMessage(
        'Google Routes kullanılamadı. API anahtarını, Routes API erişimini ve faturalandırmayı kontrol edin.',
      );
      _isOpeningDirections = false;
      return;
    }
    if (!mounted) {
      _isOpeningDirections = false;
      return;
    }

    var routeOptions =
        route['options'] as List<Map<String, dynamic>>? ?? [route];
    var selectedRouteIndex = 0;
    var selectedRoute = routeOptions[selectedRouteIndex];
    var routeDistanceKm = selectedRoute['distanceKm'] as double;
    var durationMinutes = selectedRoute['durationMinutes'] as int;
    var selectedTravelMode = routeVehicle;
    var isRecalculatingRoute = false;

    setState(() {
      _selectedVehicle = routeVehicle;
    });
    _applyRouteOptions(routeOptions, selectedRouteIndex, routeVehicle, start);
    if (shouldPersistSelectedVehicle) {
      unawaited(_persistSelectedVehicle());
    }
    await _fitMapToPoints(selectedRoute['points'] as List<LatLng>);
    if (!mounted) {
      _isOpeningDirections = false;
      return;
    }

    _isOpeningDirections = false;

    var didStartNavigation = false;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF121212),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
      ),
      builder: (modalContext) => StatefulBuilder(
        builder: (context, setSheetState) {
          void selectRouteOption(int index) {
            if (index == selectedRouteIndex ||
                index < 0 ||
                index >= routeOptions.length) {
              return;
            }
            selectedRoute = routeOptions[index];
            setSheetState(() {
              selectedRouteIndex = index;
              routeDistanceKm = selectedRoute['distanceKm'] as double;
              durationMinutes = selectedRoute['durationMinutes'] as int;
            });
            _applyRouteOptions(
              routeOptions,
              selectedRouteIndex,
              selectedTravelMode,
              start,
            );
            unawaited(_fitMapToPoints(selectedRoute['points'] as List<LatLng>));
          }

          Future<void> updateRouteOptions(String vehicle) async {
            final nextVehicle = vehicle;
            if (isRecalculatingRoute) return;
            setSheetState(() => isRecalculatingRoute = true);
            try {
              final updatedRoute = await _fetchRoadRoute(
                start,
                destination,
                vehicle: nextVehicle,
                includeAlternativeRoutes: true,
              );
              if (!mounted || !modalContext.mounted) return;

              routeOptions =
                  updatedRoute['options'] as List<Map<String, dynamic>>? ??
                  [updatedRoute];
              selectedRouteIndex = 0;
              selectedTravelMode = nextVehicle;
              selectedRoute = routeOptions.first;
              routeDistanceKm = selectedRoute['distanceKm'] as double;
              durationMinutes = selectedRoute['durationMinutes'] as int;
              setSheetState(() {});
              setState(() {
                _selectedVehicle = nextVehicle;
                _isOffRoute = false;
                _offRouteReadings = 0;
              });
              _applyRouteOptions(
                routeOptions,
                selectedRouteIndex,
                nextVehicle,
                start,
              );
              unawaited(_persistSelectedVehicle());
              await _fitMapToPoints(selectedRoute['points'] as List<LatLng>);
            } catch (error) {
              debugPrint('Rota tercihleri için rota alınamadı: $error');
              if (mounted) {
                _showTrackingMessage(
                  'Rota tercihi güncellenemedi. Lütfen tekrar deneyin.',
                );
              }
            } finally {
              if (modalContext.mounted) {
                setSheetState(() => isRecalculatingRoute = false);
              }
            }
          }

          Future<void> selectTravelMode(String vehicle) async {
            if (vehicle == selectedTravelMode) return;
            await updateRouteOptions(vehicle);
          }

          return SafeArea(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * 0.9,
              ),
              child: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(18, 12, 18, 22),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 46,
                            height: 46,
                            decoration: BoxDecoration(
                              color: const Color(0xFFFF6B00),
                              borderRadius: BorderRadius.circular(15),
                            ),
                            child: const Icon(
                              Icons.navigation_rounded,
                              color: Colors.white,
                            ),
                          ),
                          const SizedBox(width: 12),
                          const Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Hazır mısınız?',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Color(0xFFBDBDBD),
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                SizedBox(height: 3),
                                Text(
                                  'Yolculuk özeti',
                                  style: TextStyle(
                                    fontSize: 20,
                                    color: Colors.white,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            tooltip: 'Kapat',
                            onPressed: () => Navigator.pop(context),
                            icon: const Icon(
                              Icons.close_rounded,
                              color: Colors.white70,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Ulaşım türü',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          for (final mode in const [
                            (
                              value: 'Araba',
                              label: 'Araba',
                              icon: Icons.directions_car_rounded,
                            ),
                            (
                              value: 'Motosiklet',
                              label: 'Motosiklet',
                              icon: Icons.two_wheeler_rounded,
                            ),
                            (
                              value: 'Yürüyüş',
                              label: 'Yürüyüş',
                              icon: Icons.directions_walk_rounded,
                            ),
                          ])
                            Expanded(
                              child: Padding(
                                padding: const EdgeInsets.only(right: 8),
                                child: Semantics(
                                  button: true,
                                  selected: selectedTravelMode == mode.value,
                                  child: Material(
                                    color: selectedTravelMode == mode.value
                                        ? const Color(0xFF6A3212)
                                        : const Color(0xFF242424),
                                    borderRadius: BorderRadius.circular(12),
                                    child: InkWell(
                                      borderRadius: BorderRadius.circular(12),
                                      onTap: isRecalculatingRoute
                                          ? null
                                          : () => unawaited(
                                              selectTravelMode(mode.value),
                                            ),
                                      child: Container(
                                        height: 52,
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 8,
                                        ),
                                        decoration: BoxDecoration(
                                          borderRadius: BorderRadius.circular(
                                            12,
                                          ),
                                          border: Border.all(
                                            color:
                                                selectedTravelMode == mode.value
                                                ? const Color(0xFFFF7A00)
                                                : const Color(0xFF3A3A3A),
                                          ),
                                        ),
                                        child: Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.center,
                                          children: [
                                            Icon(
                                              mode.icon,
                                              size: 18,
                                              color:
                                                  selectedTravelMode ==
                                                      mode.value
                                                  ? const Color(0xFFFF9A3D)
                                                  : const Color(0xFFBDBDBD),
                                            ),
                                            const SizedBox(width: 6),
                                            FittedBox(
                                              fit: BoxFit.scaleDown,
                                              child: Text(
                                                mode.label,
                                                style: TextStyle(
                                                  color: Colors.white,
                                                  fontSize: 11,
                                                  fontWeight:
                                                      selectedTravelMode ==
                                                          mode.value
                                                      ? FontWeight.w700
                                                      : FontWeight.w500,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                      if (isRecalculatingRoute) ...[
                        const SizedBox(height: 8),
                        const LinearProgressIndicator(
                          minHeight: 2,
                          color: Color(0xFFFF7A00),
                          backgroundColor: Color(0xFF303030),
                        ),
                      ],
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: _buildCompactRouteMetric(
                              Icons.schedule_rounded,
                              navoraFormatNavigationDuration(
                                durationMinutes,
                                isWalking: selectedTravelMode == 'Yürüyüş',
                              ),
                              'Tahmini süre',
                            ),
                          ),
                          Expanded(
                            child: _buildCompactRouteMetric(
                              Icons.straighten_rounded,
                              '${routeDistanceKm.toStringAsFixed(1)} km',
                              'Mesafe',
                            ),
                          ),
                        ],
                      ),
                      if (routeOptions.length > 1) ...[
                        const SizedBox(height: 12),
                        const Text(
                          'Alternatif rotalar',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                          ),
                        ),
                        const SizedBox(height: 6),
                        SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: [
                              for (
                                var index = 0;
                                index < routeOptions.length;
                                index++
                              ) ...[
                                if (index > 0) const SizedBox(width: 8),
                                ChoiceChip(
                                  selected: selectedRouteIndex == index,
                                  selectedColor: const Color(0xFF6A3212),
                                  backgroundColor: const Color(0xFF242424),
                                  side: BorderSide(
                                    color: selectedRouteIndex == index
                                        ? const Color(0xFFFF7A00)
                                        : const Color(0xFF3A3A3A),
                                  ),
                                  label: Text(
                                    index == 0
                                        ? 'Önerilen'
                                        : 'Rota ${index + 1}',
                                  ),
                                  labelStyle: TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                    fontWeight: selectedRouteIndex == index
                                        ? FontWeight.w700
                                        : FontWeight.w500,
                                  ),
                                  onSelected: isRecalculatingRoute
                                      ? null
                                      : (_) => selectRouteOption(index),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                      const SizedBox(height: 16),
                      SizedBox(
                        width: double.infinity,
                        height: 54,
                        child: ElevatedButton.icon(
                          onPressed: isRecalculatingRoute
                              ? null
                              : () async {
                                  if (!mounted || !modalContext.mounted) return;
                                  didStartNavigation = true;
                                  Navigator.pop(modalContext);
                                  setState(() {
                                    _isNavigationActive = true;
                                    _navigationStartPosition =
                                        _currentPosition != null
                                        ? LatLng(
                                            _currentPosition!.latitude,
                                            _currentPosition!.longitude,
                                          )
                                        : _routePolylines.isNotEmpty
                                        ? _routePolylines.first.points.first
                                        : null;
                                    _isMapTilted = true;
                                    _isFollowingCurrentPosition = true;
                                    _hasMapBearing = false;
                                    _isOffRoute = false;
                                    _offRouteReadings = 0;
                                    _hasAnnouncedArrival = false;
                                    _lastNavigationRefreshAt = null;
                                    _hasShownRouteUpdateError = false;
                                    _selectedIndex = 1;
                                    _activeNavigationTitle =
                                        _selectedDestinationName;
                                    _activeNavigationDestination =
                                        _searchController.text.trim().isEmpty
                                        ? _selectedDestinationName
                                        : _searchController.text.trim();
                                    _showSearchPanel = false;
                                    FocusManager.instance.primaryFocus
                                        ?.unfocus();
                                  });
                                  await _updateScreenWakeLock();
                                  await _toggleDriveTracking();
                                },
                          icon: const Icon(Icons.navigation_rounded),
                          label: const Text('Yola çık'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFFFF6B00),
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(17),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
    if (!didStartNavigation && mounted) {
      setState(() {
        _clearRouteState();
        _selectedDestinationCoordinate = null;
        _selectedDestinationName = null;
        _selectedPlaceDetails = null;
        _searchResultName = null;
        _searchMarkers = [];
        _searchSuggestions = [];
        _searchController.clear();
        _showSearchPanel = false;
      });
    }
  }

  Future<void> _goToSavedAddress(Map<String, String> address) async {
    final title = address['title']?.trim();
    final query = address['address']?.trim();
    if (query == null || query.isEmpty) return;

    LatLng? destination;
    final latitude = double.tryParse(address['latitude'] ?? '');
    final longitude = double.tryParse(address['longitude'] ?? '');
    if (latitude != null && longitude != null) {
      destination = LatLng(latitude, longitude);
    } else {
      try {
        final locations = await geo_coding.locationFromAddress(query);
        if (locations.isNotEmpty) {
          destination = LatLng(
            locations.first.latitude,
            locations.first.longitude,
          );
        }
      } catch (error) {
        debugPrint('Kayıtlı adres bulunamadı: $error');
      }
    }

    if (destination == null || !mounted) {
      _showTrackingMessage('Bu adres için konum bulunamadı.');
      return;
    }

    setState(() {
      _searchController.text = query;
      _selectedDestinationName = title?.isNotEmpty == true ? title : query;
      _selectedDestinationCoordinate = destination;
      _searchMarkers = [
        Marker(
          markerId: const MarkerId('selected-saved-address'),
          position: destination!,
          icon: BitmapDescriptor.defaultMarkerWithHue(
            BitmapDescriptor.hueOrange,
          ),
        ),
      ];
    });
    await _moveMapTo(destination, 15);
    if (!mounted) return;
    await _showDirectionsSheet();
  }

  Future<Map<String, dynamic>> _fetchRoadRoute(
    LatLng start,
    LatLng destination, {
    String vehicle = 'Araba',
    bool includeAlternativeRoutes = false,
  }) async {
    if (NavoraTrafficService.googleRoutesApiKey.isEmpty) {
      throw StateError('Google Routes API anahtarı tanımlanmamış.');
    }
    return _fetchGoogleRoadRoute(
      start,
      destination,
      vehicle: vehicle,
      includeAlternativeRoutes: includeAlternativeRoutes,
    );
  }

  Future<Map<String, dynamic>> _fetchGoogleRoadRoute(
    LatLng start,
    LatLng destination, {
    required String vehicle,
    required bool includeAlternativeRoutes,
  }) async {
    final travelMode = switch (vehicle) {
      'Yürüyüş' => 'WALK',
      'Bisiklet' => 'BICYCLE',
      _ => 'DRIVE',
    };
    final includeTraffic = travelMode == 'DRIVE';
    final fieldMask = <String>[
      'routes.distanceMeters',
      'routes.duration',
      'routes.polyline.geoJsonLinestring',
      'routes.legs.steps.distanceMeters',
      'routes.legs.steps.navigationInstruction',
      'routes.legs.steps.startLocation',
      if (includeTraffic) 'routes.travelAdvisory.speedReadingIntervals',
    ].join(',');
    final identityHeaders = await NavoraPlacesService.clientIdentityHeaders;
    final response = await http
        .post(
          Uri.parse(
            'https://routes.googleapis.com/directions/v2:computeRoutes',
          ),
          headers: {
            ...identityHeaders,
            'Content-Type': 'application/json',
            'X-Goog-Api-Key': NavoraTrafficService.googleRoutesApiKey,
            'X-Goog-FieldMask': fieldMask,
          },
          body: jsonEncode({
            'origin': {
              'location': {
                'latLng': {
                  'latitude': start.latitude,
                  'longitude': start.longitude,
                },
              },
            },
            'destination': {
              'location': {
                'latLng': {
                  'latitude': destination.latitude,
                  'longitude': destination.longitude,
                },
              },
            },
            'travelMode': travelMode,
            if (includeTraffic && includeAlternativeRoutes)
              'computeAlternativeRoutes': true,
            'polylineEncoding': 'GEO_JSON_LINESTRING',
            'polylineQuality': 'HIGH_QUALITY',
            if (includeTraffic) ...{
              'routingPreference': 'TRAFFIC_AWARE_OPTIMAL',
              'extraComputations': ['TRAFFIC_ON_POLYLINE'],
            },
          }),
        )
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      throw Exception('Google Routes API HTTP ${response.statusCode}');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final routes = data['routes'] as List<dynamic>?;
    if (routes == null || routes.isEmpty) {
      throw Exception('Google Routes rota döndürmedi');
    }
    final parsedRoutes = routes
        .whereType<Map<String, dynamic>>()
        .map((route) => _parseGoogleRoadRoute(route, travelMode))
        .toList();
    if (parsedRoutes.isEmpty) {
      throw Exception('Google Routes returned no valid route');
    }
    return {...parsedRoutes.first, 'options': parsedRoutes};
  }

  Map<String, dynamic> _parseGoogleRoadRoute(
    Map<String, dynamic> route,
    String travelMode,
  ) {
    final polyline = route['polyline'] as Map<String, dynamic>? ?? const {};
    final geoJson =
        polyline['geoJsonLinestring'] as Map<String, dynamic>? ?? const {};
    final coordinates = geoJson['coordinates'] as List<dynamic>? ?? const [];
    final points = coordinates
        .whereType<List<dynamic>>()
        .where((coordinate) => coordinate.length >= 2)
        .map(
          (coordinate) => LatLng(
            (coordinate[1] as num).toDouble(),
            (coordinate[0] as num).toDouble(),
          ),
        )
        .toList();
    if (points.length < 2) throw Exception('Google Routes geometrisi boş');

    final advisory =
        route['travelAdvisory'] as Map<String, dynamic>? ?? const {};
    final trafficIntervals =
        advisory['speedReadingIntervals'] as List<dynamic>? ?? const [];
    final legs = route['legs'] as List<dynamic>? ?? const [];
    final steps = legs
        .whereType<Map<String, dynamic>>()
        .expand((leg) => leg['steps'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(_formatGoogleNavigationStep)
        .toList();
    final durationSeconds = double.tryParse(
      route['duration']?.toString().replaceFirst('s', '') ?? '',
    );
    final distanceKm =
        ((route['distanceMeters'] as num?)?.toDouble() ?? 0) / 1000;
    final routeDurationMinutes = (((durationSeconds ?? 0) / 60).ceil()).clamp(
      1,
      999999,
    );
    return <String, dynamic>{
      'points': points,
      'distanceKm': distanceKm,
      'durationMinutes': travelMode == 'WALK'
          ? navoraWalkingDurationMinutes(
              distanceKm: distanceKm,
              routeDurationMinutes: routeDurationMinutes,
            )
          : routeDurationMinutes.clamp(1, 999),
      'steps': steps,
      'trafficPolylines': NavoraTrafficService.buildRouteTrafficPolylines(
        points,
        trafficIntervals,
      ),
      'trafficStatus': NavoraTrafficService.statusForIntervals(
        trafficIntervals,
      ),
    };
  }

  void _applyRouteOptions(
    List<Map<String, dynamic>> routeOptions,
    int selectedIndex,
    String vehicle,
    LatLng origin,
  ) {
    if (routeOptions.isEmpty ||
        selectedIndex < 0 ||
        selectedIndex >= routeOptions.length) {
      return;
    }
    final selectedRoute = routeOptions[selectedIndex];
    final selectedPoints = navoraTrimRouteToRemainingPath(
      selectedRoute['points'] as List<LatLng>,
      origin,
      vehicle: vehicle,
    );
    final alternativePolylines = <Polyline>[];
    for (var index = 0; index < routeOptions.length; index++) {
      if (index == selectedIndex) continue;
      final option = routeOptions[index];
      final points = navoraTrimRouteToRemainingPath(
        option['points'] as List<LatLng>,
        origin,
        vehicle: vehicle,
      );
      if (points.length < 2) continue;
      alternativePolylines.add(
        Polyline(
          polylineId: PolylineId('route-alternative-$index'),
          points: points,
          color: const Color(0xFFB9C4CC),
          width: 5,
          zIndex: 1,
        ),
      );
    }
    setState(() {
      _routePolylines = [
        Polyline(
          polylineId: const PolylineId('route-navigation'),
          points: selectedPoints,
          color: const Color(0xFF4285F4),
          width: 7,
          zIndex: 2,
        ),
      ];
      _alternativeRoutePolylines = alternativePolylines;
      _navigationTrafficPolylines =
          selectedRoute['trafficPolylines'] as List<Polyline>? ?? const [];
      _navigationSteps = List<Map<String, dynamic>>.from(
        selectedRoute['steps'] as List<Map<String, dynamic>>,
      );
      _navigationStepIndex = 0;
      _navigationDistanceKm = selectedRoute['distanceKm'] as double;
      _navigationDurationMinutes = selectedRoute['durationMinutes'] as int;
      _navigationDurationSeconds = _navigationDurationMinutes! * 60.0;
    });
  }

  Map<String, dynamic> _formatGoogleNavigationStep(Map<String, dynamic> step) {
    final instruction =
        step['navigationInstruction'] as Map<String, dynamic>? ?? const {};
    final text = instruction['instructions']?.toString() ?? 'Yola devam et';
    final maneuver = instruction['maneuver']?.toString() ?? '';
    final startLocation =
        step['startLocation'] as Map<String, dynamic>? ?? const {};
    final latLng = startLocation['latLng'] as Map<String, dynamic>? ?? const {};
    final distance = (step['distanceMeters'] as num?)?.toDouble() ?? 0;
    final distanceText = distance >= 1000
        ? '${(distance / 1000).toStringAsFixed(1)} km'
        : '${distance.round()} m';
    final icon = switch (maneuver) {
      'ARRIVE' => Icons.flag_rounded,
      'TURN_LEFT' ||
      'TURN_SLIGHT_LEFT' ||
      'TURN_SHARP_LEFT' => Icons.turn_left_rounded,
      'TURN_RIGHT' ||
      'TURN_SLIGHT_RIGHT' ||
      'TURN_SHARP_RIGHT' => Icons.turn_right_rounded,
      'ROUNDABOUT_LEFT' || 'ROUNDABOUT_RIGHT' => Icons.roundabout_right_rounded,
      _ => Icons.straight_rounded,
    };
    return {
      'text': text,
      'distance': distanceText,
      'icon': icon,
      'voice': text,
      'latitude': (latLng['latitude'] as num?)?.toDouble(),
      'longitude': (latLng['longitude'] as num?)?.toDouble(),
    };
  }

  Widget _buildLiveNavigationCard() {
    final currentStepIndex = _navigationSteps.isEmpty
        ? 0
        : _navigationStepIndex.clamp(0, _navigationSteps.length - 1);
    final nextStep = _navigationSteps.isEmpty
        ? null
        : _navigationSteps[currentStepIndex];
    final upcomingStep = currentStepIndex + 1 < _navigationSteps.length
        ? _navigationSteps[currentStepIndex + 1]
        : null;
    final nextStepDistanceMeters = nextStep == null
        ? null
        : _distanceToNavigationStepMeters(nextStep);
    final nextStepDistance = nextStep == null
        ? null
        : _distanceToNavigationStep(nextStep);
    final isManeuverApproaching =
        nextStepDistanceMeters != null && nextStepDistanceMeters <= 300;
    final isManeuverVeryClose =
        nextStepDistanceMeters != null && nextStepDistanceMeters <= 100;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 10, 10),
      decoration: BoxDecoration(
        color: const Color(0xFF151515),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFFF7A00), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 220),
                      width: isManeuverApproaching ? 66 : 58,
                      height: isManeuverApproaching ? 66 : 58,
                      decoration: BoxDecoration(
                        color: isManeuverVeryClose
                            ? const Color(0xFF7A2B0A)
                            : const Color(0xFF2A180D),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Icon(
                        nextStep?['icon'] as IconData? ??
                            Icons.navigation_rounded,
                        color: isManeuverApproaching
                            ? const Color(0xFFFF9A3D)
                            : const Color(0xFFFF6B00),
                        size: isManeuverApproaching ? 44 : 40,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (nextStepDistance != null)
                            Text(
                              nextStepDistance,
                              style:
                                  const TextStyle(
                                    color: Color(0xFFFF9A3D),
                                    fontWeight: FontWeight.w800,
                                    fontSize: 17,
                                  ).copyWith(
                                    fontSize: isManeuverVeryClose ? 22 : 17,
                                  ),
                            ),
                          Text(
                            nextStep?['text'] as String? ?? 'Rotayı takip et',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                              fontSize: isManeuverApproaching ? 17 : 16,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Navigasyonu kapat',
                onPressed: () {
                  setState(_clearRouteState);
                  unawaited(_resetNavigationCamera());
                },
                icon: const Icon(Icons.close_rounded, size: 20),
              ),
            ],
          ),
          if (upcomingStep != null) ...[
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: BoxDecoration(
                color: const Color(0xFF222321),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  Icon(
                    upcomingStep['icon'] as IconData? ??
                        Icons.navigation_rounded,
                    color: const Color(0xFFBDBDBD),
                    size: 17,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Sonraki: ${upcomingStep['text'] as String? ?? 'Rotayı takip et'}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xFFD0D0D0),
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _distanceToNavigationStep(upcomingStep) ?? '',
                    style: const TextStyle(
                      color: Color(0xFFBDBDBD),
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (_fasterAlternativeRoute != null &&
              _fasterRouteMinutesSaved != null) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFF173321),
                borderRadius: BorderRadius.circular(11),
                border: Border.all(color: const Color(0xFF2E7043)),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.alt_route_rounded,
                    color: Color(0xFF80D99A),
                    size: 19,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '$_fasterRouteMinutesSaved dk daha hızlı rota bulundu',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: _switchToFasterAlternativeRoute,
                    style: TextButton.styleFrom(
                      foregroundColor: const Color(0xFF9BE7AE),
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: const Text('Kullan'),
                  ),
                  IconButton(
                    tooltip: 'Öneriyi kapat',
                    visualDensity: VisualDensity.compact,
                    onPressed: () {
                      setState(() {
                        _fasterAlternativeRoute = null;
                        _fasterRouteMinutesSaved = null;
                      });
                    },
                    icon: const Icon(
                      Icons.close_rounded,
                      color: Color(0xFFBDBDBD),
                      size: 17,
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (_isOffRoute || _isNetworkDegraded) ...[
            const SizedBox(height: 6),
            if (_isOffRoute)
              _buildNavigationStatusMessage(
                Icons.alt_route_rounded,
                'Rotadan sapıldı, rota yeniden hesaplanıyor',
              ),
            if (_isNetworkDegraded)
              _buildNavigationStatusMessage(
                Icons.wifi_off_rounded,
                'İnternet yavaş veya kullanılamıyor. Mevcut rota korunuyor.',
              ),
          ],
        ],
      ),
    );
  }

  Widget _buildNavigationMetrics() {
    final estimatedArrivalTime = navoraFormatArrivalTime(
      DateTime.now(),
      _navigationDurationMinutes,
    );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
      decoration: BoxDecoration(
        color: const Color(0xFF222321),
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: const Color(0xFF353633)),
      ),
      child: Row(
        children: [
          Expanded(
            child: _buildNavigationMetric(
              Icons.schedule_rounded,
              'SÜRE',
              navoraFormatNavigationDuration(
                _navigationDurationMinutes,
                isWalking: _selectedVehicle == 'Yürüyüş',
              ),
            ),
          ),
          Container(width: 1, height: 38, color: const Color(0xFF41413E)),
          Expanded(
            child: _buildNavigationMetric(
              Icons.route_rounded,
              'MESAFE',
              _navigationDistanceKm == null
                  ? '-'
                  : '${_navigationDistanceKm!.toStringAsFixed(1)} km',
            ),
          ),
          Container(width: 1, height: 38, color: const Color(0xFF41413E)),
          Expanded(
            child: _buildNavigationMetric(
              Icons.flag_outlined,
              'VARIŞ',
              estimatedArrivalTime ?? '-',
            ),
          ),
          Container(width: 1, height: 38, color: const Color(0xFF41413E)),
          Expanded(
            child: _buildNavigationMetric(
              Icons.speed_rounded,
              'HIZ',
              _currentPosition != null &&
                      _currentPosition!.speed.isFinite &&
                      _currentPosition!.speed >= 0
                  ? '${navoraSpeedKmh(_currentPosition!.speed).round()} km/sa'
                  : '-',
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNavigationDockAction({
    required IconData icon,
    required String label,
    required int tabIndex,
  }) {
    final isSelected = _selectedIndex == tabIndex;
    return Expanded(
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => setState(() => _selectedIndex = tabIndex),
          borderRadius: BorderRadius.circular(14),
          child: Container(
            height: 38,
            decoration: BoxDecoration(
              color: isSelected
                  ? const Color(0x33FF7A00)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  icon,
                  size: 18,
                  color: isSelected
                      ? const Color(0xFFFF9A3D)
                      : Colors.white70,
                ),
                const SizedBox(width: 7),
                Text(
                  label,
                  style: TextStyle(
                    color: isSelected
                        ? const Color(0xFFFF9A3D)
                        : Colors.white70,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildNavigationDock() => Container(
    padding: const EdgeInsets.fromLTRB(9, 8, 9, 7),
    decoration: BoxDecoration(
      color: const Color(0xF21A1A1A),
      borderRadius: BorderRadius.circular(22),
      border: Border.all(color: const Color(0xFF4A3A2D)),
      boxShadow: const [
        BoxShadow(
          color: Color(0x66000000),
          blurRadius: 20,
          offset: Offset(0, 7),
        ),
      ],
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildNavigationMetrics(),
        const SizedBox(height: 4),
        Row(
          children: [
            _buildNavigationDockAction(
              icon: Icons.forum_rounded,
              label: 'Sohbet',
              tabIndex: 3,
            ),
            Container(width: 1, height: 24, color: const Color(0xFF41413E)),
            _buildNavigationDockAction(
              icon: Icons.auto_awesome_rounded,
              label: 'Navora AI',
              tabIndex: 2,
            ),
          ],
        ),
      ],
    ),
  );

  Widget _buildNavigationStatusMessage(IconData icon, String message) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Icon(icon, color: const Color(0xFFFF9A3C), size: 16),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                color: Color(0xFFFF9A3C),
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNavigationMetric(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: const Color(0xFFFF9A3D), size: 15),
          const SizedBox(height: 2),
          Text(
            label,
            maxLines: 1,
            style: const TextStyle(
              color: Color(0xFFAAA9A5),
              fontSize: 8,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.35,
            ),
          ),
          const SizedBox(height: 2),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              value,
              maxLines: 1,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String? _distanceToNavigationStep(Map<String, dynamic> step) {
    final distanceMeters = _distanceToNavigationStepMeters(step);
    if (distanceMeters == null) return step['distance'] as String?;
    if (!distanceMeters.isFinite) return step['distance'] as String?;
    if (distanceMeters >= 1000) {
      return '${(distanceMeters / 1000).toStringAsFixed(1)} km sonra';
    }
    return '${distanceMeters.round()} m sonra';
  }

  double? _distanceToNavigationStepMeters(Map<String, dynamic> step) {
    final position = _currentPosition;
    final latitude = step['latitude'] as double?;
    final longitude = step['longitude'] as double?;
    if (position == null || latitude == null || longitude == null) return null;

    return geo.Geolocator.distanceBetween(
      position.latitude,
      position.longitude,
      latitude,
      longitude,
    );
  }

  int get _citiesVisited => _visitedCities.length;

  int get _savedRouteCount => _savedRoutes.length;

  int get _aiQueriesRemaining {
    final dailyLimit = _isProUser ? _proAiQueriesPerDay : _freeAiQueriesPerDay;
    final freeLeft = (dailyLimit - _freeAiQueriesUsedToday).clamp(
      0,
      dailyLimit,
    );
    return freeLeft;
  }

  DateTime? _historyDate(Map<String, dynamic> data) {
    final timestamp = data['completed_at'];
    if (timestamp is Timestamp) return timestamp.toDate();
    return DateTime.tryParse(data['date']?.toString() ?? '');
  }

  bool _isHistoryExpired(Map<String, dynamic> data) {
    final date = _historyDate(data);
    return date == null ||
        date.isBefore(DateTime.now().subtract(const Duration(days: 30)));
  }

  String _formatHistoryDate(dynamic value) {
    final date = value is Timestamp
        ? value.toDate()
        : DateTime.tryParse(value?.toString() ?? '');
    if (date == null) return 'Tarih yok';
    final localDate = date.toLocal();
    final day = localDate.day.toString().padLeft(2, '0');
    final month = localDate.month.toString().padLeft(2, '0');
    final hour = localDate.hour.toString().padLeft(2, '0');
    final minute = localDate.minute.toString().padLeft(2, '0');
    return '$day.$month.${localDate.year} $hour:$minute';
  }

  Future<void> _deleteExpiredHistory(
    String uid,
    List<QueryDocumentSnapshot<Map<String, dynamic>>> documents,
    String collection,
  ) async {
    final batch = FirebaseFirestore.instance.batch();
    var deleteCount = 0;
    for (final document in documents) {
      if (_isHistoryExpired(document.data())) {
        batch.delete(
          FirebaseFirestore.instance
              .collection('users')
              .doc(uid)
              .collection(collection)
              .doc(document.id),
        );
        deleteCount++;
      }
    }
    if (deleteCount > 0) await batch.commit();
  }

  String _dailyQuotaKey(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

  DocumentReference<Map<String, dynamic>> _dailyQuotaReference(
    String userId,
    String date,
  ) => FirebaseFirestore.instance
      .collection('users')
      .doc(userId)
      .collection('daily_usage')
      .doc(date);

  HttpsCallable _quotaCallable(String name) =>
      FirebaseFunctions.instanceFor(region: 'europe-west1').httpsCallable(name);

  Future<HttpsCallableResult<dynamic>> _callQuotaCallable(
    String name,
    Map<String, dynamic> data,
  ) async {
    final auth = FirebaseAuth.instance;
    final user = auth.currentUser;
    if (user == null) {
      throw FirebaseFunctionsException(
        code: 'unauthenticated',
        message: 'Oturum açmanız gerekiyor.',
      );
    }

    await user.getIdToken();
    try {
      return await _quotaCallable(name).call(data);
    } on FirebaseFunctionsException catch (error) {
      if (error.code != 'unauthenticated' ||
          auth.currentUser?.uid != user.uid) {
        rethrow;
      }
      await user.getIdToken(true);
      if (auth.currentUser?.uid != user.uid) rethrow;
      return _quotaCallable(name).call(data);
    }
  }

  Future<void> _reserveDailyQuota(String kind, String reservationId) async {
    final result = await _callQuotaCallable('reserveDailyQuota', {
      'kind': kind,
      'reservationId': reservationId,
    });
    final data = result.data;
    if (data is! Map) {
      throw StateError('Günlük kullanım yanıtı geçersiz.');
    }
    if (!mounted) return;
    setState(() {
      _dailyQuotaDate = data['date']?.toString();
      _roomsCreatedToday = (data['rooms'] as num?)?.toInt() ?? 0;
      _freeAiQueriesUsedToday = (data['ai'] as num?)?.toInt() ?? 0;
    });
  }

  Future<void> _finishChatRoomCreation(String roomId) async {
    try {
      await _callQuotaCallable('completeDailyQuotaReservation', {
        'reservationId': roomId,
      });
    } catch (error) {
      debugPrint('Sohbet odası kotası tamamlanamadı: $error');
    }

    try {
      await FirebaseFunctions.instanceFor(region: 'europe-west1')
          .httpsCallable('sendChatMessage')
          .call({
            'messageType': 'room',
            'roomId': roomId,
            'senderName': _userName,
            'text': 'Oda oluşturuldu, herkese merhaba!',
          });
    } catch (error) {
      debugPrint('Sohbet odası karşılama mesajı gönderilemedi: $error');
    }
  }

  Future<void> _subscribeToDailyQuota(String userId, String date) async {
    await _dailyQuotaSubscription?.cancel();
    if (!mounted || FirebaseAuth.instance.currentUser?.uid != userId) return;

    _dailyQuotaSubscription = _dailyQuotaReference(userId, date)
        .snapshots()
        .listen(
          (snapshot) {
            if (!mounted ||
                FirebaseAuth.instance.currentUser?.uid != userId ||
                _dailyQuotaDate != date ||
                !snapshot.exists) {
              return;
            }
            final data = snapshot.data()!;
            setState(() {
              if (data['quota_version'] == 1) {
                _roomsCreatedToday = (data['rooms'] as num?)?.toInt() ?? 0;
                _freeAiQueriesUsedToday = (data['ai'] as num?)?.toInt() ?? 0;
              } else {
                _roomsCreatedToday = 0;
                _freeAiQueriesUsedToday = 0;
              }
            });
          },
          onError: (Object error) {
            debugPrint('Günlük kullanım bilgisi dinlenemedi: $error');
            if (mounted) {
              _showTrackingMessage('Günlük kullanım bilgisi güncellenemedi.');
            }
          },
        );
  }

  void _subscribeToAiChats(String userId) {
    _aiChatsSubscription?.cancel();
    _aiChatsSubscription = FirebaseFirestore.instance
        .collection('users')
        .doc(userId)
        .collection('ai_chats')
        .orderBy('created_at', descending: true)
        .limit(50)
        .snapshots()
        .listen(
          (snapshot) {
            if (!mounted || FirebaseAuth.instance.currentUser?.uid != userId) {
              return;
            }
            final messages = <Map<String, String>>[
              {
                'sender': 'ai',
                'text': 'Merhaba! Ben Navora AI. Rotan, yakındaki mekanlar veya trafik hakkında ne öğrenmek istersin?',
              },
            ];
            for (final document in snapshot.docs.reversed) {
              final data = document.data();
              final question = data['question']?.toString().trim() ?? '';
              final answer = data['answer']?.toString().trim() ?? '';
              if (question.isEmpty || answer.isEmpty) continue;
              messages
                ..add({'sender': 'user', 'text': question})
                ..add({'sender': 'ai', 'text': answer});
            }
            setState(() {
              _aiMessages
                ..clear()
                ..addAll(messages);
            });
          },
          onError: (Object error) {
            debugPrint('Navora AI geçmişi yüklenemedi: $error');
            if (mounted) {
              _showTrackingMessage('Yapay zeka sohbet geçmişi yüklenemedi.');
            }
          },
        );
  }

  void _subscribeToUserProfile(String userId) {
    final userReference = FirebaseFirestore.instance
        .collection('users')
        .doc(userId);
    _userProfileSubscription?.cancel();
    _userProfileSubscription = userReference.snapshots().listen(
      (snapshot) {
        if (!mounted ||
            FirebaseAuth.instance.currentUser?.uid != userId ||
            !snapshot.exists) {
          return;
        }
        final data = snapshot.data()!;
        setState(() {
          _isProUser = false;
          final phone = data['phone'];
          if (phone is String) _userPhone = phone.trim();
          final photoUrl = data['photo_url']?.toString().trim();
          if (photoUrl != null && photoUrl.isNotEmpty) {
            _profilePhotoUrl = photoUrl;
          }
          final visitedCities = data['visited_cities'];
          _visitedCities
            ..clear()
            ..addAll(
              visitedCities is List
                  ? visitedCities
                        .whereType<String>()
                        .map((city) => city.trim())
                        .where((city) => city.isNotEmpty)
                  : const <String>[],
            );
        });
      },
      onError: (Object error) {
        debugPrint('Kullanıcı profili dinlenemedi: $error');
      },
    );
  }

  void _subscribeToUserCollections(String userId) {
    final userReference = FirebaseFirestore.instance
        .collection('users')
        .doc(userId);

    _savedRoutesSubscription = userReference
        .collection('saved_routes')
        .orderBy('created_at', descending: true)
        .snapshots()
        .listen(
          (snapshot) {
            if (!mounted || FirebaseAuth.instance.currentUser?.uid != userId) {
              return;
            }
            setState(() {
              _savedRoutes
                ..clear()
                ..addAll(
                  snapshot.docs.map((document) {
                    final route = document.data();
                    return <String, String>{
                      'id': document.id,
                      'title': route['title']?.toString() ?? 'Kayıtlı rota',
                      'start': route['start']?.toString() ?? '',
                      'destination': route['destination']?.toString() ?? '',
                      'distance_km': route['distance_km']?.toString() ?? '',
                      'start_latitude':
                          route['start_latitude']?.toString() ?? '',
                      'start_longitude':
                          route['start_longitude']?.toString() ?? '',
                      'destination_latitude':
                          route['destination_latitude']?.toString() ?? '',
                      'destination_longitude':
                          route['destination_longitude']?.toString() ?? '',
                      'travel_mode':
                          route['travel_mode']?.toString() ?? 'Araba',
                      'is_public': route['is_public']?.toString() ?? 'false',
                      'public_route_id':
                          route['public_route_id']?.toString() ?? '',
                    };
                  }),
                );
            });
          },
          onError: (Object error) {
            debugPrint('Kayıtlı rotalar dinlenemedi: $error');
            if (mounted) {
              _showTrackingMessage('Kayıtlı rotalar güncellenemedi.');
            }
          },
        );

    _savedAddressesSubscription = userReference
        .collection('saved_addresses')
        .snapshots()
        .listen(
          (snapshot) {
            if (!mounted || FirebaseAuth.instance.currentUser?.uid != userId) {
              return;
            }
            setState(() {
              _savedAddresses
                ..clear()
                ..addAll(
                  snapshot.docs.map((document) {
                    if (document.id == 'current_vehicle_parking') {
                      return null;
                    }
                    final address = document.data();
                    return <String, String>{
                      'id': document.id,
                      'title': address['title']?.toString() ?? 'Adres',
                      'address': address['address']?.toString() ?? '',
                      'type': address['type']?.toString() ?? 'favorite',
                      'latitude': address['latitude']?.toString() ?? '',
                      'longitude': address['longitude']?.toString() ?? '',
                    };
                  }).whereType<Map<String, String>>(),
                );
            });
          },
          onError: (Object error) {
            debugPrint('Kayıtlı adresler dinlenemedi: $error');
            if (mounted) {
              _showTrackingMessage('Kayıtlı adresler güncellenemedi.');
            }
          },
        );

    _subscribeToMapLayers();

    _drivingHistorySubscription = userReference
        .collection('driving_history')
        .snapshots()
        .listen(
          (snapshot) {
            if (!mounted || FirebaseAuth.instance.currentUser?.uid != userId) {
              return;
            }
            _liveDrivingHistory
              ..clear()
              ..addAll(
                snapshot.docs
                    .where((document) => !_isHistoryExpired(document.data()))
                    .map((document) {
                      final history = document.data();
                      return <String, String>{
                        'id': document.id,
                        'collection': 'driving_history',
                        'route':
                            history['route']?.toString() ?? 'Tamamlanan rota',
                        'date': _formatHistoryDate(
                          history['completed_at'] ?? history['date'],
                        ),
                        'duration': '${history['duration_minutes'] ?? 0} dk',
                        'km': '${history['distance_km'] ?? 0} km',
                      };
                    }),
              );
            setState(() {
              _drivingHistory
                ..clear()
                ..addAll(
                  navoraCombineDrivingHistory(
                    _liveDrivingHistory,
                    _liveRouteHistory,
                  ),
                );
            });
          },
          onError: (Object error) {
            debugPrint('Sürüş geçmişi dinlenemedi: $error');
            if (mounted) _showTrackingMessage('Sürüş geçmişi güncellenemedi.');
          },
        );

    _routeHistorySubscription = userReference
        .collection('route_history')
        .snapshots()
        .listen(
          (snapshot) {
            if (!mounted || FirebaseAuth.instance.currentUser?.uid != userId) {
              return;
            }
            _liveRouteHistory
              ..clear()
              ..addAll(
                snapshot.docs
                    .where((document) => !_isHistoryExpired(document.data()))
                    .map((document) {
                      final history = document.data();
                      return <String, String>{
                        'id': document.id,
                        'collection': 'route_history',
                        'route':
                            history['title']?.toString() ?? 'Tamamlanan rota',
                        'date': _formatHistoryDate(
                          history['completed_at'] ?? history['date'],
                        ),
                        'duration': '${history['duration_minutes'] ?? 0} dk',
                        'km': '${history['distance_km'] ?? 0} km',
                      };
                    }),
              );
            setState(() {
              _drivingHistory
                ..clear()
                ..addAll(
                  navoraCombineDrivingHistory(
                    _liveDrivingHistory,
                    _liveRouteHistory,
                  ),
                );
            });
          },
          onError: (Object error) {
            debugPrint('Rota geçmişi dinlenemedi: $error');
            if (mounted) _showTrackingMessage('Rota geçmişi güncellenemedi.');
          },
        );
  }

  Future<void> _persistDailyQuota() async {
    final userId = FirebaseAuth.instance.currentUser?.uid;
    final date = _dailyQuotaDate ?? _dailyQuotaKey(DateTime.now());
    try {
      final preferences = await SharedPreferences.getInstance();
      final prefix = 'navora.dailyQuota.${userId ?? 'guest'}.';
      await preferences.setString('${prefix}date', date);
      await preferences.setInt('${prefix}rooms', _roomsCreatedToday);
      await preferences.setInt('${prefix}ai', _freeAiQueriesUsedToday);
    } catch (error) {
      debugPrint('Günlük kullanım bilgisi kaydedilemedi: $error');
      if (mounted) {
        _showTrackingMessage('Günlük kullanım bilgisi kaydedilemedi.');
      }
    }
  }

  Future<void> _recordDailyQuotaUsage({
    bool roomCreated = false,
    bool aiQueryCompleted = false,
  }) async {
    final userId = FirebaseAuth.instance.currentUser?.uid;
    final date = _dailyQuotaKey(DateTime.now());
    if (userId == null) {
      if (mounted) {
        setState(() {
          _dailyQuotaDate = date;
          if (roomCreated) _roomsCreatedToday++;
          if (aiQueryCompleted) _freeAiQueriesUsedToday++;
        });
      }
      await _persistDailyQuota();
      return;
    }
  }

  Future<void> _loadProfileData() async {
    await _refreshVerifiedEmail();
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      _showTrackingMessage('Oda oluşturmak için önce hesabına giriş yap.');
      return;
    }
    _subscribeToUserProfile(user.uid);

    try {
      final profile = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .get();
      final savedRoutesSnapshot = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .collection('saved_routes')
          .orderBy('created_at', descending: true)
          .get();
      final savedAddressesSnapshot = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .collection('saved_addresses')
          .get();
      final drivingHistorySnapshot = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .collection('driving_history')
          .get();
      final routeHistorySnapshot = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .collection('route_history')
          .get();
      final today = _dailyQuotaKey(DateTime.now());
      final dailyQuotaSnapshot = await _dailyQuotaReference(
        user.uid,
        today,
      ).get();
      final data = profile.data() ?? <String, dynamic>{};
      if (!mounted) return;

      await _deleteExpiredHistory(
        user.uid,
        drivingHistorySnapshot.docs,
        'driving_history',
      );
      await _deleteExpiredHistory(
        user.uid,
        routeHistorySnapshot.docs,
        'route_history',
      );

      setState(() {
        final savedRoutes = savedRoutesSnapshot.docs
            .map(
              (document) => <String, String>{
                'id': document.id,
                'title': document.data()['title']?.toString() ?? 'Kayıtlı rota',
                'start': document.data()['start']?.toString() ?? '',
                'destination': document.data()['destination']?.toString() ?? '',
                'distance_km': document.data()['distance_km']?.toString() ?? '',
              },
            )
            .toList();
        _savedRoutes
          ..clear()
          ..addAll(savedRoutes);
        final savedAddresses = savedAddressesSnapshot.docs
            .where((document) => document.id != 'current_vehicle_parking')
            .map(
              (document) => <String, String>{
                'id': document.id,
                'title': document.data()['title']?.toString() ?? 'Adres',
                'address': document.data()['address']?.toString() ?? '',
                'type': document.data()['type']?.toString() ?? 'favorite',
                'latitude': document.data()['latitude']?.toString() ?? '',
                'longitude': document.data()['longitude']?.toString() ?? '',
              },
            )
            .toList();
        _savedAddresses
          ..clear()
          ..addAll(savedAddresses);
        final drivingHistory = drivingHistorySnapshot.docs
            .where((document) => !_isHistoryExpired(document.data()))
            .map((document) {
              final history = document.data();
              return <String, String>{
                'id': document.id,
                'collection': 'driving_history',
                'route': history['route']?.toString() ?? 'Tamamlanan rota',
                'date': _formatHistoryDate(
                  history['completed_at'] ?? history['date'],
                ),
                'duration': '${history['duration_minutes'] ?? 0} dk',
                'km': '${history['distance_km'] ?? 0} km',
              };
            })
            .toList();
        final routeHistory = routeHistorySnapshot.docs
            .where((document) => !_isHistoryExpired(document.data()))
            .map((document) {
              final history = document.data();
              return <String, String>{
                'id': document.id,
                'collection': 'route_history',
                'route': history['title']?.toString() ?? 'Tamamlanan rota',
                'date': _formatHistoryDate(
                  history['completed_at'] ?? history['date'],
                ),
                'duration': '${history['duration_minutes'] ?? 0} dk',
                'km': '${history['distance_km'] ?? 0} km',
              };
            })
            .toList();
        _drivingHistory
          ..clear()
          ..addAll(navoraCombineDrivingHistory(drivingHistory, routeHistory));
        final visitedCities = data['visited_cities'];
        _visitedCities
          ..clear()
          ..addAll(
            visitedCities is List
                ? visitedCities.whereType<String>()
                : const [],
          );
        _dailyQuotaDate = today;
        if (dailyQuotaSnapshot.exists &&
            dailyQuotaSnapshot.data()?['quota_version'] == 1) {
          final usage = dailyQuotaSnapshot.data()!;
          _roomsCreatedToday = (usage['rooms'] as num?)?.toInt() ?? 0;
          _freeAiQueriesUsedToday = (usage['ai'] as num?)?.toInt() ?? 0;
        } else {
          _roomsCreatedToday = 0;
          _freeAiQueriesUsedToday = 0;
        }
        final phone = data['phone'];
        final email =
            user.email ?? data['email']?.toString() ?? widget.userEmail;
        final gender =
            data['gender_preference']?.toString() ??
            data['gender']?.toString() ??
            'Belirtmek istemiyorum';
        if (email.isNotEmpty) _userEmail = email;
        _userGender = gender;
        _isProUser = false;
        final selectedVehicle = data['selected_vehicle']?.toString();
        if (selectedVehicle == 'Araba' ||
            selectedVehicle == 'Motosiklet' ||
            selectedVehicle == 'Bisiklet' ||
            selectedVehicle == 'Yürüyüş') {
          _selectedVehicle = selectedVehicle!;
        } else {
          _selectedVehicle = 'Araba';
        }
        if (phone is String && phone.isNotEmpty) _userPhone = phone;
      });
      _subscribeToUserCollections(user.uid);
      await _subscribeToDailyQuota(user.uid, today);
    } catch (error) {
      debugPrint('Profil verileri yüklenemedi: $error');
      if (mounted) {
        _showTrackingMessage('Profil verileri yüklenemedi.');
      }
    }
  }

  Future<void> _refreshVerifiedEmail() async {
    if (_isRefreshingVerifiedEmail) return;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    _isRefreshingVerifiedEmail = true;
    try {
      await user.reload();
      final refreshedUser = FirebaseAuth.instance.currentUser;
      final email = refreshedUser?.email;
      if (refreshedUser == null || email == null || email.isEmpty) return;

      if (mounted && _userEmail != email) {
        setState(() => _userEmail = email);
      }

      final profileReference = FirebaseFirestore.instance
          .collection('users')
          .doc(refreshedUser.uid);
      final profile = await profileReference.get();
      if (profile.data()?['email'] != email) {
        await profileReference.set({
          'email': email,
          'updated_at': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      }
    } on FirebaseAuthException catch (error) {
      debugPrint('E-posta durumu yenilenemedi: ${error.code}');
    } on FirebaseException catch (error) {
      debugPrint('Doğrulanmış e-posta profili güncellenemedi: ${error.code}');
    } finally {
      _isRefreshingVerifiedEmail = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomSafeInset = MediaQuery.viewPaddingOf(context).bottom;
    final isMapSearchPanelVisible =
        _selectedIndex == 1 &&
        !_isLostPetMapActive &&
        _showSearchPanel &&
        (_searchSuggestions.isNotEmpty || _searchHistory.isNotEmpty);
    final mapTopInset = _selectedIndex == 1
        ? MediaQuery.viewPaddingOf(context).top
        : 0.0;
    final snackBarBottomInset =
        bottomSafeInset +
        (_isNavigationActive && _selectedIndex == 1
            ? _navigationDockHeight
            : _bottomNavigationBarHeight) +
        _bottomNavigationGap +
        12;
    final mapBottomControlsInset = _isNavigationActive
        ? _navigationDockHeight
        : _bottomNavigationBarHeight;

    return Theme(
      data: Theme.of(context).copyWith(
        scaffoldBackgroundColor: const Color(0xFF111111),
        snackBarTheme: Theme.of(context).snackBarTheme.copyWith(
          behavior: SnackBarBehavior.floating,
          insetPadding: EdgeInsets.fromLTRB(16, 0, 16, snackBarBottomInset),
        ),
      ),
      child: Scaffold(
        resizeToAvoidBottomInset: false,
        body: SafeArea(
          top: _selectedIndex != 1,
          bottom: false,
          child: Stack(
            fit: StackFit.expand,
            children: [
              IndexedStack(
                index: _selectedIndex,
                children: [
                  _buildExplorePage(),
                  _buildMapPage(),
                  _buildAiPage(),
                  _buildChatPage(),
                  _buildProfilePage(),
                ],
              ),
              if (_selectedIndex == 1 &&
                  !_isNavigationActive &&
                  _isLostPetMapActive)
                Positioned(
                  top: mapTopInset + 10,
                  left: 16,
                  right: 16,
                  child: _buildLostPetMapToolbar(),
                ),
              if (_selectedIndex == 1 &&
                  !_isNavigationActive &&
                  !_isLostPetMapActive &&
                  _activePropertyListingType != null)
                Positioned(
                  top: mapTopInset + 10,
                  left: 16,
                  right: 16,
                  child: _buildPropertyMapToolbar(),
                ),
              if (_selectedIndex == 1 &&
                  !_isNavigationActive &&
                  !_isLostPetMapActive &&
                  _activePropertyListingType == null)
                Positioned(
                  top: mapTopInset + 10,
                  left: 16,
                  right: 16,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1F1F1F),
                          borderRadius: BorderRadius.circular(28),
                          border: Border.all(color: const Color(0xFFFF7A00)),
                        ),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          decoration: BoxDecoration(
                            color: const Color(0xFF1F1F1F),
                            borderRadius: BorderRadius.circular(22),
                          ),
                          child: Row(
                            children: [
                              if (_isSearchMode ||
                                  _searchController.text.isNotEmpty ||
                                  _showSearchPanel)
                                IconButton(
                                  tooltip: 'Aramayı iptal et',
                                  splashRadius: 18,
                                  icon: const Icon(
                                    Icons.arrow_back_rounded,
                                    color: Colors.white70,
                                  ),
                                  onPressed: _cancelSearch,
                                )
                              else
                                const Padding(
                                  padding: EdgeInsets.all(9),
                                  child: Icon(
                                    Icons.search_rounded,
                                    color: Color(0xFFFF7A00),
                                  ),
                                ),
                              Expanded(
                                child: TextField(
                                  controller: _searchController,
                                  focusNode: _searchFocusNode,
                                  onTap: _openSearchPage,
                                  textInputAction: TextInputAction.search,
                                  onChanged: _handleSearchChanged,
                                  onSubmitted: (_) =>
                                      _searchPlace(showPanel: true),
                                  style: const TextStyle(
                                    fontSize: 15,
                                    color: Colors.white,
                                    fontWeight: FontWeight.w600,
                                  ),
                                  decoration: InputDecoration(
                                    hintText: 'Nereye gitmek istersin?',
                                    filled: true,
                                    fillColor: const Color(0xFF1F1F1F),
                                    hintStyle: const TextStyle(
                                      color: Color(0xFFBDBDBD),
                                      fontSize: 15,
                                      fontWeight: FontWeight.w500,
                                    ),
                                    border: InputBorder.none,
                                    enabledBorder: InputBorder.none,
                                    focusedBorder: InputBorder.none,
                                    contentPadding: const EdgeInsets.symmetric(
                                      vertical: 14,
                                    ),
                                  ),
                                ),
                              ),
                              if (_searchController.text.trim().isNotEmpty ||
                                  _showSearchPanel ||
                                  _isSearchMode)
                                IconButton(
                                  tooltip: 'Temizle',
                                  splashRadius: 18,
                                  icon: const Icon(
                                    Icons.close_rounded,
                                    color: Colors.white70,
                                  ),
                                  onPressed: _cancelSearch,
                                )
                              else
                                Padding(
                                  padding: const EdgeInsets.only(right: 4),
                                  child: IconButton(
                                    tooltip: _isListening
                                        ? 'Sesli aramayı durdur'
                                        : 'Sesli ara',
                                    splashRadius: 18,
                                    icon: Icon(
                                      _isListening
                                          ? Icons.mic_rounded
                                          : Icons.mic_none_rounded,
                                      color: _isListening
                                          ? Colors.red
                                          : const Color(0xFFFF7A00),
                                    ),
                                    onPressed: _toggleVoiceSearch,
                                  ),
                                ),
                              if (_searchController.text.trim().isNotEmpty &&
                                  !_isSearching)
                                IconButton(
                                  tooltip: 'Ara',
                                  splashRadius: 18,
                                  icon: const Icon(
                                    Icons.search_rounded,
                                    color: Color(0xFFFF7A00),
                                  ),
                                  onPressed: _searchPlace,
                                )
                              else if (_isSearching)
                                const Padding(
                                  padding: EdgeInsets.all(10),
                                  child: SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Color(0xFFFF7A00),
                                    ),
                                  ),
                                )
                              else
                                const SizedBox(width: 8),
                            ],
                          ),
                        ),
                      ),
                      if (!_showSearchPanel && !_isSearchMode) ...[
                        if (_routeSelectionTarget != null)
                          _buildRouteSelectionPanel()
                        else ...[
                          const SizedBox(height: 10),
                          SizedBox(
                            height: 32,
                            child: ListView(
                              scrollDirection: Axis.horizontal,
                              children: [
                                _buildChip(
                                  Icons.alt_route_rounded,
                                  'Rota Oluştur',
                                  onTap: _startRoutePlanning,
                                ),
                                _buildChip(
                                  Icons.add_location_alt_rounded,
                                  'Mekân Ekle',
                                  onTap: () =>
                                      unawaited(_createCommunityPlace()),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ],
                  ),
                ),
              if (isMapSearchPanelVisible)
                Positioned(
                  left: 16,
                  right: 16,
                  bottom: bottomSafeInset + 14,
                  child: _buildSearchResultsPanel(),
                ),
              if (_selectedIndex == 1 && !isMapSearchPanelVisible)
                Positioned(
                  right: 16,
                  bottom: bottomSafeInset + mapBottomControlsInset + 8,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      FloatingActionButton.small(
                        heroTag: 'map-north-reset',
                        onPressed: _resetMapNorth,
                        tooltip: 'Haritayı kuzeye döndür',
                        backgroundColor: const Color(0xFF191919),
                        foregroundColor: const Color(0xFFFF6B00),
                        shape: const CircleBorder(),
                        child: const Icon(Icons.explore_rounded),
                      ),
                      const SizedBox(height: 10),
                      FloatingActionButton.small(
                        heroTag: 'map-layers',
                        onPressed: _showMapLayersSheet,
                        tooltip: 'Harita katmanları',
                        backgroundColor: const Color(0xFF191919),
                        foregroundColor: const Color(0xFFFF6B00),
                        shape: const CircleBorder(),
                        child: const Icon(Icons.layers_rounded),
                      ),
                      const SizedBox(height: 10),
                      if (_isNavigationActive) ...[
                        FloatingActionButton.small(
                          heroTag: 'navigation-compass',
                          onPressed: () async {
                            final position = _currentPosition;
                            if (position == null) return;
                            final nextTilted = !_isMapTilted;
                            setState(() {
                              _isMapTilted = nextTilted;
                              _isFollowingCurrentPosition = true;
                            });
                            await _centerOnPosition(position);
                          },
                          tooltip: _isMapTilted
                              ? 'Düz harita görünümü'
                              : 'Eğimli harita görünümü',
                          backgroundColor: const Color(0xFF191919),
                          foregroundColor: const Color(0xFFFF6B00),
                          shape: const CircleBorder(),
                          child: Icon(
                            _isMapTilted
                                ? Icons.terrain_rounded
                                : Icons.explore_rounded,
                          ),
                        ),
                        const SizedBox(height: 10),
                      ],
                      if (!_isNavigationActive) ...[
                        FloatingActionButton.small(
                          heroTag: 'recenter-map',
                          onPressed: _recenterMap,
                          tooltip: 'Haritayı konumuma ortala',
                          backgroundColor: const Color(0xFF191919),
                          foregroundColor: const Color(0xFFFF6B00),
                          shape: const CircleBorder(),
                          child: Icon(
                            _isFollowingCurrentPosition
                                ? Icons.my_location_rounded
                                : Icons.near_me_rounded,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              if (_selectedIndex == 1 &&
                  _isNavigationActive &&
                  !isMapSearchPanelVisible)
                Positioned(
                  left: 16,
                  bottom: bottomSafeInset + mapBottomControlsInset + 18,
                  child: FloatingActionButton.small(
                    heroTag: 'recenter-map',
                    onPressed: _recenterMap,
                    tooltip: 'Haritayı konumuma ortala',
                    backgroundColor: const Color(0xFF191919),
                    foregroundColor: const Color(0xFFFF6B00),
                    shape: const CircleBorder(),
                    child: Icon(
                      _isFollowingCurrentPosition
                          ? Icons.my_location_rounded
                          : Icons.near_me_rounded,
                    ),
                  ),
                ),
              if (_selectedIndex == 1 &&
                  _isNavigationActive &&
                  !isMapSearchPanelVisible &&
                  _currentRoadName?.isNotEmpty == true)
                Positioned(
                  left: 74,
                  right: 74,
                  bottom: bottomSafeInset + mapBottomControlsInset + 8,
                  child: IgnorePointer(
                    child: Center(
                      child: Container(
                        constraints: const BoxConstraints(maxWidth: 240),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 11,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xE6191919),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: const Color(0xFF3A3A3A)),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.signpost_rounded,
                              color: Color(0xFFFF9A3D),
                              size: 16,
                            ),
                            const SizedBox(width: 6),
                            Flexible(
                              child: Text(
                                _currentRoadName!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              if (_selectedIndex == 1 && _isNavigationActive)
                Positioned(
                  left: 16,
                  right: 16,
                  top: mapTopInset + 10,
                  child: _buildLiveNavigationCard(),
                ),
              if (_selectedIndex == 1 && !_isMapLoaded)
                const Positioned.fill(
                  child: NavoraLoadingScreen(
                    title: 'Harita hazırlanıyor',
                    subtitle: 'Yakınındaki yollar yükleniyor.',
                  ),
                ),
              if (!isMapSearchPanelVisible &&
                  _isNavigationActive &&
                  _selectedIndex == 1)
                Positioned(
                  left: 12,
                  right: 12,
                  bottom: bottomSafeInset + 6,
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 440),
                      child: _buildNavigationDock(),
                    ),
                  ),
                ),
              if (!isMapSearchPanelVisible &&
                  (!_isNavigationActive || _selectedIndex != 1))
                Positioned(
                  left: 12,
                  right: 12,
                  bottom: bottomSafeInset,
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 440),
                      child: Container(
                        height: _bottomNavigationBarHeight,
                        padding: const EdgeInsets.all(5),
                        decoration: BoxDecoration(
                          color: const Color(0xF21A1A1A),
                          borderRadius: BorderRadius.circular(36),
                          border: Border.all(color: const Color(0xFF3A3A3A)),
                          boxShadow: const [
                            BoxShadow(
                              color: Color(0x66000000),
                              blurRadius: 20,
                              offset: Offset(0, 7),
                            ),
                          ],
                        ),
                        child: Row(
                          children: [
                            _buildNavItem(Icons.explore, 'Keşfet', 0),
                            _buildNavItem(Icons.map_rounded, 'Harita', 1),
                            _buildNavItem(Icons.auto_awesome, 'Navora AI', 2),
                            _buildNavItem(Icons.forum, 'Sohbet', 3),
                            _buildNavItem(Icons.person, 'Profil', 4),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showCreatePropertyListingSheet({
    Map<String, dynamic>? listing,
  }) async {
    if (FirebaseAuth.instance.currentUser == null) {
      AppNotificationService.show('İlan vermek için önce giriş yapmalısın.');
      return;
    }

    final submitted = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: false,
      showDragHandle: false,
      backgroundColor: const Color(0xFF171817),
      builder: (context) => CreatePropertyListingSheet(listing: listing),
    );
    if (submitted == true && mounted) {
      AppNotificationService.show(
        listing == null
            ? 'İlanın incelemeye gönderildi.'
            : 'Değişiklikler incelemeye gönderildi.',
      );
    }
  }

  Future<void> _confirmDeletePropertyListing(
    Map<String, dynamic> listing, {
    VoidCallback? onDeleted,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('İlan silinsin mi?'),
        content: Text(
          '“${listing['title'] ?? 'Konut ilanı'}” ve fotoğrafları kalıcı olarak silinecek.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Vazgeç'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Sil'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      await _propertyListingService.deleteListing(listing['id'].toString());
      if (mounted) {
        onDeleted?.call();
        AppNotificationService.show('İlan silindi.');
      }
    } on FirebaseFunctionsException catch (error) {
      debugPrint('İlan silinemedi (${error.code}): ${error.message}');
      if (mounted) {
        AppNotificationService.show(switch (error.code) {
          'unauthenticated' => 'Oturumun sona ermiş. Tekrar giriş yapıp dene.',
          'permission-denied' => 'Bu ilanı silme yetkin yok.',
          'not-found' => 'İlan silme servisi bulunamadı. Uygulamayı güncelleyip tekrar dene.',
          _ => 'İlan silinemedi (${error.code}). Daha sonra tekrar dene.',
        });
      }
    } catch (error) {
      debugPrint('İlan silinemedi: $error');
      if (mounted) {
        AppNotificationService.show('İlan silinemedi. Tekrar dene.');
      }
    }
  }

  Widget _buildExplorePage() {
    return ExplorePage(
      onSelectListingType: (type) => unawaited(_openPropertyMap(type)),
      onSelectLostPet: () => unawaited(_openLostPetMap()),
      currentUserUid: FirebaseAuth.instance.currentUser?.uid,
      canManageHighlights: _canManageExploreHighlights,
      onShowCommunityPlaces: () => unawaited(_showCommunityPlacesOnMap()),
      onShowPublicRoutes: _showPublicRoutesSheet,
      onSearchCategory: (label, query) {
        setState(() => _selectedIndex = 1);
        unawaited(_searchCategory(label, query));
      },
    );
  }

  Future<void> _createCommunityPlace({
    LatLng? initialCoordinate,
    String initialName = '',
    String initialAddress = '',
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      _showTrackingMessage('Mekân eklemek için hesabına giriş yap.');
      return;
    }

    var coordinate = initialCoordinate;
    if (coordinate == null && _currentPosition != null) {
      coordinate = LatLng(
        _currentPosition!.latitude,
        _currentPosition!.longitude,
      );
    }
    if (coordinate == null) {
      final permissionGranted = await _ensureLocationPermission();
      if (!mounted || !permissionGranted) return;
      try {
        final position = await geo.Geolocator.getCurrentPosition(
          locationSettings: const geo.LocationSettings(
            accuracy: geo.LocationAccuracy.high,
          ),
        );
        if (!mounted) return;
        coordinate = LatLng(position.latitude, position.longitude);
      } catch (error) {
        debugPrint('Yeni mekân konumu alınamadı: $error');
        if (mounted) {
          _showTrackingMessage('Mekân eklemek için konum gerekli.');
        }
        return;
      }
    }

    final selectedCoordinate = coordinate;
    final submitted = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: const Color(0xFF171717),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) => CreateCommunityPlaceSheet(
        latitude: selectedCoordinate.latitude,
        longitude: selectedCoordinate.longitude,
        initialName: initialName,
        initialAddress: initialAddress,
        onSubmit:
            ({
              required name,
              required category,
              required description,
              required address,
              required photoBytes,
              required photoExtensions,
              required coordinate,
            }) async {
              if (photoBytes.length > 3 ||
                  photoBytes.length != photoExtensions.length) {
                throw StateError('En fazla 3 mekân fotoğrafı ekleyebilirsin.');
              }
              final placeReference = FirebaseFirestore.instance
                  .collection('community_places')
                  .doc();
              final uploadedReferences = <Reference>[];

              try {
                await placeReference.set({
                  'owner_uid': user.uid,
                  'name': name,
                  'category': category,
                  'description': description,
                  'address': address,
                  'latitude': coordinate.latitude,
                  'longitude': coordinate.longitude,
                  'created_at': FieldValue.serverTimestamp(),
                });
                final photoUrls = <String>[];
                for (var index = 0; index < photoBytes.length; index++) {
                  final photoExtension = photoExtensions[index];
                  final contentType = switch (photoExtension) {
                    'jpg' || 'jpeg' => 'image/jpeg',
                    'png' => 'image/png',
                    'webp' => 'image/webp',
                    _ => throw StateError(
                      'JPG, PNG veya WebP fotoğraf seçmelisin.',
                    ),
                  };
                  final photoReference = FirebaseStorage.instance.ref().child(
                    'community_places/${user.uid}/${placeReference.id}/$index',
                  );
                  uploadedReferences.add(photoReference);
                  await photoReference.putData(
                    photoBytes[index],
                    SettableMetadata(contentType: contentType),
                  );
                  photoUrls.add(await photoReference.getDownloadURL());
                }
                if (photoUrls.isNotEmpty) {
                  await placeReference.update({
                    'photo_urls': photoUrls,
                    'photo_url': photoUrls.first,
                  });
                }
              } catch (_) {
                for (final photoReference in uploadedReferences) {
                  try {
                    await photoReference.delete();
                  } catch (cleanupError) {
                    debugPrint('Mekân fotoğrafı temizlenemedi: $cleanupError');
                  }
                }
                try {
                  await placeReference.delete();
                } catch (cleanupError) {
                  debugPrint('Mekân kaydı temizlenemedi: $cleanupError');
                }
                rethrow;
              }
            },
      ),
    );
    if (submitted == true && mounted) {
      _showTrackingMessage('Mekân haritaya ve Keşfet’e eklendi.');
    }
  }

  Future<void> _showCommunityPlacesOnMap() async {
    final places = _visibleCommunityPlaces.where((place) {
      return place['latitude'] is num && place['longitude'] is num;
    }).toList();
    if (places.isEmpty) {
      _showTrackingMessage('Haritada gösterilecek topluluk mekânı yok.');
      return;
    }

    final points = places
        .map(
          (place) => LatLng(
            (place['latitude'] as num).toDouble(),
            (place['longitude'] as num).toDouble(),
          ),
        )
        .toSet()
        .toList();

    _cancelSearch();
    if (!mounted) return;
    setState(() {
      _selectedIndex = 1;
      _activePropertyListingType = null;
      _isLostPetMapActive = false;
      _selectedPlaceDetails = null;
    });

    if (points.length == 1) {
      await _moveMapTo(points.single, 14);
    } else {
      await _fitMapToPoints(points);
    }
  }

  Future<void> _showCommunityPlaceOnMap(Map<String, dynamic> place) async {
    final coordinate = LatLng(
      (place['latitude'] as num).toDouble(),
      (place['longitude'] as num).toDouble(),
    );
    final name = place['name']?.toString() ?? 'Topluluk mekânı';
    final address = place['address']?.toString() ?? '';
    setState(() {
      _clearRouteState();
      _selectedDestinationCoordinate = coordinate;
      _selectedDestinationName = name;
      _searchResultName = name;
      _searchController.text = address.isNotEmpty ? address : name;
      _selectedPlaceDetails = {
        ...place,
        'source': 'community_place',
        'category': place['category']?.toString() ?? 'Topluluk mekânı',
      };
      _searchMarkers = [
        Marker(
          markerId: MarkerId('community-place-${place['id']}'),
          position: coordinate,
          anchor: const Offset(0.5, 0.5),
          icon:
              _communityPlaceMarkerIcon ??
              BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueCyan),
          onTap: _showSelectedPlaceActionSheet,
        ),
      ];
      _searchSuggestions = [];
      _showSearchPanel = false;
      _isSearchMode = false;
    });
    await _moveMapTo(coordinate, 17);
    if (mounted) await _showSelectedPlaceActionSheet();
  }

  Future<void> _loadExploreAdminClaim() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    try {
      final token = await user.getIdTokenResult(true);
      if (!mounted || user.uid != FirebaseAuth.instance.currentUser?.uid) {
        return;
      }
      setState(() {
        _canManageExploreHighlights = token.claims?['admin'] == true;
      });
    } catch (error) {
      debugPrint('Keşfet yönetici yetkisi okunamadı: $error');
    }
  }

  Widget _buildLostPetMapToolbar() {
    final hasError = _lostPetReportsError != null;
    final visibleReports = _visibleLostPetReports
        .where(
          (report) =>
              report['collection'] ==
              (_isPetAdoptionMode
                  ? 'pet_adoption_listings'
                  : 'lost_pet_reports'),
        )
        .length;
    final status =
        _lostPetReportsError ??
        (_isLoadingLostPetReports
            ? 'Bildirimler yükleniyor...'
            : visibleReports == 0
            ? _isPetAdoptionMode
                  ? 'Henüz sahiplendirme ilanı yok'
                  : 'Aktif kayıp dost bildirimi yok'
            : _isPetAdoptionMode
            ? '$visibleReports ilan haritada'
            : '$visibleReports aktif bildirim');
    return Container(
      padding: const EdgeInsets.fromLTRB(6, 5, 12, 10),
      decoration: BoxDecoration(
        color: const Color(0xF2171717),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFF55765D)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x55000000),
            blurRadius: 16,
            offset: Offset(0, 5),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              IconButton(
                tooltip: 'Keşfet’e dön',
                onPressed: () => unawaited(_closeLostPetMap()),
                icon: const Icon(Icons.arrow_back_rounded),
                color: Colors.white,
                visualDensity: VisualDensity.compact,
              ),
              Expanded(
                child: Text(
                  _isPetAdoptionMode ? 'Sahiplendirme' : 'Kayıp dostlar',
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: 16,
                  ),
                ),
              ),
              IconButton.filled(
                tooltip: _isPetAdoptionMode
                    ? 'Sahiplendirme ilanı ekle'
                    : 'Kayıp dost bildir',
                onPressed: () => unawaited(
                  _showCreateLostPetReportSheet(isAdoption: _isPetAdoptionMode),
                ),
                icon: const Icon(Icons.add_rounded),
                style: IconButton.styleFrom(
                  backgroundColor: const Color(0xFF55765D),
                  foregroundColor: Colors.white,
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: SegmentedButton<bool>(
              segments: const [
                ButtonSegment(
                  value: false,
                  label: Text('Kayıp / Bulundu', textAlign: TextAlign.center),
                ),
                ButtonSegment(
                  value: true,
                  label: Text('Sahiplendirme', textAlign: TextAlign.center),
                ),
              ],
              selected: {_isPetAdoptionMode},
              showSelectedIcon: false,
              onSelectionChanged: (selection) =>
                  unawaited(_openLostPetMap(adoptionMode: selection.first)),
              style: SegmentedButton.styleFrom(
                foregroundColor: const Color(0xFFD7D7D7),
                selectedForegroundColor: Colors.white,
                selectedBackgroundColor: const Color(0xFF55765D),
                visualDensity: VisualDensity.compact,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 5),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (!hasError && _isLoadingLostPetReports)
                  const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.7,
                      color: Color(0xFFA9C5B0),
                    ),
                  )
                else if (!hasError)
                  const Icon(
                    Icons.location_on_outlined,
                    color: Color(0xFFA9C5B0),
                    size: 15,
                  ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    status,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Color(0xFFD0D0D0),
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPropertyMapToolbar() {
    final selectedType = _activePropertyListingType!;
    final matchingListings = _visiblePropertyListings
        .where((listing) => _matchesPropertyMapFilters(listing, selectedType))
        .length;
    final totalListings = _visiblePropertyListings
        .where((listing) => listing['listing_type'] == selectedType)
        .length;
    final status =
        _propertyListingsError ??
        (_isPropertyListingsLoading
            ? 'İlanlar yükleniyor...'
            : totalListings == 0
            ? 'Bu kategoride henüz ilan yok'
            : matchingListings == 0
            ? 'Filtrelere uygun ilan yok'
            : _propertyFilterCount == 0
            ? '$matchingListings ilan haritada'
            : '$matchingListings / $totalListings ilan haritada');

    return Container(
      padding: const EdgeInsets.fromLTRB(6, 5, 12, 10),
      decoration: BoxDecoration(
        color: const Color(0xF2171717),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0x55FF7A00)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x55000000),
            blurRadius: 16,
            offset: Offset(0, 5),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              IconButton(
                tooltip: 'Keşfet’e dön',
                onPressed: () => unawaited(_closePropertyMap()),
                icon: const Icon(Icons.arrow_back_rounded),
                color: Colors.white,
                visualDensity: VisualDensity.compact,
              ),
              Expanded(
                child: _buildPropertyTypeButton(
                  label: 'Kiralık',
                  type: 'kiralik',
                  selected: selectedType == 'kiralik',
                ),
              ),
              const SizedBox(width: 7),
              Expanded(
                child: _buildPropertyTypeButton(
                  label: 'Satılık',
                  type: 'satilik',
                  selected: selectedType == 'satilik',
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(left: 48, top: 5),
            child: Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: _openPropertyMapFilters,
                icon: const Icon(Icons.tune_rounded, size: 17),
                label: Text(
                  _propertyFilterCount == 0
                      ? 'Filtrele'
                      : 'Filtreler ($_propertyFilterCount)',
                ),
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFFFFB36B),
                  side: const BorderSide(color: Color(0x66FF7A00)),
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 7,
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 48, top: 7),
            child: Row(
              children: [
                if (_isPropertyListingsLoading)
                  const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.7,
                      color: Color(0xFFFF7A00),
                    ),
                  )
                else
                  const Icon(
                    Icons.location_on_outlined,
                    color: Color(0xFFFF9A3D),
                    size: 15,
                  ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    status,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Color(0xFFD0D0D0),
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  int get _propertyFilterCount =>
      _propertyRoomFilters.length +
      (_propertyMinimumPrice == null ? 0 : 1) +
      (_propertyMaximumPrice == null ? 0 : 1) +
      (_propertyCityFilter == null ? 0 : 1) +
      (_propertyDistrictFilter == null ? 0 : 1);

  bool _matchesPropertyMapFilters(
    Map<String, dynamic> listing,
    String listingType,
  ) {
    if (listing['listing_type'] != listingType) return false;
    if (_propertyRoomFilters.isNotEmpty &&
        !_propertyRoomFilters.contains(listing['rooms']?.toString())) {
      return false;
    }

    final price = listing['price'];
    if (price is! num ||
        (_propertyMinimumPrice != null && price < _propertyMinimumPrice!) ||
        (_propertyMaximumPrice != null && price > _propertyMaximumPrice!)) {
      return false;
    }

    if (_propertyCityFilter != null &&
        listing['city']?.toString() != _propertyCityFilter) {
      return false;
    }
    if (_propertyDistrictFilter != null &&
        listing['district']?.toString() != _propertyDistrictFilter) {
      return false;
    }
    return true;
  }

  Future<void> _openPropertyMapFilters() async {
    final minimumPriceController = TextEditingController(
      text: _propertyMinimumPrice?.toString() ?? '',
    );
    final maximumPriceController = TextEditingController(
      text: _propertyMaximumPrice?.toString() ?? '',
    );
    var selectedRooms = Set<String>.from(_propertyRoomFilters);
    var selectedCity = _propertyCityFilter ?? '';
    var selectedDistrict = _propertyDistrictFilter ?? '';
    String? validationMessage;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: false,
      backgroundColor: const Color(0xFF171717),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) {
          final cities =
              _visiblePropertyListings
                  .map((listing) => listing['city']?.toString().trim() ?? '')
                  .where((city) => city.isNotEmpty)
                  .toSet()
                  .toList()
                ..sort();
          if (selectedCity.isNotEmpty && !cities.contains(selectedCity)) {
            cities.add(selectedCity);
          }
          final districts =
              _visiblePropertyListings
                  .where(
                    (listing) =>
                        selectedCity.isEmpty ||
                        listing['city']?.toString().toLowerCase() ==
                            selectedCity.toLowerCase(),
                  )
                  .map(
                    (listing) => listing['district']?.toString().trim() ?? '',
                  )
                  .where((district) => district.isNotEmpty)
                  .toSet()
                  .toList()
                ..sort();
          if (selectedDistrict.isNotEmpty &&
              !districts.contains(selectedDistrict)) {
            districts.add(selectedDistrict);
          }
          if (selectedDistrict.isNotEmpty &&
              !districts.any(
                (district) =>
                    district.toLowerCase() == selectedDistrict.toLowerCase(),
              )) {
            districts.add(selectedDistrict);
          }

          void applyFilters({required bool clear}) {
            final minimum = clear || minimumPriceController.text.isEmpty
                ? null
                : int.tryParse(minimumPriceController.text);
            final maximum = clear || maximumPriceController.text.isEmpty
                ? null
                : int.tryParse(maximumPriceController.text);
            if (!clear &&
                ((minimumPriceController.text.isNotEmpty && minimum == null) ||
                    (maximumPriceController.text.isNotEmpty &&
                        maximum == null))) {
              setSheetState(() {
                validationMessage = 'Geçerli bir fiyat aralığı gir.';
              });
              return;
            }
            if (!clear &&
                minimum != null &&
                maximum != null &&
                minimum > maximum) {
              setSheetState(() {
                validationMessage =
                    'En düşük fiyat en yüksek fiyattan büyük olamaz.';
              });
              return;
            }
            setState(() {
              _propertyRoomFilters
                ..clear()
                ..addAll(clear ? const <String>{} : selectedRooms);
              _propertyMinimumPrice = minimum;
              _propertyMaximumPrice = maximum;
              _propertyCityFilter = clear || selectedCity.isEmpty
                  ? null
                  : selectedCity;
              _propertyDistrictFilter = clear || selectedDistrict.isEmpty
                  ? null
                  : selectedDistrict;
            });
            Navigator.of(sheetContext).pop();
          }

          return SafeArea(
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                20,
                16,
                20,
                16 + MediaQuery.viewInsetsOf(context).bottom,
              ),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Center(
                      child: Container(
                        width: 38,
                        height: 4,
                        decoration: BoxDecoration(
                          color: Colors.white30,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ),
                    const SizedBox(height: 18),
                    const Text(
                      'Konut ilanlarını filtrele',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 18),
                    const Text(
                      'Oda sayısı',
                      style: TextStyle(
                        color: Color(0xFFE0E0E0),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: ['1+0', '1+1', '2+1', '3+1', '4+1', '5+']
                          .map(
                            (room) => FilterChip(
                              label: Text(room),
                              selected: selectedRooms.contains(room),
                              onSelected: (selected) {
                                setSheetState(() {
                                  if (selected) {
                                    selectedRooms.add(room);
                                  } else {
                                    selectedRooms.remove(room);
                                  }
                                  validationMessage = null;
                                });
                              },
                              selectedColor: const Color(0xFFFF7A00),
                              checkmarkColor: Colors.white,
                              labelStyle: TextStyle(
                                color: selectedRooms.contains(room)
                                    ? Colors.white
                                    : const Color(0xFFE0E0E0),
                              ),
                              backgroundColor: const Color(0xFF292929),
                            ),
                          )
                          .toList(),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Fiyat aralığı (TL)',
                      style: TextStyle(
                        color: Color(0xFFE0E0E0),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: minimumPriceController,
                            keyboardType: TextInputType.number,
                            inputFormatters: [
                              FilteringTextInputFormatter.digitsOnly,
                            ],
                            style: const TextStyle(color: Colors.white),
                            decoration: _propertyFilterInputDecoration(
                              'En düşük',
                            ),
                            onChanged: (_) =>
                                setSheetState(() => validationMessage = null),
                          ),
                        ),
                        const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 10),
                          child: Text(
                            '—',
                            style: TextStyle(color: Colors.white70),
                          ),
                        ),
                        Expanded(
                          child: TextField(
                            controller: maximumPriceController,
                            keyboardType: TextInputType.number,
                            inputFormatters: [
                              FilteringTextInputFormatter.digitsOnly,
                            ],
                            style: const TextStyle(color: Colors.white),
                            decoration: _propertyFilterInputDecoration(
                              'En yüksek',
                            ),
                            onChanged: (_) =>
                                setSheetState(() => validationMessage = null),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    _buildPropertyLocationAutocomplete(
                      label: 'İl (yaz veya seç)',
                      initialValue: selectedCity,
                      options: cities,
                      onChanged: (city) {
                        selectedCity = city.trim();
                        selectedDistrict = '';
                        setSheetState(() {});
                      },
                      onSelected: (city) {
                        setSheetState(() {
                          selectedCity = city;
                          selectedDistrict = '';
                        });
                      },
                    ),
                    const SizedBox(height: 12),
                    _buildPropertyLocationAutocomplete(
                      key: ValueKey('property-district-$selectedCity'),
                      label: 'İlçe (yaz veya seç)',
                      initialValue: selectedDistrict,
                      options: districts,
                      onChanged: (district) {
                        selectedDistrict = district.trim();
                      },
                      onSelected: (district) {
                        setSheetState(() => selectedDistrict = district);
                      },
                    ),
                    if (validationMessage != null) ...[
                      const SizedBox(height: 10),
                      Text(
                        validationMessage!,
                        style: const TextStyle(color: Color(0xFFFF8A80)),
                      ),
                    ],
                    const SizedBox(height: 18),
                    Row(
                      children: [
                        TextButton(
                          onPressed: () => applyFilters(clear: true),
                          child: const Text(
                            'Temizle',
                            style: TextStyle(color: Color(0xFFFFB36B)),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: FilledButton(
                            onPressed: () => applyFilters(clear: false),
                            style: FilledButton.styleFrom(
                              backgroundColor: const Color(0xFFFF7A00),
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 13),
                            ),
                            child: const Text('Sonuçları göster'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
    minimumPriceController.dispose();
    maximumPriceController.dispose();
  }

  InputDecoration _propertyFilterInputDecoration(String label) {
    return InputDecoration(
      labelText: label,
      labelStyle: const TextStyle(color: Color(0xFFBDBDBD)),
      filled: true,
      fillColor: const Color(0xFF292929),
      contentPadding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFF444444)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFFFF7A00), width: 1.4),
      ),
    );
  }

  Widget _buildPropertyLocationAutocomplete({
    Key? key,
    required String label,
    required String initialValue,
    required List<String> options,
    required ValueChanged<String> onChanged,
    required ValueChanged<String> onSelected,
  }) {
    return Autocomplete<String>(
      key: key,
      initialValue: TextEditingValue(text: initialValue),
      optionsBuilder: (textEditingValue) {
        final query = textEditingValue.text.trim().toLowerCase();
        if (query.isEmpty) return options;
        return options.where((option) => option.toLowerCase().contains(query));
      },
      onSelected: onSelected,
      optionsViewBuilder: (context, selectOption, matchingOptions) {
        final optionsList = matchingOptions.toList();
        return Align(
          alignment: Alignment.topLeft,
          child: Material(
            elevation: 8,
            color: const Color(0xFF292929),
            borderRadius: BorderRadius.circular(12),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 200),
              child: SizedBox(
                width: MediaQuery.sizeOf(context).width - 40,
                child: ListView.builder(
                  padding: EdgeInsets.zero,
                  shrinkWrap: true,
                  itemCount: optionsList.length,
                  itemBuilder: (context, index) {
                    final option = optionsList[index];
                    return ListTile(
                      dense: true,
                      title: Text(
                        option,
                        style: const TextStyle(color: Colors.white),
                      ),
                      onTap: () => selectOption(option),
                    );
                  },
                ),
              ),
            ),
          ),
        );
      },
      fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) =>
          TextField(
            controller: controller,
            focusNode: focusNode,
            onChanged: onChanged,
            onSubmitted: (_) => onFieldSubmitted(),
            style: const TextStyle(color: Colors.white),
            decoration: _propertyFilterInputDecoration(label),
          ),
    );
  }

  Widget _buildPropertyTypeButton({
    required String label,
    required String type,
    required bool selected,
  }) {
    return Material(
      color: selected ? const Color(0xFFFF7A00) : const Color(0xFF292929),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: selected ? null : () => unawaited(_openPropertyMap(type)),
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          height: 38,
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                color: selected ? Colors.white : const Color(0xFFCBCBCB),
                fontWeight: FontWeight.w700,
                fontSize: 13,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMapPage() {
    final roomGlowCircles = <Circle>{};
    final navigationEndpointMarkers =
        !_isNavigationActive ||
            _routePolylines.isEmpty ||
            _routePolylines.first.points.length < 2 ||
            _navigationEndpointMarkerIcon == null
        ? <Marker>[]
        : [
            Marker(
              markerId: const MarkerId('navigation-route-start'),
              position:
                  _navigationStartPosition ??
                  _routePolylines.first.points.first,
              icon: _navigationEndpointMarkerIcon!,
              anchor: const Offset(0.5, 0.5),
              zIndexInt: 1000,
            ),
            Marker(
              markerId: const MarkerId('navigation-route-end'),
              position: _routePolylines.first.points.last,
              icon:
                  _navigationDestinationMarkerIcon ??
                  _navigationEndpointMarkerIcon!,
              anchor: const Offset(0.5, 0.5),
              zIndexInt: 1000,
            ),
          ];
    final mapItems = <Map<String, dynamic>>[];
    void addMapItem(String type, Map<String, dynamic> data, String id) {
      mapItems.add({
        'id': id,
        'type': type,
        'data': data,
        'latitude': data['latitude'],
        'longitude': data['longitude'],
      });
    }

    if (_isMapLayerVisible('rooms')) {
      for (final room in _visibleRooms) {
        addMapItem('room', room, 'room-${room['id'] ?? room['name']}');
      }
    }
    if (_isMapLayerVisible('community')) {
      for (final place in _visibleCommunityPlaces) {
        addMapItem('community', place, 'community-place-${place['id']}');
      }
    }
    for (final report in _visibleLostPetReports) {
      final isAdoption = report['collection'] == 'pet_adoption_listings';
      if (_isMapLayerVisible(isAdoption ? 'adoptions' : 'lostPets')) {
        addMapItem(
          'pet',
          report,
          '${isAdoption ? 'adoption' : 'lost-pet'}-${report['id']}',
        );
      }
    }
    if (_isMapLayerVisible('properties')) {
      for (final listing in _visiblePropertyListings) {
        if (_activePropertyListingType == null ||
            _matchesPropertyMapFilters(listing, _activePropertyListingType!)) {
          addMapItem('property', listing, 'property-${listing['id']}');
        }
      }
    }

    final roomZoom = _mapCameraPosition?.zoom ?? 11.5;
    final mapClusters = navoraClusterMapItems(mapItems, zoom: roomZoom);
    final mapContentMarkers = <Marker>[];
    for (final cluster in mapClusters) {
      if (cluster.length > 1) {
        final center = _mapClusterCenter(cluster);
        final categoryCounts = <String, int>{};
        for (final item in cluster) {
          final label = switch (item['type']) {
            'room' => 'sohbet odası',
            'property' => 'emlak ilanı',
            'pet' => 'hayvan ilanı',
            'community' => 'mekân',
            _ => 'öğe',
          };
          categoryCounts.update(label, (count) => count + 1, ifAbsent: () => 1);
        }
        final summary = categoryCounts.entries
            .map((entry) => '${entry.value} ${entry.key}')
            .join(' • ');
        mapContentMarkers.add(
          Marker(
            markerId: MarkerId(
              'map-cluster-${cluster.map((item) => item['id']).join('-')}',
            ),
            position: center,
            icon: _mapClusterMarkerIconForCount(cluster.length),
            infoWindow: InfoWindow(
              title: '${cluster.length} içerik',
              snippet: summary,
            ),
            onTap: () => _zoomToMapCluster(center),
            zIndexInt: 100,
          ),
        );
        continue;
      }

      final item = cluster.single;
      final data = Map<String, dynamic>.from(item['data'] as Map);
      final latitude = (item['latitude'] as num).toDouble();
      final longitude = (item['longitude'] as num).toDouble();
      final position = LatLng(latitude, longitude);
      final marker = switch (item['type']) {
        'room' =>
          _chatRoomMarkerIcon == null
              ? null
              : Marker(
                  markerId: MarkerId(item['id'] as String),
                  position: position,
                  icon: _roomMarkerIconForCount(
                    (data['activeUsersCount'] as num?)?.toInt() ?? 1,
                  ),
                  infoWindow: InfoWindow(
                    title: data['name']?.toString() ?? 'Sohbet Odası',
                    snippet:
                        '${(data['activeUsersCount'] as num?)?.toInt() ?? 1} kişi aktif',
                  ),
                  onTap: () => _showRoomMarkerDialog(data),
                ),
        'community' => Marker(
          markerId: MarkerId(item['id'] as String),
          position: position,
          anchor: const Offset(0.5, 0.5),
          icon:
              _communityPlaceMarkerIcon ??
              BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueCyan),
          onTap: () => _showCommunityPlaceOnMap(data),
        ),
        'pet' => _buildPetMapMarker(data, item['id'] as String, position),
        'property' => _buildPropertyMapMarker(
          data,
          item['id'] as String,
          position,
        ),
        _ => null,
      };
      if (marker != null) mapContentMarkers.add(marker);
    }

    final mapMarkers = <Marker>{..._searchMarkers, ...mapContentMarkers};
    mapMarkers.addAll(navigationEndpointMarkers);

    return Listener(
      onPointerDown: (event) => _activeMapPointers.add(event.pointer),
      onPointerUp: (event) => _activeMapPointers.remove(event.pointer),
      onPointerCancel: (event) => _activeMapPointers.remove(event.pointer),
      child: Stack(
        fit: StackFit.expand,
        children: [
          GoogleMap(
            initialCameraPosition: const CameraPosition(
              target: LatLng(41.0082, 28.9784),
              zoom: 11.5,
            ),
            cameraTargetBounds: CameraTargetBounds(
              LatLngBounds(
                southwest: LatLng(35.8, 25.6),
                northeast: LatLng(42.2, 44.8),
              ),
            ),
            minMaxZoomPreference: const MinMaxZoomPreference(5.5, 20),
            style: _darkGoogleMapStyle,
            mapType: _mapType,
            trafficEnabled: false,
            myLocationEnabled: _locationPermissionGranted,
            myLocationButtonEnabled: false,
            zoomControlsEnabled: false,
            compassEnabled: false,
            markers: mapMarkers,
            circles: roomGlowCircles,
            polylines: {
              ..._alternativeRoutePolylines,
              ..._routePolylines.map(
                (route) => Polyline(
                  polylineId: route.polylineId,
                  points: route.points,
                  color: route.color,
                  width: route.width,
                  zIndex: route.zIndex + 11,
                ),
              ),
              if (_isNavigationActive)
                ..._navigationTrafficPolylines.map(
                  (route) => Polyline(
                    polylineId: route.polylineId,
                    points: route.points,
                    color: route.color,
                    width: route.width,
                    zIndex: route.zIndex + 20,
                  ),
                ),
            },
            onMapCreated: (controller) {
              _mapController = controller;
              if (!_isMapLoaded) {
                _scheduleMapLoadingFallback(const Duration(seconds: 5));
              }
              final currentPosition = _currentPosition;
              if (currentPosition != null) {
                unawaited(_centerOnPosition(currentPosition));
              }
            },
            onTap: _handleRouteMapTap,
            onLongPress: _selectMapLocation,
            onCameraMoveStarted: () {
              if (_isProgrammaticCameraMove ||
                  _activeMapPointers.isEmpty ||
                  !_isFollowingCurrentPosition) {
                return;
              }
              if (mounted) {
                setState(() => _isFollowingCurrentPosition = false);
              }
            },
            onCameraMove: (cameraPosition) {
              _mapCameraPosition = cameraPosition;
            },
            onCameraIdle: () {
              _finishMapLoading();
              final zoom = _mapCameraPosition?.zoom ?? 11.5;
              if (_lastClusteredMapZoom != zoom && mounted) {
                _lastClusteredMapZoom = zoom;
                setState(() {});
              }
            },
          ),
        ],
      ),
    );
  }

  void _showRoomMarkerDialog(Map<String, dynamic> room) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF171717),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 22, 20, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF2A180D),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(
                    room['icon'] as IconData,
                    color: const Color(0xFFFF6B00),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    room['name'] as String,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close_rounded, color: Colors.white70),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              '${room['activeUsers']} • Konum sohbet odası',
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              height: 46,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFFF6B00),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                icon: const Icon(Icons.forum_rounded, color: Colors.white),
                label: const Text(
                  'Sohbete Git',
                  style: TextStyle(color: Colors.white),
                ),
                onPressed: () {
                  Navigator.pop(context);
                  if (FirebaseAuth.instance.currentUser == null) {
                    _showTrackingMessage(
                      'Sohbete katılmak için giriş yapmalısınız.',
                    );
                    return;
                  }
                  if (room['isProtected'] == true &&
                      !_canManageExploreHighlights) {
                    unawaited(_showPasswordPromptDialog(room));
                  } else {
                    unawaited(_openRoomChat(room));
                  }
                },
              ),
            ),
            if (room['ownerId'] == FirebaseAuth.instance.currentUser?.uid ||
                _canManageExploreHighlights) ...[
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                height: 44,
                child: OutlinedButton.icon(
                  onPressed: () {
                    Navigator.pop(context);
                    _deleteRoom(room);
                  },
                  icon: const Icon(Icons.delete_outline_rounded),
                  label: const Text('Odayı yönet ve sil'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFFFF7A00),
                    side: const BorderSide(color: Color(0xFFFF7A00)),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _mapLoadingTimer?.cancel();
    unawaited(_updateScreenWakeLock(forceEnabled: false));
    _publicChatScrollController.dispose();
    _searchController.dispose();
    _roomSearchController.dispose();
    _searchFocusNode.dispose();
    _searchDebounce?.cancel();
    _speech.stop();
    _communityPlacesSubscription?.cancel();
    _roomsSubscription?.cancel();
    _mapPropertyListingsSubscription?.cancel();
    _mapLostPetReportsSubscription?.cancel();
    _mapAdoptionListingsSubscription?.cancel();
    _publicChatSubscription?.cancel();
    _blockedUsersSubscription?.cancel();
    _searchHistorySubscription?.cancel();
    _aiChatsSubscription?.cancel();
    _dailyQuotaSubscription?.cancel();
    _userProfileSubscription?.cancel();
    _savedRoutesSubscription?.cancel();
    _savedAddressesSubscription?.cancel();
    _drivingHistorySubscription?.cancel();
    _routeHistorySubscription?.cancel();
    _roomExpiryTimer?.cancel();
    _navigationConnectivityTimer?.cancel();
    _navigationCameraUpdateTimer?.cancel();
    _positionSubscription?.cancel();
    _locationPositionSubscription?.cancel();
    _accelerometerSubscription?.cancel();
    _magnetometerSubscription?.cancel();
    _compassCameraUpdateTimer?.cancel();
    super.dispose();
  }

  Widget _buildAiPage() {
    final keyboardInset = MediaQuery.of(context).viewInsets.bottom;
    final bottomSafeInset = MediaQuery.viewPaddingOf(context).bottom;
    return Padding(
      padding: EdgeInsets.only(
        bottom: keyboardInset > 0
            ? 0
            : bottomSafeInset +
                  _bottomNavigationBarHeight +
                  _bottomNavigationGap,
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFFFF6B00),
              borderRadius: const BorderRadius.vertical(
                bottom: Radius.circular(20),
              ),
            ),
            child: Row(
              children: [
                const Icon(Icons.auto_awesome, color: Colors.white, size: 28),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text(
                    'Navora AI Asistanı',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 7,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.18),
                    ),
                  ),
                  child: Text(
                    _isProUser ? 'Sınırsız' : '$_aiQueriesRemaining hak',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.17),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.25),
                    ),
                  ),
                  child: IconButton(
                    tooltip: 'Sohbeti temizle',
                    padding: EdgeInsets.zero,
                    onPressed: _isAiResponding || _isClearingAiChats
                        ? null
                        : _clearAiConversation,
                    icon: _isClearingAiChats
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(
                            Icons.delete_sweep_rounded,
                            color: Colors.white,
                            size: 21,
                          ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: _aiMessages.length,
              itemBuilder: (context, index) {
                final msg = _aiMessages[index];
                final isAi = msg['sender'] == 'ai';
                return Align(
                  alignment: isAi
                      ? Alignment.centerLeft
                      : Alignment.centerRight,
                  child: Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: isAi
                          ? const Color(0xFF1B1B1B)
                          : const Color(0xFFFF6B00),
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.05),
                          blurRadius: 5,
                        ),
                      ],
                    ),
                    child: Text(
                      msg['text']!,
                      style: TextStyle(color: Colors.white, fontSize: 14),
                    ),
                  ),
                );
              },
            ),
          ),
          AnimatedPadding(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(context).viewInsets.bottom,
            ),
            child: Container(
              margin: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFF111111),
                borderRadius: BorderRadius.circular(26),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.28),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _aiController,
                      style: const TextStyle(
                        color: Color(0xFFBDBDBD),
                        fontSize: 14,
                      ),
                      decoration: InputDecoration(
                        hintText: 'Yapay zekaya sor...',
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
                          horizontal: 18,
                          vertical: 12,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  CircleAvatar(
                    radius: 22,
                    backgroundColor: const Color(0xFFFF6B00),
                    child: IconButton(
                      splashRadius: 20,
                      icon: const Icon(
                        Icons.send,
                        color: Colors.white,
                        size: 18,
                      ),
                      onPressed: _sendAiMessage,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // --- SOHBET SAYFASI ---
  Widget _buildChatPage() {
    final keyboardInset = MediaQuery.of(context).viewInsets.bottom;
    final bottomSafeInset = MediaQuery.viewPaddingOf(context).bottom;
    return Padding(
      padding: EdgeInsets.only(
        bottom: keyboardInset > 0
            ? 0
            : bottomSafeInset +
                  _bottomNavigationBarHeight +
                  _bottomNavigationGap,
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFFFF6B00),
              borderRadius: const BorderRadius.vertical(
                bottom: Radius.circular(20),
              ),
            ),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Row(
                        children: [
                          const Icon(
                            Icons.forum,
                            color: Colors.white,
                            size: 28,
                          ),
                          const SizedBox(width: 12),
                          Flexible(
                            child: Text(
                              _chatSubTab == 0
                                  ? 'Genel Sohbet'
                                  : 'Sohbet Odaları',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_chatSubTab == 0 && _canManageExploreHighlights)
                          IconButton(
                            tooltip: 'Genel sohbeti sıfırla',
                            onPressed: _isResettingPublicChat
                                ? null
                                : _resetPublicChat,
                            icon: _isResettingPublicChat
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                : const Icon(
                                    Icons.delete_sweep_rounded,
                                    color: Colors.white,
                                  ),
                          ),
                        if (_chatSubTab == 1)
                          SizedBox(
                            width: 36,
                            height: 36,
                            child: IconButton(
                              tooltip: 'Yeni sohbet odası aç',
                              onPressed: _showCreateRoomDialog,
                              padding: EdgeInsets.zero,
                              style: IconButton.styleFrom(
                                backgroundColor: Colors.white,
                                foregroundColor: const Color(0xFFFF6B00),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10),
                                ),
                              ),
                              icon: const Icon(Icons.add_rounded, size: 22),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: GestureDetector(
                        onTap: () => setState(() => _chatSubTab = 0),
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          decoration: BoxDecoration(
                            color: _chatSubTab == 0
                                ? Colors.white
                                : Colors.white.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            'Genel Sohbet',
                            style: TextStyle(
                              color: _chatSubTab == 0
                                  ? const Color(0xFFFF6B00)
                                  : Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: GestureDetector(
                        onTap: () => setState(() => _chatSubTab = 1),
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          decoration: BoxDecoration(
                            color: _chatSubTab == 1
                                ? Colors.white
                                : Colors.white.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            'Sohbet Odaları',
                            style: TextStyle(
                              color: _chatSubTab == 1
                                  ? const Color(0xFFFF6B00)
                                  : Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          Expanded(
            child: _chatSubTab == 0
                ? Stack(
                    children: [
                      _buildPublicFeedList(),
                      if (_showPublicChatScrollToBottom)
                        Positioned(
                          right: 16,
                          bottom: 16,
                          child: FloatingActionButton.small(
                            heroTag: 'public-chat-scroll-bottom',
                            backgroundColor: const Color(0xFFFF6B00),
                            foregroundColor: Colors.white,
                            onPressed: _scrollPublicChatToBottom,
                            child: const Icon(
                              Icons.keyboard_arrow_down_rounded,
                            ),
                          ),
                        ),
                    ],
                  )
                : _buildRoomsList(),
          ),

          if (_chatSubTab == 0)
            AnimatedPadding(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOut,
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).viewInsets.bottom,
              ),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16.0,
                  vertical: 8.0,
                ),
                color: const Color(0xFF111111),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 120),
                        child: TextField(
                          controller: _chatController,
                          minLines: 1,
                          maxLines: 4,
                          textInputAction: TextInputAction.newline,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                          ),
                          decoration: InputDecoration(
                            hintText: 'Genel sohbete mesaj yaz...',
                            hintStyle: const TextStyle(
                              color: Color(0xFFBDBDBD),
                              fontSize: 14,
                            ),
                            filled: true,
                            fillColor: const Color(0xFF191919),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(25),
                              borderSide: BorderSide.none,
                            ),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 18,
                              vertical: 12,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    CircleAvatar(
                      radius: 22,
                      backgroundColor: const Color(0xFFFF6B00),
                      child: IconButton(
                        splashRadius: 20,
                        icon: const Icon(
                          Icons.send,
                          color: Colors.white,
                          size: 18,
                        ),
                        onPressed: _sendPublicChatMessage,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildPublicFeedList() {
    final visibleMessages = _visiblePublicFeedMessages;
    return ListView.builder(
      controller: _publicChatScrollController,
      padding: const EdgeInsets.all(16),
      itemCount: visibleMessages.length,
      itemBuilder: (context, index) {
        final msg = visibleMessages[index];
        final senderName = msg['sender']?.toString() ?? '';
        final senderId = msg['senderId']?.toString() ?? '';
        final messageId = msg['_document_id']?.toString() ?? '';
        final currentUserId = FirebaseAuth.instance.currentUser?.uid;
        final distanceText = msg['distance']?.toString();
        return Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: const Color(0xFF1B1B1B),
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.5),
                blurRadius: 6,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  const CircleAvatar(
                    radius: 14,
                    backgroundColor: Color(0xFF2A180D),
                    child: Icon(
                      Icons.person,
                      size: 16,
                      color: Color(0xFFFF6B00),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Row(
                      children: [
                        Text(
                          senderName,
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Color(0xFFFF6B00),
                            fontSize: 13,
                          ),
                        ),
                        if (distanceText != null &&
                            distanceText.trim().isNotEmpty) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFF242424),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              distanceText,
                              style: TextStyle(
                                fontSize: 10,
                                color: Colors.grey.shade600,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width:
                        currentUserId != null &&
                            senderId != currentUserId &&
                            messageId.isNotEmpty
                        ? 72
                        : 32,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Text(
                          msg['time']!,
                          style: TextStyle(
                            color: Colors.grey.shade500,
                            fontSize: 11,
                          ),
                        ),
                        if (currentUserId != null &&
                            senderId != currentUserId &&
                            messageId.isNotEmpty) ...[
                          const SizedBox(width: 2),
                          IconButton(
                            tooltip: 'Mesaj seçenekleri',
                            padding: EdgeInsets.zero,
                            visualDensity: VisualDensity.compact,
                            constraints: const BoxConstraints.tightFor(
                              width: 32,
                              height: 32,
                            ),
                            icon: const Icon(
                              Icons.more_vert,
                              color: Color(0xFF8D8D8D),
                              size: 20,
                            ),
                            onPressed: () {
                              showModalBottomSheet<void>(
                                context: context,
                                builder: (sheetContext) => SafeArea(
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      ListTile(
                                        leading: const Icon(
                                          Icons.flag_outlined,
                                        ),
                                        title: const Text('Şikayet et'),
                                        onTap: () {
                                          Navigator.pop(sheetContext);
                                          unawaited(
                                            _reportPublicChatMessage(msg),
                                          );
                                        },
                                      ),
                                      ListTile(
                                        leading: const Icon(
                                          Icons.block_rounded,
                                        ),
                                        title: const Text(
                                          'Kullanıcıyı engelle',
                                        ),
                                        onTap: () {
                                          Navigator.pop(sheetContext);
                                          unawaited(
                                            _blockUser(senderId, senderName),
                                          );
                                        },
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                msg['text']!,
                style: const TextStyle(color: Colors.white, fontSize: 13),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildRoomsList() {
    final search = _roomSearchController.text.trim().toLowerCase();
    final roomsToDisplay =
        _visibleRooms.where((room) {
          final matchesSearch =
              search.isEmpty ||
              '${room['name']} ${room['type']} ${room['category']}'
                  .toLowerCase()
                  .contains(search);
          return matchesSearch;
        }).toList()..sort((first, second) {
          final firstDistance = _roomDistanceInMeters(first);
          final secondDistance = _roomDistanceInMeters(second);
          final distanceComparison = (firstDistance ?? double.infinity)
              .compareTo(secondDistance ?? double.infinity);

          if (distanceComparison != 0) {
            return distanceComparison;
          }

          final firstTime = first['updatedAt'] as DateTime?;
          final secondTime = second['updatedAt'] as DateTime?;
          return (secondTime ?? DateTime.fromMillisecondsSinceEpoch(0))
              .compareTo(firstTime ?? DateTime.fromMillisecondsSinceEpoch(0));
        });
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        TextField(
          controller: _roomSearchController,
          onChanged: (_) => setState(() {}),
          style: const TextStyle(color: Colors.white, fontSize: 14),
          decoration: InputDecoration(
            hintText: 'Oda arayın',
            hintStyle: const TextStyle(color: Color(0xFFBDBDBD), fontSize: 14),
            prefixIcon: const Icon(
              Icons.search_rounded,
              color: Color(0xFFFF6B00),
            ),
            suffixIcon: _roomSearchController.text.isEmpty
                ? null
                : IconButton(
                    tooltip: 'Temizle',
                    onPressed: () {
                      _roomSearchController.clear();
                      setState(() {});
                    },
                    icon: const Icon(
                      Icons.close_rounded,
                      color: Colors.white70,
                    ),
                  ),
            filled: true,
            fillColor: const Color(0xFF191919),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: BorderSide.none,
            ),
          ),
        ),
        const SizedBox(height: 12),
        // --- 1. GENEL SOHBET ODASI (YAKINDAKİLERDEN HARİÇ, HERKES) ---
        if (_chatSubTab < 0)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Material(
              color: const Color(0xFFFF6B00),
              borderRadius: BorderRadius.circular(16),
              elevation: 5,
              shadowColor: const Color(0xFFFF6B00),
              child: ExpansionTile(
                collapsedIconColor: Colors.white,
                iconColor: Colors.white,
                leading: const CircleAvatar(
                  backgroundColor: Color(0xFF191919),
                  child: Icon(Icons.public, color: Color(0xFFFF6B00)),
                ),
                title: const Text(
                  'Yakındaki Herkes',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                    color: Colors.white,
                  ),
                ),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 2),
                    const Text(
                      'Konumunu paylaşan yakındaki kullanıcılar',
                      style: TextStyle(fontSize: 11, color: Colors.white70),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        const Icon(
                          Icons.group,
                          size: 12,
                          color: Colors.amberAccent,
                        ),
                        const SizedBox(width: 4),
                        const Text(
                          'Yakındaki canlı akış',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: Colors.amberAccent,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                children: [
                  const Divider(height: 1, color: Colors.white24),
                  Container(
                    padding: const EdgeInsets.all(12),
                    color: const Color(0xFF151515),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Yakındaki kişilerden son mesajlar:',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: Colors.grey,
                          ),
                        ),
                        const SizedBox(height: 8),
                        ..._visiblePublicFeedMessages
                            .take(4)
                            .map(
                              (m) => Container(
                                margin: const EdgeInsets.only(bottom: 6),
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF202020),
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(
                                    color: const Color(0xFF363636),
                                  ),
                                ),
                                child: Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    Expanded(
                                      child: Text(
                                        '${m['sender']}: ${m['text']}',
                                        style: const TextStyle(fontSize: 12),
                                      ),
                                    ),
                                    Text(
                                      m['time'],
                                      style: TextStyle(
                                        fontSize: 10,
                                        color: Colors.grey.shade400,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),

        const Padding(
          padding: EdgeInsets.symmetric(vertical: 4),
          child: Text(
            'Yakındaki Sohbet Odaları',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              color: Colors.grey,
            ),
          ),
        ),
        const SizedBox(height: 8),

        // --- 2. YAKINDAKİ DİĞER ÖZEL ODALAR ---
        if (roomsToDisplay.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: const Color(0xFF1B1B1B),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFF363636)),
            ),
            child: Column(
              children: [
                Icon(
                  Icons.forum_outlined,
                  color: Colors.grey.shade400,
                  size: 30,
                ),
                const SizedBox(height: 8),
                const Text(
                  'Henüz yakındaki bir oda yok.',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                Text(
                  'İlk odayı açan kişi sen olabilirsin.',
                  style: const TextStyle(
                    color: Color(0xFFB8B8B8),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ...roomsToDisplay.asMap().entries.map((entry) {
          final room = entry.value;
          final bool isProtected = room['isProtected'] ?? false;
          return Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Material(
              color: const Color(0xFF1B1B1B),
              borderRadius: BorderRadius.circular(18),
              elevation: 2,
              shadowColor: const Color(0xFFFF6B00).withValues(alpha: 0.18),
              child: ExpansionTile(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18),
                ),
                collapsedShape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18),
                ),
                backgroundColor: const Color(0xFF1B1B1B),
                collapsedBackgroundColor: const Color(0xFF1B1B1B),
                tilePadding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 4,
                ),
                childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
                iconColor: const Color(0xFFFF6B00),
                collapsedIconColor: const Color(0xFFFF6B00),
                leading: CircleAvatar(
                  backgroundColor: const Color(0xFF2A180D),
                  child: Icon(
                    room['icon'] as IconData,
                    color: const Color(0xFFFF6B00),
                  ),
                ),
                title: Row(
                  children: [
                    if (isProtected)
                      const Padding(
                        padding: EdgeInsets.only(right: 6),
                        child: Icon(
                          Icons.lock_rounded,
                          size: 16,
                          color: Color(0xFFFFD77A),
                        ),
                      ),
                    Expanded(
                      child: Text(
                        room['name'] as String,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ],
                ),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Icon(
                          Icons.near_me,
                          size: 12,
                          color: const Color(0xFFFF8A3D),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          room['distance'] as String,
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFFFF8A3D),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '• ${room['activeUsersCount']} kişi',
                          style: TextStyle(
                            fontSize: 11,
                            color: Colors.grey.shade500,
                          ),
                        ),
                      ],
                    ),
                    if (room['updatedAt'] is DateTime)
                      Text(
                        'Güncellendi: ${_formatChatTime(room['updatedAt'] as DateTime)}',
                        style: TextStyle(
                          fontSize: 10,
                          color: Colors.grey.shade500,
                        ),
                      ),
                  ],
                ),
                onExpansionChanged: (expanded) {
                  // Oda kartına tıklanması sadece genişletme amaçlıdır; giriş burada yapılmaz.
                  // Giriş işlemi sadece açık "Odaya katıl" butonundan yapılır.
                  return;
                },
                children: [
                  if (!isProtected) ...[
                    Divider(
                      height: 1,
                      color: Colors.white.withValues(alpha: 0.08),
                    ),
                    const Padding(
                      padding: EdgeInsets.all(12),
                      child: Text(
                        'Canlı mesajları görmek için odaya katılın.',
                        style: TextStyle(
                          fontSize: 12,
                          color: Color(0xFFB8B8B8),
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 6),
                  SizedBox(
                    width: double.infinity,
                    height: 38,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFFF6B00),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      onPressed: () {
                        if (FirebaseAuth.instance.currentUser == null) {
                          _showTrackingMessage(
                            'Odaya katılmak için giriş yapmalısınız.',
                          );
                          return;
                        }
                        if (isProtected && !_canManageExploreHighlights) {
                          unawaited(_showPasswordPromptDialog(room));
                        } else {
                          unawaited(_openRoomChat(room));
                        }
                      },
                      child: Text(
                        isProtected && !_canManageExploreHighlights
                            ? 'Şifre ile odaya katıl'
                            : _canManageExploreHighlights
                            ? 'Yönetici olarak odaya gir'
                            : 'Odaya katıl ve mesaj yaz',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        }),
      ],
    );
  }

  // Sohbet Odası Oluşturma Mantığı & Modalı
  void _showCreateRoomDialog() {
    if (FirebaseAuth.instance.currentUser == null) {
      _showTrackingMessage('Oda açmak için giriş yapmalısınız.');
      return;
    }
    final roomLimit = _isProUser ? _proRoomLimit : _dailyRoomLimit;
    if (!_canManageExploreHighlights && _roomsCreatedToday >= roomLimit) {
      _showProUpgradeModal();
      return;
    }

    final TextEditingController roomNameController = TextEditingController();
    final TextEditingController roomPassController = TextEditingController();
    bool requiresPassword = false;
    bool showPassword = false;
    bool isCreating = false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF111111),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) => Padding(
          padding: EdgeInsets.only(
            top: 20,
            left: 20,
            right: 20,
            bottom: MediaQuery.of(context).viewInsets.bottom + 20,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Yeni Sohbet Odası Aç',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(
                      Icons.close_rounded,
                      color: Color(0xFFFF6B00),
                    ),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFF1A140D),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: const Color(0xFFFF8A3D).withValues(alpha: 0.45),
                  ),
                ),
                child: Text(
                  _canManageExploreHighlights
                      ? 'Yönetici hesabı: sınırsız oda açma'
                      : _isProUser
                      ? '✨ Navora Pro günlük oda hakkı: $_roomsCreatedToday / $_proRoomLimit'
                      : 'Günlük oda hakkı: $_roomsCreatedToday / $_dailyRoomLimit',
                  style: TextStyle(
                    fontSize: 12,
                    color: _isProUser
                        ? const Color(0xFFFFD4A6)
                        : Colors.grey.shade400,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: roomNameController,
                style: const TextStyle(color: Colors.white, fontSize: 14),
                decoration: InputDecoration(
                  labelText: 'Oda Adı / Mekan Adı',
                  labelStyle: const TextStyle(color: Color(0xFFBDBDBD)),
                  hintStyle: const TextStyle(color: Color(0xFFBDBDBD)),
                  prefixIcon: const Icon(
                    Icons.meeting_room,
                    color: Color(0xFFFF6B00),
                  ),
                  filled: true,
                  fillColor: const Color(0xFF191919),
                  helperText: 'En az $navoraMinimumRoomPasswordLength karakter',
                  helperStyle: const TextStyle(
                    color: Color(0xFF8F8F8F),
                    fontSize: 11,
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide(color: const Color(0xFF2B2B2B)),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide(color: const Color(0xFFFF6B00)),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                decoration: BoxDecoration(
                  color: const Color(0xFF191919),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: const Color(0xFF2B2B2B)),
                ),
                child: Material(
                  color: Colors.transparent,
                  child: SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text(
                      'Şifreli Oda Olsun mu?',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                    subtitle: const Text(
                      'Sadece şifreyi bilenler katılabilir',
                      style: TextStyle(fontSize: 11, color: Color(0xFFBDBDBD)),
                    ),
                    value: requiresPassword,
                    activeTrackColor: const Color(0xFFFF6B00),
                    activeThumbColor: Colors.white,
                    inactiveThumbColor: const Color(0xFFBDBDBD),
                    inactiveTrackColor: const Color(0xFF2B2B2B),
                    onChanged: (val) {
                      setModalState(() {
                        requiresPassword = val;
                      });
                    },
                  ),
                ),
              ),
              if (requiresPassword) ...[
                const SizedBox(height: 12),
                TextField(
                  controller: roomPassController,
                  obscureText: !showPassword,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                  decoration: InputDecoration(
                    labelText: 'Oda Şifresi',
                    labelStyle: const TextStyle(color: Color(0xFFBDBDBD)),
                    hintStyle: const TextStyle(color: Color(0xFFBDBDBD)),
                    prefixIcon: const Icon(
                      Icons.lock_outline,
                      color: Color(0xFFFF6B00),
                    ),
                    suffixIcon: IconButton(
                      onPressed: () {
                        setModalState(() {
                          showPassword = !showPassword;
                        });
                      },
                      icon: Icon(
                        showPassword
                            ? Icons.visibility_off_rounded
                            : Icons.visibility_rounded,
                        color: const Color(0xFFFF6B00),
                      ),
                    ),
                    filled: true,
                    fillColor: const Color(0xFF191919),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide(color: const Color(0xFF2B2B2B)),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide(color: const Color(0xFFFF6B00)),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFFF6B00),
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  onPressed: isCreating
                      ? null
                      : () async {
                          if (roomNameController.text.trim().isEmpty) {
                            AppNotificationService.show(
                              'Lütfen oda adını girin.',
                            );
                            return;
                          }

                          final position = _currentPosition;
                          if (position == null) {
                            AppNotificationService.show(
                              'Odayı haritada göstermek için konumunuz gerekli.',
                            );
                            return;
                          }

                          final user = FirebaseAuth.instance.currentUser;
                          if (user == null) {
                            _showTrackingMessage(
                              'Oda oluşturmak için önce hesabına giriş yap.',
                            );
                            return;
                          }
                          final password = roomPassController.text.trim();
                          if (requiresPassword &&
                              password.length <
                                  navoraMinimumRoomPasswordLength) {
                            _showTrackingMessage(
                              'Oda şifresi en az '
                              '$navoraMinimumRoomPasswordLength karakter olmalı.',
                            );
                            return;
                          }

                          setModalState(() => isCreating = true);
                          final expiresAt = DateTime.now().add(
                            _chatRoomLifetime,
                          );
                          String? quotaReservationId;
                          var quotaReserved = false;
                          try {
                            final roomReference = FirebaseFirestore.instance
                                .collection('chat_rooms')
                                .doc();
                            quotaReservationId = roomReference.id;
                            final listingReference = FirebaseFirestore.instance
                                .collection('chat_room_listings')
                                .doc(roomReference.id);
                            final salt = requiresPassword
                                ? navoraGenerateRoomPasswordSalt()
                                : '';
                            final passwordHash = requiresPassword
                                ? await navoraHashRoomPassword(password, salt)
                                : null;
                            await _reserveDailyQuota('room', roomReference.id);
                            quotaReserved = true;
                            final batch = FirebaseFirestore.instance.batch();
                            batch.set(roomReference, {
                              'schema_version': 2,
                              'owner_id': user.uid,
                              'name': roomNameController.text.trim(),
                              'type': 'Sohbet Odası',
                              'active_users': '1 kişi aktif',
                              'active_users_count': 1,
                              'member_ids': <String>[user.uid],
                              'moderator_ids': <String>[],
                              'latitude': position.latitude,
                              'longitude': position.longitude,
                              'is_protected': requiresPassword,
                              'password_salt': salt,
                              'created_at': FieldValue.serverTimestamp(),
                              'updated_at': FieldValue.serverTimestamp(),
                              'expires_at': Timestamp.fromDate(expiresAt),
                              'max_users': 50,
                            });
                            batch.set(listingReference, {
                              'owner_id': user.uid,
                              'name': roomNameController.text.trim(),
                              'type': 'Sohbet Odası',
                              'active_users': '1 kişi aktif',
                              'active_users_count': 1,
                              'latitude': position.latitude,
                              'longitude': position.longitude,
                              'is_protected': requiresPassword,
                              'password_salt': salt,
                              'created_at': FieldValue.serverTimestamp(),
                              'updated_at': FieldValue.serverTimestamp(),
                              'expires_at': Timestamp.fromDate(expiresAt),
                              'max_users': 50,
                            });
                            batch.set(
                              roomReference.collection('members').doc(user.uid),
                              {
                                'password_hash': passwordHash ?? '',
                                'joined_at': FieldValue.serverTimestamp(),
                              },
                            );
                            if (passwordHash != null) {
                              batch.set(
                                roomReference
                                    .collection('private')
                                    .doc('access'),
                                {
                                  'password_hash': passwordHash,
                                  'updated_at': FieldValue.serverTimestamp(),
                                },
                              );
                            }
                            await batch.commit();
                            quotaReserved = false;
                            unawaited(
                              _finishChatRoomCreation(roomReference.id),
                            );
                            if (!context.mounted) return;
                            Navigator.pop(context);
                            AppNotificationService.show(
                              'Sohbet odası başarıyla açıldı!',
                            );
                          } catch (error) {
                            debugPrint('Sohbet odası oluşturulamadı: $error');
                            if (quotaReserved && quotaReservationId != null) {
                              try {
                                await _callQuotaCallable(
                                  'cancelDailyQuotaReservation',
                                  {'reservationId': quotaReservationId},
                                );
                              } catch (releaseError) {
                                debugPrint(
                                  'Sohbet odası kotası geri alınamadı: $releaseError',
                                );
                              }
                            }
                            if (mounted) {
                              final quotaExceeded =
                                  error is FirebaseFunctionsException &&
                                  error.code == 'resource-exhausted';
                              if (quotaExceeded) {
                                _showProUpgradeModal();
                              } else if (error is FirebaseFunctionsException &&
                                  error.code == 'unauthenticated') {
                                _showTrackingMessage(
                                  'Oturum doğrulanamadı. Lütfen çıkış yapıp tekrar giriş yapın.',
                                );
                              } else if (error is FirebaseAuthException) {
                                _showTrackingMessage(
                                  'Oturum doğrulanamadı. Lütfen tekrar giriş yapın.',
                                );
                              } else {
                                _showTrackingMessage(
                                  'Oda oluşturulamadı. Tekrar deneyin.',
                                );
                              }
                            }
                            return;
                          } finally {
                            if (context.mounted) {
                              setModalState(() => isCreating = false);
                            }
                          }
                        },
                  child: isCreating
                      ? const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            ),
                            SizedBox(width: 10),
                            Text('Oda oluşturuluyor...'),
                          ],
                        )
                      : const Text(
                          'Odayı Kur ve Yayınla',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openRoomChat(
    Map<String, dynamic> room, {
    String? passwordHash,
  }) async {
    final roomId = (room['id'] ?? room['roomId'] ?? room['room_id'])
        ?.toString();
    if (roomId == null || roomId.isEmpty || !mounted) return;

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final ownerId = (room['ownerId'] ?? room['owner_id'])?.toString() ?? '';
    if (ownerId != user.uid) {
      final canEnter = await _joinRoom(roomId, passwordHash: passwordHash);
      if (!canEnter || !mounted) return;
    }

    final moderatorIdsValue =
        room['moderatorIds'] ?? room['moderator_ids'] ?? const <String>[];
    final moderatorIds = moderatorIdsValue is Iterable
        ? moderatorIdsValue.map((e) => e.toString()).toList()
        : <String>[];

    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => RoomChatPage(
          roomId: roomId,
          roomName: room['name']?.toString() ?? 'Sohbet Odası',
          userName: _userName,
          userId: user.uid,
          ownerId: ownerId,
          moderatorIds: moderatorIds,
        ),
      ),
    );
  }

  Future<bool> _joinRoom(String roomId, {String? passwordHash}) async {
    try {
      final result = await FirebaseFunctions.instanceFor(region: 'europe-west1')
          .httpsCallable('joinChatRoom')
          .call<Map<String, dynamic>>({
            'roomId': roomId,
            'passwordHash': passwordHash ?? '',
          });
      return result.data['joined'] == true;
    } catch (error) {
      debugPrint('Odaya giriş başarısız: $error');
      if (mounted) {
        final message = error is FirebaseFunctionsException
            ? error.message
            : null;
        _showTrackingMessage(
          message?.isNotEmpty == true
              ? message!
              : 'Odaya giriş yapılamadı. Bağlantınızı kontrol edin.',
        );
      }
      return false;
    }
  }

  Future<void> _deleteRoom(Map<String, dynamic> room) async {
    final user = FirebaseAuth.instance.currentUser;
    final roomId = room['id']?.toString();
    final ownerId = (room['ownerId'] ?? room['owner_id'])?.toString();
    if (user == null ||
        roomId == null ||
        (ownerId != user.uid && !_canManageExploreHighlights)) {
      return;
    }
    final shouldDelete = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Oda silinsin mi?'),
        content: Text('${room['name']} odası ve mesajları silinecek.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Vazgeç'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            child: const Text('Sil'),
          ),
        ],
      ),
    );
    if (shouldDelete != true) return;
    try {
      await navoraDeleteChatRoom(FirebaseFirestore.instance, roomId);
      if (mounted) _showTrackingMessage('Sohbet odası silindi.');
    } catch (error) {
      debugPrint('Sohbet odası silinemedi: $error');
      if (mounted) _showTrackingMessage('Oda silinemedi. Tekrar deneyin.');
    }
  }

  Future<void> _showPasswordPromptDialog(Map<String, dynamic> room) async {
    final currentUser = FirebaseAuth.instance.currentUser;
    final ownerId = (room['ownerId'] ?? room['owner_id'])?.toString() ?? '';
    final isOwner = currentUser != null && ownerId == currentUser.uid;

    if (isOwner || room['isProtected'] != true) {
      await _openRoomChat(room);
      return;
    }

    final passController = TextEditingController();
    final enteredPassword = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        var obscurePassword = true;
        var validationMessage = '';

        return StatefulBuilder(
          builder: (context, setDialogState) {
            void submitPassword() {
              final value = passController.text.trim();
              if (value.length < navoraMinimumRoomPasswordLength) {
                setDialogState(
                  () => validationMessage =
                      'Şifre en az $navoraMinimumRoomPasswordLength karakter olmalı.',
                );
                return;
              }
              Navigator.of(dialogContext).pop(value);
            }

            return Dialog(
              backgroundColor: const Color(0xFF191919),
              insetPadding: const EdgeInsets.symmetric(horizontal: 24),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
                side: const BorderSide(color: Color(0xFF49301F)),
              ),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(22),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 380),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(
                              color: const Color(0xFF332115),
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: const Icon(
                              Icons.lock_outline_rounded,
                              color: Color(0xFFFF9A3D),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'Şifreli oda',
                                  style: TextStyle(
                                    color: Colors.white70,
                                    fontSize: 12,
                                  ),
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  room['name']?.toString() ?? 'Sohbet odası',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 17,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            tooltip: 'Kapat',
                            visualDensity: VisualDensity.compact,
                            onPressed: () => Navigator.of(dialogContext).pop(),
                            icon: const Icon(
                              Icons.close_rounded,
                              color: Colors.white60,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),
                      TextField(
                        controller: passController,
                        autofocus: true,
                        obscureText: obscurePassword,
                        onSubmitted: (_) => submitPassword(),
                        style: const TextStyle(color: Colors.white),
                        decoration: InputDecoration(
                          labelText: 'Oda şifresi',
                          hintText:
                              'En az $navoraMinimumRoomPasswordLength karakter',
                          errorText: validationMessage.isEmpty
                              ? null
                              : validationMessage,
                          prefixIcon: const Icon(
                            Icons.key_rounded,
                            color: Color(0xFFFF9A3D),
                          ),
                          suffixIcon: IconButton(
                            tooltip: obscurePassword
                                ? 'Şifreyi göster'
                                : 'Şifreyi gizle',
                            onPressed: () => setDialogState(
                              () => obscurePassword = !obscurePassword,
                            ),
                            icon: Icon(
                              obscurePassword
                                  ? Icons.visibility_rounded
                                  : Icons.visibility_off_rounded,
                              color: Colors.white60,
                            ),
                          ),
                          filled: true,
                          fillColor: const Color(0xFF222222),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                            borderSide: const BorderSide(
                              color: Color(0xFF3A3A3A),
                            ),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                            borderSide: const BorderSide(
                              color: Color(0xFF3A3A3A),
                            ),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                            borderSide: const BorderSide(
                              color: Color(0xFFFF9A3D),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 22),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: () =>
                                  Navigator.of(dialogContext).pop(),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: Colors.white70,
                                minimumSize: const Size.fromHeight(48),
                                side: const BorderSide(color: Colors.white24),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14),
                                ),
                              ),
                              child: const Text('Vazgeç'),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: ElevatedButton.icon(
                              onPressed: submitPassword,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFFFF7A18),
                                foregroundColor: Colors.white,
                                minimumSize: const Size.fromHeight(48),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14),
                                ),
                              ),
                              icon: const Icon(Icons.login_rounded, size: 18),
                              label: const Text('Odaya katıl'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
    passController.dispose();
    if (enteredPassword == null || !mounted) return;

    final salt = room['passwordSalt']?.toString() ?? '';
    if (salt.isEmpty) {
      AppNotificationService.show('Oda şifresi doğrulanamıyor.');
      return;
    }
    await _openRoomChat(
      room,
      passwordHash: await navoraHashRoomPassword(enteredPassword, salt),
    );
  }

  Future<void> _showAboutSupportSheet() async {
    const supportEmail = 'navora.map@gmail.com';

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF191919),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 22, 20, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFF6B00).withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(
                    Icons.support_agent_rounded,
                    color: Color(0xFFFF6B00),
                  ),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text(
                    'Hakkımızda & Destek',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                ),
                IconButton(
                  tooltip: 'Kapat',
                  onPressed: () => Navigator.pop(sheetContext),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
            const SizedBox(height: 16),
            const Text(
              'Navora, yolculuklarını daha güvenli ve keyifli hale getirmek için tasarlanmış bir keşif ve sürüş uygulamasıdır.',
              style: TextStyle(
                color: Colors.white70,
                fontSize: 14,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 10),
            Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: () async {
                  final emailUri = Uri(scheme: 'mailto', path: supportEmail);
                  final opened = await launchUrl(
                    emailUri,
                    mode: LaunchMode.externalApplication,
                  );
                  if (!opened && mounted) {
                    _showTrackingMessage(
                      'Bu cihazda e-posta uygulaması bulunamadı.',
                    );
                  }
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: 8,
                    horizontal: 4,
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.email_outlined,
                        color: Color(0xFFFF6B00),
                        size: 19,
                      ),
                      const SizedBox(width: 10),
                      const Expanded(
                        child: Text(
                          supportEmail,
                          style: TextStyle(
                            color: Color(0xFFFF6B00),
                            fontSize: 13,
                          ),
                        ),
                      ),
                      const Icon(
                        Icons.open_in_new_rounded,
                        color: Colors.white54,
                        size: 17,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Geri bildirimlerinizi, hata bildirimlerinizi ve önerilerinizi bizimle paylaşabilirsiniz.',
              style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  void _showProUpgradeModal() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF191919),
      barrierColor: Colors.black,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) => Container(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 28),
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.82,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: const Color(0xFFFF8A3D).withValues(alpha: 0.18),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: const Color(0xFFFF8A3D),
                    width: 1.2,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFFFF8A3D).withValues(alpha: 0.18),
                      blurRadius: 14,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: const Icon(
                  Icons.workspace_premium_rounded,
                  color: Color(0xFFFFB066),
                  size: 36,
                ),
              ),
              const SizedBox(height: 14),
              const Text(
                'Navora Pro',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                _isProUser
                    ? 'Navora Pro üyeliğin aktif. Ayrıcalıklarını kullanabilirsin.'
                    : 'Satın alma mağaza ve sunucu doğrulaması tamamlandığında açılacak.',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13, color: Colors.white70),
              ),
              const SizedBox(height: 18),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFF1B1B1B),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(
                    color: const Color(0xFFFF8A3D).withValues(alpha: 0.45),
                  ),
                ),
                child: Column(
                  children: [
                    _buildPlanComparisonRow(
                      'Standart Hesap',
                      'AI: 3 / gün\nOda: 3 / gün',
                      isPro: false,
                    ),
                    const SizedBox(height: 12),
                    _buildPlanComparisonRow(
                      'Pro Hesap',
                      'AI: 10 / gün\nOda: 10 / gün',
                      isPro: true,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              if (!_isProUser)
                const Text(
                  'Satın alma henüz etkin değil',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Color(0xFFFFB066),
                  ),
                ),
              if (!_isProUser) const SizedBox(height: 12),
              if (_isProUser) ...[
                const SizedBox(height: 6),
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: const BorderSide(color: Color(0xFFFF8A3D)),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    onPressed: () => _showTrackingMessage(
                      'Abonelik yönetimi mağaza entegrasyonu tamamlandığında açılacak.',
                    ),
                    child: const Text(
                      'Abonelik yönetimi yakında',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ] else
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFFF6B00),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    onPressed: () => _showTrackingMessage(
                      'Pro satın alma henüz etkin değil.',
                    ),
                    child: const Text(
                      'Satın alma yakında',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPlanComparisonRow(
    String label,
    String details, {
    required bool isPro,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isPro ? const Color(0xFF2A180D) : const Color(0xFF202020),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isPro
              ? const Color(0xFFFF8A3D).withValues(alpha: 0.75)
              : const Color(0xFF333333),
          width: isPro ? 1.5 : 1,
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(
              color: isPro ? const Color(0xFFFF8A3D) : Colors.grey.shade500,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                    color: isPro ? const Color(0xFFFFB066) : Colors.white,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  details,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Colors.white70,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPremiumPlanBanner() {
    return GestureDetector(
      onTap: _showProUpgradeModal,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        clipBehavior: Clip.hardEdge,
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFF1A120D), Color(0xFF24150D), Color(0xFF171717)],
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
          ),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: const Color(0xFFFF8A3D), width: 1.1),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFFFF8A3D).withValues(alpha: 0.18),
              blurRadius: 14,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Stack(
          children: [
            Positioned(
              right: -12,
              bottom: -26,
              child: Icon(
                Icons.auto_awesome_rounded,
                size: 110,
                color: const Color(0xFFFF8A3D).withValues(alpha: 0.08),
              ),
            ),
            Positioned(
              right: 42,
              top: -14,
              child: Icon(
                Icons.star_rounded,
                size: 30,
                color: const Color(0xFFFF8A3D).withValues(alpha: 0.18),
              ),
            ),
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(11),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFF8A3D).withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(
                    Icons.workspace_premium_rounded,
                    color: Color(0xFFFFB066),
                    size: 22,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: const [
                      Text(
                        'Navora Pro',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      SizedBox(height: 2),
                      Text(
                        'Özel rota istatistikleri ve premium avantajlar',
                        style: TextStyle(color: Colors.white70, fontSize: 11),
                      ),
                    ],
                  ),
                ),
                const Icon(
                  Icons.arrow_forward_ios_rounded,
                  color: Color(0xFFFFB066),
                  size: 16,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProfilePage() {
    final isGuest = FirebaseAuth.instance.currentUser == null;
    final bottomSafeInset = MediaQuery.viewPaddingOf(context).bottom;

    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        16,
        16,
        16,
        bottomSafeInset + _bottomNavigationBarHeight + _bottomNavigationGap,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(22),
              gradient: const LinearGradient(
                colors: [
                  Color(0xFFFF7A1A),
                  Color(0xFFFF6B00),
                  Color(0xFFCB4C00),
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFFFF6B00).withValues(alpha: 0.32),
                  blurRadius: 18,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            child: Stack(
              children: [
                Positioned(
                  right: -18,
                  top: -12,
                  child: Container(
                    width: 120,
                    height: 120,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.08),
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
                Positioned(
                  left: -20,
                  bottom: -32,
                  child: Container(
                    width: 140,
                    height: 140,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.05),
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
                Column(
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        GestureDetector(
                          onTap: isGuest ? null : _showPhotoUploadDialog,
                          child: Stack(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(0),
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withValues(
                                        alpha: 0.18,
                                      ),
                                      blurRadius: 10,
                                      offset: const Offset(0, 6),
                                    ),
                                  ],
                                ),
                                child: CircleAvatar(
                                  radius: 40,
                                  backgroundColor: Color(0xFFEAF3FF),
                                  child:
                                      _profilePhotoUrl == null ||
                                          _profilePhotoUrl!.isEmpty
                                      ? const Icon(
                                          Icons.person,
                                          size: 52,
                                          color: Color(0xFFFF6B00),
                                        )
                                      : ClipOval(
                                          child: SizedBox(
                                            width: 80,
                                            height: 80,
                                            child: Image.network(
                                              _profilePhotoUrl!,
                                              fit: BoxFit.cover,
                                              errorBuilder:
                                                  (
                                                    context,
                                                    error,
                                                    stackTrace,
                                                  ) => const Icon(
                                                    Icons.person,
                                                    size: 52,
                                                    color: Color(0xFFFF6B00),
                                                  ),
                                            ),
                                          ),
                                        ),
                                ),
                              ),
                              if (!isGuest)
                                Positioned(
                                  right: 0,
                                  bottom: 0,
                                  child: Container(
                                    padding: const EdgeInsets.all(6),
                                    decoration: const BoxDecoration(
                                      color: Colors.white,
                                      shape: BoxShape.circle,
                                      boxShadow: [
                                        BoxShadow(
                                          color: Colors.black26,
                                          blurRadius: 5,
                                        ),
                                      ],
                                    ),
                                    child: _isUploadingProfilePhoto
                                        ? const SizedBox(
                                            width: 14,
                                            height: 14,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                              color: Color(0xFFFF6B00),
                                            ),
                                          )
                                        : const Icon(
                                            Icons.camera_alt_rounded,
                                            size: 14,
                                            color: Color(0xFFFF6B00),
                                          ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Flexible(
                                    child: Text(
                                      _userName,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 21,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 5,
                                    ),
                                    decoration: BoxDecoration(
                                      color: _isProUser
                                          ? const Color(0xFF1A140D)
                                          : const Color(0xFF171717),
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(
                                        color: _isProUser
                                            ? const Color(0xFFFFC76A)
                                                  .withValues(alpha: 0.7)
                                            : const Color(0xFF343434),
                                      ),
                                      boxShadow: _isProUser
                                          ? [
                                              BoxShadow(
                                                color: const Color(0xFFFFB13B)
                                                    .withValues(alpha: 0.22),
                                                blurRadius: 10,
                                                spreadRadius: 0.5,
                                                offset: const Offset(0, 3),
                                              ),
                                            ]
                                          : null,
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          _isProUser
                                              ? Icons.workspace_premium_rounded
                                              : Icons.person_outline_rounded,
                                          size: 11,
                                          color: _isProUser
                                              ? const Color(0xFFFFD77A)
                                              : Colors.white70,
                                        ),
                                        const SizedBox(width: 4),
                                        Text(
                                          _isProUser ? 'PRO' : 'STANDART',
                                          style: TextStyle(
                                            fontSize: 8.5,
                                            fontWeight: FontWeight.w800,
                                            letterSpacing: 0.6,
                                            color: _isProUser
                                                ? const Color(0xFFFFE3A1)
                                                : Colors.white70,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              Text(
                                _userEmail,
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 12,
                                  letterSpacing: 0.2,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                _userPhone.isEmpty
                                    ? 'Telefon eklenmemiş'
                                    : _userPhone,
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (!isGuest)
                          Container(
                            decoration: BoxDecoration(
                              color: const Color(0xFF2D180E),
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                color: Colors.white.withValues(alpha: 0.18),
                              ),
                            ),
                            child: IconButton(
                              tooltip: 'Profili Düzenle',
                              icon: const Icon(
                                Icons.edit_note_rounded,
                                color: Colors.white,
                                size: 28,
                              ),
                              onPressed: _showEditProfileDialog,
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 18),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        vertical: 12,
                        horizontal: 12,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.16),
                        ),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: _buildProfileStat(
                              '$_citiesVisited',
                              'Şehir',
                              onTap: _showVisitedCitiesSheet,
                            ),
                          ),
                          Container(
                            height: 28,
                            width: 1,
                            color: Colors.white30,
                          ),
                          Expanded(
                            child: _buildProfileStat(
                              '$_savedRouteCount',
                              'Rota',
                              onTap: _showSavedRoutesSheet,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          if (!isGuest) ...[
            const SizedBox(height: 28),
            _buildMyPropertyListings(),
          ],

          if (_canManageExploreHighlights) ...[
            const SizedBox(height: 10),
            _buildProfileMenuItem(
              icon: Icons.fact_check_outlined,
              title: 'İlan inceleme',
              subtitle: 'Yeni ilanları incele, onayla veya reddet',
              onTap: () => unawaited(
                Navigator.of(context).push<void>(
                  MaterialPageRoute<void>(
                    builder: (context) => const PropertyListingModerationPage(),
                  ),
                ),
              ),
            ),
            _buildProfileMenuItem(
              icon: Icons.report_gmailerrorred_rounded,
              title: 'Şikayetler',
              subtitle: 'Sohbet, ilan ve mekân bildirimlerini incele',
              onTap: () => unawaited(
                Navigator.of(context).push<void>(
                  MaterialPageRoute<void>(
                    builder: (context) => const ChatMessageModerationPage(),
                  ),
                ),
              ),
            ),
          ],

          const SizedBox(height: 22),

          const Text(
            'Yolculuk & Hesap Yönetimi',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w800,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 10),
          if (!isGuest)
            _buildProfileMenuItem(
              icon: Icons.block_rounded,
              title: 'Engellenen Kullanıcılar',
              subtitle: 'Engellediğin kullanıcıları yönet',
              onTap: _showBlockedUsersSheet,
            ),
          _buildProfileMenuItem(
            icon: Icons.bookmark_added_rounded,
            title: 'Kayıtlı Adreslerim',
            subtitle: '${_savedAddresses.length} kayıtlı konum (Ev, İş vb.)',
            onTap: _showSavedAddressesDialog,
          ),
          _buildProfileMenuItem(
            icon: Icons.history_rounded,
            title: 'Geçmiş Rotalar',
            subtitle: 'Önceki seyahatlerinizi görüntüleyin',
            onTap: _showDrivingHistoryDialog,
          ),
          _buildProfileMenuItem(
            icon: Icons.support_agent_rounded,
            title: 'Hakkımızda & Destek',
            subtitle: 'Sorularınız ve önerileriniz için bize ulaşın',
            onTap: _showAboutSupportSheet,
          ),

          const SizedBox(height: 20),

          _buildPremiumPlanBanner(),

          const SizedBox(height: 18),

          _buildProfileMenuItem(
            icon: isGuest ? Icons.login_rounded : Icons.logout_rounded,
            title: isGuest ? 'Giriş Yap' : 'Çıkış Yap',
            subtitle: isGuest
                ? 'Hesabına giriş yaparak profilini kaydet'
                : 'Hesabından güvenli bir şekilde ayrıl',
            isDangerous: !isGuest,
            onTap: widget.onLogout,
          ),
        ],
      ),
    );
  }

  Widget _buildMyPropertyListings() {
    return Row(
      children: [
        Expanded(
          child: _buildProfileListingActionCard(
            icon: Icons.home_work_outlined,
            title: 'İlanlarım',
            subtitle: 'İlanlarını yönet',
            onTap: () => unawaited(
              Navigator.of(context).push<void>(
                MaterialPageRoute<void>(
                  builder: (context) => MyPropertyListingsPage(
                    listingBuilder: (listing, onListingChanged) =>
                        _buildMyPropertyListingCard(
                          listing,
                          onListingChanged: () {
                            if (listing['listing_collection'] ==
                                'property_listings') {
                              _propertyListings.removeWhere(
                                (mapListing) =>
                                    mapListing['id'] == listing['id'],
                              );
                              if (mounted) setState(() {});
                            } else if (listing['listing_collection'] ==
                                'community_places') {
                              _communityPlaces.removeWhere(
                                (place) => place['id'] == listing['id'],
                              );
                              if (mounted) setState(() {});
                            }
                            onListingChanged();
                          },
                        ),
                    onCreateListing: () =>
                        unawaited(_showCreatePropertyListingSheet()),
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _buildProfileListingActionCard(
            icon: Icons.add_home_work_rounded,
            title: 'İlan ver',
            subtitle: 'Yeni konut ilanı oluştur',
            onTap: () => unawaited(_showCreatePropertyListingSheet()),
          ),
        ),
      ],
    );
  }

  Widget _buildProfileListingActionCard({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return Material(
      color: const Color(0xFF191919),
      shape: RoundedRectangleBorder(
        side: const BorderSide(color: Color(0xFFFF7A00), width: 1),
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: SizedBox(
          height: 112,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Icon(icon, color: const Color(0xFFFF9A3D), size: 22),
                const SizedBox(height: 7),
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Color(0xFFB8B8B8),
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMyPropertyListingCard(
    Map<String, dynamic> listing, {
    required VoidCallback onListingChanged,
  }) {
    if (listing['listing_collection'] == 'community_places') {
      return _buildMyCommunityPlaceCard(
        listing,
        onListingChanged: onListingChanged,
      );
    }
    if (listing['listing_collection'] != 'property_listings') {
      return _buildMyPetListingCard(
        listing,
        onListingChanged: onListingChanged,
      );
    }

    final status = listing['status']?.toString() ?? 'unknown';
    final isActive = status == 'active';
    final statusLabel = switch (status) {
      'active' => 'Yayında',
      'pending_review' => 'İncelemede',
      'rejected' => 'Reddedildi',
      _ => 'Pasif',
    };
    final statusColor = isActive
        ? const Color(0xFF69C981)
        : status == 'rejected'
        ? const Color(0xFFFF8A80)
        : const Color(0xFFFFC266);
    final imageUrl = listing['cover_image_url']?.toString() ?? '';

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF191919),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF303030)),
      ),
      child: Column(
        children: [
          Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: imageUrl.isEmpty
                    ? const SizedBox(
                        width: 76,
                        height: 68,
                        child: ColoredBox(
                          color: Color(0xFF252525),
                          child: Icon(
                            Icons.home_work_outlined,
                            color: Color(0xFFFF9A3D),
                          ),
                        ),
                      )
                    : Image.network(
                        imageUrl,
                        width: 76,
                        height: 68,
                        fit: BoxFit.cover,
                        errorBuilder: (context, error, stackTrace) =>
                            const SizedBox(
                              width: 76,
                              height: 68,
                              child: Icon(
                                Icons.broken_image_outlined,
                                color: Color(0xFFB8B8B8),
                              ),
                            ),
                      ),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      listing['title']?.toString() ?? 'Konut ilanı',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      _formatListingPrice(listing['price']),
                      style: const TextStyle(
                        color: Color(0xFFFFA052),
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  statusLabel,
                  style: TextStyle(
                    color: statusColor,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const Divider(height: 18, color: Color(0xFF303030)),
          Row(
            children: [
              const Icon(
                Icons.visibility_outlined,
                color: Color(0xFFB8B8B8),
                size: 17,
              ),
              const SizedBox(width: 5),
              Text(
                '${(listing['view_count'] as num?)?.toInt() ?? 0} görüntülenme',
                style: const TextStyle(color: Color(0xFFB8B8B8), fontSize: 12),
              ),
              const Spacer(),
              IconButton(
                tooltip: 'İlanı düzenle',
                visualDensity: VisualDensity.compact,
                onPressed: () => unawaited(
                  _showCreatePropertyListingSheet(listing: listing),
                ),
                icon: const Icon(Icons.edit_outlined),
                color: const Color(0xFFFFA052),
              ),
              IconButton(
                tooltip: 'İlanı sil',
                visualDensity: VisualDensity.compact,
                onPressed: () => unawaited(
                  _confirmDeletePropertyListing(
                    listing,
                    onDeleted: onListingChanged,
                  ),
                ),
                icon: const Icon(Icons.delete_outline_rounded),
                color: const Color(0xFFE57373),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildMyCommunityPlaceCard(
    Map<String, dynamic> place, {
    required VoidCallback onListingChanged,
  }) {
    final photoUrls =
        (place['photo_urls'] as List?)?.whereType<String>().toList() ??
        (place['photo_url']?.toString().isNotEmpty == true
            ? [place['photo_url'].toString()]
            : <String>[]);
    final address = place['address']?.toString().trim() ?? '';
    final category = place['category']?.toString() ?? 'Diğer';

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF191919),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF303030)),
      ),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: photoUrls.isEmpty
                ? const SizedBox(
                    width: 76,
                    height: 68,
                    child: ColoredBox(
                      color: Color(0xFF252525),
                      child: Icon(
                        Icons.storefront_rounded,
                        color: Color(0xFF64D8CB),
                      ),
                    ),
                  )
                : Image.network(
                    photoUrls.first,
                    width: 76,
                    height: 68,
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stackTrace) =>
                        const SizedBox(
                          width: 76,
                          height: 68,
                          child: Icon(
                            Icons.broken_image_outlined,
                            color: Color(0xFFB8B8B8),
                          ),
                        ),
                  ),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  place['name']?.toString() ?? 'Topluluk mekânı',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  address.isEmpty ? category : '$category • $address',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFFB8B8B8),
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Mekânı düzenle',
            visualDensity: VisualDensity.compact,
            onPressed: () => unawaited(_editCommunityPlace(place)),
            icon: const Icon(Icons.edit_outlined),
            color: const Color(0xFFFFA052),
          ),
          IconButton(
            tooltip: 'Mekânı sil',
            visualDensity: VisualDensity.compact,
            onPressed: () => unawaited(
              _confirmDeleteCommunityPlace(place, onDeleted: onListingChanged),
            ),
            icon: const Icon(Icons.delete_outline_rounded),
            color: const Color(0xFFE57373),
          ),
        ],
      ),
    );
  }

  Future<void> _editCommunityPlace(Map<String, dynamic> place) async {
    final latitude = (place['latitude'] as num?)?.toDouble();
    final longitude = (place['longitude'] as num?)?.toDouble();
    final placeId = place['id']?.toString();
    final user = FirebaseAuth.instance.currentUser;
    if (latitude == null ||
        longitude == null ||
        placeId == null ||
        user == null) {
      AppNotificationService.show('Mekân bilgileri düzenlenemedi.');
      return;
    }
    await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: const Color(0xFF171717),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) => CreateCommunityPlaceSheet(
        latitude: latitude,
        longitude: longitude,
        initialName: place['name']?.toString() ?? '',
        initialAddress: place['address']?.toString() ?? '',
        initialCategory: place['category']?.toString() ?? 'Diğer',
        initialDescription: place['description']?.toString() ?? '',
        initialPhotoUrls:
            (place['photo_urls'] as List?)?.whereType<String>().toList() ??
            (place['photo_url']?.toString().isNotEmpty == true
                ? [place['photo_url'].toString()]
                : const <String>[]),
        isEditing: true,
        onSubmit:
            ({
              required name,
              required category,
              required description,
              required address,
              required photoBytes,
              required photoExtensions,
              required coordinate,
            }) async {
              if (photoBytes.length != photoExtensions.length ||
                  photoBytes.length +
                          ((place['photo_urls'] as List?)?.length ??
                              (place['photo_url']?.toString().isNotEmpty == true
                                  ? 1
                                  : 0)) >
                      3) {
                throw StateError('Mekân en fazla 3 fotoğraf içerebilir.');
              }
              final existingPhotoUrls =
                  (place['photo_urls'] as List?)
                      ?.whereType<String>()
                      .toList() ??
                  (place['photo_url']?.toString().isNotEmpty == true
                      ? [place['photo_url'].toString()]
                      : <String>[]);
              final photoUrls = List<String>.from(existingPhotoUrls);
              final uploadedReferences = <Reference>[];
              final placeReference = FirebaseFirestore.instance
                  .collection('community_places')
                  .doc(placeId);
              try {
                for (var index = 0; index < photoBytes.length; index++) {
                  final extension = photoExtensions[index];
                  final contentType = switch (extension) {
                    'jpg' || 'jpeg' => 'image/jpeg',
                    'png' => 'image/png',
                    'webp' => 'image/webp',
                    _ => throw StateError(
                      'JPG, PNG veya WebP fotoğraf seçmelisin.',
                    ),
                  };
                  final photoReference = FirebaseStorage.instance.ref().child(
                    'community_places/${user.uid}/$placeId/${photoUrls.length}',
                  );
                  uploadedReferences.add(photoReference);
                  await photoReference.putData(
                    photoBytes[index],
                    SettableMetadata(contentType: contentType),
                  );
                  photoUrls.add(await photoReference.getDownloadURL());
                }

                await placeReference.update({
                  'name': name,
                  'category': category,
                  'description': description,
                  'address': address,
                  'latitude': coordinate.latitude,
                  'longitude': coordinate.longitude,
                  if (photoUrls.isNotEmpty) ...{
                    'photo_urls': photoUrls,
                    'photo_url': photoUrls.first,
                  },
                });
              } catch (_) {
                for (final reference in uploadedReferences) {
                  try {
                    await reference.delete();
                  } catch (cleanupError) {
                    debugPrint('Mekân fotoğrafı temizlenemedi: $cleanupError');
                  }
                }
                rethrow;
              }
            },
      ),
    );
  }

  Future<void> _confirmDeleteCommunityPlace(
    Map<String, dynamic> place, {
    required VoidCallback onDeleted,
  }) async {
    final placeId = place['id']?.toString();
    final user = FirebaseAuth.instance.currentUser;
    if (placeId == null || user == null) {
      AppNotificationService.show('Mekân silinemedi. Tekrar giriş yapıp dene.');
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Mekân silinsin mi?'),
        content: Text(
          '“${place['name']?.toString() ?? 'Topluluk mekânı'}” kalıcı olarak silinecek.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Vazgeç'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Sil'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final placeReference = FirebaseFirestore.instance
        .collection('community_places')
        .doc(placeId);
    try {
      final photoUrls =
          (place['photo_urls'] as List?)?.whereType<String>().toList() ??
          <String>[];
      final paths = <String>[
        ...List.generate(
          photoUrls.length,
          (index) => 'community_places/${user.uid}/$placeId/$index',
        ),
        'community_places/${user.uid}/$placeId/cover',
      ];
      for (final path in paths) {
        try {
          await FirebaseStorage.instance.ref().child(path).delete();
        } on FirebaseException catch (error) {
          if (error.code != 'object-not-found') rethrow;
        }
      }
      await placeReference.delete();
      _communityPlaces.removeWhere((item) => item['id'] == placeId);
      if (mounted) {
        setState(() {});
        onDeleted();
        AppNotificationService.show('Mekân silindi.');
      }
    } on FirebaseException catch (error, stackTrace) {
      debugPrint(
        'Topluluk mekânı silinemedi (${error.code}): '
        '${error.message}\n$stackTrace',
      );
      if (mounted) {
        AppNotificationService.show(
          'Mekân silinemedi (${error.code}). Tekrar dene.',
        );
      }
    } catch (error, stackTrace) {
      debugPrint('Topluluk mekânı silinemedi: $error\n$stackTrace');
      if (mounted) {
        AppNotificationService.show('Mekân silinemedi. Tekrar dene.');
      }
    }
  }

  Widget _buildMyPetListingCard(
    Map<String, dynamic> listing, {
    required VoidCallback onListingChanged,
  }) {
    final collection = listing['listing_collection'];
    final isAdoption = collection == 'pet_adoption_listings';
    final status = listing['status']?.toString() ?? 'unknown';
    final isActive = status == 'active';
    final title = (listing['pet_name']?.toString().trim().isNotEmpty ?? false)
        ? listing['pet_name'].toString()
        : isAdoption
        ? 'Sahiplendirme ilanı'
        : 'Kayıp dost bildirimi';
    final location = [
      listing['district']?.toString() ?? '',
      listing['city']?.toString() ?? '',
    ].where((part) => part.trim().isNotEmpty).join(', ');
    final imageUrl = listing['cover_image_url']?.toString() ?? '';
    final statusColor = isActive
        ? const Color(0xFF69C981)
        : const Color(0xFFFFC266);

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF191919),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF303030)),
      ),
      child: Column(
        children: [
          Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: imageUrl.isEmpty
                    ? const SizedBox(
                        width: 76,
                        height: 68,
                        child: ColoredBox(
                          color: Color(0xFF252525),
                          child: Icon(
                            Icons.pets_rounded,
                            color: Color(0xFFFF9A3D),
                          ),
                        ),
                      )
                    : Image.network(
                        imageUrl,
                        width: 76,
                        height: 68,
                        fit: BoxFit.cover,
                        errorBuilder: (context, error, stackTrace) =>
                            const SizedBox(
                              width: 76,
                              height: 68,
                              child: Icon(
                                Icons.broken_image_outlined,
                                color: Color(0xFFB8B8B8),
                              ),
                            ),
                      ),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      '${isAdoption ? 'Sahiplendirme' : 'Kayıp dost'} • '
                      '${_lostPetTypeLabel(listing['pet_type']?.toString())}'
                      '${location.isEmpty ? '' : ' • $location'}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xFFB8B8B8),
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  isActive ? 'Yayında' : 'Kapalı',
                  style: TextStyle(
                    color: statusColor,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const Divider(height: 18, color: Color(0xFF303030)),
          Row(
            children: [
              const Icon(
                Icons.visibility_outlined,
                color: Color(0xFFB8B8B8),
                size: 17,
              ),
              const SizedBox(width: 5),
              Text(
                listing['view_count'] is num
                    ? '${(listing['view_count'] as num).toInt()} görüntülenme'
                    : 'Görüntülenme alınamadı',
                style: const TextStyle(color: Color(0xFFB8B8B8), fontSize: 12),
              ),
              const Spacer(),
              if (isActive)
                IconButton(
                  tooltip: 'İlanı düzenle',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => unawaited(
                    _showCreateLostPetReportSheet(
                      isAdoption: isAdoption,
                      listing: listing,
                    ),
                  ),
                  icon: const Icon(Icons.edit_outlined),
                  color: const Color(0xFFFFA052),
                ),
              IconButton(
                tooltip: 'İlanı sil',
                visualDensity: VisualDensity.compact,
                onPressed: () => unawaited(
                  _confirmDeletePetListing(
                    listing,
                    onDeleted: onListingChanged,
                  ),
                ),
                icon: const Icon(Icons.delete_outline_rounded),
                color: const Color(0xFFE57373),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _confirmDeletePetListing(
    Map<String, dynamic> listing, {
    required VoidCallback onDeleted,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('İlan silinsin mi?'),
        content: Text(
          '“${listing['pet_name']?.toString().trim().isNotEmpty == true ? listing['pet_name'] : 'Hayvan ilanı'}” ve fotoğrafları kalıcı olarak silinecek.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Vazgeç'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Sil'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final user = FirebaseAuth.instance.currentUser;
    final collection = switch (listing['listing_collection']) {
      'lost_pet_reports' => 'lost_pet_reports',
      'pet_adoption_listings' => 'pet_adoption_listings',
      _ => null,
    };
    final listingId = listing['id']?.toString();
    if (user == null || collection == null || listingId == null) {
      AppNotificationService.show('İlan silinemedi. Tekrar giriş yapıp dene.');
      return;
    }

    final listingReference = FirebaseFirestore.instance
        .collection(collection)
        .doc(listingId);
    try {
      try {
        final views = await listingReference.collection('_views').get();
        for (var start = 0; start < views.docs.length; start += 450) {
          final batch = FirebaseFirestore.instance.batch();
          for (final view in views.docs.skip(start).take(450)) {
            batch.delete(view.reference);
          }
          await batch.commit();
        }
      } on FirebaseException catch (error) {
        debugPrint(
          'İlan görüntülenme kayıtları temizlenemedi '
          '(${error.code}): ${error.message}',
        );
      }
      await listingReference.delete();
      onDeleted();
    } on FirebaseException catch (error, stackTrace) {
      debugPrint(
        'Hayvan ilanı Firestore’dan silinemedi '
        '(${error.code}): ${error.message}\n$stackTrace',
      );
      if (mounted) {
        AppNotificationService.show(
          'İlan Firestore’dan silinemedi (${error.code}). Tekrar dene.',
        );
      }
      return;
    } catch (error, stackTrace) {
      debugPrint('Hayvan ilanı Firestore’dan silinemedi: $error\n$stackTrace');
      if (mounted) {
        AppNotificationService.show('İlan silinemedi. Tekrar dene.');
      }
      return;
    }

    final photoDeletionErrors = <FirebaseException>[];
    for (var index = 0; index < 3; index++) {
      try {
        await FirebaseStorage.instance
            .ref()
            .child('$collection/${user.uid}/$listingId/$index')
            .delete();
      } on FirebaseException catch (error) {
        if (error.code != 'object-not-found') {
          photoDeletionErrors.add(error);
          debugPrint(
            'Hayvan ilanı fotoğrafı silinemedi '
            '(${error.code}, $collection/$listingId/$index): ${error.message}',
          );
        }
      }
    }

    if (!mounted) return;
    if (photoDeletionErrors.isEmpty) {
      AppNotificationService.show('İlan silindi.');
    } else {
      AppNotificationService.show(
        'İlan silindi ancak bazı fotoğraflar silinemedi. '
        'Storage izinlerini kontrol et.',
      );
    }
  }

  Future<void> _deleteAccount() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Hesap kalıcı olarak silinsin mi?'),
        content: const Text(
          'Profilin, kayıtların, ilanların, mesajların ve hesabına bağlı dosyalar silinecek. Bu işlem geri alınamaz.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Vazgeç'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Hesabımı sil'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;

    setState(() => _isDeletingAccount = true);
    try {
      await FirebaseFunctions.instance
          .httpsCallable('deleteAccount')
          .call<Map<String, dynamic>>();
      if (mounted) widget.onLogout();
    } on FirebaseFunctionsException catch (error) {
      if (!mounted) return;
      final message = error.code == 'failed-precondition'
          ? 'Güvenlik için çıkış yapıp tekrar giriş yaptıktan sonra hesabını silebilirsin.'
          : 'Hesap silinemedi. Lütfen tekrar deneyin.';
      _showTrackingMessage(message);
    } catch (_) {
      if (!mounted) return;
      _showTrackingMessage('Hesap silinemedi. Lütfen tekrar deneyin.');
    } finally {
      if (mounted) setState(() => _isDeletingAccount = false);
    }
  }

  // --- MODAL PENCERELERİ ---

  void _showSavedAddressesDialog() {
    var isSavingAddress = false;
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF191919),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) {
          final savedAddressItems = _savedAddresses;
          return Container(
            padding: const EdgeInsets.all(20),
            height: MediaQuery.of(context).size.height * 0.6,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Kayıtlı Adreslerim',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                    Row(
                      children: [
                        IconButton(
                          tooltip: 'Adres ekle',
                          icon: const Icon(
                            Icons.add_location_alt_outlined,
                            color: Color(0xFFFFB066),
                          ),
                          onPressed: isSavingAddress
                              ? null
                              : () async {
                                  if (isSavingAddress) {
                                    return;
                                  }
                                  final address = await _showAddAddressDialog();
                                  if (address == null || !context.mounted) {
                                    return;
                                  }
                                  final user =
                                      FirebaseAuth.instance.currentUser;
                                  if (user == null) {
                                    _showTrackingMessage(
                                      'Adres kaydetmek için hesabına giriş yap.',
                                    );
                                    return;
                                  }
                                  setModalState(() => isSavingAddress = true);
                                  try {
                                    final document = await FirebaseFirestore
                                        .instance
                                        .collection('users')
                                        .doc(user.uid)
                                        .collection('saved_addresses')
                                        .add(address);
                                    address['id'] = document.id;
                                    _upsertSavedAddress(address);
                                    if (!context.mounted) return;
                                    _showTrackingMessage(
                                      '${address['title']} adreslere kaydedildi.',
                                    );
                                    setModalState(() {});
                                  } catch (error) {
                                    debugPrint('Adres kaydedilemedi: $error');
                                    if (mounted) {
                                      _showTrackingMessage(
                                        'Adres kaydedilemedi. Lütfen tekrar deneyin.',
                                      );
                                    }
                                  } finally {
                                    if (context.mounted) {
                                      setModalState(
                                        () => isSavingAddress = false,
                                      );
                                    }
                                  }
                                },
                        ),
                        IconButton(
                          icon: const Icon(Icons.close, color: Colors.white70),
                          onPressed: () => Navigator.pop(context),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Expanded(
                  child: savedAddressItems.isEmpty
                      ? const Center(
                          child: Text(
                            'Henüz kayıtlı yer yok. + simgesiyle ev, iş veya favori yer ekleyin.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Colors.white70),
                          ),
                        )
                      : ListView.builder(
                          itemCount: savedAddressItems.length,
                          itemBuilder: (context, index) {
                            final addr = savedAddressItems[index];
                            IconData iconData = Icons.location_on;
                            if (addr['type'] == 'home') iconData = Icons.home;
                            if (addr['type'] == 'work') iconData = Icons.work;
                            if (addr['type'] == 'favorite') {
                              iconData = Icons.star;
                            }
                            return Card(
                              margin: const EdgeInsets.only(bottom: 10),
                              color: const Color(0xFF1A1A1A),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                                side: const BorderSide(
                                  color: Color(0xFFFF8A3D),
                                  width: 1,
                                ),
                              ),
                              child: ListTile(
                                onTap: () async {
                                  Navigator.pop(context);
                                  await _goToSavedAddress(addr);
                                },
                                leading: CircleAvatar(
                                  backgroundColor: const Color(0xFFFF8A3D)
                                      .withValues(alpha: 0.14),
                                  child: Icon(
                                    iconData,
                                    color: const Color(0xFFFFB066),
                                  ),
                                ),
                                title: Text(
                                  addr['title']!,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: Colors.white,
                                  ),
                                ),
                                subtitle: Text(
                                  addr['address']!,
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: Colors.white70,
                                  ),
                                ),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      tooltip: 'Adrese git',
                                      icon: const Icon(
                                        Icons.navigation_rounded,
                                        color: Color(0xFFFFB066),
                                        size: 20,
                                      ),
                                      onPressed: () async {
                                        Navigator.pop(context);
                                        await _goToSavedAddress(addr);
                                      },
                                    ),
                                    IconButton(
                                      tooltip: 'Adresi sil',
                                      icon: const Icon(
                                        Icons.delete_outline,
                                        color: Colors.redAccent,
                                        size: 20,
                                      ),
                                      onPressed: () async {
                                        final user =
                                            FirebaseAuth.instance.currentUser;
                                        final addressId = addr['id'];
                                        if (user == null ||
                                            addressId == null ||
                                            addressId.isEmpty) {
                                          _showTrackingMessage(
                                            'Adres silinemedi. Tekrar deneyin.',
                                          );
                                          return;
                                        }
                                        try {
                                          await FirebaseFirestore.instance
                                              .collection('users')
                                              .doc(user.uid)
                                              .collection('saved_addresses')
                                              .doc(addressId)
                                              .delete();
                                          if (!mounted) return;
                                          setState(() {
                                            _savedAddresses.removeWhere(
                                              (savedAddress) =>
                                                  savedAddress['id'] ==
                                                  addressId,
                                            );
                                          });
                                          _showTrackingMessage(
                                            'Adres silindi.',
                                          );
                                        } catch (error) {
                                          debugPrint(
                                            'Kayıtlı adres silinemedi: $error',
                                          );
                                          _showTrackingMessage(
                                            'Adres silinemedi. Lütfen tekrar deneyin.',
                                          );
                                        }
                                        setModalState(() {});
                                      },
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _deleteHistoryEntry(
    Map<String, String> history, {
    required VoidCallback refreshSheet,
  }) async {
    final entryId = history['id'];
    final collectionName = history['collection'];
    if (entryId == null ||
        entryId.isEmpty ||
        collectionName == null ||
        (collectionName != 'driving_history' &&
            collectionName != 'route_history')) {
      _showTrackingMessage('Geçmiş kaydı silinemedi.');
      return;
    }

    final shouldDelete = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Geçmiş kaydı silinsin mi?'),
        content: Text(
          '"${history['route'] ?? 'Bu kayıt'}" geçmişten silinecek.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Vazgeç'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Sil'),
          ),
        ],
      ),
    );
    if (shouldDelete != true || !mounted) return;

    final entryKey = '$collectionName/$entryId';
    if (!_deletingHistoryEntryKeys.add(entryKey)) return;
    if (mounted) setState(() {});
    refreshSheet();
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        throw StateError('Geçmişi silmek için oturum açmalısınız.');
      }
      await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .collection(collectionName)
          .doc(entryId)
          .delete();
      if (!mounted) return;
      setState(() {
        _liveDrivingHistory.removeWhere(
          (entry) =>
              entry['collection'] == collectionName && entry['id'] == entryId,
        );
        _liveRouteHistory.removeWhere(
          (entry) =>
              entry['collection'] == collectionName && entry['id'] == entryId,
        );
        _drivingHistory.removeWhere(
          (entry) =>
              entry['collection'] == collectionName && entry['id'] == entryId,
        );
      });
      _showTrackingMessage('Geçmiş kaydı silindi.');
    } catch (error) {
      debugPrint('Geçmiş kaydı silinemedi: $error');
      if (mounted) _showTrackingMessage('Geçmiş kaydı silinemedi.');
    } finally {
      _deletingHistoryEntryKeys.remove(entryKey);
      if (mounted) setState(() {});
      refreshSheet();
    }
  }

  void _showDrivingHistoryDialog() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF191919),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) => Container(
          padding: const EdgeInsets.all(20),
          height: MediaQuery.of(context).size.height * 0.55,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Geçmiş Rotalar & Sürüşler',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white70),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF1A120D),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: const Color(0xFFFF8A3D).withValues(alpha: 0.5),
                  ),
                ),
                child: const Row(
                  children: [
                    Icon(
                      Icons.info_outline,
                      size: 18,
                      color: Color(0xFFFFB066),
                    ),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Geçmiş sürüş ve rota verileri 30 gün sonra otomatik olarak silinir.',
                        style: TextStyle(fontSize: 12, color: Colors.white70),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Expanded(
                child: _drivingHistory.isEmpty
                    ? const Center(
                        child: Text(
                          'Geçmiş kayıt bulunmuyor.',
                          style: TextStyle(color: Colors.white70),
                        ),
                      )
                    : ListView.builder(
                        itemCount: _drivingHistory.length,
                        itemBuilder: (context, index) {
                          final h = _drivingHistory[index];
                          final id = h['id'];
                          final collection = h['collection'];
                          final entryKey = id == null || collection == null
                              ? null
                              : '$collection/$id';
                          final isDeleting =
                              entryKey != null &&
                              _deletingHistoryEntryKeys.contains(entryKey);
                          return Container(
                            margin: const EdgeInsets.only(bottom: 10),
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: const Color(0xFF1A1A1A),
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                color: const Color(0xFFFF8A3D)
                                    .withValues(alpha: 0.3),
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.08),
                                  blurRadius: 10,
                                  offset: const Offset(0, 4),
                                ),
                              ],
                            ),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(14),
                              onTap: isDeleting
                                  ? null
                                  : () => _showHistoryDetails(h),
                              child: Row(
                                children: [
                                  const Icon(
                                    Icons.alt_route,
                                    color: Color(0xFFFF8A3D),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          h['route']!,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontWeight: FontWeight.bold,
                                            fontSize: 13,
                                            color: Colors.white,
                                          ),
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          '${h['date']} • ${h['duration']} • ${h['km']}',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontSize: 11,
                                            color: Colors.white70,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  IconButton(
                                    tooltip: 'Geçmiş kaydını sil',
                                    onPressed:
                                        isDeleting ||
                                            id == null ||
                                            collection == null
                                        ? null
                                        : () => _deleteHistoryEntry(
                                            h,
                                            refreshSheet: () {
                                              if (context.mounted) {
                                                setSheetState(() {});
                                              }
                                            },
                                          ),
                                    icon: isDeleting
                                        ? const SizedBox(
                                            width: 18,
                                            height: 18,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                            ),
                                          )
                                        : const Icon(
                                            Icons.delete_outline,
                                            color: Colors.redAccent,
                                          ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showHistoryDetails(Map<String, String> history) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF191919),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 22, 20, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                history['route'] ?? 'Sürüş detayı',
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                history['date'] ?? 'Tarih yok',
                style: const TextStyle(color: Colors.white70),
              ),
              const SizedBox(height: 18),
              _buildHistoryDetailRow(
                Icons.route,
                'Mesafe',
                history['km'] ?? '-',
              ),
              _buildHistoryDetailRow(
                Icons.schedule,
                'Süre',
                history['duration'] ?? '-',
              ),
              const SizedBox(height: 14),
              const Text(
                'Bu kayıt 30 gün sonunda otomatik olarak silinir.',
                style: TextStyle(fontSize: 12, color: Colors.white60),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHistoryDetailRow(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Icon(icon, size: 20, color: const Color(0xFFFF8A3D)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(label, style: const TextStyle(color: Colors.white70)),
          ),
          Text(
            value,
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
        ],
      ),
    );
  }

  Future<Map<String, String>?> _showAddAddressDialog({
    String initialTitle = '',
    String initialAddress = '',
    LatLng? initialCoordinate,
  }) async {
    final titleController = TextEditingController(text: initialTitle);
    final addressController = TextEditingController(text: initialAddress);
    String selectedType = 'favorite';
    LatLng? selectedCoordinate = initialCoordinate;

    final result = await showModalBottomSheet<Map<String, String>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF171717),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) {
          final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
          final availableHeight =
              MediaQuery.sizeOf(context).height - keyboardInset - 24;
          final sheetHeight = availableHeight < 360
              ? availableHeight
              : MediaQuery.sizeOf(context).height * 0.72;
          return AnimatedPadding(
            duration: const Duration(milliseconds: 180),
            padding: EdgeInsets.only(bottom: keyboardInset),
            child: SafeArea(
              top: false,
              child: SizedBox(
                height: sheetHeight,
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 20, 12, 12),
                      child: Row(
                        children: [
                          const Expanded(
                            child: Text(
                              'Yeni Adres Ekle',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 19,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          IconButton(
                            onPressed: () => Navigator.pop(sheetContext),
                            icon: const Icon(
                              Icons.close_rounded,
                              color: Colors.white70,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                        child: Column(
                          children: [
                            TextField(
                              controller: titleController,
                              style: const TextStyle(color: Colors.white),
                              textInputAction: TextInputAction.next,
                              decoration: _addressFormDecoration(
                                label: 'Adres adı',
                                hint: 'Ev, İş veya Favori',
                              ),
                            ),
                            const SizedBox(height: 12),
                            TextField(
                              controller: addressController,
                              maxLines: 2,
                              style: const TextStyle(color: Colors.white),
                              decoration: _addressFormDecoration(
                                label: 'Adres',
                                hint: 'Adres bilgisini yazın veya haritadan seçin',
                              ),
                            ),
                            const SizedBox(height: 10),
                            OutlinedButton.icon(
                              onPressed: () async {
                                FocusManager.instance.primaryFocus?.unfocus();
                                final coordinate = await _showAddressMapPicker(
                                  initialCoordinate: selectedCoordinate,
                                );
                                if (coordinate == null || !mounted) return;
                                final address = await _routeCoordinateLabel(
                                  coordinate,
                                );
                                if (!mounted) return;
                                setSheetState(() {
                                  selectedCoordinate = coordinate;
                                  addressController.text = address;
                                });
                              },
                              icon: const Icon(Icons.map_outlined),
                              label: Text(
                                selectedCoordinate == null
                                    ? 'Haritadan seç'
                                    : 'Haritadaki konumu değiştir',
                              ),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: const Color(0xFFFFB066),
                                minimumSize: const Size.fromHeight(46),
                                side: const BorderSide(
                                  color: Color(0xFFFF7A00),
                                ),
                              ),
                            ),
                            if (selectedCoordinate != null) ...[
                              const SizedBox(height: 6),
                              const Align(
                                alignment: Alignment.centerLeft,
                                child: Text(
                                  'Harita konumu seçildi',
                                  style: TextStyle(
                                    color: Colors.white60,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                            ],
                            const SizedBox(height: 12),
                            DropdownButtonFormField<String>(
                              initialValue: selectedType,
                              dropdownColor: const Color(0xFF242424),
                              style: const TextStyle(color: Colors.white),
                              iconEnabledColor: const Color(0xFFFF7A00),
                              decoration: _addressFormDecoration(
                                label: 'Adres türü',
                              ),
                              items: const [
                                DropdownMenuItem(
                                  value: 'home',
                                  child: Text(
                                    'Ev',
                                    style: TextStyle(color: Colors.white),
                                  ),
                                ),
                                DropdownMenuItem(
                                  value: 'work',
                                  child: Text(
                                    'İş',
                                    style: TextStyle(color: Colors.white),
                                  ),
                                ),
                                DropdownMenuItem(
                                  value: 'favorite',
                                  child: Text(
                                    'Favori',
                                    style: TextStyle(color: Colors.white),
                                  ),
                                ),
                              ],
                              onChanged: (value) {
                                if (value != null) {
                                  setSheetState(() => selectedType = value);
                                }
                              },
                            ),
                          ],
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                      child: Row(
                        children: [
                          Expanded(
                            child: TextButton(
                              onPressed: () => Navigator.pop(sheetContext),
                              child: const Text(
                                'Vazgeç',
                                style: TextStyle(color: Colors.white70),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: FilledButton(
                              onPressed: () {
                                final title = titleController.text.trim();
                                final address = addressController.text.trim();
                                if (title.isEmpty || address.isEmpty) {
                                  _showTrackingMessage(
                                    'Adres adı ve adres bilgisi gerekli.',
                                  );
                                  return;
                                }
                                Navigator.pop(sheetContext, {
                                  'title': title,
                                  'address': address,
                                  'type': selectedType,
                                  if (selectedCoordinate != null) ...{
                                    'latitude': selectedCoordinate!.latitude
                                        .toString(),
                                    'longitude': selectedCoordinate!.longitude
                                        .toString(),
                                  },
                                });
                              },
                              style: FilledButton.styleFrom(
                                backgroundColor: const Color(0xFFFF7A00),
                                foregroundColor: Colors.white,
                              ),
                              child: const Text('Kaydet'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );

    titleController.dispose();
    addressController.dispose();
    return result;
  }

  InputDecoration _addressFormDecoration({
    required String label,
    String? hint,
  }) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      labelStyle: const TextStyle(color: Color(0xFFBDBDBD)),
      hintStyle: const TextStyle(color: Color(0xFF8F8F8F)),
      filled: true,
      fillColor: const Color(0xFF1F1F1F),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFF333333)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFFFF7A00)),
      ),
    );
  }

  Future<LatLng?> _showAddressMapPicker({LatLng? initialCoordinate}) {
    final startCoordinate =
        initialCoordinate ??
        (_currentPosition == null
            ? const LatLng(41.0082, 28.9784)
            : LatLng(_currentPosition!.latitude, _currentPosition!.longitude));
    LatLng? selectedCoordinate = initialCoordinate;

    return showModalBottomSheet<LatLng>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF171717),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) => SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.82,
          child: SafeArea(
            top: false,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 18, 12, 12),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Haritadan konum seç',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: () => Navigator.pop(sheetContext),
                        icon: const Icon(
                          Icons.close_rounded,
                          color: Colors.white70,
                        ),
                      ),
                    ],
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 0, 20, 12),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Haritada kaydetmek istediğiniz noktaya dokunun.',
                      style: TextStyle(color: Colors.white70, fontSize: 13),
                    ),
                  ),
                ),
                Expanded(
                  child: GoogleMap(
                    initialCameraPosition: CameraPosition(
                      target: startCoordinate,
                      zoom: initialCoordinate == null ? 14 : 16,
                    ),
                    cameraTargetBounds: CameraTargetBounds(
                      LatLngBounds(
                        southwest: const LatLng(35.8, 25.6),
                        northeast: const LatLng(42.2, 44.8),
                      ),
                    ),
                    style: _darkGoogleMapStyle,
                    myLocationEnabled: _locationPermissionGranted,
                    myLocationButtonEnabled: true,
                    zoomControlsEnabled: false,
                    markers: selectedCoordinate == null
                        ? const <Marker>{}
                        : {
                            Marker(
                              markerId: const MarkerId('saved-address-picker'),
                              position: selectedCoordinate!,
                            ),
                          },
                    onTap: (coordinate) =>
                        setSheetState(() => selectedCoordinate = coordinate),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 18),
                  child: SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: selectedCoordinate == null
                          ? null
                          : () =>
                                Navigator.pop(sheetContext, selectedCoordinate),
                      icon: const Icon(Icons.check_rounded),
                      label: const Text('Bu konumu kullan'),
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFFFF7A00),
                        foregroundColor: Colors.white,
                        minimumSize: const Size.fromHeight(48),
                      ),
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

  void _startRoutePlanning() {
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _routeSelectionTarget = 'start';
      _routeDraftStart = null;
      _routeDraftDestination = null;
      _routeTitleController.clear();
      _routeStartController.clear();
      _routeDestinationController.clear();
      _selectedDestinationCoordinate = null;
      _selectedDestinationName = null;
      _searchMarkers = const <Marker>[];
      _searchSuggestions = [];
      _showSearchPanel = false;
      _isSearchMode = false;
    });
  }

  Widget _buildRouteSelectionPanel() {
    final isStartTarget = _routeSelectionTarget == 'start';
    final startLabel = _routeStartController.text.isEmpty
        ? 'Başlangıç noktasını seç'
        : _routeStartController.text;
    final destinationLabel = _routeDestinationController.text.isEmpty
        ? 'Varış noktasını seç'
        : _routeDestinationController.text;

    Widget locationCard({
      required String label,
      required String value,
      required IconData icon,
      required bool selected,
      required VoidCallback onTap,
    }) {
      return Expanded(
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: selected
                  ? const Color(0xFF2A180D)
                  : const Color(0xFF1F1F1F),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: selected
                    ? const Color(0xFFFF6B00)
                    : const Color(0xFF333333),
                width: selected ? 1.4 : 1,
              ),
            ),
            child: Row(
              children: [
                Icon(icon, color: const Color(0xFFFF6B00), size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        value,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF171717),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFF333333)),
      ),
      child: Column(
        children: [
          Row(
            children: [
              locationCard(
                label: 'BAŞLANGIÇ',
                value: startLabel,
                icon: Icons.trip_origin_rounded,
                selected: isStartTarget,
                onTap: () => setState(() => _routeSelectionTarget = 'start'),
              ),
              const SizedBox(width: 8),
              locationCard(
                label: 'VARIŞ',
                value: destinationLabel,
                icon: Icons.location_on_rounded,
                selected: !isStartTarget,
                onTap: () =>
                    setState(() => _routeSelectionTarget = 'destination'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              const Icon(
                Icons.touch_app_rounded,
                color: Color(0xFFFF6B00),
                size: 16,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  isStartTarget
                      ? 'Haritada başlangıç noktasına dokun'
                      : 'Haritada varış noktasına dokun',
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Rota seçimini kapat',
                onPressed: () => setState(() => _routeSelectionTarget = null),
                icon: const Icon(Icons.close_rounded, size: 18),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _handleRouteMapTap(LatLng coordinate) async {
    final target = _routeSelectionTarget;
    if (target == null) return;
    final label = await _routeCoordinateLabel(coordinate);
    if (!mounted) return;
    setState(() {
      if (target == 'start') {
        _routeDraftStart = coordinate;
        _routeStartController.text = label;
        _routeSelectionTarget = 'destination';
      } else {
        _routeDraftDestination = coordinate;
        _routeDestinationController.text = label;
        _routeSelectionTarget = 'start';
      }
    });

    if (target == 'destination') {
      await Future<void>.delayed(const Duration(milliseconds: 120));
      if (mounted &&
          _routeDraftStart != null &&
          _routeDraftDestination != null) {
        await _showRouteCreatorSheet();
      }
    }
  }

  Future<Map<String, String>?> _calculateRouteEstimate({
    LatLng? startCoordinate,
    LatLng? destinationCoordinate,
    required String vehicle,
  }) async {
    if (startCoordinate == null || destinationCoordinate == null) return null;

    try {
      final route = await _fetchRoadRoute(
        startCoordinate,
        destinationCoordinate,
        vehicle: vehicle,
      );
      return {
        'distance_km': (route['distanceKm'] as double).toStringAsFixed(1),
        'duration_minutes': '${route['durationMinutes']}',
      };
    } catch (error) {
      debugPrint('Rota hesaplanamadı: $error');
      if (mounted) {
        _showTrackingMessage(
          'Yol rotası hesaplanamadı. İnternet bağlantınızı ve Google Routes API ayarlarını kontrol edin.',
        );
      }
      return null;
    }
  }

  Future<String> _routeCoordinateLabel(LatLng coordinate) async {
    try {
      final placemarks = await geo_coding.placemarkFromCoordinates(
        coordinate.latitude,
        coordinate.longitude,
      );
      return _formatPlacemark(placemarks.isEmpty ? null : placemarks.first) ??
          '${coordinate.latitude.toStringAsFixed(5)}, ${coordinate.longitude.toStringAsFixed(5)}';
    } catch (_) {
      return '${coordinate.latitude.toStringAsFixed(5)}, ${coordinate.longitude.toStringAsFixed(5)}';
    }
  }

  void _selectRoutePointOnMap(String target) {
    FocusManager.instance.primaryFocus?.unfocus();
    Navigator.of(context).pop();
    setState(() {
      _selectedIndex = 1;
      _routeSelectionTarget = target;
      _showSearchPanel = false;
    });
  }

  Future<void> _showRouteCreatorSheet() async {
    final initialStart = _routeDraftStart;
    final initialDestination = _routeDraftDestination;
    if (initialStart == null && initialDestination == null) {
      _routeTitleController.clear();
    }
    if (initialStart == null) _routeStartController.clear();
    if (initialDestination == null) _routeDestinationController.clear();
    _routeDistanceController.clear();

    Map<String, String>? calculatedRoute;
    bool isCalculating = false;
    bool publishToDiscover = false;
    final routeVehicle = _selectedVehicle == 'Yürüyüş' ? 'Yürüyüş' : 'Araba';
    LatLng? selectedStart = initialStart;
    LatLng? selectedDestination = initialDestination;
    final route = await showModalBottomSheet<Map<String, String>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF191919),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) => Padding(
          padding: EdgeInsets.fromLTRB(
            20,
            20,
            20,
            MediaQuery.of(context).viewInsets.bottom + 20,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Yeni Rota Oluştur',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close, color: Colors.white70),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _routeTitleController,
                  textInputAction: TextInputAction.next,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    labelText: 'Rota adı',
                    prefixIcon: Icon(Icons.bookmark_outline),
                    labelStyle: const TextStyle(color: Color(0xFFBDBDBD)),
                    prefixIconColor: const Color(0xFFFF7A00),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: Color(0xFF333333)),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: Color(0xFFFF7A00)),
                    ),
                    filled: true,
                    fillColor: const Color(0xFF1F1F1F),
                  ),
                ),
                const SizedBox(height: 12),
                ListTile(
                  onTap: () => _selectRoutePointOnMap('start'),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                  tileColor: const Color(0xFF1A1A1A),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                  leading: const Icon(
                    Icons.trip_origin,
                    color: Color(0xFFFF6B00),
                  ),
                  title: Text(
                    _routeStartController.text.isEmpty
                        ? 'Başlangıç noktasını seç'
                        : _routeStartController.text,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                ListTile(
                  onTap: () => _selectRoutePointOnMap('destination'),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                  tileColor: const Color(0xFF1A1A1A),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                  leading: const Icon(
                    Icons.location_on_outlined,
                    color: Color(0xFFFF6B00),
                  ),
                  title: Text(
                    _routeDestinationController.text.isEmpty
                        ? 'Varış noktasını seç'
                        : _routeDestinationController.text,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: isCalculating
                        ? null
                        : () async {
                            setSheetState(() => isCalculating = true);
                            final estimate = await _calculateRouteEstimate(
                              startCoordinate: selectedStart,
                              destinationCoordinate: selectedDestination,
                              vehicle: routeVehicle,
                            );
                            if (!mounted) return;
                            setSheetState(() {
                              calculatedRoute = estimate;
                              isCalculating = false;
                            });
                          },
                    icon: isCalculating
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Color(0xFFFF7A00),
                            ),
                          )
                        : const Icon(
                            Icons.route_rounded,
                            color: Color(0xFFFF7A00),
                          ),
                    label: Text(
                      isCalculating ? 'Hesaplanıyor...' : 'Rotayı hesapla',
                    ),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFFFF7A00),
                      side: const BorderSide(color: Color(0xFFFF7A00)),
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
                if (calculatedRoute != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: const Color(0xFF2A180D),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        _buildRouteSummary(
                          Icons.straighten_rounded,
                          '${calculatedRoute!['distance_km']} km',
                          'Yaklaşık mesafe',
                          valueColor: Colors.white,
                          labelColor: Colors.white70,
                        ),
                        _buildRouteSummary(
                          Icons.schedule_rounded,
                          '${calculatedRoute!['duration_minutes']} dk',
                          'Tahmini süre',
                          valueColor: Colors.white,
                          labelColor: Colors.white70,
                        ),
                      ],
                    ),
                  ),
                ],
                CheckboxListTile(
                  value: publishToDiscover,
                  onChanged: FirebaseAuth.instance.currentUser == null
                      ? null
                      : (value) => setSheetState(
                          () => publishToDiscover = value ?? false,
                        ),
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  activeColor: const Color(0xFFFF7A00),
                  title: const Text(
                    'Herkese açık rota keşfinde yayımla',
                    style: TextStyle(color: Colors.white, fontSize: 13),
                  ),
                  subtitle: Text(
                    FirebaseAuth.instance.currentUser == null
                        ? 'Yayımlamak için giriş yapmalısınız.'
                        : 'Başlangıç ve varış noktaları diğer kullanıcılara görünür.',
                    style: const TextStyle(color: Colors.white70, fontSize: 11),
                  ),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: () {
                      final title = _routeTitleController.text.trim();
                      final start = _routeStartController.text.trim();
                      final destination = _routeDestinationController.text
                          .trim();
                      if (title.isEmpty ||
                          start.isEmpty ||
                          destination.isEmpty ||
                          selectedStart == null ||
                          selectedDestination == null ||
                          calculatedRoute == null) {
                        return;
                      }
                      Navigator.pop(context, {
                        'title': title,
                        'start': start,
                        'destination': destination,
                        'distance_km': calculatedRoute!['distance_km']!,
                        'duration_minutes':
                            calculatedRoute!['duration_minutes']!,
                        'start_latitude': selectedStart.latitude.toString(),
                        'start_longitude': selectedStart.longitude.toString(),
                        'destination_latitude': selectedDestination.latitude
                            .toString(),
                        'destination_longitude': selectedDestination.longitude
                            .toString(),
                        'travel_mode': routeVehicle,
                        'is_public': publishToDiscover.toString(),
                      });
                    },
                    icon: const Icon(Icons.save_outlined),
                    label: const Text('Rotayı Kaydet'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFFF7A00),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Mesafe ve süre yaklaşık hesaplanır. Kaydettikten sonra rotaya dokunarak haritada görüntüleyebilirsiniz.',
                  style: const TextStyle(fontSize: 11, color: Colors.white70),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );

    if (route == null || !mounted) return;
    final user = FirebaseAuth.instance.currentUser;
    final shouldPublish = route['is_public'] == 'true';
    if (shouldPublish && user == null) {
      _showTrackingMessage('Rota yayımlamak için hesabınıza giriş yapın.');
      return;
    }

    if (user != null) {
      final routesCollection = FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .collection('saved_routes');
      final savedRouteReference = routesCollection.doc();
      final batch = FirebaseFirestore.instance.batch();
      final privateRoute = <String, dynamic>{
        ...route,
        'created_at': FieldValue.serverTimestamp(),
      };
      if (shouldPublish) {
        final publicRouteReference = FirebaseFirestore.instance
            .collection('public_routes')
            .doc();
        privateRoute['public_route_id'] = publicRouteReference.id;
        batch.set(publicRouteReference, {
          'owner_uid': user.uid,
          'title': route['title'],
          'start': route['start'],
          'destination': route['destination'],
          'start_latitude': double.parse(route['start_latitude']!),
          'start_longitude': double.parse(route['start_longitude']!),
          'destination_latitude': double.parse(route['destination_latitude']!),
          'destination_longitude': double.parse(
            route['destination_longitude']!,
          ),
          'distance_km': double.parse(route['distance_km']!),
          'duration_minutes': int.parse(route['duration_minutes']!),
          'travel_mode': route['travel_mode'],
          'created_at': FieldValue.serverTimestamp(),
        });
      }
      batch.set(savedRouteReference, privateRoute);
      try {
        await batch.commit();
        route['id'] = savedRouteReference.id;
        if (shouldPublish) {
          route['public_route_id'] = privateRoute['public_route_id'] as String;
        }
      } catch (error) {
        debugPrint('Kayıtlı rota yazılamadı: $error');
        if (mounted) {
          _showTrackingMessage('Rota kaydedilemedi. Lütfen tekrar deneyin.');
        }
        return;
      }
    }

    setState(() {
      _savedRoutes.insert(0, Map<String, String>.from(route));
      _routeDraftStart = null;
      _routeDraftDestination = null;
      _routeSelectionTarget = null;
      if (!_isNavigationActive) {
        _routePolylines = const <Polyline>[];
        _alternativeRoutePolylines = const <Polyline>[];
        _navigationTrafficPolylines = const <Polyline>[];
      }
    });
    if (!mounted) return;
    AppNotificationService.show(
      shouldPublish
          ? 'Rota kaydedildi ve keşfe yayımlandı.'
          : 'Rota kaydedildi: ${route['distance_km']} km • ${route['duration_minutes']} dk',
    );
  }

  Widget _buildCompactRouteMetric(IconData icon, String value, String label) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, color: const Color(0xFFFF8A24), size: 17),
        const SizedBox(width: 7),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              value,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
            Text(
              label,
              style: const TextStyle(color: Color(0xFFBDBDBD), fontSize: 10),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildRouteSummary(
    IconData icon,
    String value,
    String label, {
    Color valueColor = Colors.white,
    Color labelColor = const Color(0xFFB8C2D6),
  }) {
    return Column(
      children: [
        Icon(icon, color: const Color(0xFFFF7A00), size: 21),
        const SizedBox(height: 4),
        Text(
          value,
          style: TextStyle(color: valueColor, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 2),
        Text(label, style: TextStyle(color: labelColor, fontSize: 10)),
      ],
    );
  }

  Future<void> _shareSavedRoute(Map<String, dynamic> route) async {
    final title = route['title']?.toString().trim();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Rotayı paylaş'),
        content: const Text(
          'Paylaşım bağlantısını alan herkes rotanın başlangıç ve varış '
          'konumlarını görebilir. Yalnızca güvendiğiniz kişilerle paylaşın.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Vazgeç'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Paylaş'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    String? resolveLocation({
      required String latitudeKey,
      required String longitudeKey,
      required String address,
    }) {
      final latitude = double.tryParse(route[latitudeKey]?.toString() ?? '');
      final longitude = double.tryParse(route[longitudeKey]?.toString() ?? '');
      if (latitude != null &&
          longitude != null &&
          latitude >= -90 &&
          latitude <= 90 &&
          longitude >= -180 &&
          longitude <= 180) {
        return '$latitude,$longitude';
      }
      return address.isEmpty ? null : address;
    }

    try {
      final start = resolveLocation(
        latitudeKey: 'start_latitude',
        longitudeKey: 'start_longitude',
        address: route['start']?.toString().trim() ?? '',
      );
      final destination = resolveLocation(
        latitudeKey: 'destination_latitude',
        longitudeKey: 'destination_longitude',
        address: route['destination']?.toString().trim() ?? '',
      );
      if (!mounted) return;
      if (start == null || destination == null) {
        _showTrackingMessage(
          'Rota bağlantısı oluşturulamadı. Başlangıç ve varış konumlarını kontrol edin.',
        );
        return;
      }

      final travelMode = route['travel_mode'] == 'Yürüyüş'
          ? 'walking'
          : 'driving';
      final directionsUrl = Uri.https('www.google.com', '/maps/dir/', {
        'api': '1',
        'origin': start,
        'destination': destination,
        'travelmode': travelMode,
      });
      final shareText =
          '${title == null || title.isEmpty ? 'Navora rotası' : title}\n'
          '${route['start']} → ${route['destination']}\n'
          '$directionsUrl';
      try {
        await SharePlus.instance.share(
          ShareParams(
            subject: title == null || title.isEmpty ? 'Navora rotası' : title,
            text: shareText,
          ),
        );
      } catch (error) {
        debugPrint('Sistem paylaşım menüsü açılamadı: $error');
        await Clipboard.setData(ClipboardData(text: shareText));
        if (mounted) {
          _showTrackingMessage(
            'Paylaşım menüsü açılamadı; rota bağlantısı panoya kopyalandı.',
          );
        }
      }
    } catch (error) {
      debugPrint('Kayıtlı rota paylaşılamadı: $error');
      if (mounted) {
        _showTrackingMessage(
          'Rota paylaşılamadı. Bağlantıyı panoya kopyalamak için tekrar deneyin.',
        );
      }
    }
  }

  Future<void> _showSavedRouteOnMap(Map<String, dynamic> route) async {
    if (_isNavigationActive) {
      _showTrackingMessage(
        'Navigasyon devam ederken kayıtlı rota görüntülenemiyor.',
      );
      return;
    }

    LatLng? coordinateFromFields(String latitudeKey, String longitudeKey) {
      final latitude = double.tryParse(route[latitudeKey]?.toString() ?? '');
      final longitude = double.tryParse(route[longitudeKey]?.toString() ?? '');
      if (latitude == null ||
          longitude == null ||
          latitude < -90 ||
          latitude > 90 ||
          longitude < -180 ||
          longitude > 180) {
        return null;
      }
      return LatLng(latitude, longitude);
    }

    Future<LatLng?> resolveCoordinate({
      required String latitudeKey,
      required String longitudeKey,
      required String address,
    }) async {
      final storedCoordinate = coordinateFromFields(latitudeKey, longitudeKey);
      if (storedCoordinate != null) return storedCoordinate;
      if (address.isEmpty) return null;
      final locations = await geo_coding.locationFromAddress(address);
      if (locations.isEmpty) return null;
      final location = locations.first;
      return LatLng(location.latitude, location.longitude);
    }

    final startText = route['start']?.toString().trim() ?? '';
    final destinationText = route['destination']?.toString().trim() ?? '';
    final vehicle = route['travel_mode'] == 'Yürüyüş' ? 'Yürüyüş' : 'Araba';

    try {
      final start = await resolveCoordinate(
        latitudeKey: 'start_latitude',
        longitudeKey: 'start_longitude',
        address: startText,
      );
      final destination = await resolveCoordinate(
        latitudeKey: 'destination_latitude',
        longitudeKey: 'destination_longitude',
        address: destinationText,
      );
      if (start == null || destination == null) {
        _showTrackingMessage(
          'Kayıtlı rotanın başlangıç veya varış konumu bulunamadı.',
        );
        return;
      }

      setState(() {
        _selectedIndex = 1;
        _routePolylines = const <Polyline>[];
        _alternativeRoutePolylines = const <Polyline>[];
        _navigationTrafficPolylines = const <Polyline>[];
        _selectedDestinationCoordinate = destination;
        _selectedDestinationName = destinationText;
        _searchController.text = destinationText;
        _selectedVehicle = vehicle;
      });

      final roadRoute = await _fetchRoadRoute(
        start,
        destination,
        vehicle: vehicle,
      );
      if (!mounted) return;
      final points = roadRoute['points'] as List<LatLng>;
      setState(() {
        _routePolylines = [
          Polyline(
            polylineId: const PolylineId('saved-route-preview'),
            points: points,
            color: const Color(0xFF4285F4),
            width: 6,
          ),
        ];
      });
      await _fitMapToPoints(points);
      if (mounted) _showTrackingMessage('Rota haritada gösteriliyor.');
    } catch (error) {
      debugPrint('Kayıtlı rota haritada gösterilemedi: $error');
      if (mounted) {
        _showTrackingMessage(
          'Rota haritada gösterilemedi. İnternet bağlantınızı ve Google Routes API ayarlarını kontrol edin.',
        );
      }
    }
  }

  Future<void> _startSavedRoute(Map<String, dynamic> route) async {
    final destinationText = route['destination']?.toString().trim();
    if (destinationText == null || destinationText.isEmpty) return;

    try {
      final savedLatitude = double.tryParse(
        route['destination_latitude']?.toString() ?? '',
      );
      final savedLongitude = double.tryParse(
        route['destination_longitude']?.toString() ?? '',
      );
      final savedDestination =
          savedLatitude != null &&
              savedLongitude != null &&
              savedLatitude >= -90 &&
              savedLatitude <= 90 &&
              savedLongitude >= -180 &&
              savedLongitude <= 180
          ? LatLng(savedLatitude, savedLongitude)
          : null;
      final locations = savedDestination == null
          ? await geo_coding.locationFromAddress(destinationText)
          : const <geo_coding.Location>[];
      if ((savedDestination == null && locations.isEmpty) || !mounted) {
        _showTrackingMessage('Kayıtlı rotanın varış konumu bulunamadı.');
        return;
      }
      setState(() {
        _selectedIndex = 1;
        _selectedVehicle = route['travel_mode'] == 'Yürüyüş'
            ? 'Yürüyüş'
            : 'Araba';
        _searchController.text = destinationText;
        _selectedDestinationName =
            route['title']?.toString().trim().isNotEmpty == true
            ? route['title'].toString()
            : destinationText;
        _selectedPlaceDetails = null;
        _selectedDestinationCoordinate =
            savedDestination ??
            LatLng(locations.first.latitude, locations.first.longitude);
      });
      await _showDirectionsSheet();
    } catch (error) {
      debugPrint('Kayıtlı rota başlatılamadı: $error');
      _showTrackingMessage('Kayıtlı rota başlatılamadı.');
    }
  }

  Future<void> _saveDiscoveredRoute(
    Map<String, dynamic> publicRoute,
    String publicRouteId,
  ) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      _showTrackingMessage('Rotayı kaydetmek için hesabınıza giriş yapın.');
      return;
    }
    if (_savedRoutes.any(
      (route) => route['public_route_id'] == publicRouteId,
    )) {
      _showTrackingMessage('Bu rota kayıtlı rotalarınızda zaten var.');
      return;
    }

    try {
      final savedReference = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .collection('saved_routes')
          .add({
            'title': publicRoute['title']?.toString() ?? 'Topluluk rotası',
            'start': publicRoute['start']?.toString() ?? '',
            'destination': publicRoute['destination']?.toString() ?? '',
            'start_latitude': publicRoute['start_latitude'].toString(),
            'start_longitude': publicRoute['start_longitude'].toString(),
            'destination_latitude': publicRoute['destination_latitude']
                .toString(),
            'destination_longitude': publicRoute['destination_longitude']
                .toString(),
            'distance_km': publicRoute['distance_km'].toString(),
            'duration_minutes': publicRoute['duration_minutes'].toString(),
            'travel_mode': publicRoute['travel_mode']?.toString() ?? 'Araba',
            'is_public': 'false',
            'public_route_id': publicRouteId,
            'created_at': FieldValue.serverTimestamp(),
          });
      if (!mounted) return;
      setState(() {
        _savedRoutes.insert(0, {
          'id': savedReference.id,
          'title': publicRoute['title']?.toString() ?? 'Topluluk rotası',
          'start': publicRoute['start']?.toString() ?? '',
          'destination': publicRoute['destination']?.toString() ?? '',
          'start_latitude': publicRoute['start_latitude'].toString(),
          'start_longitude': publicRoute['start_longitude'].toString(),
          'destination_latitude': publicRoute['destination_latitude']
              .toString(),
          'destination_longitude': publicRoute['destination_longitude']
              .toString(),
          'distance_km': publicRoute['distance_km'].toString(),
          'travel_mode': publicRoute['travel_mode']?.toString() ?? 'Araba',
          'is_public': 'false',
          'public_route_id': publicRouteId,
        });
      });
      _showTrackingMessage('Rota kayıtlı rotalarınıza eklendi.');
    } catch (error) {
      debugPrint('Keşfedilen rota kaydedilemedi: $error');
      if (mounted) {
        _showTrackingMessage('Rota kaydedilemedi. Lütfen tekrar deneyin.');
      }
    }
  }

  void _showPublicRoutesSheet() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF191919),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) => SizedBox(
        height: MediaQuery.of(sheetContext).size.height * 0.72,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Rota keşfet',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(sheetContext),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const Text(
                'Topluluğun paylaştığı rotaları görüntüle veya kaydet.',
                style: TextStyle(color: Colors.white70, fontSize: 12),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: FirebaseAuth.instance.currentUser == null
                    ? const Center(
                        child: Text(
                          'Topluluk rotalarını keşfetmek için giriş yapın.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.white70),
                        ),
                      )
                    : StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                        stream: FirebaseFirestore.instance
                            .collection('public_routes')
                            .orderBy('created_at', descending: true)
                            .limit(50)
                            .snapshots(),
                        builder: (context, snapshot) {
                          if (snapshot.hasError) {
                            debugPrint(
                              'Topluluk rotaları yüklenemedi: ${snapshot.error}',
                            );
                            return const Center(
                              child: Text(
                                'Topluluk rotaları yüklenemedi.',
                                style: TextStyle(color: Colors.white70),
                              ),
                            );
                          }
                          if (snapshot.connectionState ==
                              ConnectionState.waiting) {
                            return const Center(
                              child: CircularProgressIndicator(),
                            );
                          }
                          final documents = snapshot.data?.docs ?? [];
                          if (documents.isEmpty) {
                            return const Center(
                              child: Text(
                                'Henüz herkese açık rota yok.',
                                style: TextStyle(color: Colors.white70),
                              ),
                            );
                          }
                          return ListView.separated(
                            itemCount: documents.length,
                            separatorBuilder: (_, _) =>
                                const SizedBox(height: 8),
                            itemBuilder: (context, index) {
                              final document = documents[index];
                              final route = document.data();
                              final routeMap = <String, dynamic>{
                                ...route,
                                'public_route_id': document.id,
                              };
                              final isSaved = _savedRoutes.any(
                                (savedRoute) =>
                                    savedRoute['public_route_id'] ==
                                    document.id,
                              );
                              return ListTile(
                                onTap: () {
                                  Navigator.pop(sheetContext);
                                  unawaited(_showSavedRouteOnMap(routeMap));
                                },
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                tileColor: const Color(0xFF242424),
                                leading: const CircleAvatar(
                                  backgroundColor: Color(0xFF2A180D),
                                  child: Icon(
                                    Icons.alt_route,
                                    color: Color(0xFFFF6B00),
                                  ),
                                ),
                                title: Text(
                                  route['title']?.toString() ??
                                      'Topluluk rotası',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                subtitle: Text(
                                  '${route['start']} → ${route['destination']} • ${route['distance_km']} km • ${route['travel_mode']}',
                                ),
                                trailing: IconButton(
                                  tooltip: isSaved
                                      ? 'Zaten kayıtlı'
                                      : 'Rotayı kaydet',
                                  onPressed: isSaved
                                      ? null
                                      : () => unawaited(
                                          _saveDiscoveredRoute(
                                            routeMap,
                                            document.id,
                                          ),
                                        ),
                                  icon: Icon(
                                    isSaved
                                        ? Icons.bookmark_rounded
                                        : Icons.bookmark_add_outlined,
                                    color: const Color(0xFFFF9A3D),
                                  ),
                                ),
                              );
                            },
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _deleteSavedRoute(Map<String, String> route) async {
    final user = FirebaseAuth.instance.currentUser;
    final routeId = route['id'];
    if (user != null && routeId != null && routeId.isNotEmpty) {
      final firestore = FirebaseFirestore.instance;
      final batch = firestore.batch();
      batch.delete(
        firestore
            .collection('users')
            .doc(user.uid)
            .collection('saved_routes')
            .doc(routeId),
      );
      final publicRouteId = route['public_route_id'];
      if (route['is_public'] == 'true' &&
          publicRouteId != null &&
          publicRouteId.isNotEmpty) {
        batch.delete(firestore.collection('public_routes').doc(publicRouteId));
      }
      try {
        await batch.commit();
      } catch (error) {
        debugPrint('Kayıtlı rota silinemedi: $error');
        if (mounted) {
          _showTrackingMessage('Rota silinemedi. Lütfen tekrar deneyin.');
        }
        return;
      }
    }
    if (!mounted) return;
    setState(() => _savedRoutes.remove(route));
    _showTrackingMessage('Kayıtlı rota silindi.');
  }

  void _showSavedRoutesSheet() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF191919),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) => SizedBox(
        height: MediaQuery.of(context).size.height * 0.6,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Kayıtlı Rotalar',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                  ),
                  Row(
                    children: [
                      IconButton(
                        tooltip: 'Rota keşfet',
                        onPressed: () {
                          Navigator.pop(context);
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            if (mounted) _showPublicRoutesSheet();
                          });
                        },
                        icon: const Icon(Icons.explore_outlined),
                      ),
                      IconButton(
                        tooltip: 'Yeni rota kaydet',
                        onPressed: () async {
                          Navigator.pop(context);
                          await _showRouteCreatorSheet();
                        },
                        icon: const Icon(Icons.add_road),
                      ),
                      IconButton(
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Expanded(
                child: _savedRoutes.isEmpty
                    ? Center(
                        child: Text(
                          'Henüz kayıtlı rota yok.',
                          style: TextStyle(color: Colors.grey.shade600),
                        ),
                      )
                    : ListView.separated(
                        itemCount: _savedRoutes.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 8),
                        itemBuilder: (context, index) {
                          final route = _savedRoutes[index];
                          return ListTile(
                            onTap: () async {
                              Navigator.pop(context);
                              await _showSavedRouteOnMap(route);
                            },
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                            tileColor: const Color(0xFF1B1B1B),
                            leading: const CircleAvatar(
                              backgroundColor: Color(0xFF2A180D),
                              child: Icon(
                                Icons.alt_route,
                                color: Color(0xFFFF6B00),
                              ),
                            ),
                            title: Text(
                              route['title']!,
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            subtitle: Text(
                              '${route['start']}  →  ${route['destination']} • ${route['distance_km'] ?? '?'} km • ${route['travel_mode'] ?? 'Araba'}',
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  tooltip: 'Rotayı paylaş',
                                  icon: const Icon(
                                    Icons.share_rounded,
                                    color: Color(0xFFFF9A3D),
                                  ),
                                  onPressed: () => _shareSavedRoute(route),
                                ),
                                IconButton(
                                  tooltip: 'Rotayı başlat',
                                  icon: const Icon(
                                    Icons.navigation_rounded,
                                    color: Color(0xFFFF6B00),
                                  ),
                                  onPressed: () async {
                                    Navigator.pop(context);
                                    await _startSavedRoute(route);
                                  },
                                ),
                                IconButton(
                                  tooltip: 'Rotayı sil',
                                  icon: const Icon(
                                    Icons.delete_outline,
                                    color: Colors.red,
                                  ),
                                  onPressed: () async {
                                    await _deleteSavedRoute(route);
                                    if (mounted) setState(() {});
                                  },
                                ),
                              ],
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _startLocationTracking() async {
    try {
      if (!await _ensureLocationPermission()) return;
      final position = await geo.Geolocator.getCurrentPosition(
        locationSettings: const geo.LocationSettings(
          accuracy: geo.LocationAccuracy.high,
        ),
      );
      if (!mounted) return;

      await _locationPositionSubscription?.cancel();
      _locationPositionSubscription =
          geo.Geolocator.getPositionStream(
            locationSettings: const geo.LocationSettings(
              accuracy: geo.LocationAccuracy.high,
              distanceFilter: 5,
            ),
          ).listen(
            _handleLocationPosition,
            onError: (Object error) {
              debugPrint('Konum akışı durdu: $error');
              if (!mounted) return;
              setState(() => _isLocationTracking = false);
              unawaited(_stopCompassTracking());
              _showTrackingMessage(
                'Konum takibi durdu. GPS ayarlarını kontrol edin.',
              );
            },
          );

      setState(() {
        _currentPosition = position;
        _isLocationTracking = true;
        _isFollowingCurrentPosition = true;
      });
      await _startCompassTracking();
      await _centerOnPosition(position);
    } catch (error) {
      debugPrint('Konum alınırken hata: $error');
      _showTrackingMessage('Konum alınamadı. GPS ayarlarını kontrol edin.');
    }
  }

  void _handleLocationPosition(geo.Position position) {
    if (!mounted) return;
    setState(() => _currentPosition = position);
    unawaited(_updateCurrentAddress(position));
    if (navoraShouldFollowCurrentPosition(
      isNavigationActive: _isNavigationActive,
      isDriveTracking: _isDriveTracking,
      isLocationTracking: _isLocationTracking,
      isFollowing: _isFollowingCurrentPosition,
    )) {
      Future.microtask(() => _centerOnPosition(position));
    }
  }

  Future<void> _toggleDriveTracking() async {
    if (_isStartingDriveTracking) return;
    try {
      if (_isDriveTracking) {
        await _stopDriveTracking();
        return;
      }

      _isStartingDriveTracking = true;
      if (!await _ensureLocationPermission()) {
        _resetNavigationAfterFailedStart();
        return;
      }

      final startedForNavigation = _isNavigationActive;
      await _locationPositionSubscription?.cancel();
      _locationPositionSubscription = null;
      _isLocationTracking = false;

      final position = await geo.Geolocator.getCurrentPosition(
        locationSettings: const geo.LocationSettings(
          accuracy: geo.LocationAccuracy.medium,
        ),
      ).timeout(const Duration(seconds: 20));
      _lastDrivePosition = position;
      _currentPosition = position;
      if (startedForNavigation) {
        _navigationStartPosition = LatLng(
          position.latitude,
          position.longitude,
        );
      }
      _driveStartedAt = DateTime.now();
      _driveDistanceKm = 0;
      _driveStartedForNavigation = startedForNavigation;
      final destination = _selectedDestinationCoordinate;
      _navigationStartDistanceToDestinationMeters =
          startedForNavigation && destination != null
          ? geo.Geolocator.distanceBetween(
              position.latitude,
              position.longitude,
              destination.latitude,
              destination.longitude,
            )
          : null;
      _positionSubscription = geo.Geolocator.getPositionStream(
        locationSettings: geo.LocationSettings(
          accuracy: geo.LocationAccuracy.high,
          distanceFilter: startedForNavigation ? 1 : 5,
        ),
      ).listen(_handleDrivePosition);
      if (!mounted) return;
      setState(() {
        _isDriveTracking = true;
      });
      await _updateScreenWakeLock();
      if (_isNavigationActive) {
        _startNavigationConnectivityMonitor();
      }
      try {
        await _startCompassTracking();
      } catch (error) {
        debugPrint('Navigasyon pusulası başlatılamadı: $error');
      }
      try {
        await _centerOnPosition(position);
      } catch (error) {
        debugPrint('Navigasyon haritası konuma alınamadı: $error');
      }
    } catch (error) {
      debugPrint('Sürüş takibi başlatılamadı: $error');
      await _positionSubscription?.cancel();
      _positionSubscription = null;
      await _stopCompassTracking();
      _driveStartedAt = null;
      _lastDrivePosition = null;
      _driveDistanceKm = 0;
      _driveStartedForNavigation = false;
      _resetNavigationAfterFailedStart();
      if (mounted) {
        setState(() => _isDriveTracking = false);
        unawaited(_updateScreenWakeLock());
        _showTrackingMessage(
          'Navigasyon başlatılamadı. GPS bağlantınızı kontrol edip tekrar deneyin.',
        );
      }
    } finally {
      _isStartingDriveTracking = false;
    }
  }

  void _resetNavigationAfterFailedStart() {
    void reset() {
      _isNavigationActive = false;
      _isMapTilted = false;
      _isFollowingCurrentPosition = true;
      _navigationConnectivityTimer?.cancel();
      _navigationConnectivityTimer = null;
    }

    if (mounted) {
      setState(reset);
    } else {
      reset();
    }
    unawaited(_updateScreenWakeLock());
  }

  Future<void> _updateScreenWakeLock({bool? forceEnabled}) {
    _screenWakeLockQueue = _screenWakeLockQueue.then((_) async {
      final shouldKeepAwake =
          forceEnabled ?? (_isNavigationActive || _isDriveTracking);
      try {
        await WakelockPlus.toggle(enable: shouldKeepAwake);
      } on PlatformException catch (error) {
        debugPrint('Ekran açık tutulamadı: $error');
        if (shouldKeepAwake && mounted) {
          _showTrackingMessage('Navigasyon sırasında ekran açık tutulamadı.');
        }
      } on MissingPluginException catch (error) {
        debugPrint('Ekran açık tutma özelliği kullanılamıyor: $error');
        if (shouldKeepAwake && mounted) {
          _showTrackingMessage('Navigasyon sırasında ekran açık tutulamadı.');
        }
      }
    });
    return _screenWakeLockQueue;
  }

  void _startNavigationConnectivityMonitor() {
    _navigationConnectivityTimer?.cancel();
    unawaited(_checkNavigationConnectivity());
    _navigationConnectivityTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => unawaited(_checkNavigationConnectivity()),
    );
  }

  Future<void> _checkNavigationConnectivity() async {
    if (!_isNavigationActive || _isCheckingNavigationNetwork) return;
    _isCheckingNavigationNetwork = true;
    final stopwatch = Stopwatch()..start();
    try {
      final response = await http
          .get(Uri.https('www.google.com', '/generate_204'))
          .timeout(const Duration(seconds: 5));
      stopwatch.stop();
      final isDegraded = navoraIsNetworkDegraded(
        stopwatch.elapsed,
        response.statusCode,
      );
      if (mounted && _isNetworkDegraded != isDegraded) {
        setState(() => _isNetworkDegraded = isDegraded);
      }
    } catch (error) {
      stopwatch.stop();
      debugPrint('Navigasyon internet bağlantısı kontrol edilemedi: $error');
      if (mounted && !_isNetworkDegraded) {
        setState(() => _isNetworkDegraded = true);
      }
    } finally {
      _isCheckingNavigationNetwork = false;
    }
  }

  Future<void> _loadLocationPermissionState() async {
    final permission = await geo.Geolocator.checkPermission();
    if (!mounted) return;
    if (permission == geo.LocationPermission.always ||
        permission == geo.LocationPermission.whileInUse) {
      setState(() => _locationPermissionGranted = true);
      if (defaultTargetPlatform != TargetPlatform.iOS ||
          !await geo.Geolocator.isLocationServiceEnabled()) {
        return;
      }
      try {
        final position =
            await geo.Geolocator.getLastKnownPosition() ??
            await geo.Geolocator.getCurrentPosition(
              locationSettings: const geo.LocationSettings(
                accuracy: geo.LocationAccuracy.medium,
              ),
            ).timeout(const Duration(seconds: 20));
        if (!mounted) return;
        setState(() => _currentPosition = position);
        await _centerOnPosition(position);
      } catch (error) {
        debugPrint('iOS konumu alınırken hata: $error');
      }
    }
  }

  Future<bool> _ensureLocationPermission() async {
    var permission = await geo.Geolocator.checkPermission();
    if (permission == geo.LocationPermission.denied) {
      permission = await geo.Geolocator.requestPermission();
    }
    if (permission == geo.LocationPermission.deniedForever) {
      _showTrackingMessage(
        'Konum izni kapalı. iPhone Ayarları’ndan Navora Map için izin verin.',
        actionLabel: 'Ayarlar',
        onAction: () => unawaited(geo.Geolocator.openAppSettings()),
      );
      return false;
    }
    if (permission == geo.LocationPermission.denied) {
      _showTrackingMessage('Konum izni gerekiyor.');
      return false;
    }

    if (!await geo.Geolocator.isLocationServiceEnabled()) {
      _showTrackingMessage(
        'Konum servisleri kapalı. iPhone konum ayarlarını açın.',
        actionLabel: 'Konum ayarları',
        onAction: () => unawaited(geo.Geolocator.openLocationSettings()),
      );
      return false;
    }

    if (mounted) setState(() => _locationPermissionGranted = true);
    return true;
  }

  Future<void> _handleDrivePosition(geo.Position position) async {
    final previousPosition = _lastDrivePosition;
    final hasReliableNavigationPosition =
        !_isNavigationActive ||
        navoraHasReliableNavigationPosition(position.accuracy);
    if (previousPosition != null &&
        hasReliableNavigationPosition &&
        (!_isNavigationActive ||
            navoraHasReliableNavigationPosition(previousPosition.accuracy))) {
      final deltaKm = navoraSafeDistanceKm(previousPosition, position);
      if (deltaKm > 0) {
        _driveDistanceKm += deltaKm;
      }
    }

    _lastDrivePosition = position;
    if (!mounted) return;
    if (position.heading.isFinite &&
        position.heading >= 0 &&
        position.heading < 360 &&
        position.speed >= 0.8) {
      _smoothedVehicleHeading = _smoothedVehicleHeading == null
          ? position.heading
          : navoraSmoothBearing(
              _smoothedVehicleHeading!,
              position.heading,
              factor: 0.28,
            );
    }
    setState(() {
      _currentPosition = position;
      _refreshLiveRoomDistances();
    });
    if (navoraShouldFollowCurrentPosition(
      isNavigationActive: _isNavigationActive,
      isDriveTracking: _isDriveTracking,
      isLocationTracking: _isLocationTracking,
      isFollowing: _isFollowingCurrentPosition,
    )) {
      unawaited(_centerOnPosition(position));
    }
    _updateCurrentAddress(position);

    if (hasReliableNavigationPosition) {
      _announceUpcomingNavigationStep(position);
      if (await _checkNavigationArrival(position)) return;
      unawaited(_refreshNavigationRouteIfNeeded(position));
      unawaited(_checkForFasterAlternativeRoute(position));
    }
  }

  Future<void> _checkForFasterAlternativeRoute(geo.Position position) async {
    if (!_isNavigationActive ||
        _isOffRoute ||
        _isNetworkDegraded ||
        _isCheckingFasterRoute ||
        _selectedDestinationCoordinate == null ||
        (_selectedVehicle != 'Araba' && _selectedVehicle != 'Motosiklet')) {
      return;
    }
    final now = DateTime.now();
    if (_lastFasterRouteCheckAt != null &&
        now.difference(_lastFasterRouteCheckAt!) < const Duration(minutes: 5)) {
      return;
    }

    _lastFasterRouteCheckAt = now;
    _isCheckingFasterRoute = true;
    try {
      final routes = await _fetchRoadRoute(
        LatLng(position.latitude, position.longitude),
        _selectedDestinationCoordinate!,
        vehicle: _selectedVehicle,
        includeAlternativeRoutes: true,
      );
      if (!mounted ||
          !_isNavigationActive ||
          _navigationDurationMinutes == null) {
        return;
      }
      final options =
          routes['options'] as List<Map<String, dynamic>>? ?? [routes];
      Map<String, dynamic>? fasterRoute;
      for (final option in options.skip(1)) {
        final minutes = option['durationMinutes'] as int?;
        if (minutes == null ||
            minutes >= _navigationDurationMinutes! ||
            _navigationDurationMinutes! - minutes < 3) {
          continue;
        }
        if (fasterRoute == null ||
            minutes < (fasterRoute['durationMinutes'] as int)) {
          fasterRoute = option;
        }
      }
      if (fasterRoute == null) return;
      setState(() {
        _fasterAlternativeRoute = fasterRoute;
        _fasterRouteMinutesSaved =
            _navigationDurationMinutes! -
            (fasterRoute!['durationMinutes'] as int);
      });
    } catch (error) {
      debugPrint('Daha hızlı rota kontrol edilemedi: $error');
    } finally {
      _isCheckingFasterRoute = false;
    }
  }

  void _switchToFasterAlternativeRoute() {
    final route = _fasterAlternativeRoute;
    final position = _currentPosition;
    if (route == null || position == null || !_isNavigationActive) return;
    final routePoints = route['points'] as List<LatLng>;
    final remainingRoute = navoraTrimRouteToRemainingPath(
      routePoints,
      LatLng(position.latitude, position.longitude),
      vehicle: _selectedVehicle,
    );
    setState(() {
      _routePolylines = [
        Polyline(
          polylineId: const PolylineId('route-live'),
          points: remainingRoute,
          color: const Color(0xFF4285F4),
          width: 7,
          zIndex: 2,
        ),
      ];
      _alternativeRoutePolylines = const [];
      _navigationTrafficPolylines =
          route['trafficPolylines'] as List<Polyline>? ?? const [];
      _navigationSteps = List<Map<String, dynamic>>.from(
        route['steps'] as List<Map<String, dynamic>>,
      );
      _navigationStepIndex = 0;
      _navigationDistanceKm = route['distanceKm'] as double;
      _navigationDurationMinutes = route['durationMinutes'] as int;
      _navigationDurationSeconds = _navigationDurationMinutes! * 60.0;
      _fasterAlternativeRoute = null;
      _fasterRouteMinutesSaved = null;
    });
    if (_isFollowingCurrentPosition) {
      unawaited(_centerOnPosition(position));
    }
  }

  Future<bool> _checkNavigationArrival(geo.Position position) async {
    final destination = _selectedDestinationCoordinate;
    if (!_isNavigationActive || destination == null) return false;
    final distanceMeters = geo.Geolocator.distanceBetween(
      position.latitude,
      position.longitude,
      destination.latitude,
      destination.longitude,
    );

    if (!_hasAnnouncedArrival && navoraIsWithinArrivalRadius(distanceMeters)) {
      _hasAnnouncedArrival = true;
      _showTrackingMessage('Varış noktanıza yaklaştınız.');
    }

    if (!navoraIsWithinNavigationCompletionRadius(distanceMeters) ||
        _isCompletingNavigation) {
      return _isCompletingNavigation;
    }

    _isCompletingNavigation = true;
    setState(() {
      _navigationDistanceKm = 0;
      _navigationDurationSeconds = 0;
      _navigationDurationMinutes = 0;
    });
    _showTrackingMessage('Varış noktanıza ulaştınız. Navigasyon tamamlandı.');
    await _stopDriveTracking(
      navigationCompleted: true,
      completionPosition: position,
      completionDistanceToDestinationMeters: distanceMeters,
    );
    return true;
  }

  Future<void> _stopDriveTracking({
    bool navigationCompleted = false,
    geo.Position? completionPosition,
    double? completionDistanceToDestinationMeters,
  }) async {
    await _positionSubscription?.cancel();
    _positionSubscription = null;
    await _stopCompassTracking();
    final startedAt = _driveStartedAt;
    final distance = double.parse(_driveDistanceKm.toStringAsFixed(2));
    final durationMinutes = startedAt == null
        ? 0
        : DateTime.now().difference(startedAt).inMinutes;
    final hasCompletedNavigationProgress =
        navigationCompleted &&
        completionPosition != null &&
        completionDistanceToDestinationMeters != null &&
        navoraHasCompletedRouteProgress(
          traveledDistanceKm: _driveDistanceKm,
          startDistanceToDestinationMeters:
              _navigationStartDistanceToDestinationMeters ?? double.nan,
          completionDistanceToDestinationMeters:
              completionDistanceToDestinationMeters,
        );
    final shouldSaveDriveHistory = navoraShouldSaveDriveHistory(
      startedForNavigation: _driveStartedForNavigation,
      hasCompletedNavigationProgress: hasCompletedNavigationProgress,
    );

    if (FirebaseAuth.instance.currentUser != null &&
        distance > 0 &&
        shouldSaveDriveHistory) {
      try {
        await _saveCompletedDrive(
          distance: distance,
          durationMinutes: durationMinutes,
          navigationCompleted: hasCompletedNavigationProgress,
        );
      } catch (error) {
        debugPrint('Tamamlanan sürüş kaydedilemedi: $error');
        if (mounted) {
          _showTrackingMessage(
            'Navigasyon durduruldu ancak sürüş geçmişi kaydedilemedi.',
          );
        }
      }
    }

    if (!mounted) return;
    setState(() {
      _isDriveTracking = false;
      _driveStartedForNavigation = false;
      _clearRouteState();
    });
    await _updateScreenWakeLock();
    await _resetNavigationCamera();
  }

  void _announceUpcomingNavigationStep(geo.Position position) {
    if (!_isNavigationActive ||
        !navoraHasReliableNavigationPosition(position.accuracy) ||
        _navigationStepIndex >= _navigationSteps.length) {
      return;
    }
    final step = _navigationSteps[_navigationStepIndex];
    final latitude = step['latitude'] as double?;
    final longitude = step['longitude'] as double?;
    if (latitude == null || longitude == null) return;

    final distance = geo.Geolocator.distanceBetween(
      position.latitude,
      position.longitude,
      latitude,
      longitude,
    );
    if (distance > 45) return;

    _navigationStepIndex++;
    if (mounted) setState(() {});
  }

  void _handleAccelerometer(sensors.AccelerometerEvent event) {
    _gravityX = _gravityX == null ? event.x : _gravityX! * 0.8 + event.x * 0.2;
    _gravityY = _gravityY == null ? event.y : _gravityY! * 0.8 + event.y * 0.2;
    _gravityZ = _gravityZ == null ? event.z : _gravityZ! * 0.8 + event.z * 0.2;
    _updateDeviceHeading();
  }

  void _handleMagnetometer(sensors.MagnetometerEvent event) {
    _magneticField = event;
    _updateDeviceHeading();
  }

  void _updateDeviceHeading() {
    final gravityX = _gravityX;
    final gravityY = _gravityY;
    final gravityZ = _gravityZ;
    final magneticField = _magneticField;
    if (gravityX == null ||
        gravityY == null ||
        gravityZ == null ||
        magneticField == null) {
      return;
    }

    final heading = navoraCalculateCompassHeading(
      accelerationX: gravityX,
      accelerationY: gravityY,
      accelerationZ: gravityZ,
      magneticX: magneticField.x,
      magneticY: magneticField.y,
      magneticZ: magneticField.z,
    );
    if (heading == null) return;
    _deviceHeading = _deviceHeading == null
        ? heading
        : navoraSmoothBearing(_deviceHeading!, heading, factor: 0.2);
    _queueCompassCameraUpdate();
  }

  Future<void> _startCompassTracking() async {
    await _accelerometerSubscription?.cancel();
    await _magnetometerSubscription?.cancel();
    _gravityX = null;
    _gravityY = null;
    _gravityZ = null;
    _magneticField = null;
    _accelerometerSubscription = sensors
        .accelerometerEventStream(
          samplingPeriod: sensors.SensorInterval.normalInterval,
        )
        .listen(
          _handleAccelerometer,
          onError: (Object error) {
            debugPrint('Pusula ivmeölçer akışı durdu: $error');
          },
        );
    _magnetometerSubscription = sensors
        .magnetometerEventStream(
          samplingPeriod: sensors.SensorInterval.normalInterval,
        )
        .listen(
          _handleMagnetometer,
          onError: (Object error) {
            debugPrint('Pusula manyetometre akışı durdu: $error');
          },
        );
  }

  Future<void> _stopCompassTracking() async {
    _compassCameraUpdateTimer?.cancel();
    _compassCameraUpdateTimer = null;
    await _accelerometerSubscription?.cancel();
    _accelerometerSubscription = null;
    await _magnetometerSubscription?.cancel();
    _magnetometerSubscription = null;
  }

  void _queueCompassCameraUpdate() {
    final position = _currentPosition;
    final deviceHeading = _deviceHeading;
    if (position != null &&
        position.speed >= 0.8 &&
        position.heading.isFinite &&
        position.heading >= 0 &&
        position.heading < 360) {
      return;
    }
    if (_hasMapBearing &&
        deviceHeading != null &&
        ((_mapBearing - deviceHeading + 540) % 360 - 180).abs() < 1.5) {
      return;
    }

    if (_compassCameraUpdateTimer != null ||
        !navoraShouldFollowCurrentPosition(
          isNavigationActive: _isNavigationActive,
          isDriveTracking: _isDriveTracking,
          isLocationTracking: _isLocationTracking,
          isFollowing: _isFollowingCurrentPosition,
        )) {
      return;
    }

    _compassCameraUpdateTimer = Timer(const Duration(milliseconds: 180), () {
      _compassCameraUpdateTimer = null;
      final currentPosition = _currentPosition;
      if (!mounted || currentPosition == null) return;
      unawaited(_centerOnPosition(currentPosition));
    });
  }

  Future<void> _saveCompletedDrive({
    required double distance,
    required int durationMinutes,
    bool navigationCompleted = false,
  }) async {
    final user = FirebaseAuth.instance.currentUser!;
    final userReference = FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid);

    if (navigationCompleted && _activeNavigationDestination != null) {
      await userReference.collection('route_history').add({
        'title': _activeNavigationTitle ?? 'Tamamlanan rota',
        'destination': _activeNavigationDestination,
        'distance_km': distance,
        'duration_minutes': durationMinutes,
        'completed_at': FieldValue.serverTimestamp(),
        'expires_at': Timestamp.fromDate(
          DateTime.now().add(const Duration(days: 30)),
        ),
      });
      return;
    }

    await userReference.collection('driving_history').add({
      'route': 'GPS sürüşü',
      'date': DateTime.now().toIso8601String(),
      'duration_minutes': durationMinutes,
      'distance_km': distance,
      'completed_at': FieldValue.serverTimestamp(),
      'expires_at': Timestamp.fromDate(
        DateTime.now().add(const Duration(days: 30)),
      ),
    });
  }

  Future<void> _centerOnPosition(geo.Position position) async {
    final controller = _mapController;
    if (controller == null) return;

    final hasGpsHeading =
        position.heading.isFinite &&
        position.heading >= 0 &&
        position.heading < 360 &&
        position.speed >= 0.8;
    final nextHeading = hasGpsHeading ? position.heading : _deviceHeading;
    if (nextHeading != null) {
      _mapBearing = _hasMapBearing
          ? navoraSmoothBearing(_mapBearing, nextHeading)
          : nextHeading;
      _hasMapBearing = true;
    }

    if (_isNavigationActive || _isDriveTracking || _isLocationTracking) {
      _pendingNavigationCameraPosition = position;
      if (_navigationCameraUpdateTimer != null) return;
      _navigationCameraUpdateTimer = Timer(
        const Duration(milliseconds: 200),
        () {
          _navigationCameraUpdateTimer = null;
          final latestPosition = _pendingNavigationCameraPosition;
          _pendingNavigationCameraPosition = null;
          if (!mounted ||
              latestPosition == null ||
              !navoraShouldFollowCurrentPosition(
                isNavigationActive: _isNavigationActive,
                isDriveTracking: _isDriveTracking,
                isLocationTracking: _isLocationTracking,
                isFollowing: _isFollowingCurrentPosition,
              )) {
            return;
          }
          unawaited(_animateNavigationCamera(latestPosition));
        },
      );
      return;
    }

    _isProgrammaticCameraMove = true;
    try {
      await _moveMapTo(LatLng(position.latitude, position.longitude), 16);
    } finally {
      _isProgrammaticCameraMove = false;
    }
  }

  Future<void> _animateNavigationCamera(geo.Position position) async {
    final controller = _mapController;
    if (controller == null) return;

    final currentPosition = LatLng(position.latitude, position.longitude);
    final isNavigating = _isNavigationActive;
    final lookAheadMeters = (position.speed * 4).clamp(45.0, 180.0);
    final nextStepIndex = _navigationSteps.isEmpty
        ? 0
        : _navigationStepIndex.clamp(0, _navigationSteps.length - 1);
    final distanceToManeuver = _distanceFromPositionToStep(
      position,
      _navigationSteps.isEmpty ? null : _navigationSteps[nextStepIndex],
    );
    final maneuverZoom = isNavigating
        ? navoraNavigationZoomForSpeedAndManeuver(
            distanceToManeuver,
            position.speed,
          )
        : 16.0;
    final cameraTarget = isNavigating
        ? navoraOffsetCameraTarget(
            currentPosition,
            _mapBearing,
            lookAheadMeters.toDouble(),
          )
        : currentPosition;
    _isProgrammaticCameraMove = true;
    try {
      await controller.animateCamera(
        CameraUpdate.newCameraPosition(
          CameraPosition(
            target: cameraTarget,
            zoom: maneuverZoom,
            bearing: _mapBearing,
            tilt: !isNavigating || !_isMapTilted
                ? 0
                : distanceToManeuver != null && distanceToManeuver <= 150
                ? 48
                : 60,
          ),
        ),
        duration: const Duration(milliseconds: 200),
      );
    } finally {
      _isProgrammaticCameraMove = false;
    }
  }

  double? _distanceFromPositionToStep(
    geo.Position position,
    Map<String, dynamic>? step,
  ) {
    if (step == null) return null;
    final latitude = step['latitude'] as double?;
    final longitude = step['longitude'] as double?;
    if (latitude == null || longitude == null) return null;
    return geo.Geolocator.distanceBetween(
      position.latitude,
      position.longitude,
      latitude,
      longitude,
    );
  }

  Future<void> _recenterMap() async {
    if (_isNavigationActive || _isDriveTracking || _isLocationTracking) {
      final position = _currentPosition;
      if (position == null) {
        _showTrackingMessage('Konum henüz alınamadı. Biraz sonra tekrar dene.');
        return;
      }
      if (mounted) {
        setState(() => _isFollowingCurrentPosition = true);
      }
      await _centerOnPosition(position);
      return;
    }

    await _startLocationTracking();
  }

  Future<void> _resetMapNorth() async {
    final controller = _mapController;
    if (controller == null) return;

    try {
      final camera = _mapCameraPosition;
      if (camera == null) {
        _showTrackingMessage('Harita konumu henüz hazır değil.');
        return;
      }
      if (mounted) {
        setState(() {
          _isFollowingCurrentPosition = false;
          _mapBearing = 0;
          _hasMapBearing = false;
        });
      }
      _isProgrammaticCameraMove = true;
      try {
        await controller.animateCamera(
          CameraUpdate.newCameraPosition(
            CameraPosition(
              target: camera.target,
              zoom: camera.zoom,
              bearing: 0,
              tilt: camera.tilt,
            ),
          ),
        );
      } finally {
        _isProgrammaticCameraMove = false;
      }
    } catch (error) {
      debugPrint('Harita kuzeye döndürülemedi: $error');
      if (mounted) _showTrackingMessage('Harita yönü değiştirilemedi.');
    }
  }

  Future<void> _resetNavigationCamera() async {
    final controller = _mapController;
    final position = _currentPosition;
    if (controller == null || position == null) return;

    _isProgrammaticCameraMove = true;
    try {
      await controller.animateCamera(
        CameraUpdate.newCameraPosition(
          CameraPosition(
            target: LatLng(position.latitude, position.longitude),
            zoom: 16,
            bearing: 0,
            tilt: 0,
          ),
        ),
      );
    } finally {
      _isProgrammaticCameraMove = false;
    }
  }

  void _showTrackingMessage(
    String message, {
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    if (!mounted) return;
    AppNotificationService.show(
      message,
      actionLabel: actionLabel,
      onAction: onAction,
    );
  }

  Future<void> _showPhotoUploadDialog() async {
    if (_isUploadingProfilePhoto) return;
    if (FirebaseAuth.instance.currentUser == null) {
      _showTrackingMessage(
        'Profil fotoğrafı eklemek için hesabınıza giriş yapın.',
      );
      return;
    }

    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      backgroundColor: const Color(0xFF191919),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) => SafeArea(
        child: Container(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Profil Fotoğrafı Değiştir',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 6),
              Text(
                'Fotoğraf kaynağını seçin',
                style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
              ),
              const SizedBox(height: 20),
              ListTile(
                leading: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.orange.shade50,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.camera_alt, color: Color(0xFFFF6B00)),
                ),
                title: const Text(
                  'Kameradan fotoğraf çek',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                onTap: () => Navigator.pop(context, ImageSource.camera),
              ),
              ListTile(
                leading: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: const Color(0xFF2A180D),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(
                    Icons.photo_library,
                    color: Color(0xFFFF6B00),
                  ),
                ),
                title: const Text(
                  'Galeriden seç',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                onTap: () => Navigator.pop(context, ImageSource.gallery),
              ),
            ],
          ),
        ),
      ),
    );
    if (source == null || !mounted) return;

    try {
      final image = await ImagePicker().pickImage(
        source: source,
        imageQuality: 82,
        maxWidth: 1200,
        maxHeight: 1200,
      );
      if (image == null || !mounted) return;
      await _uploadProfilePhoto(image);
    } on PlatformException catch (error) {
      debugPrint('Profil fotoğrafı seçilemedi: ${error.code} ${error.message}');
      if (mounted) {
        _showTrackingMessage('Fotoğraf seçilemedi. Tekrar deneyin.');
      }
    } catch (error) {
      debugPrint('Profil fotoğrafı seçilirken hata: $error');
      if (mounted) {
        _showTrackingMessage('Fotoğraf seçilemedi. Tekrar deneyin.');
      }
    }
  }

  Future<void> _uploadProfilePhoto(XFile image) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      _showTrackingMessage(
        'Profil fotoğrafı eklemek için hesabınıza giriş yapın.',
      );
      return;
    }

    setState(() => _isUploadingProfilePhoto = true);
    try {
      final bytes = await image.readAsBytes();
      if (bytes.isEmpty) {
        throw StateError('Seçilen profil fotoğrafı boş.');
      }
      if (bytes.length > 5 * 1024 * 1024) {
        throw StateError('Profil fotoğrafı 5 MB sınırını aşıyor.');
      }
      final extension = image.name.split('.').last.toLowerCase();
      final contentType = switch (image.mimeType) {
        'image/jpeg' => 'image/jpeg',
        'image/png' => 'image/png',
        'image/webp' => 'image/webp',
        _ => switch (extension) {
          'png' => 'image/png',
          'webp' => 'image/webp',
          'jpg' || 'jpeg' => 'image/jpeg',
          _ => null,
        },
      };
      if (contentType == null) {
        throw StateError('Desteklenmeyen profil fotoğrafı biçimi.');
      }
      final photoReference = FirebaseStorage.instance.ref().child(
        'profile_photos/${user.uid}/avatar',
      );
      await photoReference.putData(
        bytes,
        SettableMetadata(contentType: contentType),
      );
      final downloadUrl =
          '${await photoReference.getDownloadURL()}&v=${DateTime.now().millisecondsSinceEpoch}';
      await FirebaseFirestore.instance.collection('users').doc(user.uid).set({
        'photo_url': downloadUrl,
        'updated_at': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      if (!mounted || FirebaseAuth.instance.currentUser?.uid != user.uid) {
        return;
      }
      setState(() {
        _profilePhotoUrl = downloadUrl;
        _isUploadingProfilePhoto = false;
      });
      _showTrackingMessage('Profil fotoğrafı güncellendi.');
    } catch (error) {
      debugPrint('Profil fotoğrafı yüklenemedi: $error');
      if (mounted) {
        setState(() => _isUploadingProfilePhoto = false);
        _showTrackingMessage(
          error is StateError
              ? error.message.toString()
              : 'Profil fotoğrafı kaydedilemedi. Tekrar deneyin.',
        );
      }
    }
  }

  void _showEditProfileDialog() {
    final nameController = TextEditingController(text: _userName);
    final emailController = TextEditingController(text: _userEmail);
    final phoneController = TextEditingController(text: _userPhone);
    String selectedGender = _userGender;

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF171717),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setSheetState) => Padding(
          padding: EdgeInsets.only(
            top: 20,
            left: 20,
            right: 20,
            bottom: MediaQuery.of(dialogContext).viewInsets.bottom + 20,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Profili Düzenle',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white70),
                    onPressed: () => Navigator.of(dialogContext).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              TextField(
                controller: nameController,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  labelText: 'Ad Soyad',
                  labelStyle: const TextStyle(color: Color(0xFFFFB066)),
                  prefixIcon: const Icon(
                    Icons.person_outline,
                    color: Color(0xFFFFB066),
                  ),
                  filled: true,
                  fillColor: const Color(0xFF1D1D1D),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: const BorderSide(color: Color(0xFFFF8A3D)),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide(
                      color: const Color(0xFFFF8A3D).withValues(alpha: 0.5),
                    ),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: const BorderSide(
                      color: Color(0xFFFF8A3D),
                      width: 1.5,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: emailController,
                keyboardType: TextInputType.emailAddress,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  labelText: 'E-posta Adresi',
                  labelStyle: const TextStyle(color: Color(0xFFFFB066)),
                  prefixIcon: const Icon(
                    Icons.email_outlined,
                    color: Color(0xFFFFB066),
                  ),
                  filled: true,
                  fillColor: const Color(0xFF1D1D1D),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: const BorderSide(color: Color(0xFFFF8A3D)),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide(
                      color: const Color(0xFFFF8A3D).withValues(alpha: 0.5),
                    ),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: const BorderSide(
                      color: Color(0xFFFF8A3D),
                      width: 1.5,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: phoneController,
                keyboardType: TextInputType.phone,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  labelText: 'Telefon Numarası',
                  labelStyle: const TextStyle(color: Color(0xFFFFB066)),
                  prefixIcon: const Icon(
                    Icons.phone_outlined,
                    color: Color(0xFFFFB066),
                  ),
                  filled: true,
                  fillColor: const Color(0xFF1D1D1D),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: const BorderSide(color: Color(0xFFFF8A3D)),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide(
                      color: const Color(0xFFFF8A3D).withValues(alpha: 0.5),
                    ),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: const BorderSide(
                      color: Color(0xFFFF8A3D),
                      width: 1.5,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              PopupMenuButton<String>(
                position: PopupMenuPosition.under,
                color: const Color(0xFF1D1D1D),
                onSelected: (value) =>
                    setSheetState(() => selectedGender = value),
                itemBuilder: (context) => const [
                  PopupMenuItem(value: 'Kadin', child: Text('Kadın')),
                  PopupMenuItem(value: 'Erkek', child: Text('Erkek')),
                  PopupMenuItem(
                    value: 'Belirtmek istemiyorum',
                    child: Text('Belirtmek istemiyorum'),
                  ),
                ],
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 16,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1D1D1D),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: const Color(0xFFFF8A3D).withValues(alpha: 0.5),
                    ),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.person_outline,
                        color: Color(0xFFFFB066),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Cinsiyet',
                              style: TextStyle(
                                color: Color(0xFFFFB066),
                                fontSize: 12,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              selectedGender,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const Icon(Icons.arrow_drop_down, color: Colors.white70),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFFF6B00),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  onPressed: () async {
                    final user = FirebaseAuth.instance.currentUser;
                    final name = nameController.text.trim();
                    final email = emailController.text.trim();
                    if (name.isEmpty) {
                      if (!mounted) return;
                      AppNotificationService.show(
                        'Ad Soyad alanı boş bırakılamaz.',
                      );
                      return;
                    }

                    if (email.isEmpty || !email.contains('@')) {
                      if (!mounted) return;
                      AppNotificationService.show(
                        'Geçerli bir e-posta adresi girin.',
                      );
                      return;
                    }

                    if (Navigator.of(
                      dialogContext,
                      rootNavigator: true,
                    ).canPop()) {
                      Navigator.of(dialogContext, rootNavigator: true).pop();
                    }

                    try {
                      final currentEmail = user?.email ?? _userEmail;
                      final emailChangeRequested =
                          user != null &&
                          user.email?.toLowerCase() != email.toLowerCase();
                      if (user != null && emailChangeRequested) {
                        await user.verifyBeforeUpdateEmail(email);
                      }
                      await user?.updateDisplayName(name);
                      if (user != null) {
                        await FirebaseFirestore.instance
                            .collection('users')
                            .doc(user.uid)
                            .set({
                              'display_name': name,
                              'email': currentEmail,
                              'photo_url': user.photoURL,
                              'phone': phoneController.text.trim(),
                              'gender_preference': selectedGender,
                              'updated_at': FieldValue.serverTimestamp(),
                            }, SetOptions(merge: true));
                      }

                      if (!mounted) return;
                      setState(() {
                        _userName = name;
                        _userEmail = currentEmail;
                        _userPhone = phoneController.text.trim();
                        _userGender = selectedGender;
                      });

                      if (!mounted) return;
                      AppNotificationService.show(
                        emailChangeRequested
                            ? 'Yeni e-posta adresinize doğrulama bağlantısı gönderildi. Onaylayana kadar eski e-posta adresiniz kullanılacak.'
                            : 'Profil bilgileri güncellendi!',
                      );
                    } on FirebaseAuthException catch (error) {
                      debugPrint(
                        'Profil e-posta değişikliği başarısız: ${error.code}',
                      );
                      if (!mounted) return;
                      AppNotificationService.show(switch (error.code) {
                        'email-already-in-use' => 'Bu e-posta başka bir hesapta kayıtlı. Farklı bir e-posta deneyin.',
                        'invalid-email' => 'Geçerli bir e-posta adresi girin.',
                        'requires-recent-login' => 'Güvenlik için çıkış yapıp yeniden giriş yaptıktan sonra deneyin.',
                        _ =>
                          'E-posta doğrulama isteği gönderilemedi (${error.code}).',
                      });
                    } on FirebaseException catch (error) {
                      debugPrint(
                        'Profil bilgileri kaydedilemedi: ${error.code}',
                      );
                      if (!mounted) return;
                      AppNotificationService.show(
                        'Profil bilgileri kaydedilemedi (${error.code}).',
                      );
                    } catch (error) {
                      debugPrint('Profil güncellenemedi: $error');
                      if (!mounted) return;
                      AppNotificationService.show(
                        'Profil kaydedilemedi. Lütfen tekrar deneyin.',
                      );
                    }
                  },
                  child: const Text(
                    'Değişiklikleri Kaydet',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                height: 46,
                child: OutlinedButton.icon(
                  onPressed: _isDeletingAccount
                      ? null
                      : () {
                          Navigator.of(dialogContext).pop();
                          unawaited(_deleteAccount());
                        },
                  icon: const Icon(Icons.delete_forever_rounded),
                  label: Text(
                    _isDeletingAccount ? 'Hesap siliniyor...' : 'Hesabımı sil',
                  ),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFFE57373),
                    side: const BorderSide(color: Color(0xFFE57373)),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _persistSelectedVehicle() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    try {
      await FirebaseFirestore.instance.collection('users').doc(user.uid).set({
        'selected_vehicle': _selectedVehicle,
        'updated_at': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (error) {
      debugPrint('Ulaşım tercihi kaydedilemedi: $error');
      if (mounted) _showTrackingMessage('Ulaşım tercihi kaydedilemedi.');
    }
  }

  Future<void> _loadNavigationEndpointMarkerIcon() async {
    final markerIcon = await _renderHighResolutionMarker(
      logicalSize: 9,
      draw: (canvas) {
        canvas
          ..drawCircle(
            const Offset(4.5, 4.5),
            4.25,
            Paint()..color = const Color(0xFF31363B),
          )
          ..drawCircle(
            const Offset(4.5, 4.5),
            3.25,
            Paint()..color = Colors.white,
          );
      },
    );
    if (!mounted) return;
    setState(() => _navigationEndpointMarkerIcon = markerIcon);

    final destinationIcon = await _renderHighResolutionMarker(
      logicalSize: 44,
      draw: (canvas) {
        canvas
          ..drawCircle(
            const Offset(22, 23),
            19,
            Paint()
              ..color = const Color(0xFF101820)
              ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
          )
          ..drawCircle(
            const Offset(22, 22),
            18,
            Paint()..color = const Color(0xFFEA4335),
          )
          ..drawCircle(
            const Offset(22, 22),
            15,
            Paint()
              ..color = Colors.white
              ..style = PaintingStyle.stroke
              ..strokeWidth = 2,
          );
        _paintMarkerGlyph(
          canvas,
          Icons.flag_rounded,
          color: Colors.white,
          fontSize: 21,
          center: const Offset(22, 22),
        );
      },
    );
    if (!mounted) return;
    setState(() => _navigationDestinationMarkerIcon = destinationIcon);
  }

  Future<void> _loadChatRoomMarkerIcon() async {
    final icon = await _createStandaloneMarkerIcon(
      Icons.forum_rounded,
      circular: true,
    );
    if (!mounted) return;
    setState(() => _chatRoomMarkerIcon = icon);
  }

  Future<void> _loadLostPetMarkerIcon() async {
    final icon = await _createStandaloneMarkerIcon(
      Icons.pets_rounded,
      bubbleColor: const Color(0xFFE53935),
      circular: true,
    );
    if (!mounted) return;
    setState(() => _lostPetMarkerIcon = icon);
  }

  Future<void> _loadCommunityPlaceMarkerIcon() async {
    final icon = await _createStandaloneMarkerIcon(
      Icons.star_rounded,
      bubbleColor: const Color(0xFF008C95),
      circular: true,
    );
    if (!mounted) return;
    setState(() => _communityPlaceMarkerIcon = icon);
  }

  Future<void> _loadListingMarkerIcons() async {
    final icons = await Future.wait([
      _createStandaloneMarkerIcon(
        Icons.home_work_rounded,
        bubbleColor: const Color(0xFF1976D2),
        circular: true,
      ),
      _createStandaloneMarkerIcon(
        Icons.sell_rounded,
        bubbleColor: const Color(0xFFFF7A00),
        circular: true,
      ),
      _createStandaloneMarkerIcon(
        Icons.pets_rounded,
        bubbleColor: const Color(0xFF2E7D32),
        circular: true,
      ),
    ]);
    if (!mounted) return;
    setState(() {
      _rentalPropertyMarkerIcon = icons[0];
      _salePropertyMarkerIcon = icons[1];
      _adoptionMarkerIcon = icons[2];
    });
  }

  BitmapDescriptor _roomMarkerIconForCount(int activeCount) {
    final count = activeCount.clamp(1, 99);
    final cached = _chatRoomMarkerIcons[count];
    if (cached != null) return cached;
    if (_loadingRoomMarkerIconCounts.add(count)) {
      unawaited(_loadChatRoomCountMarkerIcon(count));
    }
    return _chatRoomMarkerIcon!;
  }

  BitmapDescriptor _mapClusterMarkerIconForCount(int itemCount) {
    final count = itemCount.clamp(2, 99);
    final cached = _mapClusterMarkerIcons[count];
    if (cached != null) return cached;
    if (_loadingMapClusterIconCounts.add(count)) {
      unawaited(_loadMapClusterMarkerIcon(count));
    }
    return BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure);
  }

  Future<void> _loadChatRoomCountMarkerIcon(int count) async {
    try {
      final icon = await _createStandaloneMarkerIcon(
        Icons.forum_rounded,
        badgeText: count >= 99 ? '99+' : '$count',
        circular: true,
      );
      if (!mounted) return;
      setState(() => _chatRoomMarkerIcons[count] = icon);
    } catch (error) {
      _loadingRoomMarkerIconCounts.remove(count);
      debugPrint('Sohbet odası kullanıcı rozeti çizilemedi: $error');
    } finally {
      _loadingRoomMarkerIconCounts.remove(count);
    }
  }

  Future<void> _loadMapClusterMarkerIcon(int count) async {
    try {
      final icon = await _createStandaloneMarkerIcon(
        Icons.layers_rounded,
        badgeText: count >= 99 ? '99+' : '$count',
        bubbleColor: const Color(0xFF315C87),
        circular: true,
      );
      if (!mounted) return;
      setState(() => _mapClusterMarkerIcons[count] = icon);
    } catch (error) {
      debugPrint('Harita küme rozeti çizilemedi: $error');
    } finally {
      _loadingMapClusterIconCounts.remove(count);
    }
  }

  LatLng _mapClusterCenter(List<Map<String, dynamic>> cluster) {
    var latitude = 0.0;
    var longitude = 0.0;
    for (final item in cluster) {
      latitude += (item['latitude'] as num).toDouble();
      longitude += (item['longitude'] as num).toDouble();
    }
    return LatLng(latitude / cluster.length, longitude / cluster.length);
  }

  Marker _buildPetMapMarker(
    Map<String, dynamic> report,
    String markerId,
    LatLng position,
  ) {
    final isAdoption = report['collection'] == 'pet_adoption_listings';
    final petName = report['pet_name']?.toString() ?? '';
    final petType = _lostPetTypeLabel(report['pet_type']?.toString());
    return Marker(
      markerId: MarkerId(markerId),
      position: position,
      anchor: const Offset(0.5, 0.5),
      icon: isAdoption
          ? _adoptionMarkerIcon ??
                _lostPetMarkerIcon ??
                BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen)
          : _lostPetMarkerIcon ??
                BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRose),
      infoWindow: InfoWindow(
        title: petName.isEmpty
            ? isAdoption
                  ? 'Sahiplendirme ilanı'
                  : 'Kayıp ${petType.toLowerCase()}'
            : petName,
        snippet: isAdoption
            ? 'Sahiplendiriliyor • $petType • ${report['address']}'
            : '$petType • ${report['address']}',
      ),
      onTap: () => _showLostPetReport(report),
    );
  }

  Marker? _buildPropertyMapMarker(
    Map<String, dynamic> listing,
    String markerId,
    LatLng position,
  ) {
    final icon = listing['listing_type'] == 'kiralik'
        ? _rentalPropertyMarkerIcon
        : _salePropertyMarkerIcon;
    if (icon == null) return null;
    return Marker(
      markerId: MarkerId(markerId),
      position: position,
      anchor: const Offset(0.5, 0.5),
      icon: icon,
      infoWindow: InfoWindow(
        title: listing['title']?.toString() ?? 'Konut ilanı',
        snippet: _formatListingPrice(listing['price']),
      ),
      onTap: () => _showPropertyListing(listing),
    );
  }

  Future<void> _zoomToMapCluster(LatLng center) async {
    final controller = _mapController;
    if (controller == null) return;
    final currentZoom = _mapCameraPosition?.zoom ?? 11.5;
    _isProgrammaticCameraMove = true;
    try {
      await controller.animateCamera(
        CameraUpdate.newLatLngZoom(
          center,
          math.min(18.0, math.max(currentZoom + 2.5, 14.5)),
        ),
      );
    } catch (error) {
      debugPrint('Harita kümesi yakınlaştırılamadı: $error');
    } finally {
      _isProgrammaticCameraMove = false;
    }
  }

  Future<BitmapDescriptor> _createStandaloneMarkerIcon(
    IconData iconData, {
    String? badgeText,
    Color bubbleColor = const Color(0xFFFF7A00),
    bool circular = false,
  }) async {
    const size = 56.0;
    return _renderHighResolutionMarker(
      logicalSize: size,
      draw: (canvas) {
        const center = Offset(size / 2, size / 2);
        final shadowPaint = Paint()
          ..color = Colors.black.withValues(alpha: 0.3)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3);
        if (circular) {
          canvas
            ..drawCircle(center + const Offset(0, 2), 20, shadowPaint)
            ..drawCircle(center, 20, Paint()..color = bubbleColor)
            ..drawCircle(
              center,
              17,
              Paint()
                ..color = Colors.white
                ..style = PaintingStyle.stroke
                ..strokeWidth = 2,
            );
        } else {
          final bubble = Path()
            ..moveTo(18, 10)
            ..quadraticBezierTo(12, 10, 12, 16)
            ..lineTo(12, 32)
            ..quadraticBezierTo(12, 38, 18, 38)
            ..lineTo(20, 38)
            ..lineTo(18, 45)
            ..lineTo(29, 38)
            ..lineTo(38, 38)
            ..quadraticBezierTo(44, 38, 44, 32)
            ..lineTo(44, 16)
            ..quadraticBezierTo(44, 10, 38, 10)
            ..close();
          canvas
            ..drawPath(bubble.shift(const Offset(0, 2)), shadowPaint)
            ..drawPath(bubble, Paint()..color = bubbleColor)
            ..drawPath(
              bubble,
              Paint()
                ..color = Colors.white
                ..style = PaintingStyle.stroke
                ..strokeWidth = 2,
            );
        }
        _paintMarkerGlyph(
          canvas,
          iconData,
          color: Colors.white,
          fontSize: 23,
          center: center,
        );
        if (badgeText != null) {
          final textPainter = TextPainter(
            text: TextSpan(
              text: badgeText,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 9,
                fontWeight: FontWeight.w900,
              ),
            ),
            textDirection: TextDirection.ltr,
          )..layout();
          final badgeWidth = math.max(17.0, textPainter.width + 8);
          final badgeRect = RRect.fromRectAndRadius(
            Rect.fromLTWH(44 - badgeWidth / 2, 10, badgeWidth, 16),
            const Radius.circular(9),
          );
          canvas
            ..drawRRect(
              badgeRect.shift(const Offset(0, 1)),
              Paint()..color = const Color(0xAA000000),
            )
            ..drawRRect(badgeRect, Paint()..color = const Color(0xFF173344))
            ..drawRRect(
              badgeRect,
              Paint()
                ..color = Colors.white
                ..style = PaintingStyle.stroke
                ..strokeWidth = 1.2,
            );
          textPainter.paint(
            canvas,
            Offset(
              badgeRect.left + (badgeRect.width - textPainter.width) / 2,
              badgeRect.top + (badgeRect.height - textPainter.height) / 2,
            ),
          );
        }
      },
    );
  }

  Future<BitmapDescriptor> _renderHighResolutionMarker({
    required double logicalSize,
    required void Function(Canvas canvas) draw,
  }) async {
    const rasterScale = 6.0;
    final pixelSize = (logicalSize * rasterScale).round();
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(
      recorder,
      Rect.fromLTWH(0, 0, pixelSize.toDouble(), pixelSize.toDouble()),
    )..scale(rasterScale);
    draw(canvas);

    final picture = recorder.endRecording();
    final image = await picture.toImage(pixelSize, pixelSize);
    picture.dispose();
    try {
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) {
        throw StateError('Harita işaretçisi PNG olarak oluşturulamadı.');
      }
      return BitmapDescriptor.bytes(
        byteData.buffer.asUint8List(),
        width: logicalSize,
        height: logicalSize,
      );
    } finally {
      image.dispose();
    }
  }

  void _paintMarkerGlyph(
    Canvas canvas,
    IconData iconData, {
    required Color color,
    required double fontSize,
    required Offset center,
  }) {
    final textPainter = TextPainter(
      text: TextSpan(
        text: String.fromCharCode(iconData.codePoint),
        style: TextStyle(
          fontFamily: iconData.fontFamily,
          package: iconData.fontPackage,
          fontSize: fontSize,
          color: color,
          height: 1,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    textPainter.paint(
      canvas,
      Offset(
        center.dx - textPainter.width / 2,
        center.dy - textPainter.height / 2,
      ),
    );
  }

  String _vehicleDisplayName(String vehicle) {
    switch (vehicle) {
      case 'Motosiklet':
        return 'Motor';
      case 'Bisiklet':
        return 'Bisiklet';
      case 'Yürüyüş':
        return 'Yaya';
      case 'Araba':
      default:
        return 'Araba';
    }
  }

  Future<void> _sendAiMessage() async {
    if (_isAiResponding || _isClearingAiChats) return;
    final text = _aiController.text.trim();
    if (text.isEmpty) return;
    final aiLimit = _isProUser ? _proAiQueriesPerDay : _freeAiQueriesPerDay;
    if (_freeAiQueriesUsedToday >= aiLimit) {
      _showTrackingMessage('Günlük yapay zeka soru hakkınız doldu.');
      return;
    }

    FocusManager.instance.primaryFocus?.unfocus();
    final user = FirebaseAuth.instance.currentUser;
    final userContext = [
      if (_currentAddress != null) 'Mevcut adres: $_currentAddress',
      if (_selectedDestinationName != null)
        'Seçili hedef: $_selectedDestinationName',
      'Ulaşım tipi: ${_vehicleDisplayName(_selectedVehicle)}',
    ].join('\n');

    setState(() {
      _isAiResponding = true;
      _aiMessages.add({'sender': 'user', 'text': text});
      _aiMessages.add({'sender': 'ai', 'text': 'Yanıt hazırlanıyor...'});
      _aiController.clear();
    });

    String? quotaReservationId;
    try {
      if (user != null) {
        quotaReservationId = FirebaseFirestore.instance
            .collection('users')
            .doc(user.uid)
            .collection('quota_reservations')
            .doc()
            .id;
        await _reserveDailyQuota('ai', quotaReservationId);
      }
      final ai = FirebaseAI.googleAI(
        appCheck: FirebaseAppCheck.instance,
        auth: FirebaseAuth.instance,
      );
      final model = ai.generativeModel(model: 'gemini-3.5-flash');
      final prompt =
          '''Sen Navora uygulamasının Türkçe yolculuk asistanısın.
Kısa, anlaşılır ve güvenli cevap ver. Trafik veya rota hakkında kesin bilgi yoksa bunu açıkça belirt.
Kullanıcı bağlamı:
$userContext

Kullanıcının sorusu:
$text''';
      final response = await model.generateContent([Content.text(prompt)]);
      final answer = response.text?.trim();
      if (answer == null || answer.isEmpty) {
        throw Exception('Gemini boş cevap döndürdü.');
      }

      if (quotaReservationId != null) {
        final reservationId = quotaReservationId;
        quotaReservationId = null;
        try {
          await _callQuotaCallable('completeDailyQuotaReservation', {
            'reservationId': reservationId,
          });
        } catch (error) {
          debugPrint('Navora AI kotası tamamlanamadı: $error');
        }
      } else {
        await _recordDailyQuotaUsage(aiQueryCompleted: true);
      }
      if (!mounted) return;
      setState(() {
        _aiMessages.removeLast();
        _aiMessages.add({'sender': 'ai', 'text': answer});
      });
      if (user != null) {
        try {
          await FirebaseFirestore.instance
              .collection('users')
              .doc(user.uid)
              .collection('ai_chats')
              .add({
                'question': text,
                'answer': answer,
                'created_at': FieldValue.serverTimestamp(),
              });
        } catch (error) {
          debugPrint('Navora AI sohbeti kaydedilemedi: $error');
          if (mounted) {
            _showTrackingMessage('Yapay zeka sohbeti kaydedilemedi.');
          }
        }
      }
      if (mounted) setState(() => _isAiResponding = false);
    } catch (error) {
      debugPrint('Navora AI yanıtı alınamadı: $error');
      if (quotaReservationId != null) {
        try {
          await _callQuotaCallable('cancelDailyQuotaReservation', {
            'reservationId': quotaReservationId,
          });
        } catch (releaseError) {
          debugPrint('Navora AI kotası geri alınamadı: $releaseError');
        }
      }
      if (!mounted) return;
      final quotaExceeded =
          error is FirebaseFunctionsException &&
          error.code == 'resource-exhausted';
      final aiLogicNotEnabled =
          error is FirebaseAIException &&
          error.message.contains('firebasevertexai.googleapis.com');
      setState(() {
        _isAiResponding = false;
        _aiMessages.removeLast();
        _aiMessages.add({
          'sender': 'ai',
          'text': quotaExceeded
              ? 'Günlük yapay zeka soru hakkınız doldu.'
              : aiLogicNotEnabled
              ? 'Firebase projesinde AI Logic etkin değil. Firebase Console’da navoramapa projesinin AI Logic kurulumunu tamamlayın.'
              : 'Şu anda yanıt veremiyorum. İnternet bağlantısını kontrol edip tekrar deneyin.',
        });
      });
    }
  }

  Future<void> _clearAiConversation() async {
    if (_isAiResponding || _isClearingAiChats) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: const Color(0xFF1B1B1B),
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
          side: const BorderSide(color: Color(0xFF383838)),
        ),
        titlePadding: const EdgeInsets.fromLTRB(22, 22, 22, 0),
        contentPadding: const EdgeInsets.fromLTRB(22, 16, 22, 8),
        actionsPadding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        title: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: const Color(0xFF382014),
                borderRadius: BorderRadius.circular(14),
              ),
              child: const Icon(
                Icons.delete_sweep_rounded,
                color: Color(0xFFFF8A36),
              ),
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Text(
                'Sohbeti temizle',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 19,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
        content: const Text(
          'Navora AI ile yaptığın konuşmalar ve kayıtlı sohbet geçmişin silinecek.',
          style: TextStyle(color: Color(0xFFBDBDBD), fontSize: 14, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFFBDBDBD),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            child: const Text('Vazgeç'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(dialogContext, true),
            icon: const Icon(Icons.delete_outline_rounded, size: 18),
            label: const Text('Temizle'),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFFF6B00),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _isClearingAiChats = true);
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user != null) {
        final chatCollection = FirebaseFirestore.instance
            .collection('users')
            .doc(user.uid)
            .collection('ai_chats');
        final snapshot = await chatCollection.get();
        for (var start = 0; start < snapshot.docs.length; start += 500) {
          final batch = FirebaseFirestore.instance.batch();
          for (final document in snapshot.docs.skip(start).take(500)) {
            batch.delete(document.reference);
          }
          await batch.commit();
        }
      }

      if (!mounted) return;
      setState(() {
        _aiMessages
          ..clear()
          ..add({
            'sender': 'ai',
            'text': 'Merhaba! Ben Navora AI. Rotan, yakındaki mekanlar veya trafik hakkında ne öğrenmek istersin?',
          });
      });
      _showTrackingMessage('Navora AI sohbeti temizlendi.');
    } catch (error) {
      debugPrint('Navora AI sohbeti temizlenemedi: $error');
      if (mounted) {
        _showTrackingMessage(
          'Navora AI sohbeti temizlenemedi. Lütfen tekrar deneyin.',
        );
      }
    } finally {
      if (mounted) setState(() => _isClearingAiChats = false);
    }
  }

  Widget _buildProfileStat(String value, String label, {VoidCallback? onTap}) {
    final column = Column(
      children: [
        Text(
          value,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 15,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: const TextStyle(
            color: Color(0xFFFFB066),
            fontSize: 11,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
    if (onTap == null) return column;
    return GestureDetector(onTap: onTap, child: column);
  }

  void _showVisitedCitiesSheet() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF191919),
      showDragHandle: true,
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
            child: _visitedCities.isEmpty
                ? const Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ListTile(
                        leading: Icon(Icons.location_city_outlined),
                        title: Text('Henüz gidilen şehir yok'),
                        subtitle: Text(
                          'Giriş yaptıktan sonra keşfettiğin şehirler burada görünür.',
                        ),
                      ),
                    ],
                  )
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Gidilen Şehirler',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 8),
                      Flexible(
                        child: ListView.separated(
                          shrinkWrap: true,
                          itemCount: _visitedCities.length,
                          separatorBuilder: (_, _) => const Divider(height: 1),
                          itemBuilder: (context, index) => ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(
                              Icons.location_on_outlined,
                              color: Color(0xFFFF6B00),
                            ),
                            title: Text(_visitedCities[index]),
                          ),
                        ),
                      ),
                    ],
                  ),
          ),
        );
      },
    );
  }

  Widget _buildProfileMenuItem({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    bool isDangerous = false,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF111111),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: isDangerous
              ? Colors.red.withValues(alpha: 0.2)
              : const Color(0xFF2A2A2A),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.15),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(18),
        child: ListTile(
          onTap: onTap,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
          leading: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: isDangerous
                  ? Colors.red.withValues(alpha: 0.12)
                  : const Color(0xFFFF6B00).withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              icon,
              color: isDangerous ? Colors.red : const Color(0xFFFF6B00),
            ),
          ),
          title: Text(
            title,
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: isDangerous ? Colors.red : Colors.white,
              fontSize: 14,
            ),
          ),
          subtitle: Text(
            subtitle,
            style: TextStyle(color: Colors.white70, fontSize: 12),
          ),
          trailing: const Icon(
            Icons.chevron_right,
            color: Colors.white60,
            size: 20,
          ),
        ),
      ),
    );
  }

  Widget _buildChip(
    IconData icon,
    String label, {
    required VoidCallback onTap,
  }) {
    return Container(
      margin: const EdgeInsets.only(right: 10),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(15),
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: Color(0xFFFF7A00),
              borderRadius: BorderRadius.circular(15),
            ),
            child: Row(
              children: [
                Icon(icon, size: 14, color: Colors.white),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildNavItem(IconData icon, String label, int index) {
    final isSelected = _selectedIndex == index;
    return Expanded(
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => _selectMainTab(index),
          borderRadius: BorderRadius.circular(30),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            height: 56,
            margin: const EdgeInsets.symmetric(horizontal: 2),
            decoration: BoxDecoration(
              color: isSelected ? const Color(0xFFFF7A00) : Colors.transparent,
              borderRadius: BorderRadius.circular(30),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  icon,
                  color: isSelected ? Colors.white : Colors.white60,
                  size: 21,
                ),
                const SizedBox(height: 2),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: isSelected ? Colors.white : Colors.white60,
                    fontSize: 9,
                    fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
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
