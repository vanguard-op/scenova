import 'package:flutter/material.dart';

import '../theme/colors.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';
import 'app_icons.dart';

/// A pill showing a state in the semantic tokens: a tinted background, a
/// border, and the family's text shade.
///
/// `docs/Scenova/screens.md` → "Shared / Common Components" → "Review Status
/// Badge": the state never rests on colour alone, so the badge always carries
/// its own label and icon beside the colour. It takes the semantic family the
/// caller resolved, so a screen decides what a state means and the badge only
/// draws it.
class StatusBadge extends StatelessWidget {
  const StatusBadge({
    super.key,
    required this.label,
    required this.icon,
    required this.family,
    this.semanticLabel,
  });

  /// The state's own words, such as "Queued" or "Serving".
  final String label;

  final IconData icon;

  /// The semantic family the state reads in.
  final ScenovaSemanticColors family;

  /// The spoken label, when the badge needs to say what kind of state it is.
  /// Defaults to [label].
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final tokens = ScenovaTokens.of(context);
    final styles = ScenovaTextStyles.of(context);

    return Semantics(
      label: semanticLabel ?? label,
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: tokens.spacing.sm,
          vertical: tokens.spacing.xs,
        ),
        decoration: BoxDecoration(
          color: family.tint,
          borderRadius: BorderRadius.circular(ScenovaRadius.full),
          border: Border.all(color: family.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            AppIconView(
              icon: icon,
              size: tokens.sizing.iconSm,
              color: family.text,
            ),
            SizedBox(width: tokens.spacing.xs),
            Text(
              label,
              style: styles.caption.copyWith(
                color: family.text,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
