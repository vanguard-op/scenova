import 'package:flutter/material.dart';
import 'package:scenova_design/scenova_design.dart';

import '../screens/account_controller.dart';

/// The confirmation the reader meets before their account is deleted
/// (`docs/Scenova/screens/08-account.md` → Overlays: "Delete-account dialog").
///
/// It states what the deletion removes, that the shared library is unchanged,
/// and — for a reader whose plan the store granted — that billing continues
/// there until the subscription is cancelled. It blocks until it is resolved
/// and shows progress while the deletion runs.
///
/// It resolves with the deletion's outcome: [AccountDeleted] once the account
/// is gone, and null when the reader kept it. A deletion that did not complete
/// stays in the dialog with the reason and a retry, so the reader is never left
/// believing an account was removed when it was not.
class DeleteAccountDialog extends StatefulWidget {
  const DeleteAccountDialog({
    super.key,
    required this.hasActiveSubscription,
    required this.onDelete,
  });

  /// Whether the reader holds a plan the store granted, so the confirmation
  /// says billing continues through the store until the subscription is
  /// cancelled there (`C-021`).
  final bool hasActiveSubscription;

  /// Deletes the account, resolving with the outcome of the attempt.
  final Future<AccountDeletionOutcome> Function() onDelete;

  @override
  State<DeleteAccountDialog> createState() => _DeleteAccountDialogState();
}

class _DeleteAccountDialogState extends State<DeleteAccountDialog> {
  bool _deleting = false;
  String? _error;

  Future<void> _delete() async {
    setState(() {
      _deleting = true;
      _error = null;
    });
    final outcome = await widget.onDelete();
    if (!mounted) return;
    switch (outcome) {
      case AccountDeleted():
        Navigator.of(context).pop(outcome);
      case AccountDeletionFailed(:final message):
        setState(() {
          _deleting = false;
          _error = message;
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = ScenovaColors.of(context);
    final tokens = ScenovaTokens.of(context);
    final styles = ScenovaTextStyles.of(context);

    return PopScope(
      // The dialog is resolved by its buttons or by the deletion finishing; a
      // back gesture does not leave the reader mid-delete.
      canPop: !_deleting,
      child: AlertDialog(
        title: const Text('Delete your account?'),
        content: _deleting
            ? Semantics(
                liveRegion: true,
                child: Row(
                  children: <Widget>[
                    SizedBox.square(
                      dimension: tokens.sizing.iconMd,
                      child: const CircularProgressIndicator(strokeWidth: 2),
                    ),
                    SizedBox(width: tokens.spacing.sm),
                    Expanded(
                      child: Text(
                        'Deleting your account…',
                        style: styles.body.copyWith(
                          color: colors.textSecondary,
                        ),
                      ),
                    ),
                  ],
                ),
              )
            : _explanation(context),
        actions: _deleting
            ? const <Widget>[]
            : <Widget>[
                ScenovaButton(
                  label: 'Keep my account',
                  variant: ScenovaButtonVariant.ghost,
                  onPressed: () => Navigator.of(context).pop(),
                ),
                ScenovaButton(
                  label: _error == null ? 'Delete account' : 'Try again',
                  variant: ScenovaButtonVariant.destructive,
                  onPressed: _delete,
                ),
              ],
      ),
    );
  }

  /// What the reader is told before they confirm: what goes, what stays, and
  /// — when the store is billing them — how to stop that.
  Widget _explanation(BuildContext context) {
    final colors = ScenovaColors.of(context);
    final tokens = ScenovaTokens.of(context);
    final styles = ScenovaTextStyles.of(context);
    final message = _error;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (message != null) ...<Widget>[
          _DeletionNotice(message: message),
          SizedBox(height: tokens.spacing.md),
        ],
        Text(
          'Your account and your plan are removed, and the lookups saved on '
          'this device are cleared. Clips already in the shared library stay.',
          style: styles.body.copyWith(color: colors.textSecondary),
        ),
        if (widget.hasActiveSubscription) ...<Widget>[
          SizedBox(height: tokens.spacing.md),
          Text(
            'Your subscription is not cancelled here. Billing continues '
            'through the store until you cancel it there.',
            style: styles.body.copyWith(color: colors.textSecondary),
          ),
        ],
      ],
    );
  }
}

/// The reason a deletion did not complete, in the error family so it reads as
/// something to act on.
class _DeletionNotice extends StatelessWidget {
  const _DeletionNotice({required this.message});

  final String message;

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
          color: colors.error.tint,
          borderRadius: BorderRadius.circular(ScenovaRadius.md),
          border: Border.all(color: colors.error.border),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Padding(
              padding: EdgeInsets.only(top: tokens.spacing.xs),
              child: AppIconView(
                icon: AppIcons.error,
                size: tokens.sizing.iconSm,
                color: colors.error.element,
              ),
            ),
            SizedBox(width: tokens.spacing.sm),
            Expanded(
              child: Text(
                message,
                style: styles.bodySmall.copyWith(color: colors.error.text),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
