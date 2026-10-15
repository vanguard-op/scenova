import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/action_label.dart';
import 'settings_store.dart';

/// Reader preferences that the clip view, the entry gate, and the app shell
/// read.
///
/// Clip behaviour lives here so the in-context card honours it wherever it is
/// opened. The Preferences screen (a later surface) will edit the same state.
///
/// Every change is written through to the [SettingsStore], so a reader's setup
/// and preferences survive an app restart rather than returning to Onboarding.
class SettingsController extends ChangeNotifier {
  SettingsController({
    bool platformReduceMotion = false,
    bool soundOn = false,
    bool consentModelProcessing = true,
    bool actionEnabled = true,
    bool onboardingComplete = false,
    String actionLabelLocale = ActionLabelLanguages.fallback,
    SettingsStore? store,
  }) : _store = store ?? InMemorySettingsStore() {
    _platformReduceMotion = platformReduceMotion;
    _soundOn = soundOn;
    _consentModelProcessing = consentModelProcessing;
    _actionEnabled = actionEnabled;
    _onboardingComplete = onboardingComplete;
    _actionLabelLocale = actionLabelLocale;
  }

  final SettingsStore _store;

  /// The last write handed to the store, so a caller can await it before
  /// asserting what was persisted. Writes are chained in order.
  Future<void> _write = Future<void>.value();

  /// Resolves once every settings write so far has reached the store.
  @visibleForTesting
  Future<void> get pendingWrite => _write;

  /// Reads the stored settings into the controller.
  ///
  /// Called once at startup, before the first frame, so the app opens on the
  /// surface the reader left it on. The platform's reduce-motion setting and the
  /// entry gate's state are not read here: the platform owns both and the app
  /// re-checks them each launch.
  Future<void> load() async {
    final snapshot = await _store.load();
    _soundOn = snapshot.soundOn;
    _consentModelProcessing = snapshot.consentModelProcessing;
    _reduceMotionOverride = snapshot.reduceMotionOverride;
    _actionLabelLocale = snapshot.actionLabelLocale;
    _onboardingComplete = snapshot.onboardingComplete;
    notifyListeners();
  }

  /// Queues the current settings for the store.
  void _persist() {
    final snapshot = SettingsSnapshot(
      onboardingComplete: _onboardingComplete,
      consentModelProcessing: _consentModelProcessing,
      soundOn: _soundOn,
      reduceMotionOverride: _reduceMotionOverride,
      actionLabelLocale: _actionLabelLocale,
    );
    // The write is best-effort and chained in order. A write that fails must not
    // break the chain for the ones after it, and must not surface as an
    // unhandled error; the reader's choice still applies for this session.
    _write = _write
        .then((_) => _store.save(snapshot))
        .catchError((Object _) {});
  }

  bool _platformReduceMotion = false;

  /// The platform's reduce-motion setting, refreshed when the app resumes.
  bool get platformReduceMotion => _platformReduceMotion;
  set platformReduceMotion(bool value) {
    if (_platformReduceMotion == value) return;
    _platformReduceMotion = value;
    notifyListeners();
  }

  bool? _reduceMotionOverride;
  bool _soundOn = false;
  bool _consentModelProcessing = true;
  bool _actionEnabled = true;
  bool _onboardingComplete = false;
  String _actionLabelLocale = ActionLabelLanguages.fallback;

  /// Whether first-run setup has been finished or skipped.
  ///
  /// The app opens on Onboarding until this is set. It is stored with the
  /// reader's local settings; the durable store behind this flag is the same
  /// seam the rest of the preferences will move onto.
  bool get onboardingComplete => _onboardingComplete;
  set onboardingComplete(bool value) {
    if (_onboardingComplete == value) return;
    _onboardingComplete = value;
    _persist();
    notifyListeners();
  }

  /// Reduce motion, with the platform's setting winning over the reader's.
  ///
  /// When the device's own reduce-motion setting is on, a clip holds on a still
  /// frame whatever the app preference says (`FEAT-012` → Edge Cases). Otherwise
  /// the reader's explicit choice stands, and with no explicit choice the
  /// platform's setting is followed.
  bool get reduceMotion =>
      _platformReduceMotion || (_reduceMotionOverride ?? false);
  bool? get reduceMotionOverride => _reduceMotionOverride;
  set reduceMotionOverride(bool? value) {
    if (_reduceMotionOverride == value) return;
    _reduceMotionOverride = value;
    _persist();
    notifyListeners();
  }

  /// Clips are muted by default; sound is explicit.
  bool get soundOn => _soundOn;
  set soundOn(bool value) {
    if (_soundOn == value) return;
    _soundOn = value;
    _persist();
    notifyListeners();
  }

  /// Consent to send the selected word to the model provider.
  ///
  /// Generation is refused without it, while library lookups and device history
  /// still serve. Onboarding owns the first capture of this consent; the
  /// default here stands in until that surface ships.
  bool get consentModelProcessing => _consentModelProcessing;
  set consentModelProcessing(bool value) {
    if (_consentModelProcessing == value) return;
    _consentModelProcessing = value;
    _persist();
    notifyListeners();
  }

  /// The language the selection-action label is shown in (`FEAT-012`).
  String get actionLabelLocale => _actionLabelLocale;
  set actionLabelLocale(String value) {
    if (_actionLabelLocale == value) return;
    _actionLabelLocale = value;
    _persist();
    notifyListeners();
  }

  /// The chosen language, resolved against the offered set.
  ///
  /// A locale the catalogue does not offer reads as English, which is also what
  /// the label itself falls back to where no translation exists.
  ActionLabelLanguage get actionLabelLanguage =>
      ActionLabelLanguages.resolve(_actionLabelLocale);

  /// Whether the platform entry point (Android selection action, iOS extension)
  /// is enabled. When it is not, the entry gate shows how to enable it. The
  /// platform owns this, so it is not stored with the reader's preferences.
  bool get actionEnabled => _actionEnabled;
  set actionEnabled(bool value) {
    if (_actionEnabled == value) return;
    _actionEnabled = value;
    notifyListeners();
  }
}
