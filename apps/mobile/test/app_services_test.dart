import 'package:flutter_test/flutter_test.dart';
import 'package:scenova/services/app_services.dart';
import 'package:scenova/services/identity.dart';
import 'package:scenova/services/purchase_service.dart';
import 'package:scenova/services/push_tokens.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ScenovaServices.development', () {
    test('carries an identity for the lookup path', () {
      final services = ScenovaServices.development();
      addTearDown(services.dispose);

      // A debug build authenticates through the gateway's own verifier; a
      // release build defaults to Firebase (D-011).
      expect(services.identity, isA<AnonymousIdentity>());
    });

    test('carries a token source for the notify offer', () {
      final services = ScenovaServices.development();
      addTearDown(services.dispose);

      // A debug build mints a pseudonymous token; a release build takes the
      // real device token from Firebase Cloud Messaging (D-005).
      expect(
        services.pushRegistrar.tokens,
        isA<DevelopmentPushTokenProvider>(),
      );
    });

    test('presents the pseudonymous dev token the gateway verifies', () async {
      final services = ScenovaServices.development();
      addTearDown(services.dispose);

      expect(await services.identity.idToken(), startsWith('dev:'));
    });

    test('carries the scripted store until the build carries one', () {
      final services = ScenovaServices.development();
      addTearDown(services.dispose);

      // A laptop run carries none of the store defines the build path bakes in,
      // so the purchase states are exercisable without a store; a build that
      // carries the configuration drives the store client instead (FEAT-013).
      expect(services.purchases, isA<MockPurchaseService>());
    });
  });
}
