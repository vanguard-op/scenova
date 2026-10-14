import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler_platform_interface/permission_handler_platform_interface.dart';
import 'package:scenova/services/push_tokens.dart';

/// A platform messaging service whose token is scripted.
class _FakeMessaging implements PushMessaging {
  _FakeMessaging({this.value, this.fails = false});

  String? value;

  /// When true, asking for the token raises, as a missing messaging service or
  /// a platform error would.
  bool fails;

  final List<String> calls = <String>[];

  @override
  Future<String?> currentToken() async {
    calls.add('token');
    if (fails) throw StateError('no messaging service');
    return value;
  }
}

/// A notification prompt whose answer is scripted, and which records that it
/// was raised.
class _FakePermission implements NotificationPermissionGate {
  _FakePermission(this.answer);

  NotificationPermission answer;
  final List<String> calls = <String>[];

  @override
  Future<NotificationPermission> request() async {
    calls.add('permission');
    return answer;
  }

  @override
  Future<bool> openSettings() async => true;
}

/// The permission package's platform, whose status is scripted, so the mapping
/// from its statuses to the app's permission states is exercised without a
/// device.
class _FakePermissionPlatform extends PermissionHandlerPlatform {
  _FakePermissionPlatform(this.status);

  PermissionStatus status;
  bool settingsOpened = false;

  @override
  Future<PermissionStatus> checkPermissionStatus(Permission permission) async =>
      status;

  @override
  Future<Map<Permission, PermissionStatus>> requestPermissions(
    List<Permission> permissions,
  ) async => <Permission, PermissionStatus>{
    for (final permission in permissions) permission: status,
  };

  @override
  Future<bool> openAppSettings() async {
    settingsOpened = true;
    return true;
  }
}

void main() {
  group('FirebaseMessagingPushTokenProvider', () {
    test('issues the token the messaging service issued', () async {
      final permission = _FakePermission(NotificationPermission.granted);
      final messaging = _FakeMessaging(value: 'fcm-token');
      final provider = FirebaseMessagingPushTokenProvider(
        permission: permission,
        messagingOverride: messaging,
      );

      final outcome = await provider.request();

      expect(outcome, isA<PushTokenIssued>());
      expect((outcome as PushTokenIssued).token, 'fcm-token');
      // The permission prompt is raised before the token is taken, so the
      // reader's choice is made at the moment they take the notify offer.
      expect(permission.calls, <String>['permission']);
      expect(messaging.calls, <String>['token']);
    });

    test('reports a refusal the reader can answer again', () async {
      final permission = _FakePermission(NotificationPermission.denied);
      final messaging = _FakeMessaging(value: 'fcm-token');
      final provider = FirebaseMessagingPushTokenProvider(
        permission: permission,
        messagingOverride: messaging,
      );

      final outcome = await provider.request();

      expect(outcome, isA<PushTokenRefused>());
      expect((outcome as PushTokenRefused).permanently, isFalse);
      // A refused permission cannot be shown a notice, so no token is taken.
      expect(messaging.calls, isEmpty);
    });

    test('reports a refusal the platform will not ask again', () async {
      final provider = FirebaseMessagingPushTokenProvider(
        permission: _FakePermission(NotificationPermission.permanentlyDenied),
        messagingOverride: _FakeMessaging(value: 'fcm-token'),
      );

      final outcome = await provider.request();

      expect(outcome, isA<PushTokenRefused>());
      expect((outcome as PushTokenRefused).permanently, isTrue);
    });

    test('reports no token when the service has none', () async {
      final provider = FirebaseMessagingPushTokenProvider(
        permission: _FakePermission(NotificationPermission.granted),
        messagingOverride: _FakeMessaging(),
      );

      expect(await provider.request(), isA<PushTokenUnavailable>());
    });

    test('reports no token for an empty token', () async {
      final provider = FirebaseMessagingPushTokenProvider(
        permission: _FakePermission(NotificationPermission.granted),
        messagingOverride: _FakeMessaging(value: ''),
      );

      expect(await provider.request(), isA<PushTokenUnavailable>());
    });

    test('reports no token when the platform call fails', () async {
      final provider = FirebaseMessagingPushTokenProvider(
        permission: _FakePermission(NotificationPermission.granted),
        messagingOverride: _FakeMessaging(value: 'fcm-token', fails: true),
      );

      // The failure reads as no token rather than reaching the registrar.
      expect(await provider.request(), isA<PushTokenUnavailable>());
    });
  });

  group('PlatformNotificationPermission', () {
    late PermissionHandlerPlatform original;

    setUp(() => original = PermissionHandlerPlatform.instance);
    tearDown(() => PermissionHandlerPlatform.instance = original);

    Future<NotificationPermission> mapped(PermissionStatus status) {
      PermissionHandlerPlatform.instance = _FakePermissionPlatform(status);
      return const PlatformNotificationPermission().request();
    }

    test('reads a grant, provisional and limited alike, as granted', () async {
      // A provisional or limited grant still allows the notice, so the app
      // treats it as the reader having said yes.
      expect(
        await mapped(PermissionStatus.granted),
        NotificationPermission.granted,
      );
      expect(
        await mapped(PermissionStatus.provisional),
        NotificationPermission.granted,
      );
      expect(
        await mapped(PermissionStatus.limited),
        NotificationPermission.granted,
      );
    });

    test('reads a plain denial as one the reader can answer again', () async {
      expect(
        await mapped(PermissionStatus.denied),
        NotificationPermission.denied,
      );
    });

    test('reads a permanent denial or a restriction as final', () async {
      // Android reports a permanent denial only after a second refusal, and iOS
      // for any refusal once answered; a restriction (parental controls) is one
      // the app cannot prompt past either. All three need the device settings.
      expect(
        await mapped(PermissionStatus.permanentlyDenied),
        NotificationPermission.permanentlyDenied,
      );
      expect(
        await mapped(PermissionStatus.restricted),
        NotificationPermission.permanentlyDenied,
      );
    });

    test('opens the device settings through the permission package', () async {
      final platform = _FakePermissionPlatform(PermissionStatus.denied);
      PermissionHandlerPlatform.instance = platform;

      expect(
        await const PlatformNotificationPermission().openSettings(),
        isTrue,
      );
      expect(platform.settingsOpened, isTrue);
    });
  });

  group('DevelopmentPushTokenProvider', () {
    test('presents a stable token across requests', () async {
      final provider = DevelopmentPushTokenProvider();

      expect(
        (await provider.request() as PushTokenIssued).token,
        (await provider.request() as PushTokenIssued).token,
      );
    });

    test('mints a distinct pseudonymous token per install', () {
      expect(
        DevelopmentPushTokenProvider().request(),
        isNot(DevelopmentPushTokenProvider().request()),
      );
    });

    test('carries no reader data in the token', () async {
      final outcome =
          await DevelopmentPushTokenProvider().request() as PushTokenIssued;

      expect(outcome.token, startsWith('dev-push:'));
      expect(outcome.token, matches(RegExp(r'^dev-push:[0-9a-f]{32}$')));
    });
  });
}
