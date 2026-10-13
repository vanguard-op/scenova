import 'package:flutter_test/flutter_test.dart';
import 'package:scenova/services/app_services.dart';
import 'package:scenova/services/identity.dart';

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

    test('presents the pseudonymous dev token the gateway verifies', () async {
      final services = ScenovaServices.development();
      addTearDown(services.dispose);

      expect(await services.identity.idToken(), startsWith('dev:'));
    });
  });
}
