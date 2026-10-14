import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scenova_console/models/review_queue.dart';
import 'package:scenova_console/screens/review_queue_controller.dart';
import 'package:scenova_console/screens/review_queue_screen.dart';
import 'package:scenova_console/services/review_api.dart';
import 'package:scenova_console/widgets/queue_table.dart';
import 'package:scenova_console/widgets/status_badge.dart';

import 'support/harness.dart';

Future<ReviewQueueController> pumpQueue(
  WidgetTester tester, {
  required ReviewApi api,
  VoidCallback? onSignOut,
  ValueChanged<QueueItem>? onOpenEntry,
}) async {
  final controller = ReviewQueueController(api: api, onSessionExpired: () {});
  addTearDown(controller.dispose);
  await controller.load();
  await pumpThemed(
    tester,
    ReviewQueueScreen(
      controller: controller,
      onOpenEntry: onOpenEntry ?? (_) {},
      onSignOut: onSignOut ?? () {},
    ),
  );
  return controller;
}

void main() {
  group('ReviewQueueScreen · loading', () {
    testWidgets('holds the table\'s shape while the queue loads', (
      tester,
    ) async {
      final controller = ReviewQueueController(
        api: DelayedReviewApi(),
        onSessionExpired: () {},
      );
      addTearDown(controller.dispose);
      unawaited(controller.load());

      await pumpThemed(
        tester,
        ReviewQueueScreen(
          controller: controller,
          onOpenEntry: (_) {},
          onSignOut: () {},
        ),
      );

      expect(find.byType(QueueTableSkeleton), findsOneWidget);
      expect(find.byType(QueueTable), findsNothing);
    });
  });

  group('ReviewQueueScreen · loaded', () {
    testWidgets('shows the filter bar and one row per entry', (tester) async {
      await pumpQueue(
        tester,
        api: ScriptedReviewApi(
          result: pageOf(<QueueItem>[
            queueItem(
              entryId: 'entry-bank-2',
              lemma: 'bank',
              senseLabel: '2',
              reason: 'offensive',
              age: const Duration(hours: 3),
              state: ReviewState.queued,
            ),
            queueItem(
              entryId: 'entry-crane-1',
              lemma: 'crane',
              senseLabel: '1',
              reason: 'feedback_threshold',
              age: const Duration(days: 2),
              state: ReviewState.reviewed,
            ),
          ]),
        ),
      );

      expect(find.byType(QueueTable), findsOneWidget);
      expect(find.text('bank'), findsOneWidget);
      expect(find.text('crane'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
      expect(find.text('Offensive'), findsOneWidget);
      expect(find.text('Repeated negative feedback'), findsOneWidget);
      expect(find.text('3 hours ago'), findsOneWidget);
      expect(find.text('2 days ago'), findsOneWidget);
      expect(find.byType(ReviewStatusBadge), findsNWidgets(2));
      expect(find.text('Queued'), findsOneWidget);
      expect(find.text('Reviewed'), findsOneWidget);
    });

    testWidgets('a very long word truncates but keeps its full value', (
      tester,
    ) async {
      const longWord = 'pneumonoultramicroscopicsilicovolcanoconiosis';
      await pumpQueue(
        tester,
        api: ScriptedReviewApi(
          result: pageOf(<QueueItem>[queueItem(lemma: longWord)]),
        ),
      );

      final word = tester.widget<Text>(find.text(longWord));
      expect(word.maxLines, 1);
      expect(word.overflow, TextOverflow.ellipsis);
      final tooltip = tester.widget<Tooltip>(
        find.ancestor(of: find.text(longWord), matching: find.byType(Tooltip)),
      );
      expect(tooltip.message, longWord);
    });

    testWidgets('opens an entry from its row', (tester) async {
      QueueItem? opened;
      await pumpQueue(
        tester,
        api: ScriptedReviewApi(
          result: pageOf(<QueueItem>[queueItem(lemma: 'bank')]),
        ),
        onOpenEntry: (item) => opened = item,
      );

      await tester.tap(find.text('bank'));
      await tester.pump();

      expect(opened?.lemma, 'bank');
    });

    testWidgets('pages a queue longer than one page', (tester) async {
      final api = ScriptedReviewApi(
        result: pageOf(<QueueItem>[queueItem()], page: 1, pageCount: 3),
      );
      await pumpQueue(tester, api: api);

      expect(find.text('Page 1 of 3'), findsOneWidget);
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();

      expect(api.requests.last['page'], 2);
    });
  });

  group('ReviewQueueScreen · empty', () {
    testWidgets('explains the queue when nothing is awaiting review', (
      tester,
    ) async {
      await pumpQueue(tester, api: ScriptedReviewApi(result: emptyPage));

      expect(find.text('Nothing is waiting for review'), findsOneWidget);
      expect(find.byType(QueueTable), findsNothing);
    });

    testWidgets('explains the filter when a filter matches nothing', (
      tester,
    ) async {
      final controller = await pumpQueue(
        tester,
        api: ScriptedReviewApi(result: emptyPage),
      );

      controller.setReason(ReviewReason.offensive);
      await tester.pumpAndSettle();

      expect(find.text('No clips match this filter'), findsOneWidget);
      expect(find.text('Nothing is waiting for review'), findsNothing);
    });
  });

  group('ReviewQueueScreen · error', () {
    testWidgets('shows the shared Error State with a retry', (tester) async {
      final api = ScriptedReviewApi(
        error: const ReviewApiException(
          503,
          'The review service is unavailable.',
        ),
      );
      final controller = await pumpQueue(tester, api: api);

      expect(find.text('The queue could not be loaded'), findsOneWidget);
      expect(find.text('The review service is unavailable.'), findsOneWidget);

      api.error = null;
      api.result = pageOf(<QueueItem>[queueItem()]);
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();

      expect(controller.status, ReviewQueueStatus.loaded);
      expect(find.text('bank'), findsOneWidget);
    });

    testWidgets('an offline failure explains the connection', (tester) async {
      await pumpQueue(
        tester,
        api: ScriptedReviewApi(
          error: const ReviewApiException(0, 'unreachable'),
        ),
      );

      expect(
        find.textContaining('could not reach the review service'),
        findsOneWidget,
      );
    });
  });

  group('ReviewQueueScreen · refused', () {
    testWidgets('refuses access without offering a retry, and signs out', (
      tester,
    ) async {
      var signedOut = 0;
      await pumpQueue(
        tester,
        api: ScriptedReviewApi(
          error: const ReviewApiException(403, 'The curator role is required.'),
        ),
        onSignOut: () => signedOut++,
      );

      expect(find.text('Access refused'), findsOneWidget);
      expect(find.text('Try again'), findsNothing);

      await tester.tap(find.text('Sign out'));
      await tester.pump();
      expect(signedOut, 1);
    });
  });

  group('ReviewQueueScreen · filters', () {
    testWidgets('a typed word reaches the service after the debounce', (
      tester,
    ) async {
      final api = ScriptedReviewApi(result: pageOf(<QueueItem>[queueItem()]));
      await pumpQueue(tester, api: api);

      await tester.enterText(find.byType(TextField), 'bank');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      expect(api.requests.last['word'], 'bank');
      expect(find.text('Clear filters'), findsOneWidget);
    });

    testWidgets('clearing the filters reloads the whole queue', (tester) async {
      final api = ScriptedReviewApi(result: pageOf(<QueueItem>[queueItem()]));
      final controller = await pumpQueue(tester, api: api);

      controller.setWord('bank');
      await tester.pumpAndSettle();
      expect(controller.hasActiveFilters, isTrue);

      await tester.tap(find.text('Clear filters'));
      await tester.pumpAndSettle();

      expect(controller.hasActiveFilters, isFalse);
      expect(api.requests.last['word'], isNull);
    });
  });
}
