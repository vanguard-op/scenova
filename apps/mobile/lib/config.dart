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
}
