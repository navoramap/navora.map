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
import 'package:flutter/material.dart'
    show MaterialApp, SnackBar, TargetPlatform, TextField;
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
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
    expect(find.text('Giriş Yap'), findsNWidgets(2));
    expect(find.text('Kayıt Ol'), findsOneWidget);
    expect(
      find.text('Apple ile devam et'),
      defaultTargetPlatform == TargetPlatform.iOS ||
              defaultTargetPlatform == TargetPlatform.macOS
          ? findsOneWidget
          : findsNothing,
    );
  });

  testWidgets('validates empty authentication fields', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const NavoraMapApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Giriş Yap').last);
    await tester.pump();

    expect(
      find.text('Lütfen e-posta adresinizi ve şifrenizi girin.'),
      findsOneWidget,
    );
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('shows signup password mismatch in the form error area', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const NavoraMapApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Kayıt Ol').first);
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).at(0), 'Test Kullanıcı');
    await tester.enterText(find.byType(TextField).at(1), 'test@example.com');
    await tester.enterText(find.byType(TextField).at(2), '05551234567');

    final genderSelector = find.text('Seçiniz');
    await tester.ensureVisible(genderSelector);
    await tester.tap(genderSelector);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Kadın').last);
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).at(3), 'Abcdefghij');
    await tester.enterText(find.byType(TextField).at(4), 'Abcdefghik');

    final submitButton = find.text('Kayıt Ol').last;
    await tester.ensureVisible(submitButton);
    await tester.tap(submitButton);
    await tester.pump();

    final errorMessage = find.text('Şifreler eşleşmiyor.');
    await tester.ensureVisible(errorMessage);
    expect(errorMessage, findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('requires a 10-character mixed-case signup password', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const NavoraMapApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Kayıt Ol').first);
    await tester.pumpAndSettle();

    final passwordField = find.byType(TextField).at(3);
    await tester.ensureVisible(passwordField);
    await tester.enterText(passwordField, 'abcdefghij');
    await tester.pump();

    expect(find.text('Şifre en az bir büyük harf içermeli.'), findsOneWidget);

    await tester.enterText(passwordField, 'Abcdefghij');
    await tester.pump();
    expect(find.text('Şifre en az bir büyük harf içermeli.'), findsNothing);
    expect(find.text('Şifre gücü: Güçlü'), findsOneWidget);

    final termsButton = find.text('Sözleşmeyi incele');
    final privacyButton = find.text('KVKK metnini incele');
    final publicPrivacyButton = find.text('Web politikasını aç');
    await tester.ensureVisible(termsButton);
    await tester.ensureVisible(privacyButton);
    await tester.ensureVisible(publicPrivacyButton);
    expect(termsButton, findsOneWidget);
    expect(privacyButton, findsOneWidget);
    expect(publicPrivacyButton, findsOneWidget);
    await tester.tap(termsButton);
    await tester.pumpAndSettle();
    expect(find.text('Kullanıcı Sözleşmesi'), findsOneWidget);
    expect(
      find.textContaining('çocukların güvenliğini tehlikeye atan'),
      findsOneWidget,
    );
    expect(find.textContaining('hesabı kalıcı olarak kapatma'), findsOneWidget);
    expect(
      find.textContaining('uygulama içindeki şikâyet araçlarıyla'),
      findsOneWidget,
    );
    await tester.tap(find.text('Kapat'));
    await tester.pumpAndSettle();
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

    expect(remaining.length, 4);
    expect(remaining.first, const LatLng(41.0052, 28.9753));
    expect(remaining.last, const LatLng(41.015, 28.985));
    expect(remaining, isNot(contains(const LatLng(41.001, 28.970))));
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
