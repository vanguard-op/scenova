import 'package:flutter/material.dart';

import '../services/app_services.dart';
import '../services/settings_controller.dart';
import '../theme/colors.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';
import '../widgets/app_icons.dart';
import '../widgets/brand_lockup.dart';
import '../widgets/enable_action_guide.dart';
import '../widgets/first_run_walkthrough.dart';
import '../widgets/scenova_button.dart';
import '../widgets/setup_sheet.dart';
import 'onboarding_controller.dart';

/// Screen 1: Onboarding (`docs/Scenova/screens/01-onboarding.md`).
///
/// Explains what Scenova does, shows how to turn the selection action on in the
/// reader's app, and captures consent for model processing. It is the app's
/// first surface on a new install; Home takes over once setup is stored.
///
/// The five states from the screen spec are covered: the default first open, the
/// reader sent to settings (the enable card with a note to return), consent
/// declined (the note that generation is off while library lookups and history
/// still work), the panel lowered by dragging it down, which leaves a slice of
/// the setup content over the clip, and completion, which is leaving for Home.
///
/// The walkthrough clip runs full-bleed behind the setup panel on a seamless
/// loop; the panel is a solid, draggable sheet so its text keeps its contrast
/// against every frame of the clip behind it, at every position it can rest at
/// (`docs/Scenova/screens/01-onboarding.md` → Layout; `branding.md` → "Shadows"
/// and "Accessibility").
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key, required this.onComplete});

  /// Called once the reader's choices are stored, so the shell can open Home.
  final VoidCallback onComplete;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen>
    with WidgetsBindingObserver {
  OnboardingController? _controller;
  SettingsController? _settings;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // The settings are read here rather than in initState so the inherited
    // scope is safe to depend on.
    _settings = ScenovaScope.of(context).settings;
    _controller ??= OnboardingController(
      settings: _settings!,
      analytics: ScenovaScope.of(context).analytics,
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The reader returns from the reader app's settings; pick the change up so
    // the step advances without another tap.
    if (state == AppLifecycleState.resumed) {
      _controller?.refreshActionEnabled();
    }
  }

  Future<void> _finish() async {
    await _controller!.finish();
    if (!mounted) return;
    widget.onComplete();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final settings = _settings;
    if (controller == null || settings == null) return const SizedBox.shrink();
    // A full-bleed background layer holding the walkthrough, and a foreground
    // layer holding the setup panel over it. The background reaches the edges of
    // the screen; the sheet carries its own safe insets and positions itself
    // against the bottom edge.
    return Scaffold(
      body: LayoutBuilder(
        builder: (context, constraints) => Stack(
          fit: StackFit.expand,
          children: <Widget>[
            _background(context, settings),
            ListenableBuilder(
              listenable: settings,
              builder: (context, _) => ListenableBuilder(
                listenable: controller,
                builder: (context, _) => SetupSheet(
                  availableHeight: constraints.maxHeight,
                  reduceMotion: settings.reduceMotion,
                  child: _content(context, controller),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _content(BuildContext context, OnboardingController controller) {
    final tokens = ScenovaTokens.of(context);
    // The branding spec carries no content-width token; the readable column is
    // held to a multiple of the layout spacing scale until one is added.
    final contentWidth = tokens.spacing.xxxl * 6;
    final showEnableStep =
        !controller.actionEnabled ||
        controller.phase == OnboardingPhase.enablingAction;

    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: contentWidth),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _header(context),
            SizedBox(height: tokens.spacing.lg),
            _stepIndicator(context, controller),
            SizedBox(height: tokens.spacing.lg),
            if (showEnableStep) ...<Widget>[
              EnableActionGuide(
                openLabel: 'Show me how',
                onOpen: controller.phase == OnboardingPhase.ready
                    ? controller.beginEnableAction
                    : null,
              ),
              if (controller.phase == OnboardingPhase.enablingAction) ...[
                SizedBox(height: tokens.spacing.md),
                _returnNote(context, controller),
              ],
              SizedBox(height: tokens.spacing.lg),
            ],
            _consentLine(context, controller),
            if (controller.consentDeclined) ...[
              SizedBox(height: tokens.spacing.sm),
              _declinedNote(context),
            ],
            SizedBox(height: tokens.spacing.xl),
            ScenovaButton(
              label: 'Continue',
              onPressed: controller.submitting ? null : _finish,
              isSubmitting: controller.submitting,
              expanded: true,
              variant: ScenovaButtonVariant.primary,
            ),
            SizedBox(height: tokens.spacing.sm),
            Center(
              child: ScenovaButton(
                label: 'Skip for now',
                onPressed: controller.submitting ? null : _finish,
                variant: ScenovaButtonVariant.ghost,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _header(BuildContext context) {
    final colors = ScenovaColors.of(context);
    final tokens = ScenovaTokens.of(context);
    final styles = ScenovaTextStyles.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        BrandLockup(style: styles.h2),
        SizedBox(height: tokens.spacing.md),
        Text(
          'See what a word means',
          style: styles.display.copyWith(color: colors.textPrimary),
        ),
        SizedBox(height: tokens.spacing.sm),
        Text(
          'Select a word in a reading app and Scenova plays a short clip that '
          'shows its meaning — without leaving your page. You can also type or '
          'paste a word here in Scenova.',
          style: styles.body.copyWith(color: colors.textSecondary),
        ),
      ],
    );
  }

  /// The first-run walkthrough, run full-bleed behind the setup panel on a
  /// seamless loop (`docs/Scenova/screens/01-onboarding.md` → Layout and
  /// Declared Assets). Reduce motion is read from the reader's settings so the
  /// clip holds on a still frame when the platform asks it to.
  Widget _background(BuildContext context, SettingsController settings) {
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) =>
          FirstRunWalkthrough(reduceMotion: settings.reduceMotion),
    );
  }

  Widget _stepIndicator(BuildContext context, OnboardingController controller) {
    final colors = ScenovaColors.of(context);
    final tokens = ScenovaTokens.of(context);
    final styles = ScenovaTextStyles.of(context);

    return Semantics(
      label: 'Setup progress',
      value: controller.stepLabel,
      child: Row(
        children: <Widget>[
          Expanded(
            child: LinearProgressIndicator(
              value: controller.progress,
              borderRadius: BorderRadius.circular(ScenovaRadius.full),
            ),
          ),
          SizedBox(width: tokens.spacing.sm),
          Text(
            controller.stepLabel,
            style: styles.caption.copyWith(color: colors.textSecondary),
          ),
        ],
      ),
    );
  }

  Widget _returnNote(BuildContext context, OnboardingController controller) {
    final colors = ScenovaColors.of(context);
    final tokens = ScenovaTokens.of(context);
    final styles = ScenovaTextStyles.of(context);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        AppIconView(
          icon: AppIcons.info,
          size: tokens.sizing.iconSm,
          color: colors.info.element,
        ),
        SizedBox(width: tokens.spacing.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                'Turn Scenova on there, then come back.',
                style: styles.body.copyWith(
                  color: colors.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              SizedBox(height: tokens.spacing.xs),
              Text(
                controller.showActionReminder
                    ? 'It is not showing in the menu yet. You can finish this '
                          'later in Preferences.'
                    : 'Setup picks it up as soon as you return.',
                style: styles.bodySmall.copyWith(color: colors.textSecondary),
              ),
              SizedBox(height: tokens.spacing.sm),
              ScenovaButton(
                label: "I've turned it on",
                onPressed: controller.checkActionEnabled,
                variant: ScenovaButtonVariant.secondary,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _consentLine(BuildContext context, OnboardingController controller) {
    final colors = ScenovaColors.of(context);
    final styles = ScenovaTextStyles.of(context);

    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      value: controller.consent,
      onChanged: controller.submitting
          ? null
          : (value) => controller.setConsent(value),
      title: Text(
        'Send the word to the model provider',
        style: styles.body.copyWith(
          color: colors.textPrimary,
          fontWeight: FontWeight.w600,
        ),
      ),
      subtitle: Text(
        'Only the selected word or short phrase is sent — never the page you '
        'are reading.',
        style: styles.bodySmall.copyWith(color: colors.textSecondary),
      ),
    );
  }

  Widget _declinedNote(BuildContext context) {
    final colors = ScenovaColors.of(context);
    final tokens = ScenovaTokens.of(context);
    final styles = ScenovaTextStyles.of(context);

    return Semantics(
      liveRegion: true,
      child: Container(
        width: double.infinity,
        padding: EdgeInsets.all(tokens.spacing.md),
        decoration: BoxDecoration(
          color: colors.warning.tint,
          borderRadius: BorderRadius.circular(ScenovaRadius.md),
          border: Border.all(color: colors.warning.border),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            AppIconView(
              icon: AppIcons.info,
              size: tokens.sizing.iconSm,
              color: colors.warning.element,
            ),
            SizedBox(width: tokens.spacing.sm),
            Expanded(
              child: Text(
                'Generation is off. Words already in the library and your saved '
                'history still work, and you can turn this back on any time in '
                'Preferences.',
                style: styles.bodySmall.copyWith(color: colors.warning.text),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
