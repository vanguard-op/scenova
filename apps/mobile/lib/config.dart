import 'package:flutter/foundation.dart';

/// Build-time configuration and product timings.
///
/// Nothing here is a design value; design values live in `lib/theme/`.
abstract final class AppConfig {
  /// The gateway base URL.
  static const String apiBaseUrl = String.fromEnvironment(
    'SCENOVA_API_BASE_URL',
    defaultValue: 'http://localhost:8080',
  );

  /// The lookup endpoint is not live yet, so the app runs on scripted data that
  /// speaks the frozen contract. Flip with `--dart-define=SCENOVA_USE_MOCK=false`.
  static const bool useMockLookupApi = bool.fromEnvironment(
    'SCENOVA_USE_MOCK',
    defaultValue: true,
  );

  /// The event intake is not live yet, so the app records events in memory
  /// rather than posting them. Flip with
  /// `--dart-define=SCENOVA_USE_MOCK_ANALYTICS=false`.
  static const bool useMockAnalyticsApi = bool.fromEnvironment(
    'SCENOVA_USE_MOCK_ANALYTICS',
    defaultValue: true,
  );

  /// The push-registrations intake (`C-008`) is not live yet, so the app records
  /// registrations in memory rather than posting them. Flip with
  /// `--dart-define=SCENOVA_USE_MOCK_PUSH=false`.
  static const bool useMockPushApi = bool.fromEnvironment(
    'SCENOVA_USE_MOCK_PUSH',
    defaultValue: true,
  );

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
