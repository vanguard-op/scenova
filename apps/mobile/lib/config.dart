import 'package:flutter/foundation.dart';

/// Build-time configuration and product timings.
///
/// Nothing here is a design value; design values live in `lib/theme/`.
abstract final class AppConfig {
  /// The gateway URL a build was configured with, or empty when it set none.
  ///
  /// A real environment supplies this with
  /// `--dart-define=SCENOVA_API_BASE_URL=https://…`, and [apiBaseUrl] then uses
  /// it unchanged.
  static const String configuredApiBaseUrl = String.fromEnvironment(
    'SCENOVA_API_BASE_URL',
  );

  /// The base URL the client sends reader input to.
  ///
  /// A configured [configuredApiBaseUrl] wins. Otherwise the default addresses
  /// the local stack the `Makefile` boots, on the host that reaches the
  /// reader's own machine: `localhost` from a desktop or the iOS simulator, and
  /// the Android emulator's alias for the host's loopback (`10.0.2.2`), because
  /// inside the emulator `localhost` names the emulator itself. That stack is
  /// plaintext; [isSecureGateway] confines plaintext to hosts of this kind, so
  /// a build pointed at a remote gateway still carries the reader's selection
  /// over TLS (`NFR-022`).
  static String get apiBaseUrl => configuredApiBaseUrl.isNotEmpty
      ? configuredApiBaseUrl
      : defaultTargetPlatform == TargetPlatform.android
      ? 'http://10.0.2.2:8080'
      : 'http://localhost:8080';

  /// The lookup service (`C-001`/`C-002`).
  ///
  /// The app talks to the live stack by default. Scripted data that speaks the
  /// same frozen contract is opt-in for the preview gallery and tests with
  /// `--dart-define=SCENOVA_USE_MOCK=true`.
  static const bool useMockLookupApi = bool.fromEnvironment(
    'SCENOVA_USE_MOCK',
    defaultValue: false,
  );

  /// The event intake (`C-007`). Live by default; opt into the recording intake
  /// with `--dart-define=SCENOVA_USE_MOCK_ANALYTICS=true`.
  static const bool useMockAnalyticsApi = bool.fromEnvironment(
    'SCENOVA_USE_MOCK_ANALYTICS',
    defaultValue: false,
  );

  /// The push-registrations intake (`C-008`). Live by default; opt into the
  /// recording intake with `--dart-define=SCENOVA_USE_MOCK_PUSH=true`.
  static const bool useMockPushApi = bool.fromEnvironment(
    'SCENOVA_USE_MOCK_PUSH',
    defaultValue: false,
  );

  /// The feedback intake (`C-012`). Live by default; opt into the recording
  /// intake with `--dart-define=SCENOVA_USE_MOCK_FEEDBACK=true`.
  static const bool useMockFeedbackApi = bool.fromEnvironment(
    'SCENOVA_USE_MOCK_FEEDBACK',
    defaultValue: false,
  );

  /// The report intake (`C-013`). Live by default; opt into the recording intake
  /// with `--dart-define=SCENOVA_USE_MOCK_REPORT=true`.
  static const bool useMockReportApi = bool.fromEnvironment(
    'SCENOVA_USE_MOCK_REPORT',
    defaultValue: false,
  );

  /// The entitlement read (`C-018`). Live by default; opt into the scripted
  /// plan with `--dart-define=SCENOVA_USE_MOCK_ENTITLEMENT=true`, so the
  /// Account screen's states can be viewed before the service is reachable.
  static const bool useMockEntitlementApi = bool.fromEnvironment(
    'SCENOVA_USE_MOCK_ENTITLEMENT',
    defaultValue: false,
  );

  /// The hosts that resolve to the developer's own machine, where the local
  /// stack runs over plaintext. `10.0.2.2` is the Android emulator's alias for
  /// the host's loopback interface, so it reaches the same machine as
  /// `localhost` does from a desktop.
  static const Set<String> _localDevelopmentHosts = <String>{
    'localhost',
    '127.0.0.1',
    '::1',
    '10.0.2.2',
  };

  /// Whether [url] may carry reader input — a lookup, an event batch, or a push
  /// registration (`NFR-022`, no mixed content).
  ///
  /// `https` is always accepted. `http` is accepted only for a local
  /// development host ([_localDevelopmentHosts]); every other plaintext host is
  /// refused.
  static bool isSecureGateway(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) return false;
    return switch (uri.scheme) {
      'https' => true,
      'http' => _localDevelopmentHosts.contains(uri.host),
      _ => false,
    };
  }

  /// Refuses a gateway URL that would send reader input in the clear.
  ///
  /// Thrown at wiring time so a misconfigured build fails where the cause is
  /// visible, rather than reaching the network unprotected.
  static void ensureSecureGateway(String url) {
    if (isSecureGateway(url)) return;
    throw ArgumentError.value(
      url,
      'SCENOVA_API_BASE_URL',
      'The live gateway must be reached over https (NFR-022).',
    );
  }

  /// The app version reported on every event (`C-007`, `appVersion`).
  ///
  /// It mirrors the build's version; wiring it to the platform's package info is
  /// a later seam.
  static const String appVersion = String.fromEnvironment(
    'SCENOVA_APP_VERSION',
    defaultValue: '1.0.0+1',
  );

  /// The contract's batch cap for the event intake (`C-007`, at most fifty).
  static const int analyticsBatchSize = 50;

  /// How many queued events trigger a send, so a busy session does not hold
  /// events until it backgrounds.
  static const int analyticsFlushThreshold = 20;

  /// A bound on the offline queue, so a long offline stretch cannot grow it
  /// without limit. This is backpressure, not sampling.
  static const int analyticsQueueLimit = 500;

  /// A bound on the ratings the device holds for the feedback intake, so a long
  /// offline stretch cannot grow the queue without limit. The reader's latest
  /// rating of a clip is the one that counts, so the bound costs nothing the
  /// reader would miss (`C-012`).
  static const int feedbackQueueLimit = 100;

  /// A bound on the reports the device holds for the report intake, so a long
  /// offline stretch cannot grow the queue without limit. One reader reports a
  /// given clip once, so the bound costs nothing the reader would miss
  /// (`C-013`).
  static const int reportQueueLimit = 100;

  /// The contract's cap on a report's note (`C-013`, at most 300 characters).
  static const int reportNoteMaxLength = 300;

  /// How the lookup path authenticates (`C-001`/`C-002` auth).
  ///
  /// `dev` presents the pseudonymous `dev:<subject>` token the gateway's own
  /// verifier accepts outside production; `firebase` presents an anonymous
  /// Firebase ID token, upgraded to the reader's account at sign-in (D-011).
  /// A release build defaults to Firebase; a debug build to the local verifier,
  /// so the live path is authenticated on a laptop before a Firebase project is
  /// wired to the client.
  static const String authMode = String.fromEnvironment('SCENOVA_AUTH_MODE');

  /// Whether the lookup path authenticates through Firebase.
  static bool get useFirebaseAuth =>
      authMode == 'firebase' || (authMode.isEmpty && kReleaseMode);

  /// How the device's push token is obtained (`C-008`).
  ///
  /// `dev` mints a pseudonymous token for a laptop run; `firebase` takes the
  /// real device token from the platform's messaging service (D-005). A release
  /// build defaults to Firebase; a debug build to the development provider, so
  /// a laptop run needs no messaging service.
  static const String pushMode = String.fromEnvironment('SCENOVA_PUSH_MODE');

  /// Whether the push token comes from Firebase Cloud Messaging.
  static bool get useFirebaseMessaging =>
      pushMode == 'firebase' || (pushMode.isEmpty && kReleaseMode);

  /// Whether the in-context clip view is shown before a runtime flag value has
  /// been fetched (`enable_clip_view`).
  ///
  /// `release.md` starts the flag Off for its dark launch, but the Reading Loop
  /// phase has rolled it out to the Internal audience and every environment sets
  /// it on. The client's fallback matches that rolled-out state, so a fetch that
  /// has not landed keeps the shipped feature working; the kill switch is a
  /// Remote Config value of `false`. A local run can force the fallback with
  /// `--dart-define=SCENOVA_CLIP_VIEW=false`.
  static const bool clipViewEnabledByDefault = bool.fromEnvironment(
    'SCENOVA_CLIP_VIEW',
    defaultValue: true,
  );

  /// Whether saved clips replay with no connection before a runtime flag value
  /// has been fetched (`enable_offline_history`).
  ///
  /// `release.md` starts the flag Off for its dark launch, but the Trust and
  /// Continuity phase has rolled it out to the Beta audience and every
  /// environment sets it on. The client's fallback matches that rolled-out
  /// state, so a fetch that has not landed keeps offline replay working; the
  /// kill switch is a Remote Config value of `false`. A local run can force the
  /// fallback with `--dart-define=SCENOVA_OFFLINE_HISTORY=false`.
  static const bool offlineHistoryEnabledByDefault = bool.fromEnvironment(
    'SCENOVA_OFFLINE_HISTORY',
    defaultValue: true,
  );

  /// Whether the paid tier is live before a runtime flag value has been fetched
  /// (`enable_paid_tier`).
  ///
  /// `release.md` starts the flag Off for its dark launch, but the paid tier is
  /// the Polish and Account phase's own deliverable and its rollout is under
  /// way. Following the convention of the two flags above, the client's fallback
  /// matches that rolled-out state so a fetch that has not landed keeps the
  /// Paywall working; the kill switch is a Remote Config value of `false`, which
  /// reverts every reader to Free and hides the Paywall. A local run can force
  /// the fallback with `--dart-define=SCENOVA_PAID_TIER=false`.
  static const bool paidTierEnabledByDefault = bool.fromEnvironment(
    'SCENOVA_PAID_TIER',
    defaultValue: true,
  );

  /// How long a Remote Config fetch may take before it is abandoned.
  static const Duration remoteConfigFetchTimeout = Duration(seconds: 10);

  /// The shortest gap between Remote Config fetches.
  ///
  /// A kill switch has to reach a running client inside the release's
  /// thirty-minute recovery target, so Remote Config's twelve-hour default cache
  /// is too coarse; a shorter window lets a disable land while staying inside
  /// the source's throttle.
  static const Duration remoteConfigFetchInterval = Duration(minutes: 15);

  /// The wait after which the reader is told a clip is still being made and
  /// offered a notification when it is ready.
  static const Duration generatingNoticeThreshold = Duration(seconds: 10);

  /// How often the clip view re-asks for a lookup that is still generating.
  static const Duration lookupPollInterval = Duration(seconds: 3);

  /// When polling stops. A lookup left generating past this is reported as a
  /// failure with a retry.
  static const Duration lookupPollTimeout = Duration(minutes: 5);

  /// The clip cap, used when a clip arrives without a usable duration.
  static const Duration clipDurationFallback = Duration(seconds: 4);

  /// How long a lookup request may take before it is treated as a failure.
  static const Duration requestTimeout = Duration(seconds: 20);

  /// The latency the scripted lookup service simulates, so the loading state
  /// is visible in development.
  static const Duration mockLatency = Duration(milliseconds: 350);

  /// Whether the development build seeds a few lookups so Home's loaded state
  /// is visible. Turn it off to view the empty state.
  static const bool seedHistory = bool.fromEnvironment(
    'SCENOVA_SEED_HISTORY',
    defaultValue: true,
  );

  /// Whether the app opens on Onboarding.
  ///
  /// First launch is the product's onboarding by rule; the flag exists so a
  /// development run can boot straight into Home once it has seen the flow.
  /// Flip with `--dart-define=SCENOVA_ONBOARDING=false`.
  static const bool runOnboarding = bool.fromEnvironment(
    'SCENOVA_ONBOARDING',
    defaultValue: true,
  );
}
