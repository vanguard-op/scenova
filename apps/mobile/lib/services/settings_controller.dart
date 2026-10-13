import 'package:flutter/foundation.dart';

/// Reader preferences that the clip view, the entry gate, and the app shell
/// read.
///
/// Clip behaviour lives here so the in-context card honours it wherever it is
/// opened. The Preferences screen (a later surface) will edit the same state.
class SettingsController extends ChangeNotifier {
  SettingsController({
    bool platformReduceMotion = false,
    bool soundOn = false,
    bool consentModelProcessing = true,
    bool actionEnabled = true,
    bool onboardingComplete = false,
  }) {
    _platformReduceMotion = platformReduceMotion;
    _soundOn = soundOn;
    _consentModelProcessing = consentModelProcessing;
    _actionEnabled = actionEnabled;
    _onboardingComplete = onboardingComplete;
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

  /// Whether first-run setup has been finished or skipped.
  ///
  /// The app opens on Onboarding until this is set. It is stored with the
  /// reader's local settings; the durable store behind this flag is the same
  /// seam the rest of the preferences will move onto.
  bool get onboardingComplete => _onboardingComplete;
  set onboardingComplete(bool value) {
    if (_onboardingComplete == value) return;
    _onboardingComplete = value;
    notifyListeners();
  }

  /// Reduce motion, honouring an explicit reader choice over the platform
  /// setting. When on, a clip holds on a still frame and plays on tap.
  bool get reduceMotion => _reduceMotionOverride ?? _platformReduceMotion;
  bool? get reduceMotionOverride => _reduceMotionOverride;
  set reduceMotionOverride(bool? value) {
    if (_reduceMotionOverride == value) return;
    _reduceMotionOverride = value;
    notifyListeners();
  }

  /// Clips are muted by default; sound is explicit.
  bool get soundOn => _soundOn;
  set soundOn(bool value) {
    if (_soundOn == value) return;
    _soundOn = value;
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
    notifyListeners();
  }

  /// Whether the platform entry point (Android selection action, iOS extension)
  /// is enabled. When it is not, the entry gate shows how to enable it.
  bool get actionEnabled => _actionEnabled;
  set actionEnabled(bool value) {
    if (_actionEnabled == value) return;
    _actionEnabled = value;
    notifyListeners();
  }
}
