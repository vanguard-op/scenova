import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The reader's local settings as they are stored.
///
/// Only the values that outlive a launch are here: the clip's sound, the
/// reader's reduce-motion choice, consent for model processing, and whether
/// first-run setup is done. The platform's own reduce-motion setting is read
/// from the platform each launch and is never stored, and neither is the entry
/// gate's state, which the platform owns and the app re-checks.
@immutable
class SettingsSnapshot {
  const SettingsSnapshot({
    this.onboardingComplete = false,
    this.consentModelProcessing = true,
    this.soundOn = false,
    this.reduceMotionOverride,
  });

  /// Whether first-run setup has been finished or skipped.
  final bool onboardingComplete;

  /// Consent to send the selected word to the model provider.
  final bool consentModelProcessing;

  /// Whether clips carry sound. Off by default; sound is explicit.
  final bool soundOn;

  /// The reader's explicit reduce-motion choice, or null to follow the platform.
  final bool? reduceMotionOverride;
}

/// The durable home of the reader's local settings.
///
/// The store is a seam so the controller can be exercised without a platform
/// channel, and so the iOS extension can run from fresh defaults in its own
/// process rather than reading the app's suite.
abstract interface class SettingsStore {
  /// The stored settings, or the product defaults when nothing is stored yet.
  Future<SettingsSnapshot> load();

  /// Writes [snapshot] as the current settings.
  Future<void> save(SettingsSnapshot snapshot);
}

/// Stores the settings on the device through `shared_preferences`.
///
/// A fresh install has nothing stored, so [load] resolves the product defaults:
/// clips muted, model-processing consent on, and setup not yet done. Clearing
/// the app's data (or reinstalling) removes the store, so setup is asked again,
/// as the reinstall edge case requires.
class SharedPreferencesSettingsStore implements SettingsStore {
  SharedPreferencesSettingsStore({SharedPreferencesAsync? preferencesOverride})
    : _preferences = preferencesOverride;

  static const String _onboardingCompleteKey = 'settings.onboarding_complete';
  static const String _consentKey = 'settings.consent_model_processing';
  static const String _soundKey = 'settings.sound_on';
  static const String _reduceMotionKey = 'settings.reduce_motion_override';

  SharedPreferencesAsync? _preferences;

  /// The platform store, created on first use.
  ///
  /// Creating it touches the platform channel, so it is deferred until a read
  /// or write actually needs it; a build that never reads the settings (a unit
  /// test, or a run that leaves them alone) never reaches for the platform.
  SharedPreferencesAsync get _store =>
      _preferences ??= SharedPreferencesAsync();

  @override
  Future<SettingsSnapshot> load() async {
    final store = _store;
    return SettingsSnapshot(
      onboardingComplete: await store.getBool(_onboardingCompleteKey) ?? false,
      consentModelProcessing: await store.getBool(_consentKey) ?? true,
      soundOn: await store.getBool(_soundKey) ?? false,
      reduceMotionOverride: await store.getBool(_reduceMotionKey),
    );
  }

  @override
  Future<void> save(SettingsSnapshot snapshot) async {
    final store = _store;
    await store.setBool(_onboardingCompleteKey, snapshot.onboardingComplete);
    await store.setBool(_consentKey, snapshot.consentModelProcessing);
    await store.setBool(_soundKey, snapshot.soundOn);
    final override = snapshot.reduceMotionOverride;
    if (override == null) {
      // Absent means "follow the platform", which is not the same as false.
      await store.remove(_reduceMotionKey);
    } else {
      await store.setBool(_reduceMotionKey, override);
    }
  }
}

/// Keeps the settings only for the life of the process.
///
/// For tests, and for the iOS extension, which starts from the same defaults as
/// a fresh app rather than reading the app's own suite.
class InMemorySettingsStore implements SettingsStore {
  SettingsSnapshot _snapshot = const SettingsSnapshot();

  @override
  Future<SettingsSnapshot> load() async => _snapshot;

  @override
  Future<void> save(SettingsSnapshot snapshot) async => _snapshot = snapshot;
}
