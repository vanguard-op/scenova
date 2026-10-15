import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:scenova/models/history_entry.dart';
import 'package:scenova/screens/preferences_controller.dart';
import 'package:scenova/services/account_api.dart';
import 'package:scenova/services/account_session.dart';
import 'package:scenova/services/connectivity.dart';
import 'package:scenova/services/history_store.dart';

import 'support/harness.dart';

void main() {
  test(
    'a signed-out reader\'s choice is never written to the account',
    () async {
      final accountApi = MockAccountApi();
      final services = buildServices(accountApi: accountApi);
      final controller = PreferencesController(services: services);
      addTearDown(controller.dispose);

      await controller.load();
      await controller.setConsent(false);
      await controller.setLanguage('fr');

      expect(accountApi.writes, isEmpty);
      expect(controller.accountError, isNull);
      expect(services.settings.consentModelProcessing, isFalse);
      expect(services.settings.actionLabelLocale, 'fr');
    },
  );

  test(
    'a signed-in choice made offline reaches the account on reconnect',
    () async {
      final accountApi = MockAccountApi();
      final services = buildServices(
        accountApi: accountApi,
        accountSession: DevelopmentAccountSession(signedIn: true),
        online: false,
      );
      final controller = PreferencesController(services: services);
      addTearDown(controller.dispose);

      await controller.load();
      await controller.setConsent(false);

      // The choice applies on the device and is held for the connection.
      expect(services.settings.consentModelProcessing, isFalse);
      expect(accountApi.writes, isEmpty);
      expect(controller.accountError, isNotNull);

      (services.connectivity as ManualConnectivity).setOnline(true);
      await pumpEventQueue();

      expect(accountApi.writes, hasLength(1));
      expect(accountApi.writes.single.consentModelProcessing, isFalse);
      expect(controller.accountError, isNull);
    },
  );

  test('a token with no account leaves the choice on the device', () async {
    final accountApi = MockAccountApi(signedOut: true);
    final services = buildServices(
      accountApi: accountApi,
      accountSession: DevelopmentAccountSession(signedIn: true),
    );
    final controller = PreferencesController(services: services);
    addTearDown(controller.dispose);

    await controller.load();
    await controller.setConsent(false);

    // A 401 is the signed-out case, not a failure to tell the reader about.
    expect(services.settings.consentModelProcessing, isFalse);
    expect(controller.accountError, isNull);
    expect(controller.hasAccount, isFalse);
  });

  test('the clear reports the history size and empties the device', () async {
    final history = InMemoryHistoryStore(
      seed: <HistoryEntry>[seededEntry(word: 'come', phrase: 'to arrive')],
    );
    final services = buildServices(history: history);
    final controller = PreferencesController(services: services);
    addTearDown(controller.dispose);

    await controller.load();
    expect(controller.historyCount, 1);

    expect(await controller.clearHistory(), isTrue);
    expect(controller.historyCount, 0);
    expect(await history.all(), isEmpty);
  });

  test('the clear is in progress while the device removes it', () async {
    final history = _SlowHistoryStore(
      seed: <HistoryEntry>[seededEntry(word: 'come', phrase: 'to arrive')],
    );
    final services = buildServices(history: history);
    final controller = PreferencesController(services: services);
    addTearDown(controller.dispose);

    await controller.load();
    final clearing = controller.clearHistory();

    expect(controller.clearing, isTrue);

    history.cleared.complete();
    expect(await clearing, isTrue);
    expect(controller.clearing, isFalse);
  });

  test('a clear the device refused is reported rather than thrown', () async {
    final services = buildServices(history: _RefusingHistoryStore());
    final controller = PreferencesController(services: services);
    addTearDown(controller.dispose);

    await controller.load();

    expect(await controller.clearHistory(), isFalse);
    expect(controller.clearing, isFalse);
  });
}

/// A history whose clear resolves only when the test completes it.
class _SlowHistoryStore extends InMemoryHistoryStore {
  _SlowHistoryStore({super.seed});

  final Completer<void> cleared = Completer<void>();

  @override
  Future<void> clear() => cleared.future;
}

/// A history the device refuses to clear.
class _RefusingHistoryStore extends InMemoryHistoryStore {
  @override
  Future<void> clear() async => throw StateError('the device refused');
}
