import 'package:flutter_test/flutter_test.dart';
import 'package:scenova/services/feature_flags.dart';

void main() {
  test('the in-context view is on by default', () {
    expect(const FixedFeatureFlags().clipViewEnabled, isTrue);
    expect(RemoteConfigFeatureFlags().clipViewEnabled, isTrue);
  });

  test('offline replay is on by default', () {
    expect(const FixedFeatureFlags().offlineHistoryEnabled, isTrue);
    expect(RemoteConfigFeatureFlags().offlineHistoryEnabled, isTrue);
  });

  test('the paid tier is on by default', () {
    expect(const FixedFeatureFlags().paidTierEnabled, isTrue);
    expect(RemoteConfigFeatureFlags().paidTierEnabled, isTrue);
  });

  test('the paid tier can be killed, hiding the Paywall', () {
    final flags = RemoteConfigFeatureFlags(paidTierDefault: false);

    expect(flags.paidTierEnabled, isFalse);
    // The kill switch never touches the other flags.
    expect(flags.clipViewEnabled, isTrue);
  });

  test(
    'a fetch that cannot reach the flag source leaves the flags alone',
    () async {
      final flags = RemoteConfigFeatureFlags(
        clipViewDefault: false,
        offlineHistoryDefault: false,
        paidTierDefault: false,
        initialize: () async => throw StateError('Firebase is not configured'),
      );

      // A failed refresh must not throw and must not flip a flag by accident.
      await flags.refresh();

      expect(flags.clipViewEnabled, isFalse);
      expect(flags.offlineHistoryEnabled, isFalse);
      expect(flags.paidTierEnabled, isFalse);
    },
  );
}
