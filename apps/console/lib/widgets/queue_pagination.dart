import 'package:flutter/material.dart';

import '../theme/colors.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';
import 'app_icons.dart';
import 'scenova_button.dart';

/// The Pagination (`docs/Scenova/screens/09-review-queue.md` → Components):
/// pages a queue longer than one page, newest report first.
///
/// It reports the queue's own page and page count, so the console never invents
/// a page the service would clamp away.
class QueuePagination extends StatelessWidget {
  const QueuePagination({
    super.key,
    required this.page,
    required this.pageCount,
    required this.enabled,
    required this.onGoToPage,
  });

  final int page;
  final int pageCount;
  final bool enabled;
  final ValueChanged<int> onGoToPage;

  @override
  Widget build(BuildContext context) {
    final colors = ScenovaColors.of(context);
    final tokens = ScenovaTokens.of(context);
    final styles = ScenovaTextStyles.of(context);

    final hasPrevious = page > 1;
    final hasNext = page < pageCount;

    return Padding(
      padding: EdgeInsets.only(top: tokens.spacing.lg),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: <Widget>[
          Semantics(
            liveRegion: true,
            child: Text(
              'Page $page of $pageCount',
              style: styles.bodySmall.copyWith(color: colors.textSecondary),
            ),
          ),
          Row(
            children: <Widget>[
              ScenovaButton(
                label: 'Previous',
                variant: ScenovaButtonVariant.outline,
                icon: AppIcons.previous,
                onPressed: enabled && hasPrevious
                    ? () => onGoToPage(page - 1)
                    : null,
              ),
              SizedBox(width: tokens.spacing.sm),
              ScenovaButton(
                label: 'Next',
                variant: ScenovaButtonVariant.outline,
                icon: AppIcons.next,
                onPressed: enabled && hasNext
                    ? () => onGoToPage(page + 1)
                    : null,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
