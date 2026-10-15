import 'package:flutter_test/flutter_test.dart';
import 'package:scenova/models/action_label.dart';
import 'package:scenova/screens/onboarding_controller.dart';
import 'package:scenova/services/settings_controller.dart';
import 'package:scenova/services/settings_store.dart';

void main() {
  test('a fresh install opens on Onboarding with clips muted', () async {
    final controller = SettingsController(store: InMemorySettingsStore());

    await controller.load();

    expect(controller.onboardingComplete, isFalse);
    expect(controller.soundOn, isFalse);
    expect(controller.consentModelProcessing, isTrue);
    // No explicit choice, so reduce motion follows the platform.
    expect(controller.reduceMotionOverride, isNull);
  });

  test('the reader\'s settings survive a relaunch', () async {
    final store = InMemorySettingsStore();

    final before = SettingsController(store: store);
    before.onboardingComplete = true;
    before.consentModelProcessing = false;
    before.soundOn = true;
    before.reduceMotionOverride = true;
    before.actionLabelLocale = 'pt';
    await before.pendingWrite;

    final after = SettingsController(store: store);
    await after.load();

    expect(after.onboardingComplete, isTrue);
    expect(after.consentModelProcessing, isFalse);
    expect(after.soundOn, isTrue);
    expect(after.reduceMotionOverride, isTrue);
    expect(after.actionLabelLocale, 'pt');
  });

  test('the device reduce-motion setting overrides the app preference', () {
    final controller = SettingsController(platformReduceMotion: true)
      ..reduceMotionOverride = false;

    // The platform setting wins, so a clip holds on a still frame whatever the
    // app preference says (`FEAT-012` → Edge Cases).
    expect(controller.reduceMotion, isTrue);
  });

  test('a locale the catalogue does not offer reads as English', () {
    final controller = SettingsController(actionLabelLocale: 'xx');

    expect(controller.actionLabelLanguage, ActionLabelLanguages.english);
  });

  test('finishing setup is stored, so the next launch opens on Home', () async {
    final store = InMemorySettingsStore();
    final settings = SettingsController(store: store);
    final onboarding = OnboardingController(settings: settings);
    addTearDown(onboarding.dispose);

    onboarding.setConsent(false);
    await onboarding.finish();
    await settings.pendingWrite;

    final relaunched = SettingsController(store: store);
    await relaunched.load();

    expect(relaunched.onboardingComplete, isTrue);
    expect(relaunched.consentModelProcessing, isFalse);
  });

  test(
    'clearing the reduce-motion choice follows the platform again',
    () async {
      final store = InMemorySettingsStore();
      final controller = SettingsController(store: store);

      // An explicit "off" is a stored choice, distinct from no choice at all.
      controller.reduceMotionOverride = false;
      await controller.pendingWrite;

      controller.reduceMotionOverride = null;
      await controller.pendingWrite;

      final relaunched = SettingsController(store: store);
      await relaunched.load();

      expect(relaunched.reduceMotionOverride, isNull);
    },
  );

  test('a write that fails does not break the writes after it', () async {
    final store = _FlakyStore();
    final controller = SettingsController(store: store);

    // The first write fails; the reader's next change must still be stored, and
    // the failure must not surface as an unhandled error.
    controller.soundOn = true;
    await controller.pendingWrite;

    controller.consentModelProcessing = false;
    await controller.pendingWrite;

    expect(store.saved, hasLength(1));
    expect(store.saved.single.consentModelProcessing, isFalse);
  });
}

/// A store whose first write fails, so a later write can prove it still lands.
class _FlakyStore implements SettingsStore {
  final List<SettingsSnapshot> saved = <SettingsSnapshot>[];
  int calls = 0;

  @override
  Future<SettingsSnapshot> load() async => const SettingsSnapshot();

  @override
  Future<void> save(SettingsSnapshot snapshot) async {
    calls++;
    if (calls == 1) throw StateError('the store is unwritable');
    saved.add(snapshot);
  }
}
