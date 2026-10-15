import 'dart:async';

import 'package:flutter/material.dart';
import 'package:scenova_design/scenova_design.dart';

import '../config.dart';
import '../models/report.dart';

/// Opens the Report sheet over the Clip View
/// (`docs/Scenova/screens/05-report-sheet.md`).
///
/// The sheet returns what came of the report — [ReportDelivery.sent],
/// [ReportDelivery.queued], or [ReportDelivery.duplicate] — or null when the
/// reader cancelled. A report the service would not take is handled inside the
/// sheet, which stays open with an inline message and a retry.
Future<ReportDelivery?> showReportSheet(
  BuildContext context, {
  required String word,
  required bool privateToDevice,
  required bool offline,
  required Future<ReportDelivery> Function(ReportReason reason, String? note)
  onSubmit,
}) {
  return showModalBottomSheet<ReportDelivery>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => _ReportSheet(
      word: word,
      privateToDevice: privateToDevice,
      offline: offline,
      onSubmit: onSubmit,
    ),
  );
}

/// The report sheet's content: the reason list, the optional note, and the
/// Submit and Cancel actions (`docs/Scenova/screens/05-report-sheet.md`).
class _ReportSheet extends StatefulWidget {
  const _ReportSheet({
    required this.word,
    required this.privateToDevice,
    required this.offline,
    required this.onSubmit,
  });

  /// The word or phrase whose clip is being reported.
  final String word;

  /// Whether the clip is a phrase clip, which lives only on the device, so the
  /// reader is told the report has no shared effect (`FEAT-011`).
  final bool privateToDevice;

  /// Whether the device has no connection, so the report is held for the
  /// connection to return (`FEAT-011`, Edge Cases).
  final bool offline;

  final Future<ReportDelivery> Function(ReportReason reason, String? note)
  onSubmit;

  @override
  State<_ReportSheet> createState() => _ReportSheetState();
}

class _ReportSheetState extends State<_ReportSheet> {
  final TextEditingController _note = TextEditingController();

  ReportReason? _reason;
  bool _submitting = false;
  String? _errorMessage;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  /// Sends the report. The sheet closes on success, and stays open with an
  /// inline message and a retry when the service would not take it.
  Future<void> _submit() async {
    final reason = _reason;
    if (reason == null || _submitting) return;
    final note = _note.text.trim();
    setState(() {
      _submitting = true;
      _errorMessage = null;
    });
    ReportDelivery outcome;
    try {
      outcome = await widget.onSubmit(reason, note.isEmpty ? null : note);
    } on Object {
      outcome = ReportDelivery.failed;
    }
    if (!mounted) return;
    switch (outcome) {
      case ReportDelivery.sent:
      case ReportDelivery.queued:
      case ReportDelivery.duplicate:
        Navigator.of(context).pop(outcome);
      case ReportDelivery.failed:
        setState(() {
          _submitting = false;
          _errorMessage = "We couldn't send that just now.";
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = ScenovaColors.of(context);
    final tokens = ScenovaTokens.of(context);
    final styles = ScenovaTextStyles.of(context);
    // The keyboard covers the lower half of the sheet, so the content clears it.
    final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
    final canSubmit = _reason != null && !_submitting;

    return Padding(
      padding: EdgeInsets.only(bottom: keyboardInset),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            tokens.spacing.lg,
            0,
            tokens.spacing.lg,
            tokens.spacing.lg,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Semantics(
                header: true,
                child: Text(
                  'Report this clip',
                  style: styles.h3.copyWith(color: colors.textPrimary),
                ),
              ),
              SizedBox(height: tokens.spacing.xs),
              Text(
                'You are reporting “${widget.word}”.',
                style: styles.bodySmall.copyWith(color: colors.textSecondary),
              ),
              if (widget.privateToDevice) ...<Widget>[
                SizedBox(height: tokens.spacing.md),
                _Callout(
                  tone: colors.info,
                  icon: AppIcons.info,
                  message:
                      'This clip is saved only on your device. Reporting it '
                      'will not change what anyone else sees.',
                ),
              ],
              if (widget.offline) ...<Widget>[
                SizedBox(height: tokens.spacing.md),
                _Callout(
                  tone: colors.warning,
                  icon: AppIcons.offline,
                  message:
                      "You're offline. Your report will be sent when you're "
                      'back online.',
                ),
              ],
              SizedBox(height: tokens.spacing.lg),
              Text(
                'Why are you reporting it?',
                style: styles.body.copyWith(color: colors.textPrimary),
              ),
              SizedBox(height: tokens.spacing.xs),
              RadioGroup<ReportReason>(
                groupValue: _reason,
                onChanged: (value) => setState(() => _reason = value),
                child: Column(
                  children: <Widget>[
                    for (final reason in ReportReason.values)
                      RadioListTile<ReportReason>(
                        value: reason,
                        enabled: !_submitting,
                        activeColor: colors.primary,
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: tokens.spacing.sm,
                        ),
                        title: Text(
                          reason.label,
                          style: styles.body.copyWith(
                            color: colors.textPrimary,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              SizedBox(height: tokens.spacing.md),
              TextField(
                controller: _note,
                enabled: !_submitting,
                maxLength: AppConfig.reportNoteMaxLength,
                minLines: 2,
                maxLines: 3,
                textCapitalization: TextCapitalization.sentences,
                style: styles.body.copyWith(color: colors.textPrimary),
                decoration: const InputDecoration(
                  hintText: 'Add a note (optional)',
                ),
              ),
              if (_errorMessage != null) ...<Widget>[
                SizedBox(height: tokens.spacing.sm),
                Semantics(
                  liveRegion: true,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      AppIconView(
                        icon: AppIcons.error,
                        size: tokens.sizing.iconSm,
                        color: colors.error.element,
                      ),
                      SizedBox(width: tokens.spacing.sm),
                      Expanded(
                        child: Text(
                          _errorMessage!,
                          style: styles.caption.copyWith(
                            color: colors.error.text,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              SizedBox(height: tokens.spacing.lg),
              ScenovaButton(
                label: _errorMessage == null ? 'Submit report' : 'Try again',
                expanded: true,
                isSubmitting: _submitting,
                onPressed: canSubmit ? () => unawaited(_submit()) : null,
              ),
              SizedBox(height: tokens.spacing.sm),
              ScenovaButton(
                label: 'Cancel',
                variant: ScenovaButtonVariant.ghost,
                expanded: true,
                onPressed: _submitting
                    ? null
                    : () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A short note in the sheet's own tone: an explanation or a caveat the reader
/// should read before they submit.
class _Callout extends StatelessWidget {
  const _Callout({
    required this.tone,
    required this.icon,
    required this.message,
  });

  final ScenovaSemanticColors tone;
  final AppIcon icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    final tokens = ScenovaTokens.of(context);
    final styles = ScenovaTextStyles.of(context);

    return Container(
      padding: EdgeInsets.all(tokens.spacing.md),
      decoration: BoxDecoration(
        color: tone.tint,
        borderRadius: BorderRadius.circular(ScenovaRadius.md),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          AppIconView(
            icon: icon,
            size: tokens.sizing.iconSm,
            color: tone.element,
          ),
          SizedBox(width: tokens.spacing.sm),
          Expanded(
            child: Text(
              message,
              style: styles.bodySmall.copyWith(color: tone.text),
            ),
          ),
        ],
      ),
    );
  }
}
