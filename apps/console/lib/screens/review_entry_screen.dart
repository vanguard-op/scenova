import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../format/relative_age.dart';
import '../models/review_queue.dart';
import '../theme/colors.dart';
import '../theme/layout.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';
import '../widgets/app_icons.dart';
import '../widgets/scenova_button.dart';
import '../widgets/status_badge.dart';

/// Screen 10: Review Entry (`docs/Scenova/screens/10-review-entry.md`).
///
/// The queue drills down into one entry. This screen shows the entry the queue
/// carried and its review state; the entry's clip, its reports, its feedback,
/// and the review actions load here from the entry interface.
class ReviewEntryScreen extends StatelessWidget {
  const ReviewEntryScreen({
    super.key,
    required this.item,
    required this.onBack,
  });

  /// The entry as the queue listed it.
  final QueueItem item;

  /// Returns to the queue.
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final colors = ScenovaColors.of(context);
    final tokens = ScenovaTokens.of(context);
    final styles = ScenovaTextStyles.of(context);

    return SingleChildScrollView(
      padding: EdgeInsets.all(tokens.spacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          ScenovaButton(
            label: 'Back to the queue',
            variant: ScenovaButtonVariant.ghost,
            icon: AppIcons.previous,
            onPressed: onBack,
          ),
          SizedBox(height: tokens.spacing.md),
          Text(
            item.lemma,
            style: styles.display.copyWith(color: colors.textPrimary),
          ),
          SizedBox(height: tokens.spacing.xs),
          Text(
            'Sense ${item.senseLabel}',
            style: styles.bodyLarge.copyWith(color: colors.textSecondary),
          ),
          SizedBox(height: tokens.spacing.lg),
          ReviewStatusBadge(state: item.state),
          SizedBox(height: tokens.spacing.lg),
          _DetailRow(label: 'Reason', value: item.reasonLabel),
          _DetailRow(
            label: 'Queued',
            value:
                '${DateFormat.yMMMd().add_jm().format(item.queuedAt.toLocal())} '
                '· ${relativeAge(item.queuedAt)}',
          ),
        ],
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colors = ScenovaColors.of(context);
    final tokens = ScenovaTokens.of(context);
    final styles = ScenovaTextStyles.of(context);

    return Padding(
      padding: EdgeInsets.only(bottom: tokens.spacing.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: ConsoleLayout.detailLabelWidth,
            child: Text(
              label,
              style: styles.bodySmall.copyWith(color: colors.textSecondary),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: styles.body.copyWith(color: colors.textPrimary),
            ),
          ),
        ],
      ),
    );
  }
}
