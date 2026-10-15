import 'package:flutter_test/flutter_test.dart';
import 'package:scenova/models/action_label.dart';
import 'package:scenova/services/settings_store.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  setUp(() {
    // The real store talks to the platform channel; the in-memory platform
    // stands in so the key handling is exercised without a device.
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  test('an empty store resolves the product defaults', () async {
    final snapshot = await SharedPreferencesSettingsStore().load();

    expect(snapshot.onboardingComplete, isFalse);
    expect(snapshot.consentModelProcessing, isTrue);
    expect(snapshot.soundOn, isFalse);
    expect(snapshot.reduceMotionOverride, isNull);
    expect(snapshot.actionLabelLocale, ActionLabelLanguages.fallback);
  });

  test('the device store round-trips every setting', () async {
    final store = SharedPreferencesSettingsStore();
    await store.save(
      const SettingsSnapshot(
        onboardingComplete: true,
        consentModelProcessing: false,
        soundOn: true,
        reduceMotionOverride: true,
        actionLabelLocale: 'pt',
      ),
    );

    final snapshot = await store.load();

    expect(snapshot.onboardingComplete, isTrue);
    expect(snapshot.consentModelProcessing, isFalse);
    expect(snapshot.soundOn, isTrue);
    expect(snapshot.reduceMotionOverride, isTrue);
    expect(snapshot.actionLabelLocale, 'pt');
  });

  test(
    'an explicit reduce-motion choice is kept apart from no choice',
    () async {
      final store = SharedPreferencesSettingsStore();

      await store.save(const SettingsSnapshot(reduceMotionOverride: false));
      expect((await store.load()).reduceMotionOverride, isFalse);

      // Clearing the choice removes the key, so the platform setting takes over
      // again rather than the reader being pinned to "off".
      await store.save(const SettingsSnapshot());
      expect((await store.load()).reduceMotionOverride, isNull);
    },
  );
}
