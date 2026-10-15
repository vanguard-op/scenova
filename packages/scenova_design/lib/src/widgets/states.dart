import 'package:flutter/material.dart';

import '../theme/colors.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';
import 'app_icons.dart';
import 'scenova_button.dart';

/// The width a centred state is held to when a screen does not name its own.
///
/// A headline reads on one or two lines at this measure rather than stretching
/// across a wide surface.
const double _defaultStateMaxWidth = 360;

/// The shared Empty State (`docs/Scenova/screens.md` → "Shared / Common
/// Components"): a centred icon, a short headline, a line of guidance, and one
/// call to action.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.headline,
    required this.body,
    this.actionLabel,
    this.onAction,
    this.maxWidth = _defaultStateMaxWidth,
  });

  final AppIcon icon;
  final String headline;
  final String body;
  final String? actionLabel;
  final VoidCallback? onAction;

  /// The measure the state is held to. A wide surface passes its own so the
  /// headline does not stretch across it.
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final colors = ScenovaColors.of(context);
    final tokens = ScenovaTokens.of(context);
    final styles = ScenovaTextStyles.of(context);

    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: tokens.spacing.lg,
            vertical: tokens.spacing.xl,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              AppIconView(
                icon: icon,
                size: tokens.sizing.iconLg,
                color: colors.iconDefault,
              ),
              SizedBox(height: tokens.spacing.md),
              Text(
                headline,
                style: styles.h2.copyWith(color: colors.textPrimary),
                textAlign: TextAlign.center,
              ),
              SizedBox(height: tokens.spacing.sm),
              Text(
                body,
                style: styles.body.copyWith(color: colors.textSecondary),
                textAlign: TextAlign.center,
              ),
              if (actionLabel != null && onAction != null) ...<Widget>[
                SizedBox(height: tokens.spacing.lg),
                ScenovaButton(
                  label: actionLabel!,
                  onPressed: onAction,
                  variant: ScenovaButtonVariant.secondary,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// The shared Error State (`docs/Scenova/screens.md`): a centred icon, a short
/// headline, and a Retry.
class ErrorState extends StatelessWidget {
  const ErrorState({
    super.key,
    required this.headline,
    required this.body,
    this.retryLabel = 'Try again',
    this.onRetry,
    this.maxWidth = _defaultStateMaxWidth,
  });

  final String headline;
  final String body;
  final String retryLabel;
  final VoidCallback? onRetry;

  /// The measure the state is held to. A wide surface passes its own so the
  /// headline does not stretch across it.
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final colors = ScenovaColors.of(context);
    final tokens = ScenovaTokens.of(context);
    final styles = ScenovaTextStyles.of(context);

    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: tokens.spacing.lg,
            vertical: tokens.spacing.xl,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              AppIconView(
                icon: AppIcons.error,
                size: tokens.sizing.iconLg,
                color: colors.error.element,
              ),
              SizedBox(height: tokens.spacing.md),
              Text(
                headline,
                style: styles.h2.copyWith(color: colors.textPrimary),
                textAlign: TextAlign.center,
              ),
              SizedBox(height: tokens.spacing.sm),
              Text(
                body,
                style: styles.body.copyWith(color: colors.textSecondary),
                textAlign: TextAlign.center,
              ),
              if (onRetry != null) ...<Widget>[
                SizedBox(height: tokens.spacing.lg),
                ScenovaButton(
                  label: retryLabel,
                  onPressed: onRetry,
                  variant: ScenovaButtonVariant.outline,
                  icon: AppIcons.retry,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
