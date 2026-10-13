import 'dart:async';

import 'package:flutter/material.dart';

import 'app_router.dart';
import 'models/analytics_event.dart';
import 'models/lookup.dart';
import 'screens/home_screen.dart';
import 'screens/onboarding_screen.dart';
import 'screens/placeholder_screen.dart';
import 'services/app_services.dart';
import 'theme/app_theme.dart';
import 'theme/tokens.dart';

/// The app shell: theme resolution, the navigation map, and the entry gate.
///
/// The theme is rebuilt when the device class changes (the 600px breakpoint) or
/// the platform brightness changes, and the platform reduce-motion setting is
/// pushed into the reader's settings so the clip view can hold on a still
/// frame. The landing surface is Onboarding until setup is stored, then Home.
class ScenovaApp extends StatefulWidget {
  const ScenovaApp({super.key, required this.services});

  final ScenovaServices services;

  @override
  State<ScenovaApp> createState() => _ScenovaAppState();
}

class _ScenovaAppState extends State<ScenovaApp> with WidgetsBindingObserver {
  late final AppRouter _router = AppRouter(services: widget.services);
  late DeviceClass _deviceClass = _resolveDeviceClass();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _syncPlatformAccessibility();
    _listenForCaptures();
    // The app is foregrounded at launch (`EVT-001`).
    widget.services.analytics.appOpened(source: AppOpenSource.launch);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _router.dispose();
    super.dispose();
  }

  @override
  void didChangeMetrics() => _refreshDeviceClass();

  @override
  void didChangeAccessibilityFeatures() => _syncPlatformAccessibility();

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      widget.services.analytics.appOpened(source: AppOpenSource.resume);
      unawaited(widget.services.analytics.flush());
      // A kill switch disabled while the app was backgrounded takes effect on
      // the next lookup rather than the next release.
      unawaited(widget.services.featureFlags.refresh());
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      // Deliver what has been recorded before the app may be stopped.
      unawaited(widget.services.analytics.flush());
    }
  }

  void _listenForCaptures() {
    widget.services.captureChannel.selections.listen((selection) {
      _router.openSelection(selection, source: _captureSource());
    });
    widget.services.captureChannel.start();
  }

  /// Where a platform selection entered the app.
  LookupSource _captureSource() =>
      LookupPlatform.current() == LookupPlatform.android
      ? LookupSource.androidAction
      : LookupSource.iosExtension;

  void _syncPlatformAccessibility() {
    widget.services.settings.platformReduceMotion = WidgetsBinding
        .instance
        .platformDispatcher
        .accessibilityFeatures
        .disableAnimations;
  }

  void _refreshDeviceClass() {
    final next = _resolveDeviceClass();
    if (next != _deviceClass) setState(() => _deviceClass = next);
  }

  /// Setup is stored; the shell opens Home from here on
  /// (`docs/Scenova/screens.md` → Navigation Map: Onboarding → Home).
  void _finishOnboarding() {
    if (!mounted) return;
    setState(() {});
  }

  /// First launch opens on Onboarding; Home takes over once setup is stored.
  Widget get _landing => widget.services.settings.onboardingComplete
      ? HomeScreen(router: _router)
      : OnboardingScreen(onComplete: _finishOnboarding);

  DeviceClass _resolveDeviceClass() {
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    return DeviceClass.fromWidth(
      view.physicalSize.width / view.devicePixelRatio,
    );
  }

  @override
  Widget build(BuildContext context) {
    return ScenovaScope(
      services: widget.services,
      child: MaterialApp(
        title: 'Scenova',
        debugShowCheckedModeBanner: false,
        navigatorKey: _router.navigatorKey,
        theme: AppTheme.build(
          brightness: Brightness.light,
          deviceClass: _deviceClass,
        ),
        darkTheme: AppTheme.build(
          brightness: Brightness.dark,
          deviceClass: _deviceClass,
        ),
        themeMode: ThemeMode.system,
        home: _landing,
        routes: <String, WidgetBuilder>{
          AppRoutes.history: (_) => const PlaceholderScreen(
            title: 'History',
            message:
                'Saved lookups and their clips appear here in a later phase.',
          ),
          AppRoutes.preferences: (_) => const PlaceholderScreen(
            title: 'Preferences',
            message:
                'Clip sound, reduce motion, the action label, and clearing '
                'history arrive in a later phase.',
          ),
          AppRoutes.account: (_) => const PlaceholderScreen(
            title: 'Account',
            message: 'Your plan and allowance arrive with the account phase.',
          ),
        },
      ),
    );
  }
}
