import 'dart:math';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

import 'firebase_client.dart';

/// Supplies the device's platform push token (`C-008`).
///
/// The notification service addresses this token when a generation the reader
/// is waiting on completes, so the client only ever sends the token and its
/// platform — nothing about the reader or the word.
abstract interface class PushTokenProvider {
  /// The current token, or null when none is available (permission not granted,
  /// or no messaging service is configured).
  Future<String?> token();
}

/// The platform messaging service the token is issued by.
///
/// A narrow seam over the platform client, so the provider's permission and
/// failure handling is exercisable without a platform channel.
abstract interface class PushMessaging {
  /// Prompts the reader for notification permission and reports whether they
  /// allow the app to show notifications. On Android this raises the system
  /// permission dialog from API 33; elsewhere the OS answers it.
  Future<bool> requestPermission();

  /// The device's current messaging token, or null when the service has none.
  Future<String?> currentToken();
}

/// The Firebase Cloud Messaging client (`D-005`).
class FirebaseMessagingAdapter implements PushMessaging {
  FirebaseMessagingAdapter({FirebaseMessaging? messaging})
    : _messaging = messaging ?? FirebaseMessaging.instance;

  final FirebaseMessaging _messaging;

  @override
  Future<bool> requestPermission() async {
    final settings = await _messaging.requestPermission();
    return settings.authorizationStatus == AuthorizationStatus.authorized;
  }

  @override
  Future<String?> currentToken() => _messaging.getToken();
}

/// The production push token, issued by Firebase Cloud Messaging (`C-008`).
///
/// The token is fetched when the reader takes the notify offer, so the
/// permission prompt is raised at the moment the reader asks for the notice
/// rather than at startup. A refused permission, an unavailable messaging
/// service, or a platform error reads as no token: the app reports the notice
/// could not be set up rather than promising one that cannot be shown.
class FirebaseMessagingPushTokenProvider implements PushTokenProvider {
  FirebaseMessagingPushTokenProvider({
    PushMessaging? messagingOverride,
    Future<FirebaseApp> Function()? initialize,
  }) : _messaging = messagingOverride,
       _initialize = initialize ?? initializeFirebaseClient;

  PushMessaging? _messaging;
  final Future<FirebaseApp> Function() _initialize;

  @override
  Future<String?> token() async {
    try {
      final messaging = await _messagingInstance();
      if (!await messaging.requestPermission()) return null;
      final token = await messaging.currentToken();
      return (token == null || token.isEmpty) ? null : token;
    } on Object {
      // No messaging service on the build, or the platform refused the request.
      // The reader loses nothing but the offer.
      return null;
    }
  }

  Future<PushMessaging> _messagingInstance() async {
    final existing = _messaging;
    if (existing != null) return existing;
    await _initialize();
    return _messaging = FirebaseMessagingAdapter();
  }
}

/// A stable, pseudonymous device token for development and tests.
///
/// The subject is scoped to the app instance and carries nothing about the
/// reader, mirroring the anonymous identity the lookup path presents outside
/// production.
class DevelopmentPushTokenProvider implements PushTokenProvider {
  DevelopmentPushTokenProvider({String? token}) : _token = token ?? _newToken();

  final String _token;

  @override
  Future<String?> token() async => _token;

  static String _newToken() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    final hex = bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    return 'dev-push:$hex';
  }
}
