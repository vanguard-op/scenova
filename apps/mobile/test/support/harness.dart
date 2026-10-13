import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scenova/app_router.dart';
import 'package:scenova/models/entitlement.dart';
import 'package:scenova/models/history_entry.dart';
import 'package:scenova/models/lookup.dart';
import 'package:scenova/screens/clip_controller.dart';
import 'package:scenova/screens/clip_view_screen.dart';
import 'package:scenova/screens/home_screen.dart';
import 'package:scenova/services/app_services.dart';
import 'package:scenova/services/capture_channel.dart';
import 'package:scenova/services/connectivity.dart';
import 'package:scenova/services/entitlement_provider.dart';
import 'package:scenova/services/history_store.dart';
import 'package:scenova/services/lookup_api.dart';
import 'package:scenova/services/settings_controller.dart';
import 'package:scenova/theme/app_theme.dart';
import 'package:scenova/theme/tokens.dart';

/// The collaborators a test hands to a screen.
ScenovaServices buildServices({
  LookupApi? api,
  HistoryStore? history,
  bool online = true,
  SettingsController? settings,
  Entitlement entitlement = Entitlement.unmeteredGuest,
  String locale = 'en',
}) {
  return ScenovaServices(
    lookupApi: api ?? MockLookupApi(),
    historyStore: history ?? InMemoryHistoryStore(),
    connectivity: ManualConnectivity(online: online),
    settings: settings ?? SettingsController(),
    entitlements: FixedEntitlementProvider(entitlement),
    captureChannel: CaptureChannel(),
    locale: locale,
  );
}

/// Builds the app under a test: the real theme, the real Home, and a router the
/// test drives the way a platform entry point would.
class Harness {
  Harness(this.services, this.router);

  final ScenovaServices services;
  final AppRouter router;
}

Future<Harness> pumpHarness(
  WidgetTester tester, {
  LookupApi? api,
  HistoryStore? history,
  bool online = true,
  SettingsController? settings,
  Entitlement entitlement = Entitlement.unmeteredGuest,
}) async {
  final services = buildServices(
    api: api,
    history: history,
    online: online,
    settings: settings,
    entitlement: entitlement,
  );
  final router = AppRouter(services: services);
  await tester.pumpWidget(
    ScenovaScope(
      services: services,
      child: MaterialApp(
        navigatorKey: router.navigatorKey,
        theme: AppTheme.build(
          brightness: Brightness.light,
          deviceClass: DeviceClass.mobile,
        ),
        home: HomeScreen(router: router),
      ),
    ),
  );
  return Harness(services, router);
}

/// Builds the clip view on its own so a test controls the lookup timing.
Future<void> pumpClipView(
  WidgetTester tester,
  ScenovaServices services,
  ClipViewController controller, {
  VoidCallback? onDismiss,
  VoidCallback? onOpenHistory,
}) {
  return tester.pumpWidget(
    ScenovaScope(
      services: services,
      child: MaterialApp(
        theme: AppTheme.build(
          brightness: Brightness.light,
          deviceClass: DeviceClass.mobile,
        ),
        home: ClipViewScreen(
          controller: controller,
          onDismiss: onDismiss,
          onOpenHistory: onOpenHistory,
        ),
      ),
    ),
  );
}

/// Tears the tree down so no controller, ticker, or timer outlives the test.
Future<void> teardown(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
}

/// Delivers a selection the way the Android action or the iOS extension does.
Future<void> deliverCapture(WidgetTester tester, String? text) async {
  const codec = StandardMethodCodec();
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    CaptureChannel.channelName,
    codec.encodeMethodCall(
      MethodCall(CaptureChannel.methodCapture, <String, Object?>{'text': text}),
    ),
    (_) {},
  );
}

/// A history whose read resolves only when the test completes it.
class DelayedHistoryStore implements HistoryStore {
  final Completer<List<HistoryEntry>> completer =
      Completer<List<HistoryEntry>>();

  @override
  Future<List<HistoryEntry>> all() => completer.future;

  @override
  Future<List<HistoryEntry>> recent({int limit = 5}) => completer.future;

  @override
  Future<void> save(HistoryEntry entry) async {}

  @override
  Future<void> remove(String id) async {}

  @override
  Future<void> clear() async {}
}

/// A history that fails to read, for the error state.
class ThrowingHistoryStore implements HistoryStore {
  const ThrowingHistoryStore();

  @override
  Future<List<HistoryEntry>> all() async => throw StateError('unreadable');

  @override
  Future<List<HistoryEntry>> recent({int limit = 5}) async =>
      throw StateError('unreadable');

  @override
  Future<void> save(HistoryEntry entry) async {}

  @override
  Future<void> remove(String id) async {}

  @override
  Future<void> clear() async {}
}

/// A lookup service that holds its first response open, for the loading state.
class DelayedLookupApi implements LookupApi {
  final Completer<LookupResult> completer = Completer<LookupResult>();

  @override
  Future<LookupResult> createLookup(LookupRequest request) => completer.future;

  @override
  Future<LookupResult> getLookup(String lookupId) => completer.future;
}

/// A lookup service that fails, for the error and retry states.
class ThrowingLookupApi implements LookupApi {
  ThrowingLookupApi(this.error);

  final LookupApiException error;

  @override
  Future<LookupResult> createLookup(LookupRequest request) async => throw error;

  @override
  Future<LookupResult> getLookup(String lookupId) async => throw error;
}

/// A saved lookup, for seeding history.
HistoryEntry seededEntry({
  required String word,
  required String phrase,
  String? clipUrl,
  bool hasAudio = false,
  Duration age = const Duration(minutes: 1),
}) {
  return HistoryEntry(
    id: 'seed-$word',
    word: word,
    phrase: phrase,
    kind: LookupKind.word,
    savedAt: DateTime.now().subtract(age),
    clipUrl: clipUrl,
    hasAudio: hasAudio,
  );
}
