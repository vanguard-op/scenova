import 'package:flutter_test/flutter_test.dart';
import 'package:scenova/models/lookup.dart';
import 'package:scenova/services/connectivity.dart';
import 'package:scenova/services/push_registration_api.dart';
import 'package:scenova/services/push_registrar.dart';
import 'package:scenova/services/push_tokens.dart';

class _FixedTokens implements PushTokenProvider {
  _FixedTokens(this.value);

  final String? value;

  @override
  Future<String?> token() async => value;
}

void main() {
  test(
    'registers the device token against the lookup it is waiting on',
    () async {
      final api = MockPushRegistrationApi();
      final registrar = PushRegistrar(
        api: api,
        tokens: _FixedTokens('device-token'),
        connectivity: ManualConnectivity(),
      );
      addTearDown(registrar.dispose);

      expect(
        await registrar.requestClipReadyNotice(lookupId: 'lk_1'),
        PushNoticeResult.registered,
      );
      expect(api.tokens, <String>['device-token']);
      expect(api.platforms, <LookupPlatform>[LookupPlatform.current()]);
      expect(api.lookupIds, <String>['lk_1']);
      expect(registrar.pendingRegistration, isFalse);
    },
  );

  test('registers nothing when the device has no token', () async {
    final api = MockPushRegistrationApi();
    final registrar = PushRegistrar(
      api: api,
      tokens: _FixedTokens(null),
      connectivity: ManualConnectivity(),
    );
    addTearDown(registrar.dispose);

    expect(
      await registrar.requestClipReadyNotice(lookupId: 'lk_1'),
      PushNoticeResult.notRegistered,
    );
    expect(api.tokens, isEmpty);
    expect(registrar.pendingRegistration, isFalse);
  });

  test('reports a lookup the service has already finished', () async {
    final api = MockPushRegistrationApi()..declinesRegistration = true;
    final registrar = PushRegistrar(
      api: api,
      tokens: _FixedTokens('device-token'),
      connectivity: ManualConnectivity(),
    );
    addTearDown(registrar.dispose);

    expect(
      await registrar.requestClipReadyNotice(lookupId: 'lk_1'),
      PushNoticeResult.noNoticeNeeded,
    );
    // Nothing is held: a lookup that has finished has no later event to watch.
    expect(registrar.pendingRegistration, isFalse);
  });

  test('holds an offline registration and sends it, lookup and all, when back online', () async {
    final api = MockPushRegistrationApi();
    final connectivity = ManualConnectivity(online: false);
    final registrar = PushRegistrar(
      api: api,
      tokens: _FixedTokens('device-token'),
      connectivity: connectivity,
    );
    addTearDown(registrar.dispose);

    expect(
      await registrar.requestClipReadyNotice(lookupId: 'lk_1'),
      PushNoticeResult.notRegistered,
    );
    expect(api.tokens, isEmpty);
    expect(registrar.pendingRegistration, isTrue);

    // Let the connectivity subscription settle before the change, so the test
    // exercises the reconnection rather than the subscription's start.
    await pumpEventQueue();
    connectivity.setOnline(true);
    await pumpEventQueue();
    expect(api.tokens, <String>['device-token']);
    expect(api.lookupIds, <String>['lk_1']);
    expect(registrar.pendingRegistration, isFalse);
  });

  test('retries a rate-limited registration when online again', () async {
    final api = MockPushRegistrationApi()..failStatus = 429;
    final connectivity = ManualConnectivity();
    final registrar = PushRegistrar(
      api: api,
      tokens: _FixedTokens('device-token'),
      connectivity: connectivity,
    );
    addTearDown(registrar.dispose);

    expect(
      await registrar.requestClipReadyNotice(lookupId: 'lk_1'),
      PushNoticeResult.notRegistered,
    );
    expect(registrar.pendingRegistration, isTrue);

    await pumpEventQueue();
    api.failStatus = null;
    connectivity.setOnline(false);
    connectivity.setOnline(true);
    await pumpEventQueue();
    expect(api.tokens, <String>['device-token']);
    expect(api.lookupIds, <String>['lk_1']);
    expect(registrar.pendingRegistration, isFalse);
  });

  test('drops a rejected registration rather than holding it', () async {
    final api = MockPushRegistrationApi()..failStatus = 400;
    final connectivity = ManualConnectivity();
    final registrar = PushRegistrar(
      api: api,
      tokens: _FixedTokens('device-token'),
      connectivity: connectivity,
    );
    addTearDown(registrar.dispose);

    expect(
      await registrar.requestClipReadyNotice(lookupId: 'lk_1'),
      PushNoticeResult.notRegistered,
    );
    expect(registrar.pendingRegistration, isFalse);

    await pumpEventQueue();
    api.failStatus = null;
    connectivity.setOnline(false);
    connectivity.setOnline(true);
    await pumpEventQueue();
    // Nothing was held, so the reconnect sends nothing.
    expect(api.tokens, isEmpty);
  });
}
