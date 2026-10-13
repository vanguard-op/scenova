import 'package:flutter/foundation.dart';

import '../services/settings_controller.dart';

/// How many steps setup has.
///
/// The enable-action step and the consent step; the reader sees both on one
/// screen, and the step indicator reads their place against these.
const int kOnboardingStepCount = 2;

/// The states the onboarding screen renders
/// (`docs/Scenova/screens/01-onboarding.md` → States).
enum OnboardingPhase {
  /// First open: the explanation, the step indicator, and the enable-action card.
  ready,

  /// The reader has been sent to the reader app's settings to turn the action
  /// on; the card shows the instruction with a note to return.
  enablingAction,
}

/// Drives the first-run setup screen.
///
/// The controller holds the choices the screen shows and writes them through to
/// the reader's settings as they are made, so a change takes effect at once and
/// is stored (`docs/Scenova/features/FEAT-012.md` → Acceptance Criteria).
/// Consent is the first capture of the reader's choice for model processing;
/// the app opens on this screen until setup is marked complete.
class OnboardingController extends ChangeNotifier {
  OnboardingController({required SettingsController settings})
    : _settings = settings {
    _actionEnabled = settings.actionEnabled;
    _consent = settings.consentModelProcessing;
  }

  final SettingsController _settings;

  bool _actionEnabled = false;
  bool _consent = true;
  bool _enablingAction = false;
  bool _showActionReminder = false;
  bool _submitting = false;
  bool _disposed = false;

  OnboardingPhase get phase =>
      _enablingAction ? OnboardingPhase.enablingAction : OnboardingPhase.ready;

  /// Whether the platform entry point is on. The enable-action step is skipped
  /// when it already is (`docs/Scenova/screens/01-onboarding.md` → Edge Cases).
  bool get actionEnabled => _actionEnabled;

  /// The reader's consent to send the selected word to the model provider.
  bool get consent => _consent;

  /// Consent is off: generation is paused while library lookups and device
  /// history still serve.
  bool get consentDeclined => !_consent;

  /// Setup is being stored and the screen is about to leave.
  bool get submitting => _submitting;

  /// The reader returned from settings but the action is still not on. A gentle
  /// reminder, never a block: the enable step can be finished later.
  bool get showActionReminder => _showActionReminder;

  /// The fraction of setup done, for the step indicator.
  ///
  /// The enable step is the first of the two; consent is asked in both cases, so
  /// an enabled action reads as the final step.
  double get progress => _actionEnabled ? 1 : 0.5;

  /// The step indicator's caption, e.g. "Step 1 of 2".
  String get stepLabel {
    final index = _actionEnabled ? 2 : 1;
    return 'Step $index of $kOnboardingStepCount';
  }

  /// The reader asked to be shown where to turn the action on.
  void beginEnableAction() {
    if (_enablingAction) return;
    _enablingAction = true;
    _showActionReminder = false;
    notifyListeners();
  }

  /// Re-reads whether the action is on. Called when the app resumes and by the
  /// screen's own check, so the step advances the moment the reader returns with
  /// it enabled.
  void refreshActionEnabled() {
    final enabled = _settings.actionEnabled;
    if (enabled == _actionEnabled) return;
    _actionEnabled = enabled;
    if (enabled) {
      _enablingAction = false;
      _showActionReminder = false;
    }
    notifyListeners();
  }

  /// The reader says the action is on now.
  void checkActionEnabled() {
    refreshActionEnabled();
    if (_actionEnabled || _showActionReminder) return;
    _showActionReminder = true;
    notifyListeners();
  }

  /// The reader changed their consent for model processing. Written at once so
  /// generation is enabled or disabled immediately and the choice is stored.
  void setConsent(bool value) {
    if (_consent == value) return;
    _consent = value;
    _settings.consentModelProcessing = value;
    notifyListeners();
  }

  /// Stores the reader's choices and marks setup done, so the app opens on Home
  /// from now on. Called for both Continue and Skip.
  Future<void> finish() async {
    if (_submitting) return;
    _submitting = true;
    notifyListeners();

    // Consent is written as the switch is used; re-assert it here so a choice
    // made elsewhere in the session is the one that is stored.
    _settings.consentModelProcessing = _consent;
    _settings.onboardingComplete = true;

    // The durable local store and, when the reader is signed in, attaching the
    // consent to the account are awaited here; both are immediate today.
    await Future<void>.value();
    if (_disposed) return;
    _submitting = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
