import 'package:flutter/material.dart';

import '../theme/colors.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';
import 'scenova_button.dart';

/// A bottom sheet for an action whose surface belongs to a later phase.
///
/// The clip view names Report and the paywall among its actions; those sheets
/// are their own screens, so this keeps the action present and honest rather
/// than inventing their layout.
Future<void> showComingLaterSheet(
  BuildContext context, {
  required String title,
  required String message,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetContext) {
      final colors = ScenovaColors.of(sheetContext);
      final tokens = ScenovaTokens.of(sheetContext);
      final styles = ScenovaTextStyles.of(sheetContext);
      return SafeArea(
        child: Padding(
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
              Text(title, style: styles.h3.copyWith(color: colors.textPrimary)),
              SizedBox(height: tokens.spacing.sm),
              Text(
                message,
                style: styles.body.copyWith(color: colors.textSecondary),
              ),
              SizedBox(height: tokens.spacing.lg),
              ScenovaButton(
                label: 'Close',
                variant: ScenovaButtonVariant.ghost,
                expanded: true,
                onPressed: () => Navigator.of(sheetContext).pop(),
              ),
            ],
          ),
        ),
      );
    },
  );
}
