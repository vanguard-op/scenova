import 'package:flutter/material.dart';
import 'package:scenova_design/scenova_design.dart';

import '../config.dart';
import '../models/action_label.dart';
import '../services/app_services.dart';
import '../widgets/clear_history_dialog.dart';
import 'preferences_controller.dart';

/// Screen 7: Preferences (`docs/Scenova/screens/07-preferences.md`).
///
/// Controls how a clip behaves, the language of the selection-action label, the
/// reader's consent for model processing, and their on-device history. Each row
/// is a label with its control, and every change is written at once and takes
/// effect immediately.
///
/// Every state from the screen spec is covered: loading and default, with the
/// clearing state carried on the clear row and in its dialog.
class PreferencesScreen extends StatefulWidget {
  const PreferencesScreen({super.key, this.controller});

  /// The controller to drive the screen with.
  ///
  /// When it is not given the screen builds one from the services in scope and
  /// loads it; a caller that passes one owns its load and disposal. The preview
  /// gallery drives it so the clearing state can be looked at.
  final PreferencesController? controller;

  @override
  State<PreferencesScreen> createState() => _PreferencesScreenState();
}

class _PreferencesScreenState extends State<PreferencesScreen> {
  PreferencesController? _controller;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_controller != null) return;
    final injected = widget.controller;
    if (injected != null) {
      _controller = injected;
      injected.addListener(_onChanged);
      return;
    }
    // The services are read here rather than in initState so the inherited
    // scope is safe to depend on.
    final controller = PreferencesController(
      services: ScenovaScope.of(context),
    );
    _controller = controller;
    controller.addListener(_onChanged);
    controller.load();
  }

  @override
  void dispose() {
    // A controller the screen built is its own; an injected one belongs to its
    // caller, so only the listener is dropped here.
    _controller?.removeListener(_onChanged);
    if (widget.controller == null) _controller?.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  /// Confirms the clear, then runs it behind the dialog's progress state.
  ///
  /// The dialog blocks until the clear resolves; a clear the device refused
  /// leaves the reader on the screen with a message
  /// (`docs/Scenova/screens/07-preferences.md` → Overlays).
  Future<void> _confirmClearHistory() async {
    final controller = _controller!;
    final cleared = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => ClearHistoryDialog(onConfirm: controller.clearHistory),
    );
    if (!mounted || cleared != false) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content: Text('History could not be cleared. Try again.'),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Preferences')),
      body: SafeArea(child: _body(context, _controller!)),
    );
  }

  Widget _body(BuildContext context, PreferencesController controller) {
    final tokens = ScenovaTokens.of(context);
    final padding = EdgeInsets.symmetric(
      horizontal: tokens.spacing.lg,
      vertical: tokens.spacing.md,
    );

    switch (controller.status) {
      case PreferencesStatus.loading:
        return ListView(
          padding: padding,
          children: const <Widget>[SkeletonList(rows: 5)],
        );
      case PreferencesStatus.ready:
        return ListView(
          padding: padding,
          children: <Widget>[
            if (controller.accountError != null) ...<Widget>[
              _AccountNotice(
                message: controller.accountError!,
                onRetry: controller.canRetryAccountSync
                    ? controller.retryAccountSync
                    : null,
              ),
              SizedBox(height: tokens.spacing.md),
            ],
            _SwitchRow(
              label: 'Sound',
              value: controller.soundOn,
              onChanged: controller.setSound,
            ),
            const _RowDivider(),
            _SwitchRow(
              label: 'Reduce motion',
              subtitle: controller.reduceMotionLockedByPlatform
                  ? 'Your device\'s reduce-motion setting is on.'
                  : null,
              value: controller.reduceMotion,
              enabled: !controller.reduceMotionLockedByPlatform,
              onChanged: controller.setReduceMotion,
            ),
            const _RowDivider(),
            _SwitchRow(
              label: 'Look up new words',
              subtitle:
                  'Send the selected word to the model provider. When '
                  'off, no new clips are made.',
              value: controller.consentModelProcessing,
              onChanged: (value) => controller.setConsent(value),
            ),
            const _RowDivider(),
            _LanguageRow(
              language: controller.actionLabelLanguage,
              onChanged: controller.setLanguage,
            ),
            const _RowDivider(),
            const _AboutRow(),
            const _RowDivider(),
            _ClearHistoryRow(
              count: controller.historyCount,
              clearing: controller.clearing,
              onClear: _confirmClearHistory,
            ),
          ],
        );
    }
  }
}

/// A setting row: a label with a switch (`docs/Scenova/screens/07-preferences.md`
/// → Components).
class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.label,
    required this.value,
    required this.onChanged,
    this.subtitle,
    this.enabled = true,
  });

  final String label;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  /// Whether the reader can change the setting. A setting the platform owns is
  /// shown at its effective value and cannot be moved.
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final colors = ScenovaColors.of(context);
    final tokens = ScenovaTokens.of(context);
    final styles = ScenovaTextStyles.of(context);
    final labelColor = enabled ? colors.textPrimary : colors.textDisabled;

    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      value: value,
      onChanged: enabled ? onChanged : null,
      title: Text(label, style: styles.body.copyWith(color: labelColor)),
      subtitle: subtitle == null
          ? null
          : Text(
              subtitle!,
              style: styles.bodySmall.copyWith(color: colors.textSecondary),
            ),
      activeThumbColor: colors.onSolid,
      activeTrackColor: colors.primary,
      inactiveThumbColor: colors.surface,
      inactiveTrackColor: colors.border,
      trackOutlineColor: WidgetStatePropertyAll<Color>(colors.border),
      // The row is a full-width control, so it clears the 44px touch target.
      minVerticalPadding: tokens.spacing.sm,
    );
  }
}

/// The language the selection-action label is shown in
/// (`docs/Scenova/screens/07-preferences.md` → Components: "Language dropdown").
class _LanguageRow extends StatelessWidget {
  const _LanguageRow({required this.language, required this.onChanged});

  final ActionLabelLanguage language;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = ScenovaColors.of(context);
    final styles = ScenovaTextStyles.of(context);

    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(
        'Selection label language',
        style: styles.body.copyWith(color: colors.textPrimary),
      ),
      // The row reads clearly on its own; a note is added only where the chosen
      // language has no translation yet (`FEAT-012` → Edge Cases).
      subtitle: language.translated
          ? null
          : Text(
              'Shown in English until this language is ready.',
              style: styles.bodySmall.copyWith(color: colors.textSecondary),
            ),
      trailing: DropdownButton<String>(
        value: language.locale,
        underline: const SizedBox.shrink(),
        borderRadius: BorderRadius.circular(ScenovaRadius.md),
        style: styles.body.copyWith(color: colors.textPrimary),
        onChanged: (value) {
          if (value != null) onChanged(value);
        },
        items: <DropdownMenuItem<String>>[
          for (final offered in ActionLabelLanguages.all)
            DropdownMenuItem<String>(
              value: offered.locale,
              child: Text(
                offered.name,
                style: styles.body.copyWith(color: colors.textPrimary),
              ),
            ),
        ],
      ),
    );
  }
}

/// The app version (`docs/Scenova/screens/07-preferences.md` → Components:
/// "About row").
class _AboutRow extends StatelessWidget {
  const _AboutRow();

  @override
  Widget build(BuildContext context) {
    final colors = ScenovaColors.of(context);
    final styles = ScenovaTextStyles.of(context);

    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(
        'About',
        style: styles.body.copyWith(color: colors.textPrimary),
      ),
      subtitle: Text(
        'Version ${AppConfig.appVersion}',
        style: styles.bodySmall.copyWith(color: colors.textSecondary),
      ),
    );
  }
}

/// The row that removes the reader's on-device history
/// (`docs/Scenova/screens/07-preferences.md` → Components: "Clear-history row").
class _ClearHistoryRow extends StatelessWidget {
  const _ClearHistoryRow({
    required this.count,
    required this.clearing,
    required this.onClear,
  });

  final int count;
  final bool clearing;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final colors = ScenovaColors.of(context);
    final tokens = ScenovaTokens.of(context);
    final styles = ScenovaTextStyles.of(context);

    return ListTile(
      contentPadding: EdgeInsets.zero,
      onTap: clearing ? null : onClear,
      title: Text(
        'Clear history',
        style: styles.body.copyWith(
          color: clearing ? colors.textDisabled : colors.textPrimary,
        ),
      ),
      subtitle: Text(
        count == 0
            ? 'No saved lookups on this device.'
            : '$count saved ${count == 1 ? 'lookup' : 'lookups'} on this device.',
        style: styles.bodySmall.copyWith(color: colors.textSecondary),
      ),
      trailing: clearing
          ? SizedBox.square(
              dimension: tokens.sizing.iconMd,
              child: const CircularProgressIndicator(strokeWidth: 2),
            )
          : AppIconView(
              icon: AppIcons.next,
              size: tokens.sizing.iconMd,
              color: colors.iconDefault,
            ),
    );
  }
}

/// The note shown when an account-backed choice could not reach the account
/// (`C-020`). The choice itself is already stored and in effect on the device.
class _AccountNotice extends StatelessWidget {
  const _AccountNotice({required this.message, this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
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
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Padding(
                  padding: EdgeInsets.only(top: tokens.spacing.xs),
                  child: AppIconView(
                    icon: AppIcons.info,
                    size: tokens.sizing.iconSm,
                    color: colors.warning.element,
                  ),
                ),
                SizedBox(width: tokens.spacing.sm),
                Expanded(
                  child: Text(
                    message,
                    style: styles.bodySmall.copyWith(
                      color: colors.warning.text,
                    ),
                  ),
                ),
              ],
            ),
            if (onRetry != null) ...<Widget>[
              SizedBox(height: tokens.spacing.xs),
              ScenovaButton(
                label: 'Try again',
                variant: ScenovaButtonVariant.ghost,
                onPressed: onRetry,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The hairline between two setting rows.
class _RowDivider extends StatelessWidget {
  const _RowDivider();

  @override
  Widget build(BuildContext context) {
    final tokens = ScenovaTokens.of(context);
    return Divider(height: tokens.spacing.md);
  }
}
