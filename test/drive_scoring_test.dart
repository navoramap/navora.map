import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:navora_map/views/home/home_page.dart';
import 'package:navora_map/services/chat_room_service.dart';

void main() {
  test('drive scoring keeps normal speeds mostly stable', () {
    expect(navoraDriveScorePenalty(speedKmh: 85, previousSpeedKmh: 82), 0);
    expect(navoraDriveScorePenalty(speedKmh: 118, previousSpeedKmh: 110), 0);
  });

  test('drive scoring penalizes excessive speed and sudden drops', () {
    expect(navoraDriveScorePenalty(speedKmh: 130, previousSpeedKmh: 80), 2);
    expect(navoraDriveScorePenalty(speedKmh: 155, previousSpeedKmh: 90), 2);
    expect(navoraDriveScorePenalty(speedKmh: 70, previousSpeedKmh: 20), 2);
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

  test('navigation bearing smoothing crosses north by the shorter angle', () {
    expect(navoraSmoothBearing(350, 10, factor: 0.5), closeTo(0, 0.001));
  });

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
