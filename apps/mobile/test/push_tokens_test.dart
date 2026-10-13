import 'package:flutter_test/flutter_test.dart';
import 'package:scenova/services/push_tokens.dart';

/// A platform messaging service whose permission and token are scripted.
class _FakeMessaging implements PushMessaging {
  _FakeMessaging({this.permitted = true, this.value, this.fails = false});

  bool permitted;
  String? value;

  /// When true, asking for the token raises, as a missing messaging service or
  /// a platform error would.
  bool fails;

  final List<String> calls = <String>[];

  @override
  Future<bool> requestPermission() async {
    calls.add('permission');
    return permitted;
  }

  @override
  Future<String?> currentToken() async {
    calls.add('token');
    if (fails) throw StateError('no messaging service');
    return value;
  }
}

void main() {
  group('FirebaseMessagingPushTokenProvider', () {
    test('presents the device token the messaging service issued', () async {
      final messaging = _FakeMessaging(value: 'fcm-token');
      final provider = FirebaseMessagingPushTokenProvider(
        messagingOverride: messaging,
      );

      expect(await provider.token(), 'fcm-token');
      // The permission prompt is raised before the token is taken, so the
      // reader's choice is made at the moment they take the notify offer.
      expect(messaging.calls, <String>['permission', 'token']);
    });

    test('reports no token when the reader refuses notifications', () async {
      final messaging = _FakeMessaging(permitted: false, value: 'fcm-token');
      final provider = FirebaseMessagingPushTokenProvider(
        messagingOverride: messaging,
      );

      expect(await provider.token(), isNull);
      // A refused permission cannot be shown a notice, so no token is taken.
      expect(messaging.calls, <String>['permission']);
    });

    test('reports no token when the service has none', () async {
      final provider = FirebaseMessagingPushTokenProvider(
        messagingOverride: _FakeMessaging(),
      );

      expect(await provider.token(), isNull);
    });

    test('reports no token for an empty token', () async {
      final provider = FirebaseMessagingPushTokenProvider(
        messagingOverride: _FakeMessaging(value: ''),
      );

      expect(await provider.token(), isNull);
    });

    test('reports no token when the platform call fails', () async {
      final provider = FirebaseMessagingPushTokenProvider(
        messagingOverride: _FakeMessaging(value: 'fcm-token', fails: true),
      );

      // The failure reads as no token rather than reaching the registrar.
      expect(await provider.token(), isNull);
    });
  });

  group('DevelopmentPushTokenProvider', () {
    test('presents a stable token across requests', () async {
      final provider = DevelopmentPushTokenProvider();

      expect(await provider.token(), await provider.token());
    });

    test('mints a distinct pseudonymous token per install', () {
      expect(
        DevelopmentPushTokenProvider().token(),
        isNot(DevelopmentPushTokenProvider().token()),
      );
    });

    test('carries no reader data in the token', () async {
      final token = await DevelopmentPushTokenProvider().token();

      expect(token, startsWith('dev-push:'));
      expect(token, matches(RegExp(r'^dev-push:[0-9a-f]{32}$')));
    });
  });
}
