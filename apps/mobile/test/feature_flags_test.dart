import 'package:flutter_test/flutter_test.dart';
import 'package:scenova/services/feature_flags.dart';

void main() {
  test('the in-context view is on by default', () {
    expect(const FixedFeatureFlags().clipViewEnabled, isTrue);
    expect(RemoteConfigFeatureFlags().clipViewEnabled, isTrue);
  });

  test(
    'a fetch that cannot reach the flag source leaves the flag alone',
    () async {
      final flags = RemoteConfigFeatureFlags(
        clipViewDefault: false,
        initialize: () async => throw StateError('Firebase is not configured'),
      );

      // A failed refresh must not throw and must not flip the flag by accident.
      await flags.refresh();

      expect(flags.clipViewEnabled, isFalse);
    },
  );
}
