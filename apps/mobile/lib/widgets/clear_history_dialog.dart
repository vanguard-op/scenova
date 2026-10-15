import 'package:flutter/material.dart';
import 'package:scenova_design/scenova_design.dart';

/// The confirmation the reader meets before their on-device history is removed
/// (`docs/Scenova/screens/07-preferences.md` → Overlays: "Clear-history dialog").
///
/// It warns that the action cannot be undone, blocks until it is resolved, and
/// shows progress while the clear runs. It resolves to `true` when the history
/// was removed and `false` when it was not.
class ClearHistoryDialog extends StatefulWidget {
  const ClearHistoryDialog({super.key, required this.onConfirm});

  /// Removes the reader's history, resolving true when it was removed.
  final Future<bool> Function() onConfirm;

  @override
  State<ClearHistoryDialog> createState() => _ClearHistoryDialogState();
}

class _ClearHistoryDialogState extends State<ClearHistoryDialog> {
  bool _clearing = false;

  Future<void> _clear() async {
    setState(() => _clearing = true);
    final cleared = await widget.onConfirm();
    if (!mounted) return;
    Navigator.of(context).pop(cleared);
  }

  @override
  Widget build(BuildContext context) {
    final colors = ScenovaColors.of(context);
    final tokens = ScenovaTokens.of(context);
    final styles = ScenovaTextStyles.of(context);

    return PopScope(
      // The dialog is resolved by its buttons or by the clear finishing; a
      // back gesture does not leave the reader mid-clear.
      canPop: !_clearing,
      child: AlertDialog(
        title: const Text('Clear all history?'),
        content: _clearing
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
                        'Clearing history…',
                        style: styles.body.copyWith(
                          color: colors.textSecondary,
                        ),
                      ),
                    ),
                  ],
                ),
              )
            : const Text(
                'This removes every saved lookup and its clip from this device. '
                'It cannot be undone.',
              ),
        actions: _clearing
            ? const <Widget>[]
            : <Widget>[
                ScenovaButton(
                  label: 'Keep',
                  variant: ScenovaButtonVariant.ghost,
                  onPressed: () => Navigator.of(context).pop(false),
                ),
                ScenovaButton(
                  label: 'Clear',
                  variant: ScenovaButtonVariant.destructive,
                  onPressed: _clear,
                ),
              ],
      ),
    );
  }
}
