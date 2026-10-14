import 'dart:math';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:permission_handler/permission_handler.dart' as permissions;

import 'firebase_client.dart';

/// The reader's answer to the notification prompt (`FEAT-008`), normalised
/// across platforms so the app reads one set of states.
enum NotificationPermission {
  /// The reader allows notifications, so a clip-ready notice can be shown.
  granted,

  /// The reader refused. The platform will ask again the next time they take
  /// the offer.
  denied,

  /// The reader refused and the platform will not ask again; the choice has to
  /// be changed in the device's settings.
  permanentlyDenied,
}

/// The platform's notification-permission prompt (`FEAT-008`).
///
/// A narrow seam over the platform permission package, so when the prompt is
/// raised, how its answer is read, and the route back to the device settings
/// are all exercisable without a device.
abstract interface class NotificationPermissionGate {
  /// Raises the platform's prompt when it can and reports the reader's answer.
  ///
  /// Called at the moment the reader takes the notify offer, never at launch,
  /// so the prompt arrives with the reader's own intent behind it.
  Future<NotificationPermission> request();

  /// The reader's answer as it stands, read without raising the prompt.
  ///
  /// A phrase clip has no delivery path but the notice, so the device is
  /// registered for it as soon as the phrase starts generating; this is how the
  /// client knows a notice can be shown without asking again.
  Future<NotificationPermission> current();

  /// Opens the app's page in the device settings, where a refused permission is
  /// changed. Reports whether the settings surface was opened.
  Future<bool> openSettings();
}

/// The platform notification prompt, backed by the permission package.
class PlatformNotificationPermission implements NotificationPermissionGate {
  const PlatformNotificationPermission();

  @override
  Future<NotificationPermission> request() async {
    final status = await permissions.Permission.notification.request();
    return _read(status);
  }

  @override
  Future<NotificationPermission> current() async =>
      _read(await permissions.Permission.notification.status);

  /// Reads the platform's answer in the app's own terms.
  NotificationPermission _read(permissions.PermissionStatus status) {
    // `provisional` and `limited` are quieter grants: the reader allows
    // notifications, so a notice can still be shown.
    if (status.isGranted || status.isProvisional || status.isLimited) {
      return NotificationPermission.granted;
    }
    // Android reports `permanentlyDenied` only after a second refusal, and iOS
    // reports it for any refusal once the prompt has been answered; both mean
    // the platform will not ask again, so the reader has to change it in the
    // settings. `restricted` (parental controls) is read the same way, since
    // the app cannot raise a prompt either.
    if (status.isPermanentlyDenied || status.isRestricted) {
      return NotificationPermission.permanentlyDenied;
    }
    return NotificationPermission.denied;
  }

  @override
  Future<bool> openSettings() => permissions.openAppSettings();
}

/// The platform messaging service the token is issued by.
///
/// A narrow seam over the platform client, so the provider's failure handling
/// is exercisable without a platform channel.
abstract interface class PushMessaging {
  /// The device's current messaging token, or null when the service has none.
  Future<String?> currentToken();
}

/// The Firebase Cloud Messaging client (`D-005`).
class FirebaseMessagingTokenSource implements PushMessaging {
  FirebaseMessagingTokenSource({FirebaseMessaging? messaging})
    : _messaging = messaging ?? FirebaseMessaging.instance;

  final FirebaseMessaging _messaging;

  @override
  Future<String?> currentToken() => _messaging.getToken();
}

/// What came of asking the device for a push token (`C-008`).
///
/// The reader's answer is kept apart from a missing token, so the app can tell
/// a refused permission from a device that has no messaging service. The two
/// need different words and a different next step: a refusal is not a
/// connectivity problem.
sealed class PushTokenOutcome {
  const PushTokenOutcome();
}

/// The platform issued a token; a notice can be addressed to this device.
final class PushTokenIssued extends PushTokenOutcome {
  const PushTokenIssued(this.token);

  final String token;
}

/// The reader refused notifications, so no notice can be shown.
final class PushTokenRefused extends PushTokenOutcome {
  const PushTokenRefused({required this.permanently});

  /// Whether the platform will not ask again, so the choice has to be changed
  /// in the device's settings.
  final bool permanently;
}

/// No token is available for another reason: no messaging service on the build,
/// or the platform call failed.
final class PushTokenUnavailable extends PushTokenOutcome {
  const PushTokenUnavailable();
}

/// Supplies the device's platform push token (`C-008`).
///
/// The notification service addresses this token when a generation the reader
/// is waiting on completes, so the client only ever sends the token and its
/// platform — nothing about the reader or the word.
abstract interface class PushTokenProvider {
  /// Asks the platform for a token, raising the notification prompt when the
  /// reader has not answered it yet.
  Future<PushTokenOutcome> request();

  /// The device's token when the reader has already allowed notifications.
  ///
  /// The prompt is not raised: this is how a phrase lookup, whose clip reaches
  /// the device only by the notice, is registered for it without asking the
  /// reader again. A reader who has not answered is reported as the refusal it
  /// is, and the notify offer raises the prompt when they take it.
  Future<PushTokenOutcome> current();
}

/// The production push token, issued by Firebase Cloud Messaging (`C-008`).
///
/// The token is fetched when the reader takes the notify offer, so the
/// permission prompt is raised at the moment the reader asks for the notice
/// rather than at startup. A refused permission is reported as a refusal, so
/// the app can tell the reader what actually happened; an unavailable messaging
/// service or a platform error reads as no token.
class FirebaseMessagingPushTokenProvider implements PushTokenProvider {
  FirebaseMessagingPushTokenProvider({
    NotificationPermissionGate? permission,
    PushMessaging? messagingOverride,
    Future<FirebaseApp> Function()? initialize,
  }) : _permission = permission ?? const PlatformNotificationPermission(),
       _messaging = messagingOverride,
       _initialize = initialize ?? initializeFirebaseClient;

  final NotificationPermissionGate _permission;
  PushMessaging? _messaging;
  final Future<FirebaseApp> Function() _initialize;

  @override
  Future<PushTokenOutcome> request() async {
    try {
      // The reader is asked before anything is taken from the messaging
      // service, so a refusal never costs a token request.
      switch (await _permission.request()) {
        case NotificationPermission.granted:
          break;
        case NotificationPermission.denied:
          return const PushTokenRefused(permanently: false);
        case NotificationPermission.permanentlyDenied:
          return const PushTokenRefused(permanently: true);
      }
      return await _token();
    } on Object {
      // No messaging service on the build, or the platform refused the request.
      // The reader loses nothing but the offer.
      return const PushTokenUnavailable();
    }
  }

  @override
  Future<PushTokenOutcome> current() async {
    try {
      switch (await _permission.current()) {
        case NotificationPermission.granted:
          break;
        case NotificationPermission.denied:
          return const PushTokenRefused(permanently: false);
        case NotificationPermission.permanentlyDenied:
          return const PushTokenRefused(permanently: true);
      }
      return await _token();
    } on Object {
      return const PushTokenUnavailable();
    }
  }

  Future<PushTokenOutcome> _token() async {
    final messaging = await _messagingInstance();
    final token = await messaging.currentToken();
    if (token == null || token.isEmpty) return const PushTokenUnavailable();
    return PushTokenIssued(token);
  }

  Future<PushMessaging> _messagingInstance() async {
    final existing = _messaging;
    if (existing != null) return existing;
    await _initialize();
    return _messaging = FirebaseMessagingTokenSource();
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
  Future<PushTokenOutcome> request() async => PushTokenIssued(_token);

  @override
  Future<PushTokenOutcome> current() async => PushTokenIssued(_token);

  static String _newToken() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    final hex = bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    return 'dev-push:$hex';
  }
}
