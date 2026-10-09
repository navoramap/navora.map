import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/foundation.dart';

import 'dart:async';
import 'dart:convert';

import 'package:app_links/app_links.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:crypto/crypto.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import 'views/home/home_page.dart';
import 'firebase_options.dart';

part 'views/main_wrapper.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      );
    }
  } catch (e) {
    if (!e.toString().contains('duplicate-app')) {
      rethrow;
    }
  }

  if (defaultTargetPlatform == TargetPlatform.android) {
    await FirebaseAppCheck.instance.activate(
      androidProvider: kDebugMode
          ? AndroidProvider.debug
          : AndroidProvider.playIntegrity,
    );
  }

  runApp(const NavoraMapApp());
}

class NavoraMapApp extends StatefulWidget {
  const NavoraMapApp({super.key});

  @override
  State<NavoraMapApp> createState() => _NavoraMapAppState();
}

class _NavoraMapAppState extends State<NavoraMapApp> {
  final _navigatorKey = GlobalKey<NavigatorState>();
  final _appLinks = AppLinks();
  StreamSubscription<Uri>? _linkSubscription;

  @override
  void initState() {
    super.initState();
    _linkSubscription = _appLinks.uriLinkStream.listen(_openSharedListUri);
    unawaited(
      _appLinks
          .getInitialLink()
          .then(_openSharedListUri)
          .catchError((Object _) {}),
    );
  }

  @override
  void dispose() {
    _linkSubscription?.cancel();
    super.dispose();
  }

  void _openSharedListUri(Uri? uri) {
    // Shared list deep links are disabled.
    return;
  }

  @override
  Widget build(BuildContext context) {
    const brand = Color(0xFFFF6B00);
    const brandLight = Color(0xFFFF9D4D);
    const canvas = Color(0xFF121212);
    const surface = Color(0xFF1B1B1B);
    const raisedSurface = Color(0xFF242424);
    const mutedText = Color(0xFFB8B8B8);
    const outline = Color(0xFF383838);
    const error = Color(0xFFEF5350);

    final colorScheme =
        ColorScheme.fromSeed(
          seedColor: brand,
          primary: brand,
          onPrimary: Colors.white,
          secondary: brandLight,
          onSecondary: const Color(0xFF24160F),
          surface: surface,
          onSurface: Colors.white,
          error: error,
          onError: Colors.white,
          brightness: Brightness.dark,
        ).copyWith(
          surface: surface,
          surfaceContainerLowest: canvas,
          surfaceContainerLow: surface,
          surfaceContainer: raisedSurface,
          surfaceContainerHigh: raisedSurface,
          surfaceContainerHighest: raisedSurface,
          onSurfaceVariant: mutedText,
          outline: outline,
          outlineVariant: outline,
          primaryContainer: const Color(0xFF2A180D),
          onPrimaryContainer: brandLight,
          secondaryContainer: const Color(0xFF312016),
          onSecondaryContainer: brandLight,
        );

    return MaterialApp(
      navigatorKey: _navigatorKey,
      debugShowCheckedModeBanner: false,
      title: 'Navora Map',
      locale: const Locale('tr', 'TR'),
      supportedLocales: const [Locale('tr', 'TR'), Locale('en', 'US')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: colorScheme,
        scaffoldBackgroundColor: canvas,
        dividerColor: outline,
        textTheme: const TextTheme(
          displayLarge: TextStyle(fontSize: 40, fontWeight: FontWeight.w700),
          displayMedium: TextStyle(fontSize: 34, fontWeight: FontWeight.w700),
          displaySmall: TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
          headlineLarge: TextStyle(fontSize: 26, fontWeight: FontWeight.w700),
          headlineMedium: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
          headlineSmall: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
          titleLarge: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
          titleMedium: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          titleSmall: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          bodyLarge: TextStyle(fontSize: 16, fontWeight: FontWeight.w400),
          bodyMedium: TextStyle(fontSize: 14, fontWeight: FontWeight.w400),
          bodySmall: TextStyle(fontSize: 12, fontWeight: FontWeight.w400),
          labelLarge: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
          labelMedium: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          labelSmall: TextStyle(fontSize: 11, fontWeight: FontWeight.w500),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          scrolledUnderElevation: 0,
          foregroundColor: Colors.white,
          centerTitle: false,
          titleTextStyle: TextStyle(
            color: Colors.white,
            fontSize: 18,
            fontWeight: FontWeight.w700,
          ),
        ),
        cardTheme: CardThemeData(
          color: surface,
          surfaceTintColor: Colors.transparent,
          elevation: 1,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: outline),
          ),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: brand,
            foregroundColor: Colors.white,
            elevation: 0,
            disabledBackgroundColor: raisedSurface,
            disabledForegroundColor: mutedText,
            minimumSize: const Size.fromHeight(52),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
            textStyle: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(
            foregroundColor: brandLight,
            minimumSize: const Size(48, 44),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            textStyle: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            foregroundColor: Colors.white,
            minimumSize: const Size(48, 48),
            side: const BorderSide(color: outline),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
            textStyle: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
        iconButtonTheme: IconButtonThemeData(
          style: IconButton.styleFrom(
            foregroundColor: mutedText,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
        floatingActionButtonTheme: FloatingActionButtonThemeData(
          backgroundColor: raisedSurface,
          foregroundColor: brandLight,
          elevation: 2,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: outline),
          ),
        ),
        chipTheme: ChipThemeData(
          backgroundColor: raisedSurface,
          selectedColor: brand.withValues(alpha: 0.22),
          checkmarkColor: brandLight,
          disabledColor: surface,
          labelStyle: const TextStyle(color: Colors.white, fontSize: 12),
          secondaryLabelStyle: const TextStyle(color: brandLight, fontSize: 12),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: outline),
          ),
          side: const BorderSide(color: outline),
        ),
        dialogTheme: DialogThemeData(
          backgroundColor: surface,
          surfaceTintColor: Colors.transparent,
          titleTextStyle: const TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.w700,
          ),
          contentTextStyle: const TextStyle(
            color: mutedText,
            fontSize: 14,
            height: 1.4,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: const BorderSide(color: outline),
          ),
        ),
        bottomSheetTheme: const BottomSheetThemeData(
          backgroundColor: surface,
          modalBackgroundColor: surface,
          surfaceTintColor: Colors.transparent,
          showDragHandle: true,
          dragHandleColor: outline,
          dragHandleSize: Size(40, 4),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
            side: BorderSide(color: outline),
          ),
        ),
        snackBarTheme: SnackBarThemeData(
          backgroundColor: raisedSurface,
          contentTextStyle: const TextStyle(color: Colors.white, fontSize: 14),
          behavior: SnackBarBehavior.floating,
          insetPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: outline),
          ),
        ),
        navigationBarTheme: NavigationBarThemeData(
          backgroundColor: surface,
          indicatorColor: brand.withValues(alpha: 0.18),
          elevation: 0,
          height: 72,
          labelTextStyle: WidgetStateProperty.resolveWith((states) {
            return TextStyle(
              color: states.contains(WidgetState.selected)
                  ? brandLight
                  : mutedText,
              fontSize: 11,
              fontWeight: states.contains(WidgetState.selected)
                  ? FontWeight.w700
                  : FontWeight.w500,
            );
          }),
          iconTheme: WidgetStateProperty.resolveWith((states) {
            return IconThemeData(
              color: states.contains(WidgetState.selected)
                  ? brandLight
                  : mutedText,
              size: 22,
            );
          }),
        ),
        tabBarTheme: const TabBarThemeData(
          labelColor: brandLight,
          unselectedLabelColor: mutedText,
          indicatorColor: brand,
          dividerColor: outline,
          labelStyle: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
          unselectedLabelStyle: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
        ),
        switchTheme: SwitchThemeData(
          thumbColor: WidgetStateProperty.resolveWith((states) {
            return states.contains(WidgetState.selected)
                ? Colors.white
                : mutedText;
          }),
          trackColor: WidgetStateProperty.resolveWith((states) {
            return states.contains(WidgetState.selected)
                ? brand
                : raisedSurface;
          }),
          trackOutlineColor: WidgetStateProperty.all(outline),
        ),
        checkboxTheme: CheckboxThemeData(
          checkColor: WidgetStateProperty.all(Colors.white),
          fillColor: WidgetStateProperty.resolveWith((states) {
            return states.contains(WidgetState.selected)
                ? brand
                : Colors.transparent;
          }),
          side: const BorderSide(color: mutedText),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
        ),
        dividerTheme: const DividerThemeData(
          color: outline,
          thickness: 1,
          space: 1,
        ),
        tooltipTheme: TooltipThemeData(
          decoration: BoxDecoration(
            color: raisedSurface,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: outline),
          ),
          textStyle: const TextStyle(color: Colors.white, fontSize: 12),
          waitDuration: const Duration(milliseconds: 500),
        ),
        progressIndicatorTheme: const ProgressIndicatorThemeData(
          color: brand,
          linearTrackColor: raisedSurface,
          circularTrackColor: raisedSurface,
        ),
        listTileTheme: const ListTileThemeData(
          iconColor: brandLight,
          textColor: Colors.white,
          contentPadding: EdgeInsets.symmetric(horizontal: 16),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: surface,
          prefixIconColor: brandLight,
          suffixIconColor: mutedText,
          floatingLabelStyle: const TextStyle(color: brandLight),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 16,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: outline),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: outline),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: brand, width: 1.5),
          ),
          errorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: error),
          ),
          focusedErrorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: error, width: 1.5),
          ),
          labelStyle: const TextStyle(color: mutedText),
          hintStyle: const TextStyle(color: mutedText),
          helperStyle: const TextStyle(color: mutedText),
          errorStyle: const TextStyle(color: error),
        ),
        textSelectionTheme: const TextSelectionThemeData(
          cursorColor: brandLight,
          selectionColor: Color(0x66FF6B00),
          selectionHandleColor: brand,
        ),
        popupMenuTheme: PopupMenuThemeData(
          color: surface,
          surfaceTintColor: Colors.transparent,
          elevation: 8,
          textStyle: const TextStyle(color: Colors.white, fontSize: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: const BorderSide(color: outline),
          ),
        ),
        expansionTileTheme: ExpansionTileThemeData(
          backgroundColor: surface,
          collapsedBackgroundColor: surface,
          iconColor: brandLight,
          collapsedIconColor: mutedText,
          textColor: Colors.white,
          collapsedTextColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: outline),
          ),
          collapsedShape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: outline),
          ),
        ),
      ),
      builder: (context, child) {
        final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
        return Stack(
          fit: StackFit.expand,
          children: [
            ?child,
            if (keyboardInset > 0)
              Positioned(
                left: 12,
                bottom: keyboardInset + 8,
                child: Material(
                  color: raisedSurface,
                  shape: const CircleBorder(
                    side: BorderSide(color: outline),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: IconButton(
                    tooltip: 'Klavyeyi kapat',
                    onPressed: () =>
                        FocusManager.instance.primaryFocus?.unfocus(),
                    icon: const Icon(Icons.keyboard_hide_rounded),
                    color: Colors.white,
                  ),
                ),
              ),
          ],
        );
      },
      home: const MainWrapper(),
    );
  }
}
