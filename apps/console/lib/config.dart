import 'package:flutter/foundation.dart';

/// Build-time configuration for the review console.
///
/// Nothing here is a design value; design values live in `lib/theme/`. The
/// values come from `--dart-define` at build time (`.env` locally, the deploy
/// script in the cloud), so the same build command describes the same console
/// everywhere.
abstract final class ConsoleConfig {
  /// The gateway URL the console calls for the review endpoints (`C-014`).
  ///
  /// Empty means same origin: on Firebase Hosting the `/internal/review/**`
  /// rewrite sends those requests to the gateway, so the console needs no base
  /// and no CORS. A local run sets this to the gateway `make boot` starts.
  static const String configuredReviewApiBaseUrl = String.fromEnvironment(
    'CONSOLE_REVIEW_API_BASE_URL',
  );

  /// The gateway base, or empty for the console's own origin.
  static String get reviewApiBaseUrl => configuredReviewApiBaseUrl;

  /// The Firebase project the operator authenticates against.
  ///
  /// It must equal the project the services verify ID tokens against
  /// (`.env.example`, `ci/checks/env_schema.sh`); a mismatch would have the
  /// console mint tokens the gateway refuses.
  static const String firebaseProjectId = String.fromEnvironment(
    'CONSOLE_FIREBASE_PROJECT_ID',
  );

  static const String firebaseAuthDomain = String.fromEnvironment(
    'CONSOLE_FIREBASE_AUTH_DOMAIN',
  );

  static const String firebaseApiKey = String.fromEnvironment(
    'CONSOLE_FIREBASE_API_KEY',
  );

  static const String firebaseAppId = String.fromEnvironment(
    'CONSOLE_FIREBASE_APP_ID',
  );

  static const String firebaseMessagingSenderId = String.fromEnvironment(
    'CONSOLE_FIREBASE_MESSAGING_SENDER_ID',
  );

  /// Whether the build carries a complete Firebase client configuration.
  ///
  /// When it does not, the console takes the configuration from Hosting's
  /// `/__/firebase/init.json` at runtime, which `firebase_core` reads when it
  /// is initialised with no options.
  static bool get hasFirebaseClientConfig =>
      firebaseProjectId.isNotEmpty && firebaseApiKey.isNotEmpty;

  /// How the operator session authenticates (`C-014` auth).
  ///
  /// `firebase` signs in through the identity provider and requires a
  /// multi-factor session. `dev` mints the pseudonymous `dev:curator:mfa:<id>`
  /// token the gateway's own verifier accepts outside production, so a laptop
  /// run reaches the queue before a Firebase project is wired to the console.
  /// A release build defaults to Firebase; a debug build to the local verifier.
  static const String authMode = String.fromEnvironment('CONSOLE_AUTH_MODE');

  /// Whether the operator session authenticates through Firebase.
  static bool get useFirebaseAuth =>
      authMode == 'firebase' || (authMode.isEmpty && kReleaseMode);

  /// The review endpoints (`C-014`). Live by default; opt into the scripted
  /// service with `--dart-define=CONSOLE_USE_MOCK=true`, so every queue state
  /// can be viewed before the endpoint is reachable.
  static const bool useMockReviewApi = bool.fromEnvironment(
    'CONSOLE_USE_MOCK',
    defaultValue: false,
  );

  /// How long a review request may take before it is treated as a failure.
  static const Duration requestTimeout = Duration(seconds: 20);

  /// How long the word filter waits after the last keystroke before it asks
  /// the service again, so a typed word costs one request rather than one per
  /// letter.
  static const Duration wordFilterDebounce = Duration(milliseconds: 300);

  /// The hosts that resolve to the developer's own machine, where the local
  /// stack runs over plaintext.
  static const Set<String> _localDevelopmentHosts = <String>{
    'localhost',
    '127.0.0.1',
    '::1',
  };

  /// Whether [url] may carry the operator's token (`NFR-022`, no mixed
  /// content). `https` is always accepted; `http` only for a local development
  /// host.
  static bool isSecureApi(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) return false;
    return switch (uri.scheme) {
      'https' => true,
      'http' => _localDevelopmentHosts.contains(uri.host),
      _ => false,
    };
  }

  /// Refuses a gateway URL that would send the operator's token in the clear.
  ///
  /// Thrown at wiring time so a misconfigured build fails where the cause is
  /// visible, rather than reaching the network unprotected.
  static void ensureSecureApi(String url) {
    if (url.isEmpty || isSecureApi(url)) return;
    throw ArgumentError.value(
      url,
      'CONSOLE_REVIEW_API_BASE_URL',
      'The live gateway must be reached over https (NFR-022).',
    );
  }

  /// The scripted latency the mock review service simulates, so the loading
  /// state is visible in development.
  static const Duration mockLatency = Duration(milliseconds: 350);
}
