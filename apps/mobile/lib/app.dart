import 'dart:async';

import 'package:flutter/material.dart';

import 'app_router.dart';
import 'models/analytics_event.dart';
import 'models/lookup.dart';
import 'screens/clip_action_screen.dart';
import 'screens/home_screen.dart';
import 'screens/onboarding_screen.dart';
import 'screens/placeholder_screen.dart';
import 'services/app_services.dart';
import 'services/capture_channel.dart';
import 'theme/app_theme.dart';
import 'theme/tokens.dart';

/// The app shell: theme resolution, the navigation map, and the entry gate.
///
/// The theme is rebuilt when the device class changes (the 600px breakpoint) or
/// the platform brightness changes, and the platform reduce-motion setting is
/// pushed into the reader's settings so the clip view can hold on a still
/// frame. The landing surface is the in-place clip view when the Android
/// selection action launched the process; otherwise Onboarding until setup is
/// stored, then Home.
class ScenovaApp extends StatefulWidget {
  const ScenovaApp({
    super.key,
    required this.services,
    this.entryPoint = CaptureEntryPoint.app,
  });

  final ScenovaServices services;

  /// Where the process was entered from. The action entry shows only the clip,
  /// over the reading app; every other entry shows the app.
  final CaptureEntryPoint entryPoint;

  @override
  State<ScenovaApp> createState() => _ScenovaAppState();
}

class _ScenovaAppState extends State<ScenovaApp> with WidgetsBindingObserver {
  late final AppRouter _router = AppRouter(services: widget.services);
  late DeviceClass _deviceClass = _resolveDeviceClass();

  /// Whether the app has been out of the foreground since it launched.
  ///
  /// The open recorded on launch is the app's first foregrounding. Android
  /// pauses and resumes the activity around an intent it delivers to an
  /// activity already in the foreground, and the selection action's entry
  /// rebuilds the activity to be the in-place card, so one warm entry reports
  /// the same foregrounding twice: a resume from before the rebuild and the
  /// rebuilt app's own launch. A resume counts as a foregrounding of its own
  /// only once the app has actually been out of the foreground in between
  /// (`EVT-001`).
  bool _wasBackgrounded = false;

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
    switch (state) {
      case AppLifecycleState.resumed:
        // A resume is a foregrounding of its own only once the app has left the
        // foreground; the pause and resume around a delivered intent is not.
        if (_wasBackgrounded) {
          _wasBackgrounded = false;
          widget.services.analytics.appOpened(source: AppOpenSource.resume);
        }
        unawaited(widget.services.analytics.flush());
        // A kill switch disabled while the app was backgrounded takes effect on
        // the next lookup rather than the next release.
        unawaited(widget.services.featureFlags.refresh());
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        _wasBackgrounded = true;
        // Deliver what has been recorded before the app may be stopped.
        unawaited(widget.services.analytics.flush());
      case AppLifecycleState.inactive:
        // Losing focus without leaving the screen — a permission prompt, the
        // notification shade — leaves the app in the foreground.
        break;
    }
  }

  void _listenForCaptures() {
    // The in-place action surface owns the selection stream: there is no Home
    // behind it to route from and the clip is the whole surface.
    if (widget.entryPoint == CaptureEntryPoint.selectionAction) return;
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

  /// The process launched from the Android selection action opens the clip in
  /// place over the reading app; every other launch opens the app, on Onboarding
  /// until setup is stored and Home after
  /// (`docs/Scenova/screens.md` → Navigation Map).
  Widget get _landing {
    if (widget.entryPoint == CaptureEntryPoint.selectionAction) {
      return ClipActionScreen(services: widget.services);
    }
    return widget.services.settings.onboardingComplete
        ? HomeScreen(router: _router)
        : OnboardingScreen(onComplete: _finishOnboarding);
  }

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
