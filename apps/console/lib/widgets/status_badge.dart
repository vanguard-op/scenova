import 'package:flutter/material.dart';

import '../models/review_queue.dart';
import '../theme/colors.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';
import 'app_icons.dart';

/// The Review Status Badge (`docs/Scenova/screens.md` → "Shared / Common
/// Components").
///
/// It shows the queue item's review state in the semantic tokens — a tinted
/// background, a border, and the family's text shade — with the state's own
/// label and icon, so the state never rests on colour alone.
class ReviewStatusBadge extends StatelessWidget {
  const ReviewStatusBadge({super.key, required this.state});

  final ReviewState state;

  @override
  Widget build(BuildContext context) {
    final colors = ScenovaColors.of(context);
    final tokens = ScenovaTokens.of(context);
    final styles = ScenovaTextStyles.of(context);
    final family = _family(colors, state);

    return Semantics(
      label: 'Review state: ${state.label}',
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
              icon: _icon(state),
              size: tokens.sizing.iconSm,
              color: family.text,
            ),
            SizedBox(width: tokens.spacing.xs),
            Text(
              state.label,
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

  /// The semantic family the state reads in. Queued needs attention, reviewed
  /// is under way, and actioned is resolved.
  static ScenovaSemanticColors _family(
    ScenovaColors colors,
    ReviewState state,
  ) {
    return switch (state) {
      ReviewState.queued => colors.warning,
      ReviewState.reviewed => colors.info,
      ReviewState.actioned => colors.success,
    };
  }

  static AppIcon _icon(ReviewState state) {
    return switch (state) {
      ReviewState.queued => AppIcons.queued,
      ReviewState.reviewed => AppIcons.seeIt,
      ReviewState.actioned => AppIcons.actioned,
    };
  }
}
