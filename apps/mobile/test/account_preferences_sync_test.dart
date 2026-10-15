import 'package:flutter_test/flutter_test.dart';
import 'package:scenova/models/action_label.dart';
import 'package:scenova/services/account_api.dart';
import 'package:scenova/services/account_preferences_sync.dart';
import 'package:scenova/services/account_session.dart';
import 'package:scenova/services/connectivity.dart';
import 'package:scenova/services/settings_controller.dart';

/// A sync with the collaborators a test drives it through.
({AccountPreferencesSync sync, MockAccountApi api, SettingsController settings})
buildSync({
  bool signedIn = true,
  bool online = true,
  bool consentModelProcessing = true,
  String locale = 'en',
  AccountApiException? error,
  bool signedOut = false,
}) {
  final api = MockAccountApi(
    consentModelProcessing: consentModelProcessing,
    locale: locale,
    error: error,
    signedOut: signedOut,
  );
  final settings = SettingsController();
  final sync = AccountPreferencesSync(
    api: api,
    session: DevelopmentAccountSession(signedIn: signedIn),
    settings: settings,
    connectivity: ManualConnectivity(online: online),
  );
  return (sync: sync, api: api, settings: settings);
}

void main() {
  test('a signed-out reader never reaches the account', () async {
    final built = buildSync(
      signedIn: false,
      consentModelProcessing: false,
      locale: 'fr',
    );

    expect(await built.sync.adopt(), isFalse);

    // The device copy is the whole story before sign-in (`C-022`).
    expect(built.api.reads, 0);
    expect(built.settings.consentModelProcessing, isTrue);
    expect(built.settings.actionLabelLocale, ActionLabelLanguages.fallback);
  });

  test(
    'a signed-in reader adopts the account\'s consent and language',
    () async {
      final built = buildSync(consentModelProcessing: false, locale: 'fr');

      expect(await built.sync.adopt(), isTrue);

      expect(built.api.reads, 1);
      expect(built.settings.consentModelProcessing, isFalse);
      expect(built.settings.actionLabelLocale, 'fr');
      expect(built.settings.actionLabelLanguage, ActionLabelLanguages.french);
    },
  );

  test(
    'a language without a translation is kept and reads as English',
    () async {
      final built = buildSync(locale: 'pt');

      await built.sync.adopt();

      // The choice is held as made, and the label falls back to English
      // (`FEAT-012` → Edge Cases).
      expect(built.settings.actionLabelLocale, 'pt');
      expect(
        built.settings.actionLabelLanguage,
        ActionLabelLanguages.portuguese,
      );
      expect(built.settings.actionLabelLanguage.translated, isFalse);
    },
  );

  test('a language the catalogue does not offer reads as English', () async {
    final built = buildSync(locale: 'zz');

    await built.sync.adopt();

    expect(built.settings.actionLabelLocale, ActionLabelLanguages.fallback);
  });

  test('offline leaves the device copy alone', () async {
    final built = buildSync(
      online: false,
      consentModelProcessing: false,
      locale: 'fr',
    );

    expect(await built.sync.adopt(), isFalse);

    expect(built.api.reads, 0);
    expect(built.settings.consentModelProcessing, isTrue);
    expect(built.settings.actionLabelLocale, ActionLabelLanguages.fallback);
  });

  test(
    'an account the store cannot answer leaves the device copy alone',
    () async {
      final built = buildSync(
        consentModelProcessing: false,
        locale: 'fr',
        error: const AccountApiException(503, 'Your account is unavailable.'),
      );

      expect(await built.sync.adopt(), isFalse);

      expect(built.settings.consentModelProcessing, isTrue);
      expect(built.settings.actionLabelLocale, ActionLabelLanguages.fallback);
    },
  );

  test('a token with no account leaves the device copy alone', () async {
    final built = buildSync(
      consentModelProcessing: false,
      locale: 'fr',
      signedOut: true,
    );

    expect(await built.sync.adopt(), isFalse);

    expect(built.settings.consentModelProcessing, isTrue);
    expect(built.settings.actionLabelLocale, ActionLabelLanguages.fallback);
  });

  test('an account holding the same choices changes nothing', () async {
    final built = buildSync(consentModelProcessing: true, locale: 'en');
    var notified = 0;
    built.settings.addListener(() => notified++);

    expect(await built.sync.adopt(), isTrue);

    expect(built.settings.consentModelProcessing, isTrue);
    expect(built.settings.actionLabelLocale, 'en');
    expect(notified, 0);
  });
}
