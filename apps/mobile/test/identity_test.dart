import 'package:flutter_test/flutter_test.dart';
import 'package:scenova/services/identity.dart';

void main() {
  group('AnonymousIdentity', () {
    test(
      'presents the dev token the gateway verifies its subject from',
      () async {
        final identity = AnonymousIdentity(subject: 'reader-1');

        expect(await identity.idToken(), 'dev:reader-1');
      },
    );

    test('keeps one subject across requests', () async {
      final identity = AnonymousIdentity();

      expect(await identity.idToken(), await identity.idToken());
    });

    test('mints a distinct pseudonymous subject per install', () {
      expect(AnonymousIdentity().subject, isNot(AnonymousIdentity().subject));
    });

    test('carries no reader data in the subject', () {
      // Pseudonymous: a hex token, never a word, phrase, email, or name.
      expect(AnonymousIdentity().subject, matches(RegExp(r'^[0-9a-f]{32}$')));
    });

    test('upgrades to the account subject at sign-in', () async {
      final identity = AnonymousIdentity(subject: 'anon-1');

      identity.upgradeTo('account-9');

      expect(identity.subject, 'account-9');
      expect(await identity.idToken(), 'dev:account-9');
    });
  });
}
