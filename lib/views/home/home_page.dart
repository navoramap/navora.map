// ignore_for_file: avoid_types_as_parameter_names

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:http/http.dart' as http;
import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_ai/firebase_ai.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:geocoding/geocoding.dart' as geo_coding;
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:sensors_plus/sensors_plus.dart' as sensors;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'navora_points_sheet.dart';
import 'search_page.dart';
import 'room_chat_page.dart';
import 'tabs/create_property_listing_sheet.dart';
import 'tabs/create_lost_pet_report_sheet.dart';
import 'tabs/create_community_place_sheet.dart';
import 'tabs/explore_page.dart';
import '../../services/places_service.dart';
import '../../services/chat_room_service.dart';

class NavoraTrafficService {
  static const String _tomTomApiKey = String.fromEnvironment(
    'TOMTOM_API_KEY',
    defaultValue: 'nDfLbvCCiy55ZR0BtMe5VYbzKeMR8tib',
  );

  static Future<Map<String, dynamic>> fetchTrafficStatus(
    LatLng position, {
    String? apiKey,
  }) async {
    final key = (apiKey ?? _tomTomApiKey).trim();
    if (key.isNotEmpty) {
      try {
        final uri = Uri.https(
          'api.tomtom.com',
          '/traffic/services/4/flowSegmentData/absolute/10/json',
          {
            'point': '${position.latitude},${position.longitude}',
            'unit': 'KMPH',
            'openLr': 'false',
            'key': key,
          },
        );

        final response = await http
            .get(uri)
            .timeout(const Duration(seconds: 12));
        if (response.statusCode == 200) {
          final data = jsonDecode(response.body) as Map<String, dynamic>;
          final flow =
              (data['flowSegmentData'] as Map<String, dynamic>?) ?? const {};
          final currentSpeed = (flow['currentSpeed'] as num?)?.toDouble() ?? 0;
          final freeFlowSpeed =
              (flow['freeFlowSpeed'] as num?)?.toDouble() ?? 0;
          final confidence = (flow['confidence'] as num?)?.toInt() ?? 0;
          final delay = currentSpeed > 0 && freeFlowSpeed > 0
              ? ((freeFlowSpeed - currentSpeed) / freeFlowSpeed * 100)
                    .clamp(0, 100)
                    .round()
              : 0;
          final status = delay >= 35
              ? 'Yoğun'
              : delay >= 15
              ? 'Orta'
              : 'Açık';
          return {
            'status': status,
            'delayPercent': delay,
            'confidence': confidence,
            'description': 'Canlı trafik verisi aktif.',
          };
        }
      } catch (_) {
        debugPrint('TomTom trafik verisi alınamadı, yerel durum kullanılacak.');
      }
    }

    return {
      'status': 'Açık',
      'delayPercent': 0,
      'confidence': 0,
      'description': 'Anahtar yoksa yerel trafik görünümü gösteriliyor.',
    };
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

double navoraAverageSpeedKmh({
  required double distanceKm,
  required int durationSeconds,
}) {
  if (distanceKm <= 0 || durationSeconds <= 0) {
    return 0;
  }

  return (distanceKm / durationSeconds) * 3600;
}

int navoraDriveScorePenalty({
  required double speedKmh,
  required double? previousSpeedKmh,
}) {
  var speedPenalty = 0;
  if (speedKmh > 150) {
    speedPenalty = 2;
  } else if (speedKmh > 120) {
    speedPenalty = 1;
  }

  var changePenalty = 0;
  if (previousSpeedKmh != null) {
    final delta = (speedKmh - previousSpeedKmh).abs();
    if (delta > 35) {
      changePenalty = 2;
    } else if (delta > 20) {
      changePenalty = 1;
    }
  }

  return speedPenalty > changePenalty ? speedPenalty : changePenalty;
}

bool navoraShouldFollowCurrentPosition({
  required bool isNavigationActive,
  required bool isDriveTracking,
  bool isFollowing = true,
}) {
  return (isNavigationActive || isDriveTracking) && isFollowing;
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

String navoraRouteProfileForVehicle(String vehicle) {
  switch (vehicle) {
    case 'Bisiklet':
      return 'cycling';
    case 'Yürüyüş':
      return 'foot';
    case 'Motosiklet':
    case 'Araba':
    default:
      return 'driving';
  }
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
  var nearestIndex = 0;
  var nearestDistance = double.infinity;

  for (var index = 0; index < routePoints.length; index++) {
    final point = routePoints[index];
    final distance = geo.Geolocator.distanceBetween(
      currentPosition.latitude,
      currentPosition.longitude,
      point.latitude,
      point.longitude,
    );

    if (distance < nearestDistance) {
      nearestDistance = distance;
      nearestIndex = index;
    }
  }

  if (nearestDistance > maxDistanceMeters) {
    return routePoints;
  }

  return routePoints.sublist(nearestIndex);
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

class _HomePageState extends State<HomePage> {
  static const Duration _chatRoomLifetime = Duration(hours: 24);
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
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  Timer? _searchDebounce;
  List<Marker> _searchMarkers = const [];
  List<Polyline> _routePolylines = const [];
  List<Map<String, dynamic>> _navigationSteps = [];
  double? _navigationDistanceKm;
  int? _navigationDurationMinutes;
  bool _isNavigationActive = false;
  bool _isOpeningDirections = false;
  bool _isMapTilted = false;
  bool _isFollowingCurrentPosition = true;
  bool _isProgrammaticCameraMove = false;
  bool _hasNavigationBearing = false;
  bool _isOffRoute = false;
  bool _isNavigationVoiceEnabled = true;
  int _navigationStepIndex = 0;
  double _navigationBearing = 0;
  String? _activeNavigationTitle;
  String? _activeNavigationDestination;
  final FlutterTts _tts = FlutterTts();
  final SpeechToText _speech = SpeechToText();
  bool _isListening = false;
  final List<Map<String, dynamic>> _roadReports = [];
  final List<Map<String, dynamic>> _liveRooms = [];
  final List<Map<String, dynamic>> _communityPlaces = [];
  final List<Map<String, dynamic>> _propertyListings = [];
  final List<Map<String, dynamic>> _lostPetReports = [];
  String? _activePropertyListingType;
  bool _isLostPetMapActive = false;
  bool _isPetAdoptionMode = false;
  bool _isPropertyListingsLoading = false;
  String? _propertyListingsError;
  int _propertyListingsQueryGeneration = 0;
  bool _isLoadingLostPetReports = false;
  String? _lostPetReportsError;
  int _lostPetQueryGeneration = 0;
  String? _navigationTrafficStatus;
  LatLng? _selectedDestinationCoordinate;
  String? _selectedDestinationName;
  Map<String, dynamic>? _selectedPlaceDetails;
  final List<Map<String, dynamic>> _searchHistory = [];
  List<Map<String, dynamic>> _searchSuggestions = [];
  int _searchRequestId = 0;
  String? _searchResultName;
  bool _isSearching = false;
  bool _isSearchMode = false;
  String? _activeCategory;
  bool _showSearchPanel = false;
  String? _routeSelectionTarget;
  LatLng? _routeDraftStart;
  LatLng? _routeDraftDestination;
  StreamSubscription<geo.Position>? _positionSubscription;
  StreamSubscription<sensors.AccelerometerEvent>? _accelerometerSubscription;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>?
  _roadReportsSubscription;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>?
  _communityPlacesSubscription;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _roomsSubscription;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>?
  _propertyListingsSubscription;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>?
  _lostPetReportsSubscription;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>?
  _publicChatSubscription;
  Timer? _roadReportCleanupTimer;
  Timer? _roomExpiryTimer;
  geo.Position? _currentPosition;
  String? _currentAddress;
  DateTime? _lastAddressLookupAt;
  DateTime? _lastNavigationRefreshAt;
  bool _isRefreshingNavigation = false;
  geo.Position? _lastDrivePosition;
  DateTime? _driveStartedAt;
  bool _isDriveTracking = false;
  double _driveDistanceKm = 0;
  double _vehicleStartKm = 0;
  double? _previousSpeedKmh;
  int _driveScore = 100;
  DateTime? _lastCrashAlertAt;

  late String _userName;
  late String _userEmail;
  String _userPhone = '+90 532 000 0000';
  String _userBio = '🧭 İstanbul Keşif Tutkunu | Sık Seyahat Eden';
  String _userGender = 'Belirtmek istemiyorum';
  String _selectedVehicle = 'Araba';
  final Map<String, BitmapDescriptor> _vehicleMarkerIcons = {};

  // Pro & Oda Sınırı Değişkenleri
  bool _isProUser = false;
  bool _isDeletingAccount = false;
  bool _canManageExploreHighlights = false;
  BitmapDescriptor? _chatRoomMarkerIcon;
  bool _locationPermissionGranted = false;
  static const int _dailyRoomLimit = 3;
  static const int _freeAiQueriesPerDay = 3;
  static const int _proRoomLimit = 10;
  static const int _proAiQueriesPerDay = 10;
  int _roomsCreatedToday = 0;
  int _freeAiQueriesUsedToday = 0;
  String? _dailyQuotaDate;

  int _navoraPoints = 0;
  int _bonusChatRooms = 0;
  int _bonusAiQueries = 0;
  bool _hasProfileFrame = false;
  bool _hasAuroraTheme = false;
  bool _proDiscountUnlocked = false;
  final List<String> _visitedCities = [];
  int _communityReports = 0;
  Map<String, dynamic>? _monthlyDrivingAnalytics;
  int _monthlyDriveCount = 0;
  final List<Map<String, String>> _savedRoutes = [];

  final List<Map<String, dynamic>> _pointLedger = [];

  String _vehicleBrandModel = 'Volkswagen Golf 1.5 TSI';
  String _vehicleKm = '47.550';

  double _parseVehicleKm() {
    final normalized = _vehicleKm
        .trim()
        .replaceAll('.', '')
        .replaceAll(',', '.');
    return double.tryParse(normalized) ?? 0;
  }

  String _formatVehicleKm(double kilometers) {
    final digits = kilometers.round().toString();
    final groups = <String>[];
    for (var end = digits.length; end > 0; end -= 3) {
      final start = math.max(0, end - 3);
      groups.insert(0, digits.substring(start, end));
    }
    return groups.join('.');
  }

  final List<Map<String, String>> _savedAddresses = [
    {'title': 'Ev', 'address': 'Koşuyolu, Kadıköy / İstanbul', 'type': 'home'},
    {
      'title': 'İş',
      'address': 'Maslak Mahallesi, Sarıyer / İstanbul',
      'type': 'work',
    },
    {
      'title': 'Favori Kafe',
      'address': 'Alaçatı, Çeşme / İzmir',
      'type': 'favorite',
    },
  ];

  final List<Map<String, String>> _sosContacts = [];

  final List<Map<String, String>> _drivingHistory = [];

  final TextEditingController _aiController = TextEditingController();
  final TextEditingController _routeTitleController = TextEditingController();
  final TextEditingController _routeStartController = TextEditingController();
  final TextEditingController _routeDestinationController =
      TextEditingController();
  final TextEditingController _routeDistanceController =
      TextEditingController();
  LatLng? _activeRouteStart;
  LatLng? _activeRouteDestination;
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

  // Yakındaki Herkese Açık Mesajlar
  final List<Map<String, dynamic>> _publicFeedMessages = [
    {
      'sender': 'Ahmet',
      'text': 'Karaköy sahil tarafında trafik biraz yoğun bilginiz olsun.',
      'time': '14:20',
      'distance': '350m uzakta',
    },
    {
      'sender': 'Selin',
      'text':
          'Kadıköy tarafında önerebileceğiniz sessiz çalışma kafesi var mı?',
      'time': '14:22',
      'distance': '1.2km uzakta',
    },
    {
      'sender': 'Burak',
      'text': 'Moda Sahil\'de hava inanılmaz keyifli, yürüyüş yapacaklar kaçırmasın.',
      'time': '14:30',
      'distance': '800m uzakta',
    },
  ];

  // Uygulamadaki Herkesin Katılabileceği Genel Sohbet Odası Verisi
  final Map<String, dynamic> _generalGlobalRoom = {
    'name': 'Genel Sohbet Odası (Tüm Kullanıcılar)',
    'type': 'Genel / Sınırsız Alan',
    'distance': 'Uygulama Geneli',
    'activeUsers': '142 kişi aktif',
    'icon': Icons.public,
    'isProtected': false,
    'password': '',
    'messages': [
      {
        'sender': 'Sistem',
        'text': 'Genel Sohbet Odasına hoş geldiniz! Buradan tüm Navora kullanıcılarıyla konuşabilirsiniz.',
        'time': '00:00',
      },
      {
        'sender': 'Zeynep',
        'text': 'Herkese selamlar, İzmir\'den katılıyorum!',
        'time': '14:35',
      },
    ],
  };

  @override
  void initState() {
    super.initState();
    _userName = widget.userName;
    _userEmail = widget.userEmail;
    _initializeVoiceNavigation();
    _loadVehicleMarkerIcons();
    _loadChatRoomMarkerIcon();
    _loadLocationPermissionState();
    _loadProfileData();
    _loadExploreAdminClaim();
    _listenToRoadReports();
    _listenToCommunityPlaces();
    _subscribeToLiveRooms();
    _subscribeToPublicChat();
    _publicChatScrollController.addListener(_handlePublicChatScroll);
    _roadReportCleanupTimer = Timer.periodic(
      const Duration(minutes: 1),
      (_) => _removeExpiredRoadReports(),
    );
    _roomExpiryTimer = Timer.periodic(
      const Duration(minutes: 1),
      (_) => _removeExpiredRoomsFromView(),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => _initializeLocation());
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
    final generation = ++_propertyListingsQueryGeneration;
    await _propertyListingsSubscription?.cancel();
    if (!mounted || generation != _propertyListingsQueryGeneration) return;

    setState(() {
      _selectedIndex = 1;
      _activePropertyListingType = listingType;
      _propertyListings.clear();
      _isPropertyListingsLoading = true;
      _propertyListingsError = null;
    });

    if (FirebaseAuth.instance.currentUser == null) {
      setState(() {
        _isPropertyListingsLoading = false;
        _propertyListingsError = 'İlanları görmek için giriş yapmalısın.';
      });
      return;
    }

    _propertyListingsSubscription = FirebaseFirestore.instance
        .collection('property_listings')
        .where('status', isEqualTo: 'active')
        .where('listing_type', isEqualTo: listingType)
        .orderBy('created_at', descending: true)
        .limit(100)
        .snapshots()
        .listen(
          (snapshot) {
            if (!mounted || generation != _propertyListingsQueryGeneration) {
              return;
            }
            final listings = snapshot.docs
                .map((document) {
                  final data = document.data();
                  return <String, dynamic>{...data, 'id': document.id};
                })
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
            if (listings.isNotEmpty && _mapController != null) {
              final firstListing = listings.first;
              unawaited(
                _mapController!.animateCamera(
                  CameraUpdate.newLatLngZoom(
                    LatLng(
                      (firstListing['latitude'] as num).toDouble(),
                      (firstListing['longitude'] as num).toDouble(),
                    ),
                    13,
                  ),
                ),
              );
            }
          },
          onError: (Object error) {
            debugPrint('Emlak ilanları alınamadı: $error');
            if (!mounted || generation != _propertyListingsQueryGeneration) {
              return;
            }
            setState(() {
              _isPropertyListingsLoading = false;
              _propertyListingsError =
                  'İlanlar şu anda yüklenemiyor. Daha sonra tekrar dene.';
            });
          },
        );
  }

  Future<void> _closePropertyMap() async {
    ++_propertyListingsQueryGeneration;
    await _propertyListingsSubscription?.cancel();
    if (!mounted) return;
    setState(() {
      _selectedIndex = 0;
      _activePropertyListingType = null;
      _propertyListings.clear();
      _isPropertyListingsLoading = false;
      _propertyListingsError = null;
    });
  }

  Future<void> _openLostPetMap({bool adoptionMode = false}) async {
    final generation = ++_lostPetQueryGeneration;
    await _lostPetReportsSubscription?.cancel();
    await _propertyListingsSubscription?.cancel();
    if (!mounted || generation != _lostPetQueryGeneration) return;

    setState(() {
      _selectedIndex = 1;
      _activePropertyListingType = null;
      _isLostPetMapActive = true;
      _isPetAdoptionMode = adoptionMode;
      _propertyListings.clear();
      _lostPetReports.clear();
      _isLoadingLostPetReports = true;
      _lostPetReportsError = null;
    });

    if (FirebaseAuth.instance.currentUser == null) {
      setState(() {
        _isLoadingLostPetReports = false;
        _lostPetReportsError =
            'Hayvan ilanlarını görmek için giriş yapmalısın.';
      });
      return;
    }

    final collectionName = adoptionMode
        ? 'pet_adoption_listings'
        : 'lost_pet_reports';
    _lostPetReportsSubscription = FirebaseFirestore.instance
        .collection(collectionName)
        .where('status', isEqualTo: 'active')
        .orderBy('created_at', descending: true)
        .limit(100)
        .snapshots()
        .listen(
          (snapshot) {
            if (!mounted || generation != _lostPetQueryGeneration) return;
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
              _lostPetReports
                ..clear()
                ..addAll(reports);
              _isLoadingLostPetReports = false;
              _lostPetReportsError = null;
            });
            if (reports.isNotEmpty && _mapController != null) {
              final firstReport = reports.first;
              unawaited(
                _mapController!.animateCamera(
                  CameraUpdate.newLatLngZoom(
                    LatLng(
                      (firstReport['latitude'] as num).toDouble(),
                      (firstReport['longitude'] as num).toDouble(),
                    ),
                    13,
                  ),
                ),
              );
            }
          },
          onError: (Object error) {
            debugPrint('Kayıp dost bildirimleri alınamadı: $error');
            if (!mounted || generation != _lostPetQueryGeneration) return;
            setState(() {
              _isLoadingLostPetReports = false;
              _lostPetReportsError =
                  'Bildirimler yüklenemedi. Daha sonra tekrar dene.';
            });
          },
        );
  }

  Future<void> _closeLostPetMap() async {
    ++_lostPetQueryGeneration;
    await _lostPetReportsSubscription?.cancel();
    if (!mounted) return;
    setState(() {
      _selectedIndex = 0;
      _isLostPetMapActive = false;
      _isPetAdoptionMode = false;
      _lostPetReports.clear();
      _isLoadingLostPetReports = false;
      _lostPetReportsError = null;
    });
  }

  Future<void> _showCreateLostPetReportSheet({bool isAdoption = false}) async {
    if (FirebaseAuth.instance.currentUser == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Bildirim vermek için önce giriş yapmalısın.')),
      );
      return;
    }
    final submitted = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: false,
      backgroundColor: Colors.transparent,
      builder: (context) => CreateLostPetReportSheet(isAdoption: isAdoption),
    );
    if (submitted == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            isAdoption
                ? 'Sahiplendirme ilanı haritaya eklendi.'
                : 'Kayıp dost bildirimin haritaya eklendi.',
          ),
        ),
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
    final imageUrl = report['cover_image_url']?.toString() ?? '';
    final phone = report['contact_phone']?.toString() ?? '';
    final isOwner =
        report['owner_uid'] == FirebaseAuth.instance.currentUser?.uid;
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
              if (imageUrl.isNotEmpty)
                ClipRRect(
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(22),
                  ),
                  child: Image.network(
                    imageUrl,
                    width: double.infinity,
                    height: 220,
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stackTrace) =>
                        const SizedBox.shrink(),
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
                    else if (phone.isNotEmpty)
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
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Arama uygulaması açılamadı.')),
        );
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            isAdoption
                ? 'Sahiplendirme ilanı kapatıldı.'
                : 'Bildirim bulundu olarak kapatıldı.',
          ),
        ),
      );
    } catch (error) {
      debugPrint('Kayıp dost bildirimi kapatılamadı: $error');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Bildirim kapatılamadı. Tekrar dene.')),
      );
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
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
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

  Future<void> _initializeVoiceNavigation() async {
    await _tts.setLanguage('tr-TR');
    await _tts.setSpeechRate(0.48);
    await _tts.setVolume(1.0);
    await _tts.setPitch(1.0);
  }

  Future<void> _speakNavigation(String message) async {
    if (!_isNavigationVoiceEnabled) return;
    try {
      await _tts.stop();
      await _tts.speak(message);
    } catch (error) {
      debugPrint('Navigasyon sesi başlatılamadı: $error');
    }
  }

  void _listenToRoadReports() {
    _roadReportsSubscription = FirebaseFirestore.instance
        .collection('road_reports')
        .orderBy('created_at', descending: true)
        .limit(100)
        .snapshots()
        .listen(
          (snapshot) {
            if (!mounted) return;
            final reports = snapshot.docs
                .map((document) {
                  final data = document.data();
                  final createdAt = data['created_at'];
                  final expiresAt = data['expires_at'];
                  final expiry = expiresAt is Timestamp
                      ? expiresAt.toDate()
                      : null;
                  return <String, dynamic>{
                    'id': document.id,
                    'userId': data['user_id']?.toString() ?? '',
                    'type': data['type']?.toString() ?? 'Trafik',
                    'description': data['description']?.toString() ?? '',
                    'latitude': (data['latitude'] as num?)?.toDouble(),
                    'longitude': (data['longitude'] as num?)?.toDouble(),
                    'time': createdAt is Timestamp
                        ? _formatReportTime(createdAt.toDate())
                        : 'Yeni',
                    'confirmationCount':
                      (data['confirmation_count'] as num?)?.toInt() ?? 0,
                    'incorrectCount':
                      (data['incorrect_count'] as num?)?.toInt() ?? 0,
                    'expiresAt': expiry,
                    'reference': document.reference,
                  };
                })
                .where((report) {
                  final expiry = report['expiresAt'] as DateTime?;
                  return report['latitude'] is double &&
                      report['longitude'] is double &&
                      (expiry == null || expiry.isAfter(DateTime.now()));
                })
                .toList();
            setState(() {
              _roadReports
                ..clear()
                ..addAll(reports);
            });
          },
          onError: (error) => debugPrint('Yol bildirimleri alınamadı: $error'),
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
            final places = snapshot.docs.map((document) {
              final data = document.data();
              return <String, dynamic>{
                'id': document.id,
                'ownerUid': data['owner_uid']?.toString() ?? '',
                'name': data['name']?.toString() ?? '',
                'category': data['category']?.toString() ?? 'Diğer',
                'description': data['description']?.toString() ?? '',
                'address': data['address']?.toString() ?? '',
                'photoUrl': data['photo_url']?.toString() ?? '',
                'latitude': (data['latitude'] as num?)?.toDouble(),
                'longitude': (data['longitude'] as num?)?.toDouble(),
              };
            }).where((place) {
              return place['name'] is String &&
                  (place['name'] as String).isNotEmpty &&
                  place['latitude'] is double &&
                  place['longitude'] is double;
            }).toList();
            setState(() {
              _communityPlaces
                ..clear()
                ..addAll(places);
            });
          },
          onError: (error) => debugPrint('Topluluk mekânları alınamadı: $error'),
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
      await FirebaseFirestore.instance.collection('public_chat_messages').add({
        'senderId': user.uid,
        'senderName': _userName,
        'text': text,
        'latitude': _currentPosition?.latitude,
        'longitude': _currentPosition?.longitude,
        'createdAt': FieldValue.serverTimestamp(),
      });
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
    for (final message in _publicFeedMessages) {
      final latitude = (message['latitude'] as num?)?.toDouble();
      final longitude = (message['longitude'] as num?)?.toDouble();
      if (latitude == null || longitude == null) continue;
      message['distance'] =
          _distanceFromCurrentPosition(latitude, longitude) ??
          message['distance'];
    }
  }

  Duration _reportDuration(String type) {
    switch (type) {
      case 'Radar':
        return const Duration(hours: 2);
      case 'Trafik':
        return const Duration(hours: 1);
      case 'Yol çalışması':
        return const Duration(hours: 24);
      case 'Kaza':
        return const Duration(hours: 4);
      default:
        return const Duration(hours: 2);
    }
  }

  void _removeExpiredRoadReports() {
    final now = DateTime.now();
    final expired = _roadReports.where((report) {
      final expiry = report['expiresAt'] as DateTime?;
      return expiry != null && !expiry.isAfter(now);
    }).toList();
    if (expired.isEmpty) return;

    if (mounted) {
      setState(() {
        _roadReports.removeWhere((report) {
          final expiry = report['expiresAt'] as DateTime?;
          return expiry != null && !expiry.isAfter(now);
        });
      });
    }
    for (final report in expired) {
      final reference = report['reference'];
      if (reference is DocumentReference<Map<String, dynamic>>) {
        reference.delete().catchError((_) {});
      }
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

    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _isSearching = true);
    try {
      final locations = await geo_coding.locationFromAddress(query);
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
      final placemark = placemarks.isEmpty ? null : placemarks.first;
      final resultName = _formatPlacemark(placemark) ?? query;

      if (!mounted) return;
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
        _searchHistory.removeWhere((item) => item['query'] == query);
        _searchHistory.insert(0, {
          'query': query,
          'name': _searchResultName,
          'coordinate': coordinate,
        });
        if (_searchHistory.length > 5) _searchHistory.removeLast();
        _showSearchPanel = showPanel;
      });
      await _moveMapTo(coordinate, 15);
      if (mounted) {
        Future.microtask(() async {
          await Future<void>.delayed(const Duration(milliseconds: 300));
          if (mounted) {
            _showSelectedPlaceActionSheet();
          }
        });
      }
    } on PlatformException catch (error) {
      debugPrint('Yer araması başarısız: $error');
      _showTrackingMessage('Yer araması şu anda kullanılamıyor.');
    } catch (error) {
      debugPrint('Yer araması başarısız: $error');
      _showTrackingMessage(
        'Yer bulunamadı. İnternet bağlantınızı kontrol edin.',
      );
    } finally {
      if (mounted) setState(() => _isSearching = false);
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
      _searchHistory.removeWhere((history) => history['query'] == query);
      _searchHistory.insert(0, {
        'query': query,
        'name': name,
        'coordinate': coordinate,
      });
      if (_searchHistory.length > 5) _searchHistory.removeLast();
    });
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
    await Future<void>.delayed(const Duration(milliseconds: 150));
    if (!mounted || _selectedDestinationCoordinate == null) return;

    final placeDetails = _selectedPlaceDetails ?? const <String, dynamic>{};
    final ratingText = placeDetails['ratingText']?.toString();
    final phoneNumber = placeDetails['phoneNumber']?.toString();
    final websiteUri = Uri.tryParse(
      placeDetails['websiteUri']?.toString() ?? '',
    );
    final openingHours = (placeDetails['openingHours'] as List<dynamic>? ?? const [])
        .map((day) => day.toString())
        .toList(growable: false);
    final isOpenNow = placeDetails['isOpenNow'] as bool?;
    final currentPosition = _currentPosition;
    final distanceText = currentPosition == null
        ? null
        : _formatNearbyDistance(
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
                                placeDetails['category']?.toString() ??
                                    _activeCategory ??
                                    'Konum',
                                style: const TextStyle(
                                  color: Color(0xFFFF6B00),
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            if (distanceText != null) ...[
                              const SizedBox(width: 8),
                              Text(
                                distanceText,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.white70,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
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
                        onPressed: () => launchUrl(
                          Uri(scheme: 'tel', path: phoneNumber),
                        ),
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
                  (placeDetails['description']?.toString().isNotEmpty ?? false)) ...[
                const SizedBox(height: 10),
                Text(
                  placeDetails['description'].toString(),
                  style: const TextStyle(color: Colors.white70, height: 1.4),
                ),
              ],
              if (placeDetails['source'] == 'google_places') ...[
                const SizedBox(height: 8),
                const Text(
                  'Google Places',
                  style: TextStyle(color: Colors.white54, fontSize: 10),
                ),
              ],
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () async {
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
              if (placeDetails['source'] != 'community_place') ...[
                const SizedBox(height: 4),
                Align(
                  alignment: Alignment.center,
                  child: TextButton.icon(
                    onPressed: () async {
                      final coordinate = _selectedDestinationCoordinate;
                      if (coordinate == null) return;
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
  }

  Future<void> _selectMapLocation(LatLng coordinate) async {
    if (!mounted) return;

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
      final address = _formatPlacemark(
        placemarks.isEmpty ? null : placemarks.first,
      );
      if (!mounted || address == null) return;
      setState(() => _currentAddress = address);
    } catch (error) {
      debugPrint('Anlık adres alınamadı: $error');
    }
  }

  Future<void> _refreshNavigationRouteIfNeeded(geo.Position position) async {
    if (!_isNavigationActive || _selectedDestinationCoordinate == null) return;

    final currentPosition = LatLng(position.latitude, position.longitude);
    final liveRoute = _routePolylines.isEmpty
        ? const <LatLng>[]
        : _routePolylines.first.points;
    final offRouteThresholdMeters = switch (_selectedVehicle) {
      'Yürüyüş' => 30.0,
      'Bisiklet' => 45.0,
      'Motosiklet' => 65.0,
      _ => 80.0,
    };
    final recoveryThresholdMeters = offRouteThresholdMeters * 0.65;
    final distanceToRoute = navoraDistanceToRouteMeters(
      currentPosition,
      liveRoute,
    );
    final hasLiveRoute = liveRoute.length > 1;
    final isOffRoute =
        hasLiveRoute &&
        (_isOffRoute
            ? distanceToRoute > recoveryThresholdMeters
            : distanceToRoute > offRouteThresholdMeters);
    if (hasLiveRoute && isOffRoute != _isOffRoute) {
      _isOffRoute = isOffRoute;
      if (mounted) setState(() {});
      if (isOffRoute) {
        unawaited(
          _speakNavigation('Rotadan saptınız. Rota yeniden hesaplanıyor.'),
        );
      }
    }

    if (_isRefreshingNavigation) return;
    final now = DateTime.now();
    if (!_isOffRoute &&
        _lastNavigationRefreshAt != null &&
        now.difference(_lastNavigationRefreshAt!) <
            const Duration(seconds: 12)) {
      return;
    }
    _lastNavigationRefreshAt = now;
    _isRefreshingNavigation = true;
    try {
      final route = await _fetchRoadRoute(
        currentPosition,
        _selectedDestinationCoordinate!,
        vehicle: _selectedVehicle,
      );
      if (!mounted || !_isNavigationActive) return;
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
            color: const Color(0xFFE85D04),
            width: 7,
          ),
        ];
        _navigationSteps = List<Map<String, dynamic>>.from(route['steps']);
        _navigationStepIndex = 0;
        _navigationDistanceKm = route['distanceKm'] as double;
        _navigationDurationMinutes = route['durationMinutes'] as int;
        _isOffRoute = false;
      });
    } catch (error) {
      debugPrint('Canlı rota güncellenemedi: $error');
    } finally {
      _isRefreshingNavigation = false;
    }
  }

  void _handleSearchChanged(String value) {
    _searchDebounce?.cancel();
    final query = value.trim();
    if (mounted && !_isSearchMode) {
      setState(() => _isSearchMode = true);
    }
    if (query.isEmpty) {
      if (mounted) {
        setState(() {
          _searchSuggestions = [];
          _showSearchPanel = false;
        });
      }
      return;
    }

    if (mounted) {
      setState(() {
        _showSearchPanel = true;
      });
    }

    _searchDebounce = Timer(const Duration(milliseconds: 450), () {
      _loadSearchSuggestions(query);
    });
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
              : LatLng(
                  _currentPosition!.latitude,
                  _currentPosition!.longitude,
                ),
        ),
      ),
    );
    if (selected == null || !mounted) return;
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

  Future<void> _loadSearchSuggestions(String query) async {
    final requestId = ++_searchRequestId;
    try {
      final isBusinessQuery = NavoraPlacesService.isBusinessQuery(query);
      if (isBusinessQuery) {
        var businesses = <Map<String, dynamic>>[];
        try {
          businesses = await NavoraPlacesService.searchText(
            query,
            location: _currentPosition == null
                ? null
                : LatLng(
                    _currentPosition!.latitude,
                    _currentPosition!.longitude,
                  ),
          );
        } catch (error) {
          debugPrint('Google Places text search failed: $error');
        }
        if (businesses.isNotEmpty) {
          if (!mounted || requestId != _searchRequestId) return;
          setState(() {
            _searchSuggestions = businesses;
            _showSearchPanel = true;
          });
          return;
        }
        final category = _matchNearbyCategory(query);
        if (category != null && _currentPosition != null) {
          await _loadNearbyCategoryResults(
            category,
            _currentPosition,
            _nearbyBusinessConfig()[category]!,
          );
          return;
        }
      } else {
        var googleSuggestions = <Map<String, dynamic>>[];
        try {
          googleSuggestions = await NavoraPlacesService.autocomplete(
            query,
            location: _currentPosition == null
                ? null
                : LatLng(
                    _currentPosition!.latitude,
                    _currentPosition!.longitude,
                  ),
          );
        } catch (error) {
          debugPrint('Google Places autocomplete failed: $error');
        }
        if (googleSuggestions.isNotEmpty) {
          if (!mounted || requestId != _searchRequestId) return;
          setState(() {
            _searchSuggestions = googleSuggestions;
            _showSearchPanel = true;
          });
          return;
        }

        var googleResults = <Map<String, dynamic>>[];
        try {
          googleResults = await NavoraPlacesService.searchText(
            query,
            location: _currentPosition == null
                ? null
                : LatLng(
                    _currentPosition!.latitude,
                    _currentPosition!.longitude,
                  ),
          );
        } catch (error) {
          debugPrint('Google Places text search failed: $error');
        }
        if (googleResults.isNotEmpty) {
          if (!mounted || requestId != _searchRequestId) return;
          setState(() {
            _searchSuggestions = googleResults;
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
      final currentPosition = _currentPosition;
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
              : _formatNearbyDistance(distanceMeters),
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

      if (!mounted || requestId != _searchRequestId) return;
      if (suggestions.isEmpty && _currentPosition != null) {
        final fallbackCategory = _matchNearbyCategory(query);
        if (fallbackCategory != null) {
          final config = _nearbyBusinessConfig()[fallbackCategory]!;
          await _loadNearbyCategoryResults(
            fallbackCategory,
            _currentPosition,
            config,
          );
          return;
        }
      }

      if (suggestions.isEmpty) {
        final locations = await geo_coding.locationFromAddress(query);
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
              'distanceMeters': null,
              'distanceText': null,
            },
          ];
        }
      }

      if (!mounted || requestId != _searchRequestId) return;
      setState(() {
        _searchSuggestions = suggestions;
        _showSearchPanel = suggestions.isNotEmpty;
      });
      if (_activeCategory != null && suggestions.isNotEmpty) {
        await _showCategoryResultsOnMap(suggestions);
      }
    } catch (error) {
      debugPrint('Arama önerileri alınamadı: $error');
      if (!mounted) return;
      final fallback = await _buildFallbackLocationSuggestion(query);
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
        'distanceMeters': null,
        'distanceText': null,
      };
    } catch (_) {
      return null;
    }
  }

  Future<void> _showCategoryResultsOnMap(
    List<Map<String, dynamic>> suggestions,
  ) async {
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
    if (!mounted || points.isEmpty) return;
    setState(() => _searchMarkers = markers);
    if (points.length == 1) {
      await _moveMapTo(points.first, 14);
      return;
    }
    await _fitMapToPoints(points);
  }

  String _searchResultCategory(Map<String, dynamic> item) {
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
      return 'İşletme veya mekan';
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
    _navigationSteps = [];
    _navigationStepIndex = 0;
    _navigationDistanceKm = null;
    _navigationDurationMinutes = null;
    _isNavigationActive = false;
    _isMapTilted = false;
    _isFollowingCurrentPosition = true;
    _hasNavigationBearing = false;
    _navigationBearing = 0;
    _isOffRoute = false;
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
        if (mounted) setState(() => _currentPosition = position);
      } catch (error) {
        debugPrint('Yakın kategori konumu alınamadı: $error');
        _showTrackingMessage('Yakındaki yerleri göstermek için konum gerekli.');
        return;
      }
    }
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
      );
    } else {
      await _loadSearchSuggestions(query);
    }
  }

  Future<void> _loadNearbyCategoryResults(
    String label,
    geo.Position? position,
    Map<String, String> config,
  ) async {
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
              'distanceText': _formatNearbyDistance(distance),
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
      if (!mounted) return;
      setState(() {
        _searchSuggestions = nearbySuggestions;
        _showSearchPanel = nearbySuggestions.isNotEmpty;
      });
      await _showCategoryResultsOnMap(nearbySuggestions);
    } catch (error) {
      debugPrint('Yakındaki $label sonuçları alınamadı: $error');
      _showTrackingMessage('Yakındaki $label sonuçları şu anda alınamıyor.');
    }
  }

  String _formatNearbyDistance(double meters) {
    if (meters < 1000) return '${meters.round()} m';
    return '${(meters / 1000).toStringAsFixed(1)} km';
  }

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

  Future<void> _saveSelectedPlace() async {
    final title = _selectedDestinationName?.trim();
    if (title == null || title.isEmpty) return;
    final address = await _showAddAddressDialog(
      initialTitle: title,
      initialAddress: _searchController.text.trim(),
    );
    if (address == null || !mounted) return;
    if (_selectedDestinationCoordinate != null) {
      address['latitude'] = _selectedDestinationCoordinate!.latitude.toString();
      address['longitude'] = _selectedDestinationCoordinate!.longitude
          .toString();
    }
    final resolvedAddress = await _resolveAddressCoordinates(address);

    final user = FirebaseAuth.instance.currentUser;
    try {
      if (user != null) {
        final document = await FirebaseFirestore.instance
            .collection('users')
            .doc(user.uid)
            .collection('saved_addresses')
            .add(resolvedAddress);
        resolvedAddress['id'] = document.id;
      }
      setState(() => _savedAddresses.add(resolvedAddress));
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
      constraints: const BoxConstraints(maxHeight: 320),
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
                    final category = item['category'] ?? 'Konum';
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
                                Container(
                                  width: 38,
                                  height: 38,
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF2A180D),
                                    borderRadius: BorderRadius.circular(12),
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
                                      const SizedBox(height: 6),
                                      Row(
                                        children: [
                                          Icon(
                                            Icons.location_on_rounded,
                                            size: 11,
                                            color: const Color(0xFFFF7A00),
                                          ),
                                          const SizedBox(width: 4),
                                          Expanded(
                                            child: Text(
                                              '$category • ${distanceText ?? 'Yakın konum'}',
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                color: Colors.white70,
                                                fontSize: 10.5,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 6,
                                  ),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF1A1A1A),
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: Text(
                                    distanceText ?? 'Harita',
                                    style: const TextStyle(
                                      color: Color(0xFFFF6B00),
                                      fontSize: 10,
                                      fontWeight: FontWeight.w700,
                                    ),
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
                    onPressed: () {
                      setState(() {
                        _searchHistory.clear();
                        _showSearchPanel = false;
                      });
                    },
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

  Future<String?> _showVehiclePicker() {
    const vehicles = [
      ('Araba', 'Araba', Icons.directions_car_rounded),
      ('Motosiklet', 'Motor', Icons.two_wheeler_rounded),
      ('Bisiklet', 'Bisiklet', Icons.pedal_bike_rounded),
      ('Yürüyüş', 'Yaya', Icons.directions_walk_rounded),
    ];
    final kmController = TextEditingController(text: _vehicleKm);

    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF191919),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) {
        String localSelectedVehicle = _selectedVehicle;

        return StatefulBuilder(
          builder: (context, setSheetState) {
            final shouldShowKmInput = localSelectedVehicle != 'Yürüyüş';
            final kmFieldLabel = switch (localSelectedVehicle) {
              'Araba' => 'Araba KM',
              'Motosiklet' => 'Motor KM',
              'Bisiklet' => 'Bisiklet KM',
              _ => 'KM',
            };
            final kmHintText = switch (localSelectedVehicle) {
              'Araba' => 'Mevcut araç kilometresini girin',
              'Motosiklet' => 'Mevcut motor kilometresini girin',
              'Bisiklet' => 'Mevcut bisiklet kilometresini girin',
              _ => 'Mevcut kilometre değerini girin',
            };

            return SafeArea(
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  20,
                  18,
                  20,
                  MediaQuery.of(sheetContext).viewInsets.bottom + 12,
                ),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.of(sheetContext).size.height * 0.85,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 4),
                      ...vehicles.map(
                        (vehicle) => Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          decoration: BoxDecoration(
                            color: localSelectedVehicle == vehicle.$1
                                ? const Color(0xFF2B1A10)
                                : const Color(0xFF1B1B1B),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: localSelectedVehicle == vehicle.$1
                                  ? const Color(0xFFFF8A3D)
                                        .withValues(alpha: 0.9)
                                  : const Color(0xFFFF8A3D)
                                        .withValues(alpha: 0.25),
                            ),
                          ),
                          child: Material(
                            color: Colors.transparent,
                            child: InkWell(
                              borderRadius: BorderRadius.circular(16),
                              onTap: () {
                                setSheetState(
                                  () => localSelectedVehicle = vehicle.$1,
                                );
                              },
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                  vertical: 12,
                                ),
                                child: Row(
                                  children: [
                                    CircleAvatar(
                                      backgroundColor: const Color(0xFF2A180D),
                                      child: Icon(
                                        vehicle.$3,
                                        color: const Color(0xFFFF6B00),
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Text(
                                        vehicle.$2,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                    if (localSelectedVehicle == vehicle.$1)
                                      const Icon(
                                        Icons.check_circle,
                                        color: Color(0xFFFF6B00),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      if (shouldShowKmInput) ...[
                        const SizedBox(height: 10),
                        Container(
                          padding: const EdgeInsets.all(0),
                          decoration: BoxDecoration(
                            color: const Color(0xFF171717),
                            borderRadius: BorderRadius.circular(18),
                          ),
                          child: TextField(
                            controller: kmController,
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                            ),
                            decoration: InputDecoration(
                              hintText: kmHintText,
                              hintStyle: const TextStyle(
                                color: Colors.white54,
                                fontSize: 13,
                              ),
                              labelText: kmFieldLabel,
                              labelStyle: const TextStyle(
                                color: Color(0xFFFFB066),
                                fontWeight: FontWeight.w700,
                              ),
                              filled: true,
                              fillColor: const Color(0xFF171717),
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 14,
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(14),
                                borderSide: BorderSide(
                                  color: const Color(0xFFFF8A3D)
                                      .withValues(alpha: 0.45),
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
                        ),
                      ],
                      const SizedBox(height: 16),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed: () {
                            final cleanedKm = kmController.text
                                .replaceAll(RegExp(r'[^0-9,\.]'), '')
                                .trim();
                            if (cleanedKm.isNotEmpty) {
                              _vehicleKm = cleanedKm;
                            }
                            setState(
                              () => _selectedVehicle = localSelectedVehicle,
                            );
                            unawaited(_persistVehicleProfile());
                            Navigator.pop(sheetContext, localSelectedVehicle);
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFFFF6B00),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                          child: const Text(
                            'Seç ve kaydet',
                            style: TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
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
  }

  Future<void> _showDirectionsSheet() async {
    if (!mounted || _isOpeningDirections) return;
    _isOpeningDirections = true;
    await Future<void>.delayed(const Duration(milliseconds: 220));
    if (!mounted) {
      _isOpeningDirections = false;
      return;
    }

    var currentPosition = _currentPosition;
    if (currentPosition == null) {
      if (!await _ensureLocationPermission()) {
        _isOpeningDirections = false;
        return;
      }
      currentPosition = await geo.Geolocator.getCurrentPosition(
        locationSettings: const geo.LocationSettings(
          accuracy: geo.LocationAccuracy.medium,
        ),
      );
      if (mounted) setState(() => _currentPosition = currentPosition);
    }

    final destination = _selectedDestinationCoordinate;
    if (destination == null || !mounted) {
      _isOpeningDirections = false;
      return;
    }
    final start = LatLng(currentPosition.latitude, currentPosition.longitude);

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
        vehicle: _selectedVehicle,
      );
    } catch (error) {
      debugPrint('Yol rotası alınamadı: $error');
      _showTrackingMessage(
        'Gerçek yol tarifi alınamadı. İnternet bağlantınızı kontrol edin.',
      );
      _isOpeningDirections = false;
      return;
    }
    if (!mounted) {
      _isOpeningDirections = false;
      return;
    }

    final routePoints = route['points'] as List<LatLng>;
    final routeDistanceKm = route['distanceKm'] as double;
    final durationMinutes = route['durationMinutes'] as int;
    final trafficInfo = await NavoraTrafficService.fetchTrafficStatus(start);
    final remainingRoute = navoraTrimRouteToRemainingPath(
      routePoints,
      start,
      vehicle: _selectedVehicle,
    );

    setState(() {
      _navigationTrafficStatus = trafficInfo['status'] as String? ?? 'Açık';
      _routePolylines = [
        Polyline(
          polylineId: const PolylineId('route-navigation'),
          points: remainingRoute,
          color: const Color(0xFFE85D04),
          width: 7,
        ),
      ];
      _navigationSteps = List<Map<String, dynamic>>.from(route['steps']);
      _navigationStepIndex = 0;
      _navigationDistanceKm = routeDistanceKm;
      _navigationDurationMinutes = durationMinutes;
    });
    await _fitMapToPoints([start, destination]);
    if (!mounted) {
      _isOpeningDirections = false;
      return;
    }

    _isOpeningDirections = false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF121212),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
      ),
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 12, 18, 22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 42,
                  height: 5,
                  margin: const EdgeInsets.only(bottom: 18),
                  decoration: BoxDecoration(
                    color: const Color(0xFF4A4A4A),
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
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
              const SizedBox(height: 16),
              Text(
                _selectedDestinationName ?? 'Seçilen konum',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                'Mevcut konumunuzdan yol tarifi',
                style: TextStyle(color: Color(0xFFBDBDBD), fontSize: 13),
              ),
              const SizedBox(height: 6),
              Text(
                'Araç: ${_vehicleDisplayName(_selectedVehicle)}',
                style: const TextStyle(
                  color: Color(0xFFFFB066),
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 18),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(12, 16, 12, 16),
                decoration: BoxDecoration(
                  color: const Color(0xFF242424),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _buildRouteSummary(
                      Icons.straighten_rounded,
                      '${routeDistanceKm.toStringAsFixed(1)} km',
                      'Yaklaşık mesafe',
                    ),
                    _buildRouteSummary(
                      Icons.schedule_rounded,
                      '$durationMinutes dk',
                      'Tahmini süre',
                    ),
                    _buildRouteSummary(
                      Icons.traffic_rounded,
                      _navigationTrafficStatus ?? 'Açık',
                      'Trafik katmanı',
                    ),
                  ],
                ),
              ),
              if (_navigationSteps.isNotEmpty) ...[
                const SizedBox(height: 14),
                const Text(
                  'Yol üzerindeki adımlar',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 6),
                ..._navigationSteps.take(3).map(_buildNavigationStep),
              ],
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                height: 54,
                child: ElevatedButton.icon(
                  onPressed: () async {
                    Navigator.pop(context);
                    if (mounted) {
                      setState(() {
                        _isNavigationActive = true;
                        _isMapTilted = true;
                        _isFollowingCurrentPosition = true;
                        _hasNavigationBearing = false;
                        _isOffRoute = false;
                        _selectedIndex = 1;
                        _activeNavigationTitle = _selectedDestinationName;
                        _activeNavigationDestination =
                            _searchController.text.trim().isEmpty
                            ? _selectedDestinationName
                            : _searchController.text.trim();
                        _showSearchPanel = false;
                        FocusManager.instance.primaryFocus?.unfocus();
                      });
                    }
                    await _speakNavigation(
                      'Yola çıkıldı. ${_navigationSteps.isEmpty ? 'Rotanızı takip edin.' : _navigationSteps.first['voice']}',
                    );
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
    );
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
  }) async {
    final profile = navoraRouteProfileForVehicle(vehicle);
    final uri = Uri.parse(
      'https://router.project-osrm.org/route/v1/$profile/'
      '${start.longitude},${start.latitude};'
      '${destination.longitude},${destination.latitude}'
      '?overview=full&geometries=geojson&steps=true',
    );
    final response = await http.get(uri).timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      throw Exception('OSRM HTTP ${response.statusCode}');
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final routes = data['routes'] as List<dynamic>?;
    if (routes == null || routes.isEmpty) throw Exception('Rota bulunamadı');
    final selectedRoute = routes.first as Map<String, dynamic>;
    final geometry = selectedRoute['geometry'] as Map<String, dynamic>;
    final coordinates = geometry['coordinates'] as List<dynamic>;
    final points = coordinates
        .map(
          (coordinate) => LatLng(
            (coordinate[1] as num).toDouble(),
            (coordinate[0] as num).toDouble(),
          ),
        )
        .toList();
    final legs = selectedRoute['legs'] as List<dynamic>? ?? [];
    final rawSteps = legs
        .expand(
          (leg) =>
              (leg as Map<String, dynamic>)['steps'] as List<dynamic>? ?? [],
        )
        .map((step) => _formatNavigationStep(step as Map<String, dynamic>))
        .toList();
    return {
      'points': points,
      'distanceKm': ((selectedRoute['distance'] as num).toDouble() / 1000),
      'durationMinutes':
          (((selectedRoute['duration'] as num).toDouble() / 60).ceil()).clamp(
            1,
            999,
          ),
      'steps': rawSteps,
    };
  }

  Map<String, dynamic> _formatNavigationStep(Map<String, dynamic> step) {
    final maneuver = step['maneuver'] as Map<String, dynamic>? ?? {};
    final type = maneuver['type']?.toString() ?? 'continue';
    final modifier = maneuver['modifier']?.toString();
    final roadName = step['name']?.toString();
    final maneuverLocation = maneuver['location'] as List<dynamic>?;
    final action = switch (type) {
      'depart' => 'Yola çık',
      'arrive' => 'Hedefe ulaştın',
      'roundabout' || 'rotary' => 'Döner kavşaktan çık',
      'turn' => '${_turkishDirection(modifier)} dön',
      'merge' => 'Yola katıl',
      'fork' => 'Yol ayrımında ${_turkishDirection(modifier)} devam et',
      _ => 'Düz devam et',
    };
    final distance = (step['distance'] as num? ?? 0).toDouble();
    final distanceText = distance >= 1000
        ? '${(distance / 1000).toStringAsFixed(1)} km'
        : '${distance.round()} m';
    return {
      'text': roadName == null || roadName.isEmpty
          ? action
          : '$action, $roadName',
      'distance': distanceText,
      'icon': _navigationIcon(type, modifier),
      'voice':
          '$distanceText sonra ${roadName == null || roadName.isEmpty ? action : '$action, $roadName'}',
      'latitude': maneuverLocation != null && maneuverLocation.length > 1
          ? (maneuverLocation[1] as num).toDouble()
          : null,
      'longitude': maneuverLocation != null && maneuverLocation.isNotEmpty
          ? (maneuverLocation[0] as num).toDouble()
          : null,
    };
  }

  String _turkishDirection(String? modifier) {
    switch (modifier) {
      case 'left':
        return 'sola';
      case 'right':
        return 'sağa';
      case 'slight left':
        return 'hafif sola';
      case 'slight right':
        return 'hafif sağa';
      case 'uturn':
        return 'U dönüşü';
      default:
        return 'ileriye';
    }
  }

  IconData _navigationIcon(String type, String? modifier) {
    if (type == 'arrive') return Icons.flag_rounded;
    if (type == 'roundabout' || type == 'rotary') {
      return Icons.roundabout_right_rounded;
    }
    if (modifier == 'left' || modifier == 'slight left') {
      return Icons.turn_left_rounded;
    }
    if (modifier == 'right' || modifier == 'slight right') {
      return Icons.turn_right_rounded;
    }
    return Icons.straight_rounded;
  }

  Widget _buildNavigationStep(Map<String, dynamic> step) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Icon(
            step['icon'] as IconData,
            color: const Color(0xFFFF6B00),
            size: 20,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              step['text'] as String,
              style: const TextStyle(color: Colors.white, fontSize: 12),
            ),
          ),
          Text(
            step['distance'] as String,
            style: const TextStyle(color: Colors.white70, fontSize: 11),
          ),
        ],
      ),
    );
  }

  Widget _buildLiveNavigationCard() {
    final nextStep = _navigationSteps.isEmpty
        ? null
        : _navigationSteps[_navigationStepIndex.clamp(
            0,
            _navigationSteps.length - 1,
          )];
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
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
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFF2A180D),
                  borderRadius: BorderRadius.circular(11),
                ),
                child: const Icon(
                  Icons.navigation_rounded,
                  color: Color(0xFFFF6B00),
                  size: 20,
                ),
              ),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'Navigasyon açık',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                ),
              ),
              IconButton(
                tooltip: _isNavigationVoiceEnabled
                    ? 'Navigasyon sesini kapat'
                    : 'Navigasyon sesini aç',
                onPressed: () async {
                  final enabled = !_isNavigationVoiceEnabled;
                  setState(() => _isNavigationVoiceEnabled = enabled);
                  if (enabled) {
                    await _speakNavigation('Navigasyon sesi açıldı.');
                  } else {
                    await _tts.stop();
                  }
                },
                icon: Icon(
                  _isNavigationVoiceEnabled
                      ? Icons.volume_up_rounded
                      : Icons.volume_off_rounded,
                  color: _isNavigationVoiceEnabled
                      ? const Color(0xFFFF6B00)
                      : const Color(0xFF98A2B3),
                ),
              ),
              IconButton(
                tooltip: 'Navigasyonu kapat',
                onPressed: () => setState(() {
                  _clearRouteState();
                }),
                icon: const Icon(Icons.close_rounded, size: 20),
              ),
            ],
          ),
          if (_isOffRoute || !_isFollowingCurrentPosition) ...[
            const SizedBox(height: 4),
            Row(
              children: [
                Icon(
                  _isOffRoute ? Icons.alt_route_rounded : Icons.pan_tool_alt,
                  color: _isOffRoute
                      ? const Color(0xFFFF6B00)
                      : const Color(0xFF98A2B3),
                  size: 16,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    _isOffRoute
                        ? 'Rotadan sapıldı, rota yeniden hesaplanıyor'
                        : 'Harita takibi duraklatıldı',
                    style: TextStyle(
                      color: _isOffRoute
                          ? const Color(0xFFFF9A3C)
                          : const Color(0xFFB5BCC8),
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ],
          if (nextStep != null) ...[
            const Divider(height: 12, color: Color(0xFF333333)),
            Row(
              children: [
                Icon(
                  nextStep['icon'] as IconData,
                  color: const Color(0xFFFF6B00),
                  size: 34,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Sıradaki hareket',
                        style: TextStyle(color: Colors.white, fontSize: 11),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        nextStep['text'] as String,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 16,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  nextStep['distance'] as String,
                  style: const TextStyle(
                    color: Color(0xFFFF6B00),
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                ),
              ],
            ),
          ],
          if (_selectedDestinationName != null) ...[
            const SizedBox(height: 8),
            Text(
              'Hedef: $_selectedDestinationName',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 11),
            ),
          ],
          const SizedBox(height: 8),
          if (_currentAddress != null) ...[
            Text(
              _currentAddress!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white60, fontSize: 11),
            ),
            const SizedBox(height: 6),
          ],
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              Text(
                '${_navigationDistanceKm?.toStringAsFixed(1) ?? '-'} km',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Text(
                '${_navigationDurationMinutes ?? '-'} dk',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              ),
              TextButton(
                onPressed: _isDriveTracking ? _toggleDriveTracking : null,
                style: TextButton.styleFrom(
                  foregroundColor: const Color(0xFFFF7A00),
                  disabledForegroundColor: Colors.white38,
                ),
                child: const Text('Bitir'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  int get _monthEarned => _pointLedger
      .where((e) => (e['amount'] as int) > 0)
      .fold(0, (sum, e) => sum + (e['amount'] as int));

  int get _monthSpent => _pointLedger
      .where((e) => (e['amount'] as int) < 0)
      .fold(0, (sum, e) => sum + -(e['amount'] as int));

  int get _citiesVisited => _visitedCities.length;

  int get _savedRouteCount => _savedRoutes.length;

  int get _aiQueriesRemaining {
    final dailyLimit = _isProUser ? _proAiQueriesPerDay : _freeAiQueriesPerDay;
    final freeLeft = (dailyLimit - _freeAiQueriesUsedToday).clamp(
      0,
      dailyLimit,
    );
    return freeLeft + _bonusAiQueries;
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
    return '${date.day.toString().padLeft(2, '0')}.${date.month.toString().padLeft(2, '0')}.${date.year}';
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

  Future<void> _persistDailyQuota() async {
    final userId = FirebaseAuth.instance.currentUser?.uid ?? 'guest';
    final preferences = await SharedPreferences.getInstance();
    final prefix = 'navora.dailyQuota.$userId.';
    await preferences.setString(
      '${prefix}date',
      _dailyQuotaDate ?? _dailyQuotaKey(DateTime.now()),
    );
    await preferences.setInt('${prefix}rooms', _roomsCreatedToday);
    await preferences.setInt('${prefix}ai', _freeAiQueriesUsedToday);
  }

  Future<void> _loadProfileData() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    try {
      final preferences = await SharedPreferences.getInstance();
      final quotaPrefix = 'navora.dailyQuota.${user.uid}.';
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
      final sosContactsSnapshot = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .collection('sos_contacts')
          .get();
      final communityReportsSnapshot = await FirebaseFirestore.instance
          .collection('road_reports')
          .where('user_id', isEqualTo: user.uid)
          .get();
      final data = profile.data();
      if (!mounted || data == null) return;

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
        if (savedAddresses.isNotEmpty) {
          _savedAddresses
            ..clear()
            ..addAll(savedAddresses);
        }
        final drivingHistory = drivingHistorySnapshot.docs
            .where((document) => !_isHistoryExpired(document.data()))
            .map((document) => document.data())
            .map(
              (history) => <String, String>{
                'route': history['route']?.toString() ?? 'Tamamlanan rota',
                'date': history['date']?.toString() ?? '',
                'duration': '${history['duration_minutes'] ?? 0} dk',
                'km': '${history['distance_km'] ?? 0} km',
                'score': history['score']?.toString() ?? '0',
              },
            )
            .toList();
        final routeHistory = routeHistorySnapshot.docs
            .where((document) => !_isHistoryExpired(document.data()))
            .map((document) => document.data())
            .map(
              (history) => <String, String>{
                'route': history['title']?.toString() ?? 'Tamamlanan rota',
                'date': _formatHistoryDate(history['completed_at']),
                'duration': '${history['duration_minutes'] ?? 0} dk',
                'km': '${history['distance_km'] ?? 0} km',
                'score': history['score']?.toString() ?? '0',
              },
            )
            .toList();
        drivingHistory.addAll(routeHistory);
        if (drivingHistory.isNotEmpty) {
          _drivingHistory
            ..clear()
            ..addAll(drivingHistory);
        }
        final now = DateTime.now();
        final monthStart = DateTime(now.year, now.month);
        final monthlyDrives = drivingHistorySnapshot.docs.where((document) {
          final data = document.data();
          final timestamp = data['completed_at'];
          final completedAt = timestamp is Timestamp
              ? timestamp.toDate()
              : DateTime.tryParse(data['date']?.toString() ?? '');
          return completedAt != null && !completedAt.isBefore(monthStart);
        }).toList();
        if (monthlyDrives.isEmpty) {
          _monthlyDriveCount = 0;
          _monthlyDrivingAnalytics = null;
        } else {
          _monthlyDriveCount = monthlyDrives.length;
          final totalDistance = monthlyDrives.fold<double>(
            0,
            (total, document) =>
                total +
                ((document.data()['distance_km'] as num?)?.toDouble() ?? 0),
          );
          final totalSpeed = monthlyDrives.fold<double>(
            0,
            (total, document) =>
                total +
                ((document.data()['average_speed_kmh'] as num?)?.toDouble() ??
                    0),
          );
          final totalScore = monthlyDrives.fold<double>(
            0,
            (total, document) =>
                total + ((document.data()['score'] as num?)?.toDouble() ?? 0),
          );
          _monthlyDrivingAnalytics = {
            'total_distance_km': totalDistance,
            'average_speed_kmh': totalSpeed / monthlyDrives.length,
            'driving_score': totalScore / monthlyDrives.length,
            'saved_co2_kg': totalDistance * 0.12,
          };
        }
        final sosContacts = sosContactsSnapshot.docs
            .map(
              (document) => {
                'id': document.id,
                'name': document.data()['name']?.toString() ?? '',
                'phone': document.data()['phone']?.toString() ?? '',
                'relation': document.data()['relation']?.toString() ?? '',
              },
            )
            .toList();
        _sosContacts
          ..clear()
          ..addAll(sosContacts);
        final visitedCities = data['visited_cities'];
        _visitedCities
          ..clear()
          ..addAll(
            visitedCities is List
                ? visitedCities.whereType<String>()
                : const [],
          );
        _communityReports = communityReportsSnapshot.docs.length;
        final storedPoints = data['navora_points'];
        _navoraPoints =
            preferences.getInt('navora.points.${user.uid}') ??
            (storedPoints is num ? storedPoints.toInt() : 0);
        final today = _dailyQuotaKey(DateTime.now());
        final storedQuotaDate = preferences.getString('${quotaPrefix}date');
        _dailyQuotaDate = today;
        if (storedQuotaDate == today) {
          _roomsCreatedToday = preferences.getInt('${quotaPrefix}rooms') ?? 0;
          _freeAiQueriesUsedToday = preferences.getInt('${quotaPrefix}ai') ?? 0;
        } else {
          _roomsCreatedToday = 0;
          _freeAiQueriesUsedToday = 0;
          unawaited(_persistDailyQuota());
        }
        final encodedPointLedger = preferences.getString(
          'navora.pointLedger.${user.uid}',
        );
        final pointLedger = encodedPointLedger == null
            ? <Map<String, dynamic>>[]
            : (jsonDecode(encodedPointLedger) as List<dynamic>)
                  .whereType<Map>()
                  .map(Map<String, dynamic>.from)
                  .toList();
        _pointLedger
          ..clear()
          ..addAll(pointLedger);
        final phone = data['phone'];
        final bio = data['bio'];
        final email =
            data['email']?.toString() ?? user.email ?? widget.userEmail;
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
        final vehicleBrandModel = data['vehicle_brand_model']?.toString();
        final vehicleKm = data['vehicle_km']?.toString();
        if (vehicleBrandModel != null && vehicleBrandModel.isNotEmpty) {
          _vehicleBrandModel = vehicleBrandModel;
        }
        if (vehicleKm != null && vehicleKm.isNotEmpty) _vehicleKm = vehicleKm;
        if (phone is String && phone.isNotEmpty) _userPhone = phone;
        if (bio is String && bio.isNotEmpty) _userBio = bio;
      });
    } catch (_) {
      // Profil verisi okunamazsa varsayılan bilgiler kullanılmaya devam eder.
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomSafeInset = MediaQuery.viewPaddingOf(context).bottom;

    return Theme(
      data: ThemeData.light().copyWith(
        scaffoldBackgroundColor: const Color(0xFF111111),
      ),
      child: Scaffold(
        resizeToAvoidBottomInset: false,
        body: SafeArea(
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
                  top: 10,
                  left: 16,
                  right: 16,
                  child: _buildLostPetMapToolbar(),
                ),
              if (_selectedIndex == 1 &&
                  !_isNavigationActive &&
                  !_isLostPetMapActive &&
                  _activePropertyListingType != null)
                Positioned(
                  top: 10,
                  left: 16,
                  right: 16,
                  child: _buildPropertyMapToolbar(),
                ),
              if (_selectedIndex == 1 &&
                  !_isNavigationActive &&
                  !_isLostPetMapActive &&
                  _activePropertyListingType == null)
                Positioned(
                  top: 10,
                  left: 16,
                  right: 16,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          color: const Color(0xFF171717),
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
                                  onTap: () => unawaited(_createCommunityPlace()),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ],
                  ),
                ),
              if (_selectedIndex == 1 &&
                  !_isLostPetMapActive &&
                  _showSearchPanel)
                Positioned(
                  left: 16,
                  right: 16,
                  bottom: 14,
                  child: _buildSearchResultsPanel(),
                ),
              if (_selectedIndex == 1)
                Positioned(
                  right: 16,
                  bottom: 90,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
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
                          child: Icon(
                            _isMapTilted
                                ? Icons.terrain_rounded
                                : Icons.explore_rounded,
                          ),
                        ),
                        const SizedBox(height: 10),
                      ],
                      FloatingActionButton.small(
                        heroTag: 'my-location',
                        onPressed: () async {
                          try {
                            if (!await _ensureLocationPermission()) return;
                            final position =
                                _currentPosition ??
                                await geo.Geolocator.getLastKnownPosition() ??
                                await geo.Geolocator.getCurrentPosition(
                                  locationSettings: const geo.LocationSettings(
                                    accuracy: geo.LocationAccuracy.medium,
                                  ),
                                ).timeout(const Duration(seconds: 20));
                            if (mounted) {
                              setState(() {
                                _currentPosition = position;
                                _isFollowingCurrentPosition = true;
                              });
                              await _centerOnPosition(position);
                            }
                          } catch (error) {
                            debugPrint('Konum alınırken hata: $error');
                            _showTrackingMessage(
                              'Konum alınamadı. GPS ayarlarını kontrol edin.',
                            );
                          }
                        },
                        tooltip: _isFollowingCurrentPosition
                            ? 'Konumum'
                            : 'Takibe dön',
                        backgroundColor: const Color(0xFF191919),
                        foregroundColor: const Color(0xFFFF6B00),
                        child: Icon(
                          _isFollowingCurrentPosition
                              ? Icons.my_location
                              : Icons.near_me_rounded,
                        ),
                      ),
                      if (_isDriveTracking) ...[
                        const SizedBox(height: 10),
                        FloatingActionButton.small(
                          heroTag: 'road-report',
                          onPressed: _showAddRoadReportSheet,
                          tooltip: 'Yol bildirimi ekle',
                          backgroundColor: const Color(0xFF191919),
                          foregroundColor: const Color(0xFFFF6B00),
                          child: const Icon(Icons.add_alert_rounded),
                        ),
                      ],
                    ],
                  ),
                ),
              if (_selectedIndex == 1 && _isNavigationActive)
                Positioned(
                  left: 16,
                  right: 16,
                  top: 10,
                  child: _buildLiveNavigationCard(),
                ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: SizedBox(
                  height: 76 + bottomSafeInset,
                  child: Stack(
                    children: [
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: bottomSafeInset,
                        height: 76,
                        child: Container(
                          decoration: BoxDecoration(
                            color: const Color(0xFFFF7A00),
                            border: const Border(
                              top: BorderSide(
                                color: Color(0xFFFFA04D),
                                width: 1,
                              ),
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        height: 56,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceAround,
                          children: [
                            _buildNavItem(Icons.explore, 'Keşfet', 0),
                            _buildNavItem(Icons.map_rounded, 'Harita', 1),
                            _buildNavItem(Icons.auto_awesome, 'Navora AI', 2),
                            _buildNavItem(Icons.forum, 'Sohbet', 3),
                            _buildNavItem(Icons.person, 'Profil', 4),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showAddRoadReportSheet() async {
    if (_currentPosition == null) {
      _showTrackingMessage('Bildirim eklemek için önce konumunuzu açın.');
      return;
    }

    const reportTypes = ['Radar', 'Trafik', 'Yol çalışması', 'Kaza'];
    String selectedType = reportTypes.first;
    final descriptionController = TextEditingController();
    final report = await showModalBottomSheet<Map<String, String>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF171717),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) => Padding(
          padding: EdgeInsets.fromLTRB(
            20,
            22,
            20,
            MediaQuery.of(context).viewInsets.bottom + 24,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Yol bildirimi ekle',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 19,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Bildirim mevcut konumunuzda haritaya işaretlenecek.',
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                initialValue: selectedType,
                dropdownColor: const Color(0xFF242424),
                style: const TextStyle(color: Colors.white),
                iconEnabledColor: const Color(0xFFFF7A00),
                decoration: InputDecoration(
                  labelText: 'Bildirim türü',
                  labelStyle: const TextStyle(color: Color(0xFFBDBDBD)),
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
                items: reportTypes
                    .map(
                      (type) => DropdownMenuItem(
                        value: type,
                        child: Row(
                          children: [
                            Icon(
                              _reportIcon(type),
                              size: 20,
                              color: const Color(0xFFFF7A00),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              type,
                              style: const TextStyle(color: Colors.white),
                            ),
                          ],
                        ),
                      ),
                    )
                    .toList(),
                onChanged: (value) {
                  if (value != null) setSheetState(() => selectedType = value);
                },
              ),
              const SizedBox(height: 12),
              TextField(
                controller: descriptionController,
                maxLines: 2,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  labelText: 'Kısa açıklama',
                  hintText: 'Örn. Sağ şeritte yoğunluk var',
                  labelStyle: const TextStyle(color: Color(0xFFBDBDBD)),
                  hintStyle: const TextStyle(color: Color(0xFF8F8F8F)),
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
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                height: 46,
                child: ElevatedButton.icon(
                  onPressed: () {
                    Navigator.pop(context, {
                      'type': selectedType,
                      'description': descriptionController.text.trim(),
                    });
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFFF7A00),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  icon: const Icon(Icons.publish_rounded),
                  label: const Text('Haritada yayınla'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    descriptionController.dispose();

    if (report == null || !mounted || _currentPosition == null) return;
    final position = _currentPosition!;
    final reportType = report['type']!;
    final expiresAt = DateTime.now().add(_reportDuration(reportType));
    final reportDescription = report['description']!.isEmpty
        ? 'Yol durumu bildirimi'
        : report['description']!;
    setState(() {
      _roadReports.add({
        'id': DateTime.now().microsecondsSinceEpoch,
        'type': reportType,
        'description': reportDescription,
        'latitude': position.latitude,
        'longitude': position.longitude,
        'time': 'Şimdi',
        'confirmationCount': 0,
        'incorrectCount': 0,
        'expiresAt': expiresAt,
      });
    });
    try {
      await FirebaseFirestore.instance.collection('road_reports').add({
        'type': reportType,
        'description': reportDescription,
        'latitude': position.latitude,
        'longitude': position.longitude,
        'created_at': FieldValue.serverTimestamp(),
        'expires_at': Timestamp.fromDate(expiresAt),
        'user_id': FirebaseAuth.instance.currentUser?.uid,
        'confirmation_count': 0,
        'incorrect_count': 0,
      });
      if (mounted) setState(() => _communityReports++);
    } catch (error) {
      debugPrint('Yol bildirimi kaydedilemedi: $error');
      if (!mounted) return;
      _showTrackingMessage(
        'Bildirim sadece bu cihazda gösteriliyor. Sunucuya kaydedilemedi.',
      );
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Yol bildirimi haritaya eklendi.')),
    );
  }

  Future<void> _showCreatePropertyListingSheet() async {
    if (FirebaseAuth.instance.currentUser == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('İlan vermek için önce giriş yapmalısın.'),
        ),
      );
      return;
    }

    final submitted = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: false,
      backgroundColor: Colors.transparent,
      builder: (context) => const CreatePropertyListingSheet(),
    );
    if (submitted == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('İlanın incelemeye gönderildi.')),
      );
    }
  }

  Widget _buildExplorePage() {
    return ExplorePage(
      onSelectListingType: (type) => unawaited(_openPropertyMap(type)),
      onSelectLostPet: () => unawaited(_openLostPetMap()),
      currentUserUid: FirebaseAuth.instance.currentUser?.uid,
      canManageHighlights: _canManageExploreHighlights,
      savedAddresses: _savedAddresses,
        communityPlaces: _communityPlaces,
        onAddCommunityPlace: () => unawaited(_createCommunityPlace()),
        onSelectCommunityPlace: (place) =>
          unawaited(_openCommunityPlaceFromExplore(place)),
        onShowCommunityPlaces: () =>
            unawaited(_showCommunityPlacesOnMap()),
      recentSearches: _searchHistory
          .map(
            (search) => <String, String>{
              'name': search['name']?.toString() ?? '',
              'query': search['query']?.toString() ?? '',
            },
          )
          .toList(),
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
        onSubmit: ({
          required name,
          required category,
          required description,
          required address,
          required photoBytes,
          required photoExtension,
        }) async {
          final placeReference = FirebaseFirestore.instance
              .collection('community_places')
              .doc();
          final photoReference = photoBytes == null || photoExtension == null
              ? null
              : FirebaseStorage.instance.ref().child(
                  'community_places/${user.uid}/${placeReference.id}/cover',
                );

          try {
            await placeReference.set({
              'owner_uid': user.uid,
              'name': name,
              'category': category,
              'description': description,
              'address': address,
              'latitude': selectedCoordinate.latitude,
              'longitude': selectedCoordinate.longitude,
              'created_at': FieldValue.serverTimestamp(),
            });
            if (photoReference != null && photoBytes != null) {
              final contentType = switch (photoExtension) {
                'jpg' || 'jpeg' => 'image/jpeg',
                'png' => 'image/png',
                'webp' => 'image/webp',
                _ => throw StateError('JPG, PNG veya WebP fotoğraf seçmelisin.'),
              };
              await photoReference.putData(
                photoBytes,
                SettableMetadata(contentType: contentType),
              );
              await placeReference.update({
                'photo_url': await photoReference.getDownloadURL(),
              });
            }
          } catch (_) {
            if (photoReference != null) {
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

  Future<void> _openCommunityPlaceFromExplore(
    Map<String, dynamic> place,
  ) async {
    final latitude = place['latitude'] as double?;
    final longitude = place['longitude'] as double?;
    if (latitude == null || longitude == null) return;
    setState(() => _selectedIndex = 1);
    await _showCommunityPlaceOnMap(place);
  }

  Future<void> _showCommunityPlacesOnMap() async {
    final places = _communityPlaces.where((place) {
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
          icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueCyan),
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
    final status =
        _lostPetReportsError ??
        (_isLoadingLostPetReports
            ? 'Bildirimler yükleniyor...'
            : _lostPetReports.isEmpty
            ? _isPetAdoptionMode
                  ? 'Henüz sahiplendirme ilanı yok'
                  : 'Aktif kayıp dost bildirimi yok'
            : _isPetAdoptionMode
            ? '${_lostPetReports.length} ilan haritada'
            : '${_lostPetReports.length} aktif bildirim');
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
    final status =
        _propertyListingsError ??
        (_isPropertyListingsLoading
            ? 'İlanlar yükleniyor...'
            : _propertyListings.isEmpty
            ? 'Bu kategoride henüz ilan yok'
            : '${_propertyListings.length} ilan haritada');

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
            padding: const EdgeInsets.only(left: 48, top: 1),
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
    final roomMarkers = _liveRooms
        .where(
          (room) =>
              _chatRoomMarkerIcon != null &&
              room['latitude'] is num &&
              room['longitude'] is num,
        )
        .map(
          (room) => Marker(
            markerId: MarkerId(
              'room-${room['id'] ?? room['name'] ?? DateTime.now().microsecondsSinceEpoch}',
            ),
            position: LatLng(
              (room['latitude'] as num).toDouble(),
              (room['longitude'] as num).toDouble(),
            ),
            icon: _chatRoomMarkerIcon!,
            onTap: () => _showRoomMarkerDialog(room),
          ),
        )
        .toList();
    final communityPlaceMarkers = _communityPlaces
        .map(
          (place) => Marker(
            markerId: MarkerId('community-place-${place['id']}'),
            position: LatLng(
              (place['latitude'] as num).toDouble(),
              (place['longitude'] as num).toDouble(),
            ),
            icon: BitmapDescriptor.defaultMarkerWithHue(
              BitmapDescriptor.hueCyan,
            ),
            onTap: () => _showCommunityPlaceOnMap(place),
          ),
        )
        .toList();
    final reportMarkers = _roadReports
        .map(
          (report) => Marker(
            markerId: MarkerId('report-${report['id']}'),
            position: LatLng(
              (report['latitude'] as num).toDouble(),
              (report['longitude'] as num).toDouble(),
            ),
            icon: BitmapDescriptor.defaultMarkerWithHue(
              _reportMarkerColor(report['type'] as String) == Colors.red
                  ? BitmapDescriptor.hueRed
                  : _reportMarkerColor(report['type'] as String) ==
                        Colors.orange
                  ? BitmapDescriptor.hueOrange
                  : BitmapDescriptor.hueBlue,
            ),
            onTap: () => _showRoadReportDialog(report),
          ),
        )
        .toList();
    final currentVehicleMarker =
        _currentPosition == null || !_isNavigationActive
        ? null
        : Marker(
            markerId: const MarkerId('current-vehicle-location'),
            position: LatLng(
              _currentPosition!.latitude,
              _currentPosition!.longitude,
            ),
            icon:
                _vehicleMarkerIcons[_selectedVehicle] ??
                BitmapDescriptor.defaultMarkerWithHue(
                  BitmapDescriptor.hueAzure,
                ),
            zIndexInt: 999,
          );
    final savedAddressMarkers = _savedAddresses
        .asMap()
        .entries
        .where((entry) {
          final latitude = double.tryParse(entry.value['latitude'] ?? '');
          final longitude = double.tryParse(entry.value['longitude'] ?? '');
          return latitude != null && longitude != null;
        })
        .map((entry) {
          final address = entry.value;
          final latitude = double.parse(address['latitude']!);
          final longitude = double.parse(address['longitude']!);
          final hue = address['type'] == 'home'
              ? BitmapDescriptor.hueAzure
              : address['type'] == 'work'
              ? BitmapDescriptor.hueGreen
              : BitmapDescriptor.hueRose;
          return Marker(
            markerId: MarkerId('saved-address-${entry.key}'),
            position: LatLng(latitude, longitude),
            icon: BitmapDescriptor.defaultMarkerWithHue(hue),
            onTap: () async {
              final coordinate = LatLng(latitude, longitude);
              final title = address['title'] ?? 'Kayıtlı adres';
              setState(() {
                _selectedDestinationCoordinate = coordinate;
                _selectedDestinationName = title;
                _selectedPlaceDetails = null;
                _searchController.text = address['address'] ?? title;
                _searchResultName = title;
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
              await _showSelectedPlaceActionSheet();
            },
          );
        })
        .toList();
    final lostPetMarkers = _lostPetReports.map((report) {
      final isAdoption = report['collection'] == 'pet_adoption_listings';
      final latitude = (report['latitude'] as num).toDouble();
      final longitude = (report['longitude'] as num).toDouble();
      final petName = report['pet_name']?.toString() ?? '';
      final petType = _lostPetTypeLabel(report['pet_type']?.toString());
      return Marker(
        markerId: MarkerId(
          '${isAdoption ? 'adoption' : 'lost-pet'}-${report['id']}',
        ),
        position: LatLng(latitude, longitude),
        icon: BitmapDescriptor.defaultMarkerWithHue(
          isAdoption ? BitmapDescriptor.hueGreen : BitmapDescriptor.hueRose,
        ),
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
    }).toList();
    final propertyMarkers = _propertyListings.map((listing) {
      final latitude = (listing['latitude'] as num).toDouble();
      final longitude = (listing['longitude'] as num).toDouble();
      return Marker(
        markerId: MarkerId('property-${listing['id']}'),
        position: LatLng(latitude, longitude),
        icon: BitmapDescriptor.defaultMarkerWithHue(
          listing['listing_type'] == 'kiralik'
              ? BitmapDescriptor.hueAzure
              : BitmapDescriptor.hueOrange,
        ),
        infoWindow: InfoWindow(
          title: listing['title']?.toString() ?? 'Konut ilanı',
          snippet: _formatListingPrice(listing['price']),
        ),
        onTap: () => _showPropertyListing(listing),
      );
    }).toList();

    final mapMarkers = <Marker>{
      ..._searchMarkers,
      ...roomMarkers,
      ...communityPlaceMarkers,
      ...reportMarkers,
      ...savedAddressMarkers,
      ...lostPetMarkers,
      ...propertyMarkers,
    };
    if (currentVehicleMarker != null) {
      mapMarkers.add(currentVehicleMarker);
    }

    return GoogleMap(
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
      myLocationEnabled: _locationPermissionGranted && !_isNavigationActive,
      myLocationButtonEnabled: true,
      zoomControlsEnabled: false,
      compassEnabled: true,
      markers: mapMarkers,
      circles: roomGlowCircles,
      polylines: _routePolylines.toSet(),
      onMapCreated: (controller) {
        _mapController = controller;
      },
      onTap: _handleRouteMapTap,
      onLongPress: _selectMapLocation,
      onCameraMoveStarted: () {
        if (_isProgrammaticCameraMove || !_isFollowingCurrentPosition) return;
        if (mounted) {
          setState(() => _isFollowingCurrentPosition = false);
        }
      },
    );
  }

  Color _reportMarkerColor(String type) {
    switch (type) {
      case 'Radar':
        return const Color(0xFFFF6B00);
      case 'Trafik':
        return Colors.red;
      case 'Yol çalışması':
        return Colors.orange;
      default:
        return Colors.orange;
    }
  }

  void _showRoadReportDialog(Map<String, dynamic> report) {
    final reportId = report['id']?.toString();
    final currentUser = FirebaseAuth.instance.currentUser;
    final canVote = reportId != null &&
        currentUser != null &&
        report['userId'] != currentUser.uid;
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) {
          final isSubmitting = report['isSubmittingFeedback'] == true;
          return Padding(
          padding: const EdgeInsets.fromLTRB(20, 22, 20, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    _reportIcon(report['type'] as String),
                    color: const Color(0xFFFF6B00),
                    size: 28,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      report['type'] as String,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                report['description'] as String,
                style: const TextStyle(fontSize: 14, height: 1.4),
              ),
              const SizedBox(height: 8),
              Text(
                'Topluluk bildirimi • ${report['time']}',
                style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
              ),
              const SizedBox(height: 12),
              Text(
                '${report['confirmationCount'] ?? 0} doğrulama • '
                '${report['incorrectCount'] ?? 0} yanlış bildirimi',
                style: TextStyle(color: Colors.grey.shade400, fontSize: 12),
              ),
              if (canVote) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: isSubmitting
                            ? null
                            : () => _sendRoadReportFeedback(
                                context,
                                setSheetState,
                                report,
                                reportId,
                                'confirmed',
                              ),
                        icon: const Icon(Icons.thumb_up_alt_outlined),
                        label: const Text('Doğrula'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: isSubmitting
                            ? null
                            : () => _sendRoadReportFeedback(
                                context,
                                setSheetState,
                                report,
                                reportId,
                                'incorrect',
                              ),
                        icon: const Icon(Icons.flag_outlined),
                        label: const Text('Yanlış bildir'),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
          );
        },
      ),
    );
  }

  Future<void> _sendRoadReportFeedback(
    BuildContext sheetContext,
    StateSetter setSheetState,
    Map<String, dynamic> report,
    String reportId,
    String vote,
  ) async {
    setSheetState(() => report['isSubmittingFeedback'] = true);
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) throw StateError('sign-in-required');

      final reportReference = FirebaseFirestore.instance
          .collection('road_reports')
          .doc(reportId);
      final feedbackReference = reportReference
          .collection('feedback')
          .doc(user.uid);
      final counterField = vote == 'confirmed'
          ? 'confirmation_count'
          : 'incorrect_count';

      await FirebaseFirestore.instance.runTransaction((transaction) async {
        final reportSnapshot = await transaction.get(reportReference);
        final feedbackSnapshot = await transaction.get(feedbackReference);
        if (!reportSnapshot.exists) throw StateError('report-missing');
        if (feedbackSnapshot.exists) throw StateError('already-voted');

        final reportData = reportSnapshot.data()!;
        if (reportData['user_id'] == user.uid) {
          throw StateError('own-report');
        }
        final expiresAt = reportData['expires_at'];
        if (expiresAt is! Timestamp || !expiresAt.toDate().isAfter(DateTime.now())) {
          throw StateError('report-expired');
        }

        transaction.set(feedbackReference, {
          'vote': vote,
          'created_at': FieldValue.serverTimestamp(),
        });
        transaction.update(reportReference, {
          counterField: FieldValue.increment(1),
        });
      });

      if (!mounted) return;
      setState(() {
        final index = _roadReports.indexWhere(
          (item) => item['id']?.toString() == reportId,
        );
        if (index < 0) return;
        final field = vote == 'confirmed'
            ? 'confirmationCount'
            : 'incorrectCount';
        _roadReports[index][field] =
            ((_roadReports[index][field] as int?) ?? 0) + 1;
      });
      if (sheetContext.mounted) Navigator.pop(sheetContext);
      _showTrackingMessage(
        vote == 'confirmed'
            ? 'Bildirim doğrulandı.'
            : 'Yanlış bildirim inceleme için işaretlendi.',
      );
    } catch (error) {
      final message = error is StateError && error.message == 'already-voted'
          ? 'Bu bildirim için zaten oy kullandın.'
          : error is StateError && error.message == 'own-report'
          ? 'Kendi bildirimini doğrulayamazsın.'
          : error is StateError && error.message == 'report-expired'
          ? 'Bu bildirimin süresi dolmuş.'
          : error is StateError && error.message == 'sign-in-required'
          ? 'Oy kullanmak için giriş yapmalısın.'
          : 'Geri bildirimin kaydedilemedi.';
      debugPrint('Yol bildirimi geri bildirimi kaydedilemedi: $error');
      if (mounted) _showTrackingMessage(message);
    } finally {
      if (sheetContext.mounted) {
        setSheetState(() => report['isSubmittingFeedback'] = false);
      }
    }
  }

  IconData _reportIcon(String type) {
    switch (type) {
      case 'Radar':
        return Icons.speed_rounded;
      case 'Trafik':
        return Icons.traffic_rounded;
      case 'Yol çalışması':
        return Icons.construction_rounded;
      default:
        return Icons.car_crash_rounded;
    }
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
                  if (room['isProtected'] == true) {
                    _showPasswordPromptDialog(room);
                  } else {
                    _openRoomChat(room);
                  }
                },
              ),
            ),
            if (room['ownerId'] == FirebaseAuth.instance.currentUser?.uid) ...[
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
    _publicChatScrollController.dispose();
    _searchController.dispose();
    _roomSearchController.dispose();
    _searchFocusNode.dispose();
    _searchDebounce?.cancel();
    _tts.stop();
    _speech.stop();
    _roadReportsSubscription?.cancel();
    _communityPlacesSubscription?.cancel();
    _roomsSubscription?.cancel();
    _propertyListingsSubscription?.cancel();
    _lostPetReportsSubscription?.cancel();
    _publicChatSubscription?.cancel();
    _roadReportCleanupTimer?.cancel();
    _roomExpiryTimer?.cancel();
    _positionSubscription?.cancel();
    _accelerometerSubscription?.cancel();
    super.dispose();
  }

  Widget _buildAiPage() {
    final keyboardInset = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: keyboardInset > 0 ? 0 : 90),
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
                Text(
                  _isProUser ? 'Sınırsız' : '$_aiQueriesRemaining soru hakkı',
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
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
    return Padding(
      padding: EdgeInsets.only(bottom: keyboardInset > 0 ? 0 : 90),
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
                    Row(
                      children: [
                        const Icon(Icons.forum, color: Colors.white, size: 28),
                        const SizedBox(width: 12),
                        Text(
                          _chatSubTab == 0 ? 'Genel Sohbet' : 'Sohbet Odaları',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    if (_chatSubTab == 1)
                      ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF191919),
                          foregroundColor: const Color(0xFFFF6B00),
                          elevation: 0,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 6,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        icon: const Icon(Icons.add_circle_outline, size: 18),
                        label: const Text(
                          'Oda Aç',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        onPressed: _showCreateRoomDialog,
                      ),
                  ],
                ),
                const SizedBox(height: 14),
                Row(
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
    return ListView.builder(
      controller: _publicChatScrollController,
      padding: const EdgeInsets.all(16),
      itemCount: _publicFeedMessages.length,
      itemBuilder: (context, index) {
        final msg = _publicFeedMessages[index];
        final senderName = msg['sender']?.toString() ?? '';
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
                  Text(
                    msg['time']!,
                    style: TextStyle(color: Colors.grey.shade500, fontSize: 11),
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
        _liveRooms.where((room) {
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
                        const SizedBox(width: 8),
                        Text(
                          '• ${_generalGlobalRoom['activeUsers']}',
                          style: const TextStyle(
                            fontSize: 11,
                            color: Colors.white70,
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
                        ..._publicFeedMessages
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
                        if (isProtected) {
                          _showPasswordPromptDialog(room);
                        } else {
                          _openRoomChat(room);
                        }
                      },
                      child: Text(
                        isProtected
                            ? 'Şifre ile odaya katıl'
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
    if (_roomsCreatedToday >= roomLimit) {
      _showProUpgradeModal();
      return;
    }

    final TextEditingController roomNameController = TextEditingController();
    final TextEditingController roomPassController = TextEditingController();
    bool requiresPassword = false;
    bool showPassword = false;

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
                  _isProUser
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
                  onPressed: () async {
                    if (roomNameController.text.trim().isEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Lütfen oda adını girin.'),
                        ),
                      );
                      return;
                    }

                    final position = _currentPosition;
                    if (position == null) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text(
                            'Odayı haritada göstermek için konumunuz gerekli.',
                          ),
                        ),
                      );
                      return;
                    }

                    final user = FirebaseAuth.instance.currentUser;
                    if (user == null) return;
                    final password = roomPassController.text.trim();
                    if (requiresPassword && password.length < 12) {
                      _showTrackingMessage(
                        'Oda şifresi en az 12 karakter olmalı.',
                      );
                      return;
                    }

                    final expiresAt = DateTime.now().add(_chatRoomLifetime);
                    try {
                      final roomReference = FirebaseFirestore.instance
                          .collection('chat_rooms')
                          .doc();
                      final listingReference = FirebaseFirestore.instance
                          .collection('chat_room_listings')
                          .doc(roomReference.id);
                      final salt = requiresPassword
                          ? navoraGenerateRoomPasswordSalt()
                          : '';
                      final passwordHash = requiresPassword
                          ? await navoraHashRoomPassword(password, salt)
                          : null;
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
                          roomReference.collection('private').doc('access'),
                          {
                            'password_hash': passwordHash,
                            'updated_at': FieldValue.serverTimestamp(),
                          },
                        );
                      }
                      batch.set(roomReference.collection('messages').doc(), {
                        'sender': _userName,
                        'sender_id': user.uid,
                        'text': 'Oda oluşturuldu, herkese merhaba!',
                        'time': 'Şimdi',
                        'created_at': FieldValue.serverTimestamp(),
                      });
                      await batch.commit();
                      if (mounted) {
                        setState(() {
                          _roomsCreatedToday++;
                          _dailyQuotaDate = _dailyQuotaKey(DateTime.now());
                        });
                      }
                    } catch (error) {
                      debugPrint('Sohbet odası oluşturulamadı: $error');
                      if (mounted) {
                        _showTrackingMessage(
                          'Oda oluşturulamadı. Tekrar deneyin.',
                        );
                      }
                      return;
                    }

                    unawaited(_persistDailyQuota());

                    if (!context.mounted) return;
                    Navigator.pop(context);
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Sohbet odası başarıyla açıldı!'),
                      ),
                    );
                  },
                  child: const Text(
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

    final canEnter = await _joinRoom(
      roomId,
      user.uid,
      passwordHash: passwordHash,
    );
    if (!canEnter || !mounted) {
      if (mounted) _showTrackingMessage('Şifre hatalı veya oda dolu.');
      return;
    }

    final ownerId = (room['ownerId'] ?? room['owner_id'])?.toString() ?? '';
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

  Future<bool> _joinRoom(
    String roomId,
    String userId, {
    String? passwordHash,
  }) async {
    try {
      final firestore = FirebaseFirestore.instance;
      final reference = firestore.collection('chat_rooms').doc(roomId);
      final listingReference = firestore
          .collection('chat_room_listings')
          .doc(roomId);
      final memberReference = reference.collection('members').doc(userId);
      var allowed = false;
      await firestore.runTransaction((transaction) async {
        final listingSnapshot = await transaction.get(listingReference);
        final memberSnapshot = await transaction.get(memberReference);
        if (!listingSnapshot.exists) return;
        if (memberSnapshot.exists) {
          allowed = true;
          return;
        }
        final listing = listingSnapshot.data()!;
        final isProtected = listing['is_protected'] == true;
        if (isProtected && (passwordHash == null || passwordHash.isEmpty)) {
          return;
        }
        final activeCount =
            (listing['active_users_count'] as num?)?.toInt() ?? 1;
        final maxUsers = (listing['max_users'] as num?)?.toInt() ?? 50;
        if (activeCount >= maxUsers) return;

        transaction.set(memberReference, {
          'password_hash': passwordHash ?? '',
          'joined_at': FieldValue.serverTimestamp(),
        });
        transaction.update(reference, {
          'member_ids': FieldValue.arrayUnion([userId]),
          'active_users_count': FieldValue.increment(1),
          'active_users': '${activeCount + 1} kişi',
          'updated_at': FieldValue.serverTimestamp(),
        });
        transaction.update(listingReference, {
          'active_users_count': FieldValue.increment(1),
          'active_users': '${activeCount + 1} kişi',
          'updated_at': FieldValue.serverTimestamp(),
        });
        allowed = true;
      });
      return allowed;
    } catch (error) {
      debugPrint('Odaya giriş başarısız: $error');
      if (mounted) _showTrackingMessage('Şifre hatalı veya oda dolu.');
      return false;
    }
  }

  Future<void> _deleteRoom(Map<String, dynamic> room) async {
    final user = FirebaseAuth.instance.currentUser;
    final roomId = room['id']?.toString();
    if (user == null || roomId == null || room['ownerId'] != user.uid) return;
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

  void _showPasswordPromptDialog(Map<String, dynamic> room) {
    final currentUser = FirebaseAuth.instance.currentUser;
    final ownerId = (room['ownerId'] ?? room['owner_id'])?.toString() ?? '';
    final isOwner = currentUser != null && ownerId == currentUser.uid;

    if (isOwner || room['isProtected'] != true) {
      _openRoomChat(room);
      return;
    }

    final TextEditingController passController = TextEditingController();
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: const Color(0xFF171717),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(22),
          side: const BorderSide(color: Color(0xFFFF8A3D), width: 1.2),
        ),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0xFF2A180D),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(
                Icons.lock_outline_rounded,
                color: Color(0xFFFF8A3D),
                size: 18,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                '${room['name']} (Şifreli)',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
              ),
            ),
          ],
        ),
        content: TextField(
          controller: passController,
          obscureText: true,
          style: const TextStyle(color: Colors.white, fontSize: 14),
          decoration: InputDecoration(
            labelText: 'Oda şifresini girin',
            labelStyle: const TextStyle(color: Color(0xFFBDBDBD)),
            hintStyle: const TextStyle(color: Color(0xFFBDBDBD)),
            filled: true,
            fillColor: const Color(0xFF1B1B1B),
            prefixIcon: const Icon(
              Icons.vpn_key_rounded,
              color: Color(0xFFFF8A3D),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide(color: const Color(0xFF2D2D2D)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide(color: const Color(0xFFFF8A3D)),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () =>
                Navigator.of(dialogContext, rootNavigator: true).pop(),
            child: const Text(
              'İptal',
              style: TextStyle(color: Color(0xFFBDBDBD)),
            ),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFFF6B00),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onPressed: () async {
              final enteredPassword = passController.text.trim();
              final salt = room['passwordSalt']?.toString() ?? '';
              if (enteredPassword.length < 12 || salt.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Oda şifresi geçersiz.')),
                );
                return;
              }
              Navigator.of(dialogContext, rootNavigator: true).pop();
              await _openRoomChat(
                room,
                passwordHash: await navoraHashRoomPassword(
                  enteredPassword,
                  salt,
                ),
              );
            },
            child: const Text(
              'Giriş Yap',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showAboutSupportSheet() {
    const supportEmail = 'destek@navora.app';

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF191919),
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
                  onPressed: () => Navigator.pop(context),
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
            const SizedBox(height: 18),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFF202020),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: const Color(0xFF333333)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.email_outlined, color: Color(0xFFFF6B00)),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Bize ulaşın',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                        SizedBox(height: 3),
                        Text(
                          supportEmail,
                          style: TextStyle(
                            color: Color(0xFFFF6B00),
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'E-posta adresini kopyala',
                    onPressed: () {
                      Clipboard.setData(
                        const ClipboardData(text: supportEmail),
                      );
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Destek e-posta adresi kopyalandı.'),
                        ),
                      );
                    },
                    icon: const Icon(Icons.copy_rounded, size: 20),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
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

    return SingleChildScrollView(
      padding: const EdgeInsets.only(top: 16, left: 16, right: 16, bottom: 100),
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
                          onTap: _showPhotoUploadDialog,
                          child: Stack(
                            children: [
                              Container(
                                padding: EdgeInsets.all(
                                  _hasProfileFrame ? 3 : 0,
                                ),
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  gradient: _hasProfileFrame
                                      ? const LinearGradient(
                                          colors: [
                                            Color(0xFFFFD166),
                                            Color(0xFFFFA000),
                                          ],
                                        )
                                      : null,
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
                                child: const CircleAvatar(
                                  radius: 40,
                                  backgroundColor: Color(0xFFEAF3FF),
                                  child: Icon(
                                    Icons.person,
                                    size: 52,
                                    color: Color(0xFFFF6B00),
                                  ),
                                ),
                              ),
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
                                  child: const Icon(
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
                                _userPhone,
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 12,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 6,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF1F120C)
                                      .withValues(alpha: 0.55),
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(
                                    color: Colors.white.withValues(alpha: 0.14),
                                  ),
                                ),
                                child: Text(
                                  _userBio,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.9),
                                    fontSize: 11,
                                    fontStyle: FontStyle.italic,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
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
                          Container(
                            height: 28,
                            width: 1,
                            color: Colors.white30,
                          ),
                          Expanded(
                            child: _buildProfileStat(
                              formatNavoraPoints(_navoraPoints),
                              'Puan',
                              onTap: _showNavoraPointsSheet,
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

          const SizedBox(height: 20),

          const Text(
            'Bu Ayki Sürüş Analizleri',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w800,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 10),
          if (_monthlyDrivingAnalytics == null)
            _buildEmptyAnalyticsCard()
          else
            _buildMonthlyAnalyticsCard(),

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
          _buildProfileMenuItem(
            icon: Icons.add_home_work_rounded,
            title: 'İlan ver',
            subtitle: 'Kiralık veya satılık konutunu paylaş',
            onTap: () => unawaited(_showCreatePropertyListingSheet()),
          ),
          _buildProfileMenuItem(
            icon: Icons.stars_rounded,
            title: 'Navora Puan & Takas',
            subtitle:
                '${formatNavoraPoints(_navoraPoints)} puan • ${NavoraRank.current(_navoraPoints).name}',
            onTap: _showNavoraPointsSheet,
          ),
          _buildProfileMenuItem(
            icon: Icons.bookmark_added_rounded,
            title: 'Kayıtlı Adreslerim',
            subtitle: '${_savedAddresses.length} kayıtlı konum (Ev, İş vb.)',
            onTap: _showSavedAddressesDialog,
          ),
          _buildProfileMenuItem(
            icon: Icons.history_rounded,
            title: 'Geçmiş Rotalar & Sürüşler',
            subtitle: 'Önceki seyahatleriniz ve skorlarınız',
            onTap: _showDrivingHistoryDialog,
          ),
          _buildProfileMenuItem(
            icon: Icons.sos_rounded,
            title: 'Acil Durum (SOS) Kişileri',
            subtitle: '${_sosContacts.length} güvenli kişi tanımlı',
            onTap: _showSosContactsDialog,
          ),
          _buildProfileMenuItem(
            icon: Icons.support_agent_rounded,
            title: 'Hakkımızda & Destek',
            subtitle: 'Sorularınız ve önerileriniz için bize ulaşın',
            onTap: _showAboutSupportSheet,
          ),

          const SizedBox(height: 18),

          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Keşif Rozeti & Başarımlar',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                ),
              ),
              TextButton(
                onPressed: _showAllBadgesSheet,
                child: const Text(
                  'Tümünü Gör (9)',
                  style: TextStyle(fontSize: 12, color: Color(0xFFFFA15C)),
                ),
              ),
            ],
          ),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF111111),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: const Color(0xFF2A2A2A)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.18),
                  blurRadius: 12,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: SizedBox(
              height: 108,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  _buildBadgeItem(
                    Icons.explore,
                    'Şehir Kaşifi',
                    '10+ Şehir',
                    Colors.amber,
                  ),
                  _buildBadgeItem(
                    Icons.nightlight_round,
                    'Gece Sürücüsü',
                    '50 Gece Gezisi',
                    Colors.deepOrange,
                  ),
                  _buildBadgeItem(
                    Icons.ev_station,
                    'Çevre Dostu',
                    'E-Şarj Kullanıcısı',
                    Colors.green,
                  ),
                  _buildBadgeItem(
                    Icons.verified_user,
                    'Topluluk Lideri',
                    '20 Bildirim',
                    const Color(0xFFFF6B00),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 20),

          _buildPremiumPlanBanner(),

          const SizedBox(height: 18),

          _buildVehicleSelectionCard(),

          const SizedBox(height: 18),

          if (!isGuest)
            _buildProfileMenuItem(
              icon: Icons.delete_forever_rounded,
              title: _isDeletingAccount ? 'Hesap siliniyor...' : 'Hesabımı sil',
              subtitle: 'Hesabını ve ilişkili verileri kalıcı olarak sil',
              isDangerous: true,
              onTap: _isDeletingAccount ? () {} : _deleteAccount,
            ),

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
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF191919),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) => Container(
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
                        onPressed: () async {
                          final address = await _showAddAddressDialog();
                          if (address == null || !mounted) return;
                          final user = FirebaseAuth.instance.currentUser;
                          if (user != null) {
                            final document = await FirebaseFirestore.instance
                                .collection('users')
                                .doc(user.uid)
                                .collection('saved_addresses')
                                .add(address);
                            address['id'] = document.id;
                          }
                          setState(() => _savedAddresses.add(address));
                          setModalState(() {});
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
                child: ListView.builder(
                  itemCount: _savedAddresses.length,
                  itemBuilder: (context, index) {
                    final addr = _savedAddresses[index];
                    IconData iconData = Icons.location_on;
                    if (addr['type'] == 'home') iconData = Icons.home;
                    if (addr['type'] == 'work') iconData = Icons.work;
                    if (addr['type'] == 'favorite') iconData = Icons.star;

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
                          child: Icon(iconData, color: const Color(0xFFFFB066)),
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
                                final user = FirebaseAuth.instance.currentUser;
                                final addressId = addr['id'];
                                if (user != null && addressId != null) {
                                  await FirebaseFirestore.instance
                                      .collection('users')
                                      .doc(user.uid)
                                      .collection('saved_addresses')
                                      .doc(addressId)
                                      .delete();
                                }
                                setState(() {
                                  _savedAddresses.removeAt(index);
                                });
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
        ),
      ),
    );
  }

  void _showDrivingHistoryDialog() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF191919),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) => Container(
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
                  Icon(Icons.info_outline, size: 18, color: Color(0xFFFFB066)),
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
              child: ListView.builder(
                itemCount: _drivingHistory.length,
                itemBuilder: (context, index) {
                  final h = _drivingHistory[index];
                  return Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1A1A1A),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: const Color(0xFFFF8A3D).withValues(alpha: 0.3),
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
                      onTap: () => _showHistoryDetails(h),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            children: [
                              const Icon(
                                Icons.alt_route,
                                color: Color(0xFFFF8A3D),
                              ),
                              const SizedBox(width: 12),
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    h['route']!,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 13,
                                      color: Colors.white,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    '${h['date']} • ${h['duration']} • ${h['km']}',
                                    style: const TextStyle(
                                      fontSize: 11,
                                      color: Colors.white70,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFFFF8A3D)
                                  .withValues(alpha: 0.14),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: const Color(0xFFFF8A3D)
                                    .withValues(alpha: 0.5),
                              ),
                            ),
                            child: Text(
                              '${h['score']} Puan',
                              style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: Color(0xFFFFB066),
                              ),
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
              _buildHistoryDetailRow(
                Icons.verified,
                'Sürüş skoru',
                '${history['score'] ?? '-'} puan',
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
  }) async {
    final titleController = TextEditingController(text: initialTitle);
    final addressController = TextEditingController(text: initialAddress);
    String selectedType = 'favorite';

    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: const Color(0xFF171717),
          title: const Text(
            'Yeni Adres Ekle',
            style: TextStyle(color: Colors.white),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: titleController,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  labelText: 'Adres adı',
                  hintText: 'Ev, İş veya Favori',
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
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: addressController,
                maxLines: 2,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  labelText: 'Adres',
                  hintText: 'Adres bilgisini yazın',
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
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: selectedType,
                dropdownColor: const Color(0xFF242424),
                style: const TextStyle(color: Colors.white),
                iconEnabledColor: const Color(0xFFFF7A00),
                decoration: InputDecoration(
                  labelText: 'Adres türü',
                  labelStyle: const TextStyle(color: Color(0xFFBDBDBD)),
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
                ),
                items: const [
                  DropdownMenuItem(
                    value: 'home',
                    child: Text('Ev', style: TextStyle(color: Colors.white)),
                  ),
                  DropdownMenuItem(
                    value: 'work',
                    child: Text('İş', style: TextStyle(color: Colors.white)),
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
                  if (value != null) setDialogState(() => selectedType = value);
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text(
                'Vazgeç',
                style: TextStyle(color: Colors.white70),
              ),
            ),
            FilledButton(
              onPressed: () {
                final title = titleController.text.trim();
                final address = addressController.text.trim();
                if (title.isEmpty || address.isEmpty) return;
                Navigator.pop(context, {
                  'title': title,
                  'address': address,
                  'type': selectedType,
                });
              },
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFFF7A00),
                foregroundColor: Colors.white,
              ),
              child: const Text('Kaydet'),
            ),
          ],
        ),
      ),
    );

    return result;
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
  }) async {
    if (startCoordinate == null || destinationCoordinate == null) return null;

    try {
      final straightDistance =
          geo.Geolocator.distanceBetween(
            startCoordinate.latitude,
            startCoordinate.longitude,
            destinationCoordinate.latitude,
            destinationCoordinate.longitude,
          ) /
          1000;
      final estimatedDistance = straightDistance * 1.2;
      final estimatedMinutes = (estimatedDistance / 38 * 60).ceil().clamp(
        1,
        999,
      );

      _activeRouteStart = startCoordinate;
      _activeRouteDestination = destinationCoordinate;
      return {
        'distance_km': estimatedDistance.toStringAsFixed(1),
        'duration_minutes': '$estimatedMinutes',
      };
    } catch (error) {
      debugPrint('Rota hesaplanamadı: $error');
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

  Future<void> _showRouteCreatorSheet() async {
    final initialStart = _routeDraftStart;
    final initialDestination = _routeDraftDestination;
    _routeTitleController.clear();
    if (initialStart == null) _routeStartController.clear();
    if (initialDestination == null) _routeDestinationController.clear();
    _routeDistanceController.clear();

    Map<String, String>? calculatedRoute;
    bool isCalculating = false;
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
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: () {
                    final title = _routeTitleController.text.trim();
                    final start = _routeStartController.text.trim();
                    final destination = _routeDestinationController.text.trim();
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
                      'duration_minutes': calculatedRoute!['duration_minutes']!,
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
                'Mesafe ve süre yaklaşık olarak hesaplanır. Rota çizgisi haritada gösterilir.',
                style: const TextStyle(fontSize: 11, color: Colors.white70),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );

    if (route == null || !mounted) return;
    setState(() {
      _savedRoutes.insert(0, route);
      _routeDraftStart = null;
      _routeDraftDestination = null;
      _routeSelectionTarget = null;
      if (_activeRouteStart != null && _activeRouteDestination != null) {
        _routePolylines = [
          Polyline(
            polylineId: const PolylineId('saved-route'),
            points: [_activeRouteStart!, _activeRouteDestination!],
            color: const Color(0xFFFF6B00),
            width: 6,
          ),
        ];
      }
    });
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      final document = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .collection('saved_routes')
          .add({...route, 'created_at': FieldValue.serverTimestamp()});
      route['id'] = document.id;
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Rota kaydedildi: ${route['distance_km']} km • ${route['duration_minutes']} dk',
        ),
      ),
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

  Future<void> _startSavedRoute(Map<String, dynamic> route) async {
    final destinationText = route['destination']?.toString().trim();
    if (destinationText == null || destinationText.isEmpty) return;

    try {
      final locations = await geo_coding.locationFromAddress(destinationText);
      if (locations.isEmpty || !mounted) {
        _showTrackingMessage('Kayıtlı rotanın varış konumu bulunamadı.');
        return;
      }
      final location = locations.first;
      setState(() {
        _selectedIndex = 1;
        _searchController.text = destinationText;
        _selectedDestinationName =
            route['title']?.toString().trim().isNotEmpty == true
            ? route['title'].toString()
            : destinationText;
        _selectedPlaceDetails = null;
        _selectedDestinationCoordinate = LatLng(
          location.latitude,
          location.longitude,
        );
      });
      await _showDirectionsSheet();
    } catch (error) {
      debugPrint('Kayıtlı rota başlatılamadı: $error');
      _showTrackingMessage('Kayıtlı rota başlatılamadı.');
    }
  }

  Future<void> _deleteSavedRoute(Map<String, String> route) async {
    final user = FirebaseAuth.instance.currentUser;
    final routeId = route['id'];
    if (user != null && routeId != null && routeId.isNotEmpty) {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .collection('saved_routes')
          .doc(routeId)
          .delete();
    }
    if (!mounted) return;
    setState(() => _savedRoutes.remove(route));
    _showTrackingMessage('Kayıtlı rota silindi.');
  }

  Future<void> _shareSavedRoute(Map<String, String> route) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      _showTrackingMessage('Rota paylaşmak için hesabına giriş yap.');
      return;
    }
    try {
      final title = route['title']?.trim().isNotEmpty == true
          ? route['title']!.trim()
          : 'Paylaşılan rota';
      final start = route['start']?.trim();
      final destination = route['destination']?.trim();
      final shareText = [
        title,
        if (start != null && start.isNotEmpty) 'Başlangıç: $start',
        if (destination != null && destination.isNotEmpty) 'Varış: $destination',
      ].join('\n');
      await SharePlus.instance.share(
        ShareParams(text: shareText),
      );
    } catch (_) {
      if (mounted) _showTrackingMessage('Rota bağlantısı oluşturulamadı.');
    }
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
                              await _startSavedRoute(route);
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
                              '${route['start']}  →  ${route['destination']} • ${route['distance_km'] ?? '?'} km',
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
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
                                  tooltip: 'Rotayı paylaş',
                                  icon: const Icon(Icons.share_outlined),
                                  onPressed: () =>
                                      unawaited(_shareSavedRoute(route)),
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

  Future<void> _toggleDriveTracking() async {
    try {
      if (_isDriveTracking) {
        await _stopDriveTracking();
        return;
      }

      if (!await _ensureLocationPermission()) return;

      final position = await geo.Geolocator.getCurrentPosition(
        locationSettings: const geo.LocationSettings(
          accuracy: geo.LocationAccuracy.medium,
        ),
      );
      _lastDrivePosition = position;
      _currentPosition = position;
      _driveStartedAt = DateTime.now();
      _driveDistanceKm = 0;
      _vehicleStartKm = _parseVehicleKm();
      _previousSpeedKmh = null;
      _driveScore = 100;
      _positionSubscription = geo.Geolocator.getPositionStream(
        locationSettings: const geo.LocationSettings(
          accuracy: geo.LocationAccuracy.high,
          distanceFilter: 10,
        ),
      ).listen(_handleDrivePosition);
      _accelerometerSubscription = sensors
          .accelerometerEventStream(
            samplingPeriod: sensors.SensorInterval.normalInterval,
          )
          .listen(_handleAccelerometer);
      if (!mounted) return;
      setState(() {
        _isDriveTracking = true;
      });
      await _centerOnPosition(position);
    } catch (_) {
      await _positionSubscription?.cancel();
      _positionSubscription = null;
      if (mounted) {
        setState(() => _isDriveTracking = false);
        _showTrackingMessage(
          'GPS başlatılamadı. Konum izni ve cihaz ayarlarını kontrol edin.',
        );
      }
    }
  }

  Future<void> _loadLocationPermissionState() async {
    final permission = await geo.Geolocator.checkPermission();
    if (!mounted) return;
    if (permission == geo.LocationPermission.always ||
        permission == geo.LocationPermission.whileInUse) {
      setState(() => _locationPermissionGranted = true);
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

  void _handleDrivePosition(geo.Position position) {
    final previousPosition = _lastDrivePosition;
    if (previousPosition != null) {
      final deltaKm = navoraSafeDistanceKm(previousPosition, position);
      if (deltaKm > 0) {
        _driveDistanceKm += deltaKm;
      }
    }

    final speedKmh = position.speed < 0 ? 0.0 : position.speed * 3.6;
    final sanitizedSpeedKmh = speedKmh.isNaN || speedKmh.isInfinite
        ? 0.0
        : speedKmh;
    if (sanitizedSpeedKmh > 2) {
      final penalty = navoraDriveScorePenalty(
        speedKmh: sanitizedSpeedKmh,
        previousSpeedKmh: _previousSpeedKmh,
      );
      if (penalty > 0) {
        _driveScore = (_driveScore - penalty).clamp(0, 100);
      }
      _previousSpeedKmh = sanitizedSpeedKmh;
    }
    _announceUpcomingNavigationStep(position);
    _lastDrivePosition = position;
    if (!mounted) return;
    setState(() {
      _currentPosition = position;
      _vehicleKm = _formatVehicleKm(_vehicleStartKm + _driveDistanceKm);
      _refreshLiveRoomDistances();
    });
    if (navoraShouldFollowCurrentPosition(
      isNavigationActive: _isNavigationActive,
      isDriveTracking: _isDriveTracking,
      isFollowing: _isFollowingCurrentPosition,
    )) {
      Future.microtask(() => _centerOnPosition(position));
    }
    _updateCurrentAddress(position);
    _refreshNavigationRouteIfNeeded(position);
  }

  Future<void> _stopDriveTracking() async {
    await _positionSubscription?.cancel();
    _positionSubscription = null;
    await _accelerometerSubscription?.cancel();
    _accelerometerSubscription = null;
    final startedAt = _driveStartedAt;
    final durationSeconds = startedAt == null
        ? 0
        : DateTime.now().difference(startedAt).inSeconds;
    final distance = double.parse(_driveDistanceKm.toStringAsFixed(2));
    final averageSpeed = navoraAverageSpeedKmh(
      distanceKm: distance,
      durationSeconds: durationSeconds,
    );
    final durationMinutes = startedAt == null
        ? 0
        : DateTime.now().difference(startedAt).inMinutes;

    if (FirebaseAuth.instance.currentUser != null && distance > 0) {
      await _saveCompletedDrive(
        distance: distance,
        durationMinutes: durationMinutes,
        averageSpeed: averageSpeed,
        score: _driveScore,
      );
    }

    if (!mounted) return;
    setState(() {
      _isDriveTracking = false;
      _clearRouteState();
      _vehicleKm = _formatVehicleKm(_vehicleStartKm + distance);
    });
    unawaited(_persistVehicleProfile());
    await _tts.stop();
    _showTrackingMessage(
      '${distance.toStringAsFixed(2)} km sürüş tamamlandı. Skor: $_driveScore/100',
    );
  }

  void _announceUpcomingNavigationStep(geo.Position position) {
    if (!_isNavigationActive ||
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
    if (_navigationStepIndex < _navigationSteps.length) {
      final nextVoice =
          _navigationSteps[_navigationStepIndex]['voice'] as String;
      _speakNavigation(nextVoice);
    }
    if (mounted) setState(() {});
  }

  void _handleAccelerometer(sensors.AccelerometerEvent event) {
    final recentlyAlerted =
        _lastCrashAlertAt != null &&
        DateTime.now().difference(_lastCrashAlertAt!) <
            const Duration(seconds: 30);
    if (!_isDriveTracking || recentlyAlerted) return;

    final acceleration = math.sqrt(
      event.x * event.x + event.y * event.y + event.z * event.z,
    );
    if (acceleration < 28) return;

    _lastCrashAlertAt = DateTime.now();
    _showCrashConfirmation();
  }

  Future<void> _showCrashConfirmation() async {
    if (!mounted) return;
    final shouldSend = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        Future.delayed(const Duration(seconds: 10), () {
          if (dialogContext.mounted) Navigator.pop(dialogContext, true);
        });
        return AlertDialog(
          title: const Text('Kaza algılandı'),
          content: const Text(
            'Sert bir darbe algılandı. 10 saniye içinde iptal etmezseniz SOS uyarısı gönderilecek.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Yanlış alarm'),
            ),
          ],
        );
      },
    );
    if (shouldSend == true) await _sendSosAlert();
  }

  Future<void> _sendSosAlert() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || _sosContacts.isEmpty) {
      _showTrackingMessage('SOS kişisi bulunamadı. Önce bir kişi ekleyin.');
      return;
    }

    try {
      final position =
          _currentPosition ?? await geo.Geolocator.getCurrentPosition();
      final locationUrl =
          'https://maps.google.com/?q=${position.latitude},${position.longitude}';
      await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .collection('sos_alerts')
          .add({
            'type': 'possible_accident',
            'message':
                'Olası kaza algılandı. Lütfen kullanıcıyla iletişime geçin.',
            'latitude': position.latitude,
            'longitude': position.longitude,
            'location_url': locationUrl,
            'contacts': _sosContacts
                .map(
                  (contact) => {
                    'name': contact['name'],
                    'phone': contact['phone'],
                    'relation': contact['relation'],
                  },
                )
                .toList(),
            'created_at': FieldValue.serverTimestamp(),
          });
      _showTrackingMessage('SOS uyarısı konum bilgisiyle kaydedildi.');
      await _messageSosContact(_sosContacts.first);
    } catch (_) {
      _showTrackingMessage('SOS uyarısı gönderilemedi. Konum alınamadı.');
    }
  }

  Future<void> _callSosContact(Map<String, String> contact) async {
    final phone = contact['phone']?.trim();
    if (phone == null || phone.isEmpty) return;
    final uri = Uri(scheme: 'tel', path: phone);
    if (!await launchUrl(uri)) {
      _showTrackingMessage('Arama ekranı açılamadı.');
    }
  }

  Future<void> _messageSosContact(Map<String, String> contact) async {
    final phone = contact['phone']?.trim();
    if (phone == null || phone.isEmpty) return;
    final position = _currentPosition;
    final location = position == null
        ? ''
        : '\nKonum: https://maps.google.com/?q=${position.latitude},${position.longitude}';
    final uri = Uri(
      scheme: 'sms',
      path: phone,
      queryParameters: {
        'body':
            'Navora acil durum bildirimi. Lütfen beni kontrol edin.$location',
      },
    );
    if (!await launchUrl(uri)) {
      _showTrackingMessage('Mesaj ekranı açılamadı.');
    }
  }

  Future<void> _saveCompletedDrive({
    required double distance,
    required int durationMinutes,
    required double averageSpeed,
    required int score,
  }) async {
    final user = FirebaseAuth.instance.currentUser!;
    final userReference = FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid);
    final analytics = <String, dynamic>{};

    await FirebaseFirestore.instance.runTransaction((transaction) async {
      final snapshot = await transaction.get(userReference);
      final data = snapshot.data() ?? <String, dynamic>{};
      final oldAnalytics = data['monthly_driving_analytics'];
      if (oldAnalytics is Map) {
        analytics.addAll(Map<String, dynamic>.from(oldAnalytics));
      }
      final oldDistance =
          (analytics['total_distance_km'] as num?)?.toDouble() ?? 0;
      analytics['total_distance_km'] = oldDistance + distance;
      analytics['average_speed_kmh'] = averageSpeed;
      analytics['driving_score'] = score;
      analytics['saved_co2_kg'] =
          ((analytics['saved_co2_kg'] as num?)?.toDouble() ?? 0) +
          distance * 0.12;
      transaction.set(userReference, {
        'monthly_driving_analytics': analytics,
        'updated_at': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    });

    await userReference.collection('driving_history').add({
      'route': 'GPS sürüşü',
      'date': DateTime.now().toIso8601String(),
      'duration_minutes': durationMinutes,
      'distance_km': distance,
      'average_speed_kmh': averageSpeed,
      'score': score,
      'completed_at': FieldValue.serverTimestamp(),
      'expires_at': Timestamp.fromDate(
        DateTime.now().add(const Duration(days: 30)),
      ),
    });
    if (_activeNavigationDestination != null) {
      await userReference.collection('route_history').add({
        'title': _activeNavigationTitle ?? 'Tamamlanan rota',
        'destination': _activeNavigationDestination,
        'distance_km': distance,
        'duration_minutes': durationMinutes,
        'score': score,
        'completed_at': FieldValue.serverTimestamp(),
        'expires_at': Timestamp.fromDate(
          DateTime.now().add(const Duration(days: 30)),
        ),
      });
    }
    if (!mounted) return;
    final previousAnalytics = _monthlyDrivingAnalytics;
    final previousCount = _monthlyDriveCount;
    final previousDistance =
        (previousAnalytics?['total_distance_km'] as num?)?.toDouble() ?? 0;
    final previousAverageSpeed =
        (previousAnalytics?['average_speed_kmh'] as num?)?.toDouble() ?? 0;
    final previousScore =
        (previousAnalytics?['driving_score'] as num?)?.toDouble() ?? 0;
    final driveCount = previousCount + 1;
    final totalDistance = previousDistance + distance;
    setState(() {
      _monthlyDriveCount = driveCount;
      _monthlyDrivingAnalytics = {
        'total_distance_km': totalDistance,
        'average_speed_kmh':
            ((previousAverageSpeed * previousCount) + averageSpeed) /
            driveCount,
        'driving_score': ((previousScore * previousCount) + score) / driveCount,
        'saved_co2_kg': totalDistance * 0.12,
      };
    });
  }

  Future<void> _centerOnPosition(geo.Position position) async {
    final controller = _mapController;
    if (controller == null) return;

    if (_isNavigationActive) {
      if (position.heading.isFinite &&
          position.heading >= 0 &&
          position.heading < 360 &&
          position.speed >= 0.8) {
        _navigationBearing = _hasNavigationBearing
            ? navoraSmoothBearing(_navigationBearing, position.heading)
            : position.heading;
        _hasNavigationBearing = true;
      }
      final currentPosition = LatLng(position.latitude, position.longitude);
      final lookAheadMeters = (position.speed * 3).clamp(45.0, 110.0);
      final cameraTarget = navoraOffsetCameraTarget(
        currentPosition,
        _navigationBearing,
        lookAheadMeters,
      );
      _isProgrammaticCameraMove = true;
      try {
        await controller.animateCamera(
          CameraUpdate.newCameraPosition(
            CameraPosition(
              target: cameraTarget,
              zoom: 17,
              bearing: _navigationBearing,
              tilt: _isMapTilted ? 48 : 0,
            ),
          ),
        );
      } finally {
        _isProgrammaticCameraMove = false;
      }
      return;
    }

    _isProgrammaticCameraMove = true;
    try {
      await _moveMapTo(LatLng(position.latitude, position.longitude), 16);
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
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        action: actionLabel != null && onAction != null
            ? SnackBarAction(label: actionLabel, onPressed: onAction)
            : null,
      ),
    );
  }

  void _showSosContactsDialog() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF191919),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) => Container(
          padding: const EdgeInsets.all(20),
          height: MediaQuery.of(context).size.height * 0.55,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Acil Durum (SOS) Kişileri',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                  Row(
                    children: [
                      IconButton(
                        tooltip: 'Kişi ekle',
                        icon: const Icon(
                          Icons.person_add_alt_1,
                          color: Color(0xFFFFB066),
                        ),
                        onPressed: () async {
                          final contact = await _showAddSosContactDialog();
                          if (contact == null || !mounted) return;
                          final user = FirebaseAuth.instance.currentUser;
                          if (user != null) {
                            final document = await FirebaseFirestore.instance
                                .collection('users')
                                .doc(user.uid)
                                .collection('sos_contacts')
                                .add(contact);
                            contact['id'] = document.id;
                          }
                          setState(() => _sosContacts.add(contact));
                          setModalState(() {});
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
              const SizedBox(height: 6),
              const Text(
                'Kaza veya acil durumlarda otomatik bilgilendirilecek kişiler.',
                style: TextStyle(fontSize: 12, color: Colors.white70),
              ),
              const SizedBox(height: 14),
              Expanded(
                child: ListView.builder(
                  itemCount: _sosContacts.length,
                  itemBuilder: (context, index) {
                    final sos = _sosContacts[index];
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
                        leading: const CircleAvatar(
                          backgroundColor: Color(0xFFFF8A3D),
                          child: Icon(
                            Icons.phone_in_talk,
                            color: Colors.white,
                            size: 20,
                          ),
                        ),
                        title: Text(
                          sos['name']!,
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                            color: Colors.white,
                          ),
                        ),
                        subtitle: Text(
                          '${sos['phone']} • ${sos['relation']}',
                          style: const TextStyle(
                            fontSize: 11,
                            color: Colors.white70,
                          ),
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: 'Ara',
                              icon: const Icon(
                                Icons.call,
                                color: Color(0xFFFFB066),
                              ),
                              onPressed: () => _callSosContact(sos),
                            ),
                            IconButton(
                              tooltip: 'Mesaj hazırla',
                              icon: const Icon(
                                Icons.sms_outlined,
                                color: Color(0xFFFF8A3D),
                              ),
                              onPressed: () => _messageSosContact(sos),
                            ),
                            IconButton(
                              tooltip: 'Kişiyi sil',
                              icon: const Icon(
                                Icons.delete_outline,
                                color: Colors.redAccent,
                              ),
                              onPressed: () async {
                                final user = FirebaseAuth.instance.currentUser;
                                final contactId = sos['id'];
                                if (user != null && contactId != null) {
                                  await FirebaseFirestore.instance
                                      .collection('users')
                                      .doc(user.uid)
                                      .collection('sos_contacts')
                                      .doc(contactId)
                                      .delete();
                                }
                                setState(() => _sosContacts.removeAt(index));
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
        ),
      ),
    );
  }

  Future<Map<String, String>?> _showAddSosContactDialog() async {
    final nameController = TextEditingController();
    final phoneController = TextEditingController();
    final relationController = TextEditingController();

    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('SOS kişisi ekle'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration: const InputDecoration(labelText: 'Ad Soyad'),
            ),
            TextField(
              controller: phoneController,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(labelText: 'Telefon'),
            ),
            TextField(
              controller: relationController,
              decoration: const InputDecoration(labelText: 'Yakınlık'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Vazgeç'),
          ),
          FilledButton(
            onPressed: () {
              final name = nameController.text.trim();
              final phone = phoneController.text.trim();
              if (name.isEmpty || phone.isEmpty) return;
              Navigator.pop(context, {
                'name': name,
                'phone': phone,
                'relation': relationController.text.trim().isEmpty
                    ? 'Yakın kişi'
                    : relationController.text.trim(),
              });
            },
            child: const Text('Kaydet'),
          ),
        ],
      ),
    );

    return result;
  }

  void _showPhotoUploadDialog() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF191919),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) => Container(
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
                'Kamera ile Çek',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              onTap: () {
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Kamera açılıyor...')),
                );
              },
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
                'Galeriden Seç',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              onTap: () {
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Galeri açılıyor...')),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showEditProfileDialog() {
    final nameController = TextEditingController(text: _userName);
    final emailController = TextEditingController(text: _userEmail);
    final phoneController = TextEditingController(text: _userPhone);
    final bioController = TextEditingController(text: _userBio);
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
              const SizedBox(height: 14),
              TextField(
                controller: bioController,
                maxLines: 3,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  labelText: 'Hakkımda / Biyografi',
                  labelStyle: const TextStyle(color: Color(0xFFFFB066)),
                  prefixIcon: const Icon(
                    Icons.info_outline,
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
                    final messenger = ScaffoldMessenger.maybeOf(context);

                    if (name.isEmpty) {
                      if (!mounted) return;
                      messenger?.showSnackBar(
                        const SnackBar(
                          content: Text('Ad Soyad alanı boş bırakılamaz.'),
                        ),
                      );
                      return;
                    }

                    if (email.isEmpty || !email.contains('@')) {
                      if (!mounted) return;
                      messenger?.showSnackBar(
                        const SnackBar(
                          content: Text('Geçerli bir e-posta adresi girin.'),
                        ),
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
                      if (user != null && user.email != email) {
                        await user.verifyBeforeUpdateEmail(email);
                      }
                      await user?.updateDisplayName(name);
                      if (user != null) {
                        await FirebaseFirestore.instance
                            .collection('users')
                            .doc(user.uid)
                            .set({
                              'display_name': name,
                              'email': email,
                              'photo_url': user.photoURL,
                              'phone': phoneController.text.trim(),
                              'bio': bioController.text.trim(),
                              'gender_preference': selectedGender,
                              'updated_at': FieldValue.serverTimestamp(),
                            }, SetOptions(merge: true));
                      }

                      if (!mounted) return;
                      setState(() {
                        _userName = name;
                        _userEmail = email;
                        _userPhone = phoneController.text.trim();
                        _userBio = bioController.text.trim();
                        _userGender = selectedGender;
                      });

                      if (!mounted) return;
                      messenger?.showSnackBar(
                        const SnackBar(
                          content: Text('Profil bilgileri güncellendi!'),
                        ),
                      );
                    } catch (_) {
                      if (!mounted) return;
                      messenger?.showSnackBar(
                        const SnackBar(
                          content: Text(
                            'Profil kaydedilemedi. Lütfen tekrar deneyin.',
                          ),
                        ),
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
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _persistVehicleProfile() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    await FirebaseFirestore.instance.collection('users').doc(user.uid).set({
      'selected_vehicle': _selectedVehicle,
      'vehicle_brand_model': _vehicleBrandModel,
      'vehicle_km': _vehicleKm,
      'updated_at': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Widget _buildEmptyAnalyticsCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 22, horizontal: 18),
      decoration: BoxDecoration(
        color: const Color(0xFF111111),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: const Color(0xFF2A2A2A)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.15),
            blurRadius: 12,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: const Text(
        'Henüz sürüş analizi bulunmuyor.',
        textAlign: TextAlign.center,
        style: TextStyle(
          color: Colors.white70,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _buildMonthlyAnalyticsCard() {
    final analytics = _monthlyDrivingAnalytics!;
    String value(String key, String suffix) {
      final rawValue = analytics[key];
      if (rawValue is num) {
        return '${rawValue % 1 == 0 ? rawValue.toInt() : rawValue.toStringAsFixed(1)}$suffix';
      }
      return '-';
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF111111),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: const Color(0xFF2A2A2A)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.15),
            blurRadius: 12,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Row(
        children: [
          Expanded(
            child: _buildAnalyticsItem(
              Icons.verified,
              value('driving_score', ' / 100'),
              'Sürüş Skoru',
              Colors.green,
            ),
          ),
          Container(height: 35, width: 1, color: Colors.grey.shade200),
          Expanded(
            child: _buildAnalyticsItem(
              Icons.speed_rounded,
              value('average_speed_kmh', ' km/h'),
              'Ort. Hız',
              Colors.orange,
            ),
          ),
          Container(height: 35, width: 1, color: Colors.grey.shade200),
          Expanded(
            child: _buildAnalyticsItem(
              Icons.eco,
              value('saved_co2_kg', ' kg'),
              'Tasarruf',
              Colors.teal,
            ),
          ),
          Container(height: 35, width: 1, color: Colors.grey.shade200),
          Expanded(
            child: _buildAnalyticsItem(
              Icons.route,
              value('total_distance_km', ' km'),
              'Toplam Yol',
              const Color(0xFFFF6B00),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAnalyticsItem(
    IconData icon,
    String value,
    String label,
    Color color,
  ) {
    return Column(
      children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 12,
            color: Colors.white,
          ),
          textAlign: TextAlign.center,
        ),
        Text(
          label,
          style: TextStyle(color: Colors.white70, fontSize: 10),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  Widget _buildBadgeItem(
    IconData icon,
    String title,
    String subtitle,
    Color color,
  ) {
    return Container(
      width: 110,
      margin: const EdgeInsets.only(right: 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF111111),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFF2A2A2A)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.15),
            blurRadius: 8,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          CircleAvatar(
            radius: 18,
            backgroundColor: color.withValues(alpha: 0.18),
            child: Icon(icon, color: color, size: 20),
          ),
          const SizedBox(height: 6),
          Text(
            title,
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 11,
              color: Colors.white,
            ),
            overflow: TextOverflow.ellipsis,
          ),
          Text(
            subtitle,
            style: TextStyle(color: Colors.white70, fontSize: 9),
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  Widget _buildVehicleSelectionCard() {
    final currentVehicle = _vehicleDisplayName(_selectedVehicle);
    final isWalkingVehicle = _selectedVehicle == 'Yürüyüş';
    final vehicleMetricLabel = switch (_selectedVehicle) {
      'Motosiklet' => 'Motor KM',
      'Bisiklet' => 'Bisiklet KM',
      'Araba' => 'Araba KM',
      _ => '',
    };

    return GestureDetector(
      onTap: () async {
        final selectedVehicle = await _showVehiclePicker();
        if (selectedVehicle != null && mounted) {
          setState(() {});
        }
      },
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFF111111),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: const Color(0xFF2A2A2A)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.18),
              blurRadius: 12,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: const Color(0xFFFF6B00).withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Icon(
                _vehicleIcon(_selectedVehicle),
                color: const Color(0xFFFF6B00),
                size: 27,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  currentVehicle,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
            if (!isWalkingVehicle) ...[
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    vehicleMetricLabel,
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    '$_vehicleKm km',
                    style: const TextStyle(
                      color: Color(0xFFFFB066),
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _loadVehicleMarkerIcons() async {
    final markerIcons = <String, BitmapDescriptor>{};
    final vehicleMap = <String, IconData>{
      'Araba': Icons.directions_car_filled,
      'Motosiklet': Icons.two_wheeler,
      'Bisiklet': Icons.pedal_bike,
      'Yürüyüş': Icons.directions_walk,
    };

    for (final entry in vehicleMap.entries) {
      markerIcons[entry.key] = await _createVehicleMarkerBitmap(entry.value);
    }

    if (!mounted) return;
    setState(() {
      _vehicleMarkerIcons.clear();
      _vehicleMarkerIcons.addAll(markerIcons);
    });
  }

  Future<void> _loadChatRoomMarkerIcon() async {
    final icon = await _createStandaloneMarkerIcon(Icons.forum_rounded);
    if (!mounted) return;
    setState(() => _chatRoomMarkerIcon = icon);
  }

  Future<BitmapDescriptor> _createStandaloneMarkerIcon(
    IconData iconData,
  ) async {
    const size = 128;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(
      recorder,
      Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble()),
    );
    final textPainter = TextPainter(textDirection: TextDirection.ltr);
    textPainter.text = TextSpan(
      text: String.fromCharCode(iconData.codePoint),
      style: TextStyle(
        fontFamily: iconData.fontFamily,
        fontSize: 76,
        color: const Color(0xFFFF7A00),
        height: 1,
      ),
    );
    textPainter.layout();
    textPainter.paint(canvas, const Offset(26, 26));

    final image = await recorder.endRecording().toImage(size, size);
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    return BitmapDescriptor.bytes(
      byteData!.buffer.asUint8List(),
      width: size.toDouble(),
      height: size.toDouble(),
    );
  }

  Future<BitmapDescriptor> _createVehicleMarkerBitmap(IconData iconData) async {
    const int size = 56;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, const Rect.fromLTWH(0, 0, 56, 56));

    final shadowPaint = Paint()
      ..color = Colors.black.withValues(alpha: 0.18)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 7);
    final circlePaint = Paint()..color = const Color(0xFFFF6B00);
    final iconPaint = Paint()..color = Colors.white;

    canvas.drawCircle(const Offset(28, 28), 21, shadowPaint);
    canvas.drawCircle(const Offset(28, 28), 17, circlePaint);

    final textPainter = TextPainter(textDirection: TextDirection.ltr);
    textPainter.text = TextSpan(
      text: String.fromCharCode(iconData.codePoint),
      style: TextStyle(
        fontFamily: 'MaterialIcons',
        fontSize: 26,
        color: iconPaint.color,
        height: 1,
      ),
    );
    textPainter.layout();
    textPainter.paint(canvas, const Offset(14, 14));

    final picture = recorder.endRecording();
    final image = await picture.toImage(size, size);
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);

    return BitmapDescriptor.bytes(
      byteData!.buffer.asUint8List(),
      width: size.toDouble(),
      height: size.toDouble(),
    );
  }

  IconData _vehicleIcon(String vehicle) {
    switch (vehicle) {
      case 'Motosiklet':
        return Icons.two_wheeler;
      case 'Bisiklet':
        return Icons.pedal_bike;
      case 'Yürüyüş':
        return Icons.directions_walk;
      case 'Araba':
      default:
        return Icons.directions_car_filled;
    }
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
      if (_monthlyDrivingAnalytics != null)
        'Bu ay sürüş analizi: $_monthlyDrivingAnalytics',
    ].join('\n');

    setState(() {
      _aiMessages.add({'sender': 'user', 'text': text});
      _aiMessages.add({'sender': 'ai', 'text': 'Yanıt hazırlanıyor...'});
      _aiController.clear();
    });

    try {
      final ai = FirebaseAI.googleAI(auth: FirebaseAuth.instance);
      final model = ai.generativeModel(model: 'gemini-2.5-flash');
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

      if (!mounted) return;
      setState(() {
        _freeAiQueriesUsedToday++;
        _dailyQuotaDate = _dailyQuotaKey(DateTime.now());
        _aiMessages.removeLast();
        _aiMessages.add({'sender': 'ai', 'text': answer});
      });
      unawaited(_persistDailyQuota());
      if (user != null) {
        unawaited(
          FirebaseFirestore.instance
              .collection('users')
              .doc(user.uid)
              .collection('ai_chats')
              .add({
                'question': text,
                'answer': answer,
                'created_at': FieldValue.serverTimestamp(),
              }),
        );
      }
    } catch (error) {
      debugPrint('Navora AI yanıtı alınamadı: $error');
      if (!mounted) return;
      setState(() {
        _aiMessages.removeLast();
        _aiMessages.add({
          'sender': 'ai',
          'text': 'Şu anda yanıt veremiyorum. AI Logic kurulumunu ve bağlantıyı kontrol edin.',
        });
      });
    }
  }

  Future<void> _persistPointChange({
    required int balance,
    required String title,
    required String detail,
    required int amount,
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    final entry = <String, dynamic>{
      'title': title,
      'detail': detail,
      'amount': amount,
      'date': 'Şimdi',
    };
    setState(() {
      _pointLedger.insert(0, entry);
      if (_pointLedger.length > 100) _pointLedger.removeLast();
    });
    final preferences = await SharedPreferences.getInstance();
    await preferences.setInt('navora.points.${user.uid}', balance);
    await preferences.setString(
      'navora.pointLedger.${user.uid}',
      jsonEncode(_pointLedger),
    );
  }

  void _showNavoraPointsSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF191919),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return NavoraPointsSheet(
              points: _navoraPoints,
              monthEarned: _monthEarned,
              monthSpent: _monthSpent,
              bonusChatRooms: _bonusChatRooms,
              bonusAiQueries: _bonusAiQueries,
              hasProfileFrame: _hasProfileFrame,
              hasAuroraTheme: _hasAuroraTheme,
              hasProDiscount: _proDiscountUnlocked,
              citiesVisited: _citiesVisited,
              communityReports: _communityReports,
              ledger: _pointLedger,
              onChanged: () {
                setState(() {});
                setModalState(() {});
              },
              onRedeem: _redeemNavoraReward,
            );
          },
        );
      },
    );
  }

  bool _redeemNavoraReward(NavoraReward reward) {
    if (reward.id == 'frame' && _hasProfileFrame) return false;
    if (reward.id == 'theme' && _hasAuroraTheme) return false;
    if (reward.id == 'pro_discount' && _proDiscountUnlocked) return false;

    if (_navoraPoints < reward.cost) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Bu takas için puanın yetersiz.')),
      );
      return false;
    }

    setState(() {
      _navoraPoints -= reward.cost;
      switch (reward.id) {
        case 'room':
          _bonusChatRooms++;
          break;
        case 'ai':
          _bonusAiQueries++;
          break;
        case 'frame':
          _hasProfileFrame = true;
          break;
        case 'theme':
          _hasAuroraTheme = true;
          break;
        case 'pro_discount':
          _proDiscountUnlocked = true;
          break;
      }
    });
    unawaited(
      _persistPointChange(
        balance: _navoraPoints,
        title: reward.title,
        detail: 'Takas',
        amount: -reward.cost,
      ),
    );

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${reward.title} hesabına eklendi.')),
    );
    return true;
  }

  void _showAllBadgesSheet() {
    final nightDriveCount = _drivingHistory.where((history) {
      final date = DateTime.tryParse(history['date'] ?? '');
      return date != null && (date.hour >= 22 || date.hour < 6);
    }).length;
    final totalDistance =
        (_monthlyDrivingAnalytics?['total_distance_km'] as num?)?.toDouble() ??
        0;
    final drivingScore =
        (_monthlyDrivingAnalytics?['driving_score'] as num?)?.toDouble() ?? 0;
    final badges = [
      {
        'title': 'Şehir Kaşifi',
        'detail': '10 şehir keşfet',
        'unlocked': _citiesVisited >= 10,
        'progress': '$_citiesVisited / 10',
        'icon': Icons.explore,
        'color': Colors.amber,
      },
      {
        'title': 'Gece Sürücüsü',
        'detail': '10 gece sürüşü',
        'unlocked': nightDriveCount >= 10,
        'progress': '$nightDriveCount / 10',
        'icon': Icons.nightlight_round,
        'color': Colors.deepOrange,
      },
      {
        'title': 'Çevre Dostu',
        'detail': '100 km sürüş tamamla',
        'unlocked': totalDistance >= 100,
        'progress': '${totalDistance.toStringAsFixed(0)} / 100 km',
        'icon': Icons.ev_station,
        'color': Colors.green,
      },
      {
        'title': 'Topluluk Lideri',
        'detail': '20 topluluk bildirimi',
        'unlocked': _communityReports >= 20,
        'progress': '$_communityReports / 20',
        'icon': Icons.verified_user,
        'color': const Color(0xFFFF6B00),
      },
      {
        'title': 'Kıta Gezgini',
        'detail': '20 şehir keşfet',
        'unlocked': _citiesVisited >= 20,
        'progress': '$_citiesVisited / 20',
        'icon': Icons.public,
        'color': Colors.orange,
      },
      {
        'title': 'Kaptan',
        'detail': 'Kaptan seviyesine ulaş',
        'unlocked': NavoraRank.current(_navoraPoints).name == 'Kaptan',
        'progress': NavoraRank.current(_navoraPoints).name,
        'icon': Icons.military_tech,
        'color': Colors.deepOrange,
      },
      {
        'title': 'Rota Ustası',
        'detail': '5 kayıtlı rota oluştur',
        'unlocked': _savedRoutes.length >= 5,
        'progress': '${_savedRoutes.length} / 5',
        'icon': Icons.alt_route,
        'color': Colors.cyan,
      },
      {
        'title': 'Güvenli Sürücü',
        'detail': '90 ve üzeri sürüş skoru',
        'unlocked': drivingScore >= 90,
        'progress': '${drivingScore.toStringAsFixed(0)} / 90',
        'icon': Icons.shield_outlined,
        'color': Colors.green,
      },
      {
        'title': 'Uzun Yolcu',
        'detail': '500 km yol tamamla',
        'unlocked': totalDistance >= 500,
        'progress': '${totalDistance.toStringAsFixed(0)} / 500 km',
        'icon': Icons.directions_car_filled_outlined,
        'color': Colors.orange,
      },
    ];

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF191919),
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) => ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.82,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '9 Keşif Rozeti & Başarımlar',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 14),
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: badges.length,
                  separatorBuilder: (context, index) =>
                      const SizedBox(height: 10),
                  itemBuilder: (context, index) {
                    final badge = badges[index];
                    final unlocked = badge['unlocked'] as bool;
                    final color = badge['color'] as Color;

                    return TweenAnimationBuilder<double>(
                      tween: Tween(
                        begin: unlocked ? 0.35 : 0.0,
                        end: unlocked ? 1.0 : 0.0,
                      ),
                      duration: const Duration(milliseconds: 900),
                      curve: Curves.easeInOut,
                      builder: (context, glow, _) => Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: const Color(0xFF171717),
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(
                            color: unlocked
                                ? const Color(0xFFFF8C42).withValues(alpha: 0.7)
                                : Colors.white.withValues(alpha: 0.08),
                          ),
                          boxShadow: null,
                        ),
                        child: ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Container(
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              boxShadow: unlocked
                                  ? [
                                      BoxShadow(
                                        color: color.withValues(
                                          alpha: 0.42 * glow,
                                        ),
                                        blurRadius: 14 * glow,
                                        spreadRadius: 3 * glow,
                                      ),
                                    ]
                                  : null,
                            ),
                            child: CircleAvatar(
                              radius: 20,
                              backgroundColor: color.withValues(
                                alpha: unlocked ? 0.2 : 0.08,
                              ),
                              child: Icon(
                                badge['icon'] as IconData,
                                color: unlocked ? color : Colors.grey,
                              ),
                            ),
                          ),
                          title: Text(
                            badge['title'] as String,
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: unlocked
                                  ? Colors.white
                                  : Colors.grey.shade400,
                            ),
                          ),
                          subtitle: Text(
                            '${badge['detail']} • ${badge['progress']}',
                            style: TextStyle(
                              fontSize: 12,
                              color: unlocked
                                  ? Colors.white70
                                  : Colors.grey.shade500,
                            ),
                          ),
                          trailing: Icon(
                            unlocked ? Icons.check_circle : Icons.lock_outline,
                            color: unlocked ? Colors.orange : Colors.grey,
                            size: 20,
                          ),
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
    return GestureDetector(
      onTap: () {
        setState(() {
          _selectedIndex = index;
        });
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: 70,
        height: 56,
        color: Colors.transparent,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.start,
          children: [
            Icon(
              icon,
              color: isSelected ? Colors.white : Colors.white60,
              size: isSelected ? 28 : 22,
            ),
            const SizedBox(height: 3),
            Text(
              label,
              style: TextStyle(
                color: isSelected ? Colors.white : Colors.white60,
                fontSize: 10,
                fontWeight: isSelected ? FontWeight.w800 : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
