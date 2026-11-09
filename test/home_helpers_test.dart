import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:navora_map/views/home/home_page.dart';
import 'package:navora_map/views/home/search_page.dart';
import 'package:navora_map/services/chat_room_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('navigation duration switches to hours after 60 minutes', () {
    expect(navoraFormatNavigationDuration(59), '59 dk');
    expect(navoraFormatNavigationDuration(60), '1 sa');
    expect(navoraFormatNavigationDuration(125), '2 sa 5 dk');
    expect(navoraFormatNavigationDuration(1500), '25 sa');
    expect(
      navoraFormatNavigationDuration(7500, isWalking: true),
      '15 gün 5 sa',
    );
    expect(navoraFormatNavigationDuration(null), '-');
  });

  test('navigation arrival time updates from remaining duration', () {
    final now = DateTime(2026, 10, 28, 22, 30);
    expect(navoraFormatArrivalTime(now, 45), '23:15');
    expect(navoraFormatArrivalTime(now, 120), '00:30');
    expect(navoraFormatArrivalTime(now, null), isNull);
  });

  test('navigation ETA keeps fractional progress between GPS updates', () {
    final firstUpdate = navoraScaleRemainingDurationSeconds(
      durationSeconds: 600,
      remainingDistanceKm: 9.9,
      previousDistanceKm: 10,
    );
    final secondUpdate = navoraScaleRemainingDurationSeconds(
      durationSeconds: firstUpdate,
      remainingDistanceKm: 9.8,
      previousDistanceKm: 9.9,
    );

    expect(firstUpdate, lessThan(600));
    expect(secondUpdate, lessThan(firstUpdate));
    expect(navoraDurationMinutesFromSeconds(59), 1);
    expect(navoraDurationMinutesFromSeconds(0), 0);
  });

  test('route length sums remaining polyline segment distances', () {
    const points = [LatLng(41.0, 29.0), LatLng(41.0, 29.01)];
    expect(navoraRouteLengthKm(points), inInclusiveRange(0.8, 0.9));
    expect(navoraRouteLengthKm(const []), 0);
  });

  test('navigation zoom increases as the next maneuver approaches', () {
    expect(navoraNavigationZoomForManeuverDistance(500), 17);
    expect(navoraNavigationZoomForManeuverDistance(300), 18);
    expect(navoraNavigationZoomForManeuverDistance(100), 19);
    expect(navoraNavigationZoomForManeuverDistance(null), 17);
  });

  test(
    'navigation camera zoom adapts to speed without hiding nearby turns',
    () {
      expect(navoraNavigationZoomForSpeedAndManeuver(500, 5), 17);
      expect(navoraNavigationZoomForSpeedAndManeuver(500, 20), 16.5);
      expect(navoraNavigationZoomForSpeedAndManeuver(500, 30), 16);
      expect(navoraNavigationZoomForSpeedAndManeuver(50, 30), 18);
      expect(navoraNavigationZoomForSpeedAndManeuver(500, double.nan), 17);
    },
  );

  test('off-route detection responds sooner and accounts for GPS accuracy', () {
    expect(
      navoraOffRouteThresholdMeters(vehicle: 'Araba', accuracyMeters: 10),
      60,
    );
    expect(
      navoraOffRouteThresholdMeters(vehicle: 'Yürüyüş', accuracyMeters: 10),
      25,
    );
    expect(
      navoraOffRouteThresholdMeters(vehicle: 'Bisiklet', accuracyMeters: 100),
      55,
    );
  });

  test(
    'route recalculation uses a newer position after significant movement',
    () {
      expect(
        navoraShouldRefetchRouteFromLatestPosition(
          movedMeters: 17,
          speedMetersPerSecond: 0,
        ),
        isFalse,
      );
      expect(
        navoraShouldRefetchRouteFromLatestPosition(
          movedMeters: 80,
          speedMetersPerSecond: 25,
        ),
        isTrue,
      );
      expect(
        navoraShouldRefetchRouteFromLatestPosition(
          movedMeters: double.nan,
          speedMetersPerSecond: 2,
        ),
        isFalse,
      );
    },
  );

  test('chat rooms cluster at wide zoom and separate when zoomed in', () {
    final rooms = [
      {'id': 'near-a', 'latitude': 41.0, 'longitude': 29.0},
      {'id': 'near-b', 'latitude': 41.0001, 'longitude': 29.0001},
      {'id': 'far', 'latitude': 41.5, 'longitude': 29.5},
    ];

    final wideZoomClusters = navoraClusterChatRooms(rooms, zoom: 11);
    expect(wideZoomClusters, hasLength(2));
    expect(
      wideZoomClusters.map((cluster) => cluster.length).toSet(),
      contains(2),
    );
    expect(navoraClusterChatRooms(rooms, zoom: 15), hasLength(3));
  });

  test('slow or unavailable internet is flagged for navigation', () {
    expect(navoraIsNetworkDegraded(const Duration(seconds: 2), 204), isFalse);
    expect(navoraIsNetworkDegraded(const Duration(seconds: 4), 204), isTrue);
    expect(
      navoraIsNetworkDegraded(const Duration(milliseconds: 100), 503),
      isTrue,
    );
  });

  test('navigation speed is converted from meters per second to km/h', () {
    expect(navoraSpeedKmh(10), 36);
    expect(navoraSpeedKmh(-1), 0);
    expect(navoraSpeedKmh(double.nan), 0);
  });

  test('long walking routes use a realistic daily walking estimate', () {
    expect(
      navoraWalkingDurationMinutes(distanceKm: 500, routeDurationMinutes: 960),
      7500,
    );
    expect(
      navoraWalkingDurationMinutes(distanceKm: 10, routeDurationMinutes: 180),
      180,
    );
  });

  test('navigation follow can be paused by manual camera movement', () {
    expect(
      navoraShouldFollowCurrentPosition(
        isNavigationActive: true,
        isDriveTracking: true,
        isFollowing: false,
      ),
      isFalse,
    );
  });

  test('navigation ignores low-accuracy GPS fixes for route decisions', () {
    expect(navoraHasReliableNavigationPosition(5), isTrue);
    expect(navoraHasReliableNavigationPosition(50), isTrue);
    expect(navoraHasReliableNavigationPosition(51), isFalse);
    expect(navoraHasReliableNavigationPosition(double.nan), isFalse);
  });

  test('arrival alert starts before reaching the destination', () {
    expect(navoraIsWithinArrivalRadius(300), isTrue);
    expect(navoraIsWithinArrivalRadius(300.1), isFalse);
    expect(navoraIsWithinArrivalRadius(double.infinity), isFalse);
  });

  test('navigation completion waits until the destination is reached', () {
    expect(navoraIsWithinNavigationCompletionRadius(60), isTrue);
    expect(navoraIsWithinNavigationCompletionRadius(60.1), isFalse);
    expect(navoraIsWithinNavigationCompletionRadius(double.infinity), isFalse);
  });

  test('route history requires arrival and measurable travel progress', () {
    expect(
      navoraHasCompletedRouteProgress(
        traveledDistanceKm: 0.2,
        startDistanceToDestinationMeters: 500,
        completionDistanceToDestinationMeters: 20,
      ),
      isTrue,
    );
    expect(
      navoraHasCompletedRouteProgress(
        traveledDistanceKm: 0,
        startDistanceToDestinationMeters: 500,
        completionDistanceToDestinationMeters: 20,
      ),
      isFalse,
    );
    expect(
      navoraHasCompletedRouteProgress(
        traveledDistanceKm: 0.03,
        startDistanceToDestinationMeters: 500,
        completionDistanceToDestinationMeters: 20,
      ),
      isFalse,
    );
    expect(
      navoraHasCompletedRouteProgress(
        traveledDistanceKm: 0.2,
        startDistanceToDestinationMeters: 100,
        completionDistanceToDestinationMeters: 80,
      ),
      isFalse,
    );
  });

  test('incomplete navigation does not create drive-history entries', () {
    expect(
      navoraShouldSaveDriveHistory(
        startedForNavigation: true,
        hasCompletedNavigationProgress: false,
      ),
      isFalse,
    );
    expect(
      navoraShouldSaveDriveHistory(
        startedForNavigation: true,
        hasCompletedNavigationProgress: true,
      ),
      isTrue,
    );
    expect(
      navoraShouldSaveDriveHistory(
        startedForNavigation: false,
        hasCompletedNavigationProgress: false,
      ),
      isTrue,
    );
  });

  test(
    'search filters categories, keeps distant results, and prioritizes nearby',
    () {
      final results = [
        {'name': 'Yakın kafe', 'type': 'cafe', 'distanceMeters': 1200},
        {'name': 'Uzak kafe', 'type': 'cafe', 'distanceMeters': 25000},
        {'name': 'Yakın market', 'type': 'supermarket', 'distanceMeters': 800},
        {'name': 'Konum sonucu', 'type': 'place'},
      ];

      final filtered = navoraFilterMapSearchResults(
        results,
        category: 'Kafe',
      );

      expect(filtered.map((result) => result['name']), [
        'Yakın kafe',
        'Uzak kafe',
      ]);
      expect(
        navoraFilterMapSearchResults(
          results,
          category: 'Tümü',
        ).map((result) => result['name']),
        ['Yakın market', 'Yakın kafe', 'Uzak kafe', 'Konum sonucu'],
      );
    },
  );

  test('location tracking follows until the map is manually moved', () {
    expect(
      navoraShouldFollowCurrentPosition(
        isNavigationActive: false,
        isDriveTracking: false,
        isLocationTracking: true,
      ),
      isTrue,
    );
    expect(
      navoraShouldFollowCurrentPosition(
        isNavigationActive: false,
        isDriveTracking: false,
        isLocationTracking: true,
        isFollowing: false,
      ),
      isFalse,
    );
  });

  test('traffic intervals color only slow and jammed route sections', () {
    const routePoints = [
      LatLng(41.0, 29.0),
      LatLng(41.1, 29.1),
      LatLng(41.2, 29.2),
      LatLng(41.3, 29.3),
      LatLng(41.4, 29.4),
    ];
    final intervals = [
      {
        'speed': 'NORMAL',
        'startPolylinePointIndex': 0,
        'endPolylinePointIndex': 1,
      },
      {
        'speed': 'SLOW',
        'startPolylinePointIndex': 1,
        'endPolylinePointIndex': 3,
      },
      {
        'speed': 'TRAFFIC_JAM',
        'startPolylinePointIndex': 3,
        'endPolylinePointIndex': 4,
      },
    ];

    final polylines = NavoraTrafficService.buildRouteTrafficPolylines(
      routePoints,
      intervals,
    );

    expect(polylines, hasLength(2));
    expect(polylines[0].points, routePoints.sublist(1, 4));
    expect(polylines[0].color.toARGB32(), 0xFFFFC107);
    expect(polylines[0].zIndex, greaterThan(0));
    expect(polylines[1].points, routePoints.sublist(3, 5));
    expect(polylines[1].color.toARGB32(), 0xFFE53935);
    expect(NavoraTrafficService.statusForIntervals(intervals), 'Yoğun');
  });

  test('navigation bearing smoothing crosses north by the shorter angle', () {
    expect(navoraSmoothBearing(350, 10, factor: 0.5), closeTo(0, 0.001));
  });

  test('compass heading uses the phone tilt to find north and east', () {
    expect(
      navoraCalculateCompassHeading(
        accelerationX: 0,
        accelerationY: 0,
        accelerationZ: 9.8,
        magneticX: 0,
        magneticY: 1,
        magneticZ: 0,
      ),
      closeTo(0, 0.001),
    );
    expect(
      navoraCalculateCompassHeading(
        accelerationX: 0,
        accelerationY: 0,
        accelerationZ: 9.8,
        magneticX: -1,
        magneticY: 0,
        magneticZ: 0,
      ),
      closeTo(90, 0.001),
    );
    expect(
      navoraCalculateCompassHeading(
        accelerationX: 0,
        accelerationY: 0,
        accelerationZ: 9.8,
        magneticX: -0.3535,
        magneticY: 0.3535,
        magneticZ: 0.866,
      ),
      closeTo(45, 0.1),
    );
  });

  test(
    'compass heading is unavailable when sensor vectors cannot define it',
    () {
      expect(
        navoraCalculateCompassHeading(
          accelerationX: 0,
          accelerationY: 0,
          accelerationZ: 0,
          magneticX: 0,
          magneticY: 1,
          magneticZ: 0,
        ),
        isNull,
      );
    },
  );

  test('navigation camera target looks ahead in the current direction', () {
    final target = navoraOffsetCameraTarget(const LatLng(0, 0), 0, 100);
    expect(target.latitude, greaterThan(0));
    expect(target.longitude, closeTo(0, 0.001));
  });

  test(
    'route distance measures distance to a segment, not only its points',
    () {
      final distance = navoraDistanceToRouteMeters(
        const LatLng(0.0005, 0.0005),
        const [LatLng(0, 0), LatLng(0.001, 0.001)],
      );
      expect(distance, lessThan(1));
    },
  );

  test(
    'room password hashes are salted and stable for matching input',
    () async {
      final hash = await navoraHashRoomPassword(
        'a-long-room-password',
        'test-salt',
      );
      expect(hash, hasLength(64));
      expect(
        await navoraHashRoomPassword('a-long-room-password', 'test-salt'),
        hash,
      );
      expect(
        await navoraHashRoomPassword('a-long-room-password', 'other-salt'),
        isNot(hash),
      );
    },
  );
}
