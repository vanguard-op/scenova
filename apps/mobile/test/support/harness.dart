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
import 'package:scenova/screens/onboarding_screen.dart';
import 'package:scenova/services/analytics.dart';
import 'package:scenova/services/analytics_api.dart';
import 'package:scenova/services/app_services.dart';
import 'package:scenova/services/capture_channel.dart';
import 'package:scenova/services/clip_notice_inbox.dart';
import 'package:scenova/services/clip_notice_source.dart';
import 'package:scenova/services/connectivity.dart';
import 'package:scenova/services/entitlement_provider.dart';
import 'package:scenova/services/feature_flags.dart';
import 'package:scenova/services/history_store.dart';
import 'package:scenova/services/identity.dart';
import 'package:scenova/services/lookup_api.dart';
import 'package:scenova/services/push_registration_api.dart';
import 'package:scenova/services/push_registrar.dart';
import 'package:scenova/services/push_tokens.dart';
import 'package:scenova/services/settings_controller.dart';
import 'package:scenova/theme/app_theme.dart';
import 'package:scenova/theme/tokens.dart';
import 'package:scenova/widgets/app_icons.dart';

/// The collaborators a test hands to a screen.
ScenovaServices buildServices({
  LookupApi? api,
  HistoryStore? history,
  bool online = true,
  SettingsController? settings,
  Entitlement entitlement = Entitlement.unmeteredGuest,
  IdentityProvider? identity,
  AnalyticsApi? analyticsApi,
  PushRegistrationApi? pushApi,
  PushTokenProvider? pushTokens,
  NotificationPermissionGate? notificationPermission,
  ClipNoticeSource? clipNoticeSource,
  FeatureFlags? featureFlags,
  String locale = 'en',
}) {
  final connectivity = ManualConnectivity(online: online);
  final settingsController = settings ?? SettingsController();
  return ScenovaServices(
    lookupApi: api ?? MockLookupApi(),
    identity: identity ?? AnonymousIdentity(),
    historyStore: history ?? InMemoryHistoryStore(),
    connectivity: connectivity,
    settings: settingsController,
    entitlements: FixedEntitlementProvider(entitlement),
    captureChannel: CaptureChannel(),
    analytics: AnalyticsClient(
      api: analyticsApi ?? MockAnalyticsApi(),
      settings: settingsController,
      connectivity: connectivity,
      anonymousId: 'test-anonymous',
      appVersion: 'test',
      locale: locale,
    ),
    pushRegistrar: PushRegistrar(
      api: pushApi ?? MockPushRegistrationApi(),
      tokens:
          pushTokens ?? DevelopmentPushTokenProvider(token: 'test-push-token'),
      connectivity: connectivity,
    ),
    clipNotices: ClipNoticeInbox(
      source: clipNoticeSource ?? ScriptedClipNoticeSource(),
    ),
    notificationPermission:
        notificationPermission ?? ScriptedNotificationPermission(),
    featureFlags: featureFlags ?? const FixedFeatureFlags(),
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
  FeatureFlags? featureFlags,
}) async {
  final services = buildServices(
    api: api,
    history: history,
    online: online,
    settings: settings,
    entitlement: entitlement,
    featureFlags: featureFlags,
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

/// Finds the widget drawing [icon], whether it is a custom-set glyph or a
/// system icon, so a test asserts the app's own icon and not the platform's.
Finder findIcon(AppIcon icon) => find.byWidgetPredicate(
  (widget) => widget is AppIconView && widget.icon == icon,
);

/// Sizes the test window to a phone so a mobile screen lays out as designed.
void usePhoneWindow(WidgetTester tester) {
  tester.view.physicalSize = const Size(400, 940);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// Builds the onboarding screen on its own with the real theme.
///
/// The shell owns the switch to Home, so a test reads completion from
/// [VoidCallback] it passes in and from the reader's stored settings.
Future<ScenovaServices> pumpOnboarding(
  WidgetTester tester, {
  SettingsController? settings,
  FeatureFlags? featureFlags,
  VoidCallback? onComplete,
}) async {
  usePhoneWindow(tester);
  final services = buildServices(
    settings: settings,
    featureFlags: featureFlags,
  );
  await tester.pumpWidget(
    ScenovaScope(
      services: services,
      child: MaterialApp(
        theme: AppTheme.build(
          brightness: Brightness.light,
          deviceClass: DeviceClass.mobile,
        ),
        home: OnboardingScreen(onComplete: onComplete ?? () {}),
      ),
    ),
  );
  await tester.pump();
  return services;
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

/// A notification prompt whose answer is scripted, and which records how many
/// times it was raised and how often the settings were opened.
class ScriptedNotificationPermission implements NotificationPermissionGate {
  ScriptedNotificationPermission({
    this.answer = NotificationPermission.granted,
    NotificationPermission? quietAnswer,
  }) : _currentAnswer = quietAnswer;

  NotificationPermission answer;

  /// The answer a query reads while the prompt is not raised, when it differs
  /// from what the prompt would say. Defaults to [answer].
  NotificationPermission? _currentAnswer;

  /// How many times the prompt was raised.
  int requests = 0;

  /// How many times the device settings were opened.
  int settingsOpened = 0;

  /// The answer a query reads while the prompt is not raised.
  NotificationPermission get currentAnswer => _currentAnswer ?? answer;

  set currentAnswer(NotificationPermission value) => _currentAnswer = value;

  @override
  Future<NotificationPermission> request() async {
    requests++;
    return answer;
  }

  @override
  Future<NotificationPermission> current() async => currentAnswer;

  @override
  Future<bool> openSettings() async {
    settingsOpened++;
    return true;
  }
}

/// A token source whose outcome is scripted, so the registrar and the screen can
/// be driven through a refusal without a messaging service.
class ScriptedPushTokenProvider implements PushTokenProvider {
  ScriptedPushTokenProvider(this.outcome, {PushTokenOutcome? quietOutcome})
    : _currentOutcome = quietOutcome;

  PushTokenOutcome outcome;

  /// The outcome a query reads while the prompt is not raised, when it differs
  /// from [outcome].
  PushTokenOutcome? _currentOutcome;

  /// How many times the prompt was raised.
  int requests = 0;

  /// The outcome a query reads while the prompt is not raised.
  PushTokenOutcome get currentOutcome => _currentOutcome ?? outcome;

  set currentOutcome(PushTokenOutcome value) => _currentOutcome = value;

  @override
  Future<PushTokenOutcome> request() async {
    requests++;
    return outcome;
  }

  @override
  Future<PushTokenOutcome> current() async => currentOutcome;
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

/// Wraps a lookup service and counts the lookups that reach it, so a test can
/// prove a clip was served from the device without a new generation.
class RecordingLookupApi implements LookupApi {
  RecordingLookupApi(this.delegate);

  final LookupApi delegate;
  int createCalls = 0;

  @override
  Future<LookupResult> createLookup(LookupRequest request) {
    createCalls++;
    return delegate.createLookup(request);
  }

  @override
  Future<LookupResult> getLookup(String lookupId) =>
      delegate.getLookup(lookupId);
}

/// A saved lookup, for seeding history.
HistoryEntry seededEntry({
  required String word,
  required String phrase,
  String? clipUrl,
  bool hasAudio = false,
  LookupKind kind = LookupKind.word,
  Duration age = const Duration(minutes: 1),
}) {
  return HistoryEntry(
    id: 'seed-$word',
    word: word,
    phrase: phrase,
    kind: kind,
    savedAt: DateTime.now().subtract(age),
    clipUrl: clipUrl,
    hasAudio: hasAudio,
  );
}
