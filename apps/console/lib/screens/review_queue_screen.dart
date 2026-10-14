import 'package:flutter/material.dart';

import '../models/review_queue.dart';
import '../theme/colors.dart';
import '../theme/tokens.dart';
import '../theme/typography.dart';
import '../widgets/app_icons.dart';
import '../widgets/filter_bar.dart';
import '../widgets/queue_pagination.dart';
import '../widgets/queue_table.dart';
import '../widgets/states.dart';
import 'review_queue_controller.dart';

/// Screen 9: the Review Queue (`docs/Scenova/screens/09-review-queue.md`).
///
/// The console's first screen: the entries readers reported and flagged, one
/// row per entry, newest report first, narrowed by a reason, a state, or a word
/// and paged when the queue runs long.
class ReviewQueueScreen extends StatelessWidget {
  const ReviewQueueScreen({
    super.key,
    required this.controller,
    required this.onOpenEntry,
    required this.onSignOut,
  });

  final ReviewQueueController controller;
  final ValueChanged<QueueItem> onOpenEntry;

  /// Signs out when an authenticated operator lacks the curator role.
  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        return SingleChildScrollView(
          padding: EdgeInsets.all(ScenovaTokens.of(context).spacing.xl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              const _QueueHeading(),
              QueueFilterBar(
                reason: controller.reasonFilter,
                state: controller.stateFilter,
                word: controller.wordFilter,
                enabled: controller.status == ReviewQueueStatus.loaded,
                hasActiveFilters: controller.hasActiveFilters,
                onReasonChanged: controller.setReason,
                onStateChanged: controller.setState,
                onWordChanged: controller.setWord,
                onClear: controller.clearFilters,
                onRefresh: controller.refresh,
              ),
              _QueueBody(
                controller: controller,
                onOpenEntry: onOpenEntry,
                onSignOut: onSignOut,
              ),
            ],
          ),
        );
      },
    );
  }
}

class _QueueHeading extends StatelessWidget {
  const _QueueHeading();

  @override
  Widget build(BuildContext context) {
    final colors = ScenovaColors.of(context);
    final tokens = ScenovaTokens.of(context);
    final styles = ScenovaTextStyles.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          'Review queue',
          style: styles.h1.copyWith(color: colors.textPrimary),
        ),
        SizedBox(height: tokens.spacing.xs),
        Text(
          'Entries readers reported or flagged, newest first.',
          style: styles.body.copyWith(color: colors.textSecondary),
        ),
      ],
    );
  }
}

/// The queue's own area: the table, its loading shape, its empty explanation,
/// its failure, and the pagination.
class _QueueBody extends StatelessWidget {
  const _QueueBody({
    required this.controller,
    required this.onOpenEntry,
    required this.onSignOut,
  });

  final ReviewQueueController controller;
  final ValueChanged<QueueItem> onOpenEntry;
  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context) {
    switch (controller.status) {
      case ReviewQueueStatus.loading:
        return const QueueTableSkeleton();
      case ReviewQueueStatus.refused:
        return _CentredState(
          child: EmptyState(
            icon: AppIcons.refused,
            headline: 'Access refused',
            body:
                'This account does not have the curator role. '
                'Ask an administrator to grant it, then sign in again.',
            actionLabel: 'Sign out',
            onAction: onSignOut,
          ),
        );
      case ReviewQueueStatus.error:
        return _CentredState(
          child: ErrorState(
            headline: 'The queue could not be loaded',
            body: _failureBody(controller),
            onRetry: controller.refresh,
          ),
        );
      case ReviewQueueStatus.loaded:
        return _LoadedQueue(controller: controller, onOpenEntry: onOpenEntry);
    }
  }

  /// A failure's body, worded for what the curator can do about it.
  static String _failureBody(ReviewQueueController controller) {
    final failure = controller.failure;
    if (failure == null) return 'Something went wrong. Try again.';
    if (failure.isOffline) {
      return 'The console could not reach the review service. '
          'Check your connection and try again.';
    }
    return failure.message;
  }
}

/// Gives a centred state breathing room inside the scrolling body.
class _CentredState extends StatelessWidget {
  const _CentredState({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final tokens = ScenovaTokens.of(context);
    return Padding(
      padding: EdgeInsets.symmetric(vertical: tokens.spacing.xxl),
      child: child,
    );
  }
}

class _LoadedQueue extends StatelessWidget {
  const _LoadedQueue({required this.controller, required this.onOpenEntry});

  final ReviewQueueController controller;
  final ValueChanged<QueueItem> onOpenEntry;

  @override
  Widget build(BuildContext context) {
    if (controller.items.isEmpty) {
      // A filter that matches nothing explains the filter; an empty queue
      // explains the queue (`docs/Scenova/screens/09-review-queue.md` →
      // Edge Cases).
      return _CentredState(
        child: controller.hasActiveFilters
            ? EmptyState(
                icon: AppIcons.report,
                headline: 'No clips match this filter',
                body: 'Try a different reason, state, or word.',
                actionLabel: 'Clear filters',
                onAction: controller.clearFilters,
              )
            : EmptyState(
                icon: AppIcons.report,
                headline: 'Nothing is waiting for review',
                body: 'Reported and flagged clips appear here, newest first.',
                actionLabel: 'Refresh',
                onAction: controller.refresh,
              ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (controller.isRefreshing)
          Padding(
            padding: EdgeInsets.only(
              bottom: ScenovaTokens.of(context).spacing.sm,
            ),
            child: const LinearProgressIndicator(minHeight: 2),
          ),
        QueueTable(items: controller.items, onOpen: onOpenEntry),
        QueuePagination(
          page: controller.page,
          pageCount: controller.pageCount,
          enabled: !controller.isRefreshing,
          onGoToPage: controller.goToPage,
        ),
      ],
    );
  }
}
