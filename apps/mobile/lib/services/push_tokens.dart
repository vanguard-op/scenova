import 'dart:math';

/// Supplies the device's platform push token (`C-008`).
///
/// The notification service addresses this token when a generation the reader
/// is waiting on completes, so the client only ever sends the token and its
/// platform — nothing about the reader or the word.
///
/// The production source is the platform's messaging service (FCM on Android,
/// APNs on iOS) through `firebase_messaging`, which needs the Firebase project
/// files and the APNs entitlement on the build. That platform configuration is
/// not in the build yet, so this interface is the seam the app swaps behind and
/// the development provider below stands in until it lands.
abstract interface class PushTokenProvider {
  /// The current token, or null when none is available (permission not granted,
  /// or no messaging service is configured).
  Future<String?> token();
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
