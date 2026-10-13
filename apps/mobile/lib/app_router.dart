import 'package:flutter/material.dart';

import 'models/analytics_event.dart';
import 'screens/clip_controller.dart';
import 'screens/clip_view_screen.dart';
import 'services/app_services.dart';
import 'services/capture_intake.dart';

/// The app's named destinations (`docs/Scenova/screens.md` → Navigation Map).
abstract final class AppRoutes {
  static const String home = '/home';
  static const String history = '/history';
  static const String preferences = '/preferences';
  static const String account = '/account';
}

/// A message the reader should see when a selection could not be looked up as
/// received.
@immutable
class CaptureNotice {
  const CaptureNotice(this.message);

  final String message;
}

/// Owns navigation for the entry gate.
///
/// A selection from the Android action or the iOS extension and a word typed on
/// Home both arrive here. A second selection while the clip view is open
/// updates it in place rather than stacking a second view
/// (`docs/Scenova/user-flow.md` → "Alternate Path E").
class AppRouter {
  AppRouter({required this.services});

  final ScenovaServices services;
  final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

  /// Raised on Home when a selection needed a correction.
  final ValueNotifier<CaptureNotice?> notice = ValueNotifier<CaptureNotice?>(
    null,
  );

  ClipViewController? _activeClip;

  /// The clip view controller when one is open.
  ClipViewController? get activeClip => _activeClip;

  /// Opens a selection from the entry field or a platform entry point.
  ///
  /// [source] records where it entered the app, for `lookup_started`.
  Future<void> openSelection(
    CaptureSelection selection, {
    LookupSource source = LookupSource.typed,
  }) async {
    final navigator = navigatorKey.currentState;
    if (navigator == null) return;

    if (selection.isEmpty) {
      // An empty selection opens an empty state and starts no lookup.
      navigator.popUntil((route) => route.isFirst);
      notice.value = const CaptureNotice(
        'Nothing to look up — type or paste a word.',
      );
      return;
    }

    if (selection.overLimit && selection.notice != null) {
      notice.value = CaptureNotice(selection.notice!);
    }

    final active = _activeClip;
    if (active != null) {
      await active.submit(selection);
      return;
    }

    final controller = ClipViewController(
      services: services,
      selection: selection,
      source: source,
    );
    _activeClip = controller;
    await navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => ClipViewScreen(
          controller: controller,
          onDismiss: dismissClip,
          onOpenHistory: openHistory,
        ),
      ),
    );
    _activeClip = null;
    controller.dispose();
  }

  /// The reader dismissed a clip view.
  void dismissClip() => navigatorKey.currentState?.maybePop();

  void openHistory() => _pushNamed(AppRoutes.history);

  void openPreferences() => _pushNamed(AppRoutes.preferences);

  void openAccount() => _pushNamed(AppRoutes.account);

  void clearNotice() => notice.value = null;

  void _pushNamed(String route) {
    navigatorKey.currentState?.pushNamed(route);
  }

  void dispose() {
    notice.dispose();
  }
}
