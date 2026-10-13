import 'package:flutter/material.dart';

import '../theme/colors.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';
import 'app_icons.dart';

/// The shared Offline Banner (`docs/Scenova/screens.md`).
///
/// A persistent inline banner that says the device is offline. It is shown
/// where history or saved clips still serve, and pairs with a state that
/// explains what is and is not available rather than blocking the screen.
class OfflineBanner extends StatelessWidget {
  const OfflineBanner({super.key, this.message});

  final String? message;

  @override
  Widget build(BuildContext context) {
    final colors = ScenovaColors.of(context);
    final tokens = ScenovaTokens.of(context);
    final styles = ScenovaTextStyles.of(context);

    return Semantics(
      liveRegion: true,
      child: Container(
        width: double.infinity,
        padding: EdgeInsets.symmetric(
          horizontal: tokens.spacing.md,
          vertical: tokens.spacing.sm,
        ),
        decoration: BoxDecoration(
          color: colors.warningTint,
          borderRadius: BorderRadius.circular(ScenovaRadius.md),
        ),
        child: Row(
          children: <Widget>[
            Icon(
              AppIcons.offline,
              size: tokens.sizing.iconSm,
              color: colors.warning,
            ),
            SizedBox(width: tokens.spacing.sm),
            Expanded(
              child: Text(
                message ?? 'You are offline. Saved clips still play.',
                style: styles.bodySmall.copyWith(color: colors.textPrimary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
