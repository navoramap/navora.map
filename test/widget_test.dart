// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart'
    show CoreFirebaseOptions, CoreInitializeResponse, TestFirebaseCoreHostApi;
import 'package:firebase_auth_platform_interface/firebase_auth_platform_interface.dart';
import 'package:flutter/material.dart' show MaterialApp;
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import 'package:navora_map/firebase_options.dart';
import 'package:navora_map/main.dart';
import 'package:navora_map/views/home/home_page.dart';
import 'package:navora_map/views/home/tabs/profile_page.dart';

void main() {
  setUpAll(() async {
    TestFirebaseCoreHostApi.setUp(_FirebaseCoreHostApi());
    FirebaseAuthPlatform.instance = _TestFirebaseAuthPlatform();
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
  });

  testWidgets('shows the authentication screen', (WidgetTester tester) async {
    await tester.pumpWidget(const NavoraMapApp());
    await tester.pumpAndSettle();

    expect(find.text('NAVORA MAP'), findsOneWidget);
    expect(find.text('Giris Yap'), findsNWidgets(2));
    expect(find.text('Kayit Ol'), findsOneWidget);
  });

  testWidgets('validates empty authentication fields', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const NavoraMapApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Giris Yap').last);
    await tester.pump();

    expect(find.text('Lütfen tüm alanları doldurun.'), findsOneWidget);
  });

  testWidgets('shows membership upgrade flow in the profile page', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: ProfilePage()));
    await tester.pumpAndSettle();

    expect(find.text('Standart plan'), findsOneWidget);
    expect(find.text('Pro üyelik al'), findsOneWidget);

    await tester.tap(find.text('Pro üyelik al'));
    await tester.pumpAndSettle();

    expect(find.text('Pro üyelik'), findsOneWidget);
    expect(
      find.text(
        'Pro satın alma şu anda etkin değil. Mağaza ürünleri ve sunucu doğrulaması tamamlandığında burada açılacak.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Kapat'));
    await tester.pumpAndSettle();

    expect(find.text('Standart plan'), findsOneWidget);
    expect(find.text('Pro plan'), findsNothing);

    await tester.scrollUntilVisible(find.text('Hesabımı sil'), 300);
    expect(find.text('Hesabımı sil'), findsOneWidget);
    await tester.tap(find.text('Hesabımı sil'));
    await tester.pumpAndSettle();
    expect(find.text('Hesap kalıcı olarak silinsin mi?'), findsOneWidget);
    await tester.tap(find.text('Vazgeç'));
    await tester.pumpAndSettle();
    expect(find.text('Hesap kalıcı olarak silinsin mi?'), findsNothing);
  });

  test(
    'follow current location when navigation or drive tracking is active',
    () {
      expect(
        navoraShouldFollowCurrentPosition(
          isNavigationActive: true,
          isDriveTracking: false,
        ),
        isTrue,
      );
      expect(
        navoraShouldFollowCurrentPosition(
          isNavigationActive: false,
          isDriveTracking: true,
        ),
        isTrue,
      );
      expect(
        navoraShouldFollowCurrentPosition(
          isNavigationActive: false,
          isDriveTracking: false,
        ),
        isFalse,
      );
    },
  );

  test('prefers business names over display address in osm suggestions', () {
    final result = <String, dynamic>{
      'display_name': 'Sahibata Mahallesi, Kadıköy, İstanbul',
      'name': 'Lazoğlu Kahvaltı',
      'namedetails': {'name': 'Lazoğlu Kahvaltı'},
      'address': {
        'road': 'Sahibata Caddesi',
        'suburb': 'Kadıköy',
        'city': 'İstanbul',
      },
    };

    expect(navoraResolveSearchTitle(result, 'laz'), 'Lazoğlu Kahvaltı');
    expect(
      navoraResolveSearchSubtitle(result),
      'Sahibata Caddesi, Kadıköy, İstanbul',
    );
  });

  test('removes already traveled route segments from the active polyline', () {
    final route = [
      const LatLng(41.001, 28.970),
      const LatLng(41.005, 28.975),
      const LatLng(41.010, 28.980),
      const LatLng(41.015, 28.985),
    ];

    final remaining = navoraTrimRouteToRemainingPath(
      route,
      const LatLng(41.0052, 28.9753),
    );

    expect(remaining.length, 3);
    expect(remaining.first, const LatLng(41.005, 28.975));
    expect(remaining.last, const LatLng(41.015, 28.985));
  });

  test('calculates drive analytics from real distance and elapsed time', () {
    final distanceKm = 45.2;
    final durationSeconds = 3600;

    expect(
      navoraAverageSpeedKmh(
        distanceKm: distanceKm,
        durationSeconds: durationSeconds,
      ),
      closeTo(45.2 / 1, 0.01),
    );
  });
}

class _FirebaseCoreHostApi implements TestFirebaseCoreHostApi {
  @override
  Future<CoreInitializeResponse> initializeApp(
    String appName,
    CoreFirebaseOptions initializeAppRequest,
  ) async {
    return CoreInitializeResponse(
      name: appName,
      options: initializeAppRequest,
      pluginConstants: const {},
    );
  }

  @override
  Future<List<CoreInitializeResponse>> initializeCore() async => const [];

  @override
  Future<CoreFirebaseOptions> optionsFromResource() async {
    return CoreFirebaseOptions(
      apiKey: 'test-api-key',
      appId: 'test-app-id',
      messagingSenderId: 'test-sender-id',
      projectId: 'test-project-id',
    );
  }
}

class _TestFirebaseAuthPlatform extends FirebaseAuthPlatform {
  @override
  FirebaseAuthPlatform delegateFor({required FirebaseApp app}) => this;

  @override
  FirebaseAuthPlatform setInitialValues({
    PigeonUserDetails? currentUser,
    String? languageCode,
  }) => this;

  @override
  UserPlatform? get currentUser => null;

  @override
  set currentUser(UserPlatform? userPlatform) {}
}
