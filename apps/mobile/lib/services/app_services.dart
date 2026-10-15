import 'package:flutter/widgets.dart';

import '../config.dart';
import '../models/entitlement.dart';
import '../models/history_entry.dart';
import '../models/lookup.dart';
import 'analytics.dart';
import 'analytics_api.dart';
import 'capture_channel.dart';
import 'clip_notice_inbox.dart';
import 'clip_notice_source.dart';
import 'clip_store.dart';
import 'connectivity.dart';
import 'entitlement_provider.dart';
import 'feature_flags.dart';
import 'feedback_api.dart';
import 'feedback_outbox.dart';
import 'feedback_store.dart';
import 'history_store.dart';
import 'identity.dart';
import 'lookup_api.dart';
import 'poster_frame_store.dart';
import 'push_registration_api.dart';
import 'push_registrar.dart';
import 'push_tokens.dart';
import 'report_api.dart';
import 'report_outbox.dart';
import 'report_store.dart';
import 'reported_clip_store.dart';
import 'reported_clip_watch.dart';
import 'saved_clip_keeper.dart';
import 'settings_controller.dart';
import 'settings_store.dart';

/// The collaborators the presentation layer reads.
///
/// Screens take these from [ScenovaScope] rather than constructing them, so a
/// test can swap any one of them for a scripted stand-in.
class ScenovaServices {
  ScenovaServices({
    required this.lookupApi,
    required this.identity,
    required this.historyStore,
    required this.connectivity,
    required this.settings,
    required this.entitlements,
    required this.captureChannel,
    required this.analytics,
    required this.pushRegistrar,
    required this.clipNotices,
    required this.notificationPermission,
    required this.featureFlags,
    required this.feedbackOutbox,
    required this.reportOutbox,
    required this.reportedClips,
    required this.savedClips,
    required this.posterFrames,
    required this.clips,
    this.locale = 'en',
  });

  final LookupApi lookupApi;

  /// The reader's identity, presented on every lookup (`C-001`/`C-002` auth).
  final IdentityProvider identity;

  final HistoryStore historyStore;
  final ConnectivityMonitor connectivity;
  final SettingsController settings;
  final EntitlementProvider entitlements;
  final CaptureChannel captureChannel;

  /// Emits the product's events (`C-007`).
  final AnalyticsClient analytics;

  /// Registers the device for a clip-ready notice (`C-008`).
  final PushRegistrar pushRegistrar;

  /// The clip-ready notices that reach the device (`C-008`). The clip is
  /// obtained from the notice, played, and saved to device history.
  final ClipNoticeInbox clipNotices;

  /// The platform notification prompt (`FEAT-008`): raised when the reader takes
  /// the notify offer, and the route back to the device settings when they have
  /// refused it for good.
  final NotificationPermissionGate notificationPermission;

  /// The client-side release flags the build honours (`release.md`).
  final FeatureFlags featureFlags;

  /// Delivers the reader's clip ratings, holding them on the device until a
  /// connection returns (`C-012`, `FEAT-010`).
  final FeedbackOutbox feedbackOutbox;

  /// Delivers the reader's clip reports, holding them on the device until a
  /// connection returns (`C-013`, `FEAT-011`).
  final ReportOutbox reportOutbox;

  /// Registers the device for a reported clip's regenerated notice and replaces
  /// the reported clip with the one the notice delivers (`FEAT-009`,
  /// `FEAT-011`).
  final ReportedClipWatch reportedClips;

  /// Fetches a saved lookup's clip and derives its poster frame, keeping both on
  /// the device beside the entry (`FEAT-009`).
  final SavedClipKeeper savedClips;

  /// The poster frames kept beside the device history, one per saved lookup
  /// (`FEAT-009`). The History row draws its thumbnail from here.
  final PosterFrameStore posterFrames;

  /// The clips kept on the device, one per saved lookup, so a saved clip
  /// replays with no connection (`FEAT-009`).
  final ClipStore clips;

  /// The reader's locale, sent with a lookup.
  final String locale;

  /// The development wiring: scripted data that speaks the frozen contract,
  /// the device's own history, and a manual connectivity switch.
  factory ScenovaServices.development({
    String locale = 'en',
    Entitlement entitlement = Entitlement.unmeteredGuest,
    HistoryStore? historyStore,
    List<HistoryEntry> history = const <HistoryEntry>[],
    SettingsStore? settingsStore,
    FeatureFlags? featureFlags,
    PendingFeedbackStore? feedbackStore,
    PendingReportStore? reportStore,
    ReportedClipStore? reportedClipStore,
    PosterFrameStore? posterFrames,
    ClipStore? clips,
  }) {
    // The live intakes carry reader input over the network, so the gateway must
    // be reached over TLS (`NFR-022`). A build that points at a plaintext remote
    // host fails here rather than on the wire.
    final useLiveGateway =
        !AppConfig.useMockLookupApi ||
        !AppConfig.useMockAnalyticsApi ||
        !AppConfig.useMockPushApi ||
        !AppConfig.useMockFeedbackApi ||
        !AppConfig.useMockReportApi;
    if (useLiveGateway) AppConfig.ensureSecureGateway(AppConfig.apiBaseUrl);

    // The identity the lookup path presents: an anonymous Firebase ID token in
    // production, and the gateway's pseudonymous dev token on a laptop
    // (`C-001`/`C-002` auth; D-011).
    final identity = AppConfig.useFirebaseAuth
        ? FirebaseIdentity()
        : AnonymousIdentity();

    final connectivity = ManualConnectivity();
    final settings = SettingsController(
      onboardingComplete: !AppConfig.runOnboarding,
      // A fresh install has not enabled the platform entry point yet, so
      // Onboarding's enable step is shown; the platform sets this once the
      // action or extension is on.
      actionEnabled: false,
      store: settingsStore ?? SharedPreferencesSettingsStore(),
    );

    // The reader is asked for the notification permission only when they take
    // the notify offer, so the app never prompts at launch.
    const notificationPermission = PlatformNotificationPermission();

    final resolvedHistory = historyStore ?? InMemoryHistoryStore(seed: history);
    final resolvedClips = clips ?? DeviceClipStore();
    final resolvedPosters = posterFrames ?? DevicePosterFrameStore();
    final savedClips = SavedClipKeeper(
      history: resolvedHistory,
      clips: resolvedClips,
      posters: resolvedPosters,
    );
    // The clip-ready notice arrives through the platform's messaging service
    // in production; a laptop run drives the same intake by hand, so the
    // phrase path is exercisable without a push provider.
    final clipNotices = ClipNoticeInbox(
      source: AppConfig.useFirebaseMessaging
          ? FirebaseClipNoticeSource()
          : ScriptedClipNoticeSource(),
    );
    final pushRegistrar = PushRegistrar(
      api: AppConfig.useMockPushApi
          ? MockPushRegistrationApi()
          : HttpPushRegistrationApi(
              baseUrl: AppConfig.apiBaseUrl,
              idTokenProvider: identity.idToken,
            ),
      // The device token the notification service addresses (`C-008`): the
      // real Firebase Cloud Messaging token in production, and a pseudonymous
      // development token on a laptop, mirroring the identity above.
      tokens: AppConfig.useFirebaseMessaging
          ? FirebaseMessagingPushTokenProvider(
              permission: notificationPermission,
            )
          : DevelopmentPushTokenProvider(),
      connectivity: connectivity,
    );

    return ScenovaServices(
      lookupApi: AppConfig.useMockLookupApi
          ? MockLookupApi(latency: AppConfig.mockLatency)
          : HttpLookupApi(
              baseUrl: AppConfig.apiBaseUrl,
              idTokenProvider: identity.idToken,
              localeProvider: () => locale,
            ),
      identity: identity,
      historyStore: resolvedHistory,
      connectivity: connectivity,
      settings: settings,
      entitlements: FixedEntitlementProvider(entitlement),
      captureChannel: CaptureChannel(),
      analytics: AnalyticsClient(
        api: AppConfig.useMockAnalyticsApi
            ? MockAnalyticsApi()
            : HttpAnalyticsApi(
                baseUrl: AppConfig.apiBaseUrl,
                idTokenProvider: identity.idToken,
              ),
        settings: settings,
        connectivity: connectivity,
        anonymousId: newAnalyticsId(),
        appVersion: AppConfig.appVersion,
        locale: locale,
      ),
      pushRegistrar: pushRegistrar,
      clipNotices: clipNotices,
      notificationPermission: notificationPermission,
      featureFlags: featureFlags ?? RemoteConfigFeatureFlags(),
      feedbackOutbox: FeedbackOutbox(
        api: AppConfig.useMockFeedbackApi
            ? MockFeedbackApi(latency: AppConfig.mockLatency)
            : HttpFeedbackApi(
                baseUrl: AppConfig.apiBaseUrl,
                idTokenProvider: identity.idToken,
              ),
        store: feedbackStore ?? SharedPreferencesPendingFeedbackStore(),
        connectivity: connectivity,
      ),
      reportOutbox: ReportOutbox(
        api: AppConfig.useMockReportApi
            ? MockReportApi(latency: AppConfig.mockLatency)
            : HttpReportApi(
                baseUrl: AppConfig.apiBaseUrl,
                idTokenProvider: identity.idToken,
              ),
        store: reportStore ?? SharedPreferencesPendingReportStore(),
        connectivity: connectivity,
      ),
      reportedClips: ReportedClipWatch(
        history: resolvedHistory,
        savedClips: savedClips,
        store: reportedClipStore ?? SharedPreferencesReportedClipStore(),
        push: pushRegistrar,
        notices: clipNotices,
      ),
      savedClips: savedClips,
      posterFrames: resolvedPosters,
      clips: resolvedClips,
      locale: locale,
    );
  }

  void dispose() {
    connectivity.dispose();
    settings.dispose();
    captureChannel.dispose();
    analytics.dispose();
    reportedClips.dispose();
    pushRegistrar.dispose();
    clipNotices.dispose();
    feedbackOutbox.dispose();
    reportOutbox.dispose();
  }
}

/// Provides [ScenovaServices] to the widget tree.
class ScenovaScope extends InheritedWidget {
  const ScenovaScope({super.key, required this.services, required super.child});

  final ScenovaServices services;

  static ScenovaServices of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<ScenovaScope>();
    assert(scope != null, 'ScenovaScope is missing above this widget.');
    return scope!.services;
  }

  @override
  bool updateShouldNotify(ScenovaScope oldWidget) =>
      services != oldWidget.services;
}

/// A lookup that has been saved to device history, built from a result.
HistoryEntry historyEntryFrom(
  LookupResult result, {
  required DateTime savedAt,
  Sense? sense,
}) {
  final chosen = sense ?? (result.senses.isEmpty ? null : result.senses.first);
  return HistoryEntry(
    id: '${result.lookupId}-${chosen?.senseLabel ?? '0'}',
    word: result.displayWord,
    phrase: chosen?.glossPhrase ?? '',
    kind: result.kind,
    savedAt: savedAt,
    clipUrl: chosen?.clip?.url,
    hasAudio: chosen?.clip?.hasAudio ?? false,
    // The lookup the service issued, so a clip replayed from the device can
    // still be rated against the entry it came from (`C-012`).
    lookupId: result.lookupId,
  );
}
