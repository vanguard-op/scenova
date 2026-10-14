import 'package:flutter_test/flutter_test.dart';
import 'package:scenova_console/models/review_queue.dart';
import 'package:scenova_console/screens/review_queue_controller.dart';
import 'package:scenova_console/services/review_api.dart';

import 'support/harness.dart';

void main() {
  group('ReviewQueueController', () {
    test('starts loading, then shows the queue', () async {
      final api = ScriptedReviewApi(
        result: pageOf(<QueueItem>[queueItem()], openCount: 4),
      );
      final controller = ReviewQueueController(
        api: api,
        onSessionExpired: () {},
      );
      addTearDown(controller.dispose);

      expect(controller.status, ReviewQueueStatus.loading);
      await controller.load();

      expect(controller.status, ReviewQueueStatus.loaded);
      expect(controller.items, hasLength(1));
      expect(controller.openCount, 4);
      expect(controller.page, 1);
      expect(controller.pageCount, 1);
      expect(controller.isRefreshing, isFalse);
    });

    test('an empty queue is loaded, not an error', () async {
      final controller = ReviewQueueController(
        api: ScriptedReviewApi(result: emptyPage),
        onSessionExpired: () {},
      );
      addTearDown(controller.dispose);

      await controller.load();

      expect(controller.status, ReviewQueueStatus.loaded);
      expect(controller.items, isEmpty);
      expect(controller.hasActiveFilters, isFalse);
    });

    test('an unavailable service is a retryable error', () async {
      final api = ScriptedReviewApi(
        error: const ReviewApiException(
          503,
          'The review service is unavailable.',
        ),
      );
      final controller = ReviewQueueController(
        api: api,
        onSessionExpired: () {},
      );
      addTearDown(controller.dispose);

      await controller.load();

      expect(controller.status, ReviewQueueStatus.error);
      expect(controller.failure!.isRetryable, isTrue);

      // The retry re-asks, and a healthy service recovers.
      api.error = null;
      api.result = emptyPage;
      await controller.refresh();
      expect(controller.status, ReviewQueueStatus.loaded);
    });

    test('a refused role is its own state, not a retry', () async {
      final controller = ReviewQueueController(
        api: ScriptedReviewApi(
          error: const ReviewApiException(403, 'The curator role is required.'),
        ),
        onSessionExpired: () {},
      );
      addTearDown(controller.dispose);

      await controller.load();

      expect(controller.status, ReviewQueueStatus.refused);
      expect(controller.failure!.isForbidden, isTrue);
    });

    test('a session that ends is reported, not shown as a failure', () async {
      var expired = 0;
      final controller = ReviewQueueController(
        api: ScriptedReviewApi(
          error: const ReviewApiException(
            401,
            'The operator session is missing.',
          ),
        ),
        onSessionExpired: () => expired++,
      );
      addTearDown(controller.dispose);

      await controller.load();

      expect(expired, 1);
      expect(controller.status, isNot(ReviewQueueStatus.error));
      expect(controller.status, isNot(ReviewQueueStatus.refused));
    });

    test('a filter reloads from the first page', () async {
      final api = ScriptedReviewApi(result: pageOf(<QueueItem>[queueItem()]));
      final controller = ReviewQueueController(
        api: api,
        onSessionExpired: () {},
      );
      addTearDown(controller.dispose);
      await controller.load();
      controller.goToPage(2);
      await pumpEventQueue();

      controller.setReason(ReviewReason.offensive);
      await pumpEventQueue();

      expect(controller.reasonFilter, ReviewReason.offensive);
      expect(controller.hasActiveFilters, isTrue);
      expect(controller.page, 1);
      expect(api.requests.last['reason'], 'offensive');
      expect(api.requests.last['page'], 1);
    });

    test('clearing the filters reloads the whole queue', () async {
      final api = ScriptedReviewApi(result: pageOf(<QueueItem>[queueItem()]));
      final controller = ReviewQueueController(
        api: api,
        onSessionExpired: () {},
      );
      addTearDown(controller.dispose);
      await controller.load();

      controller.setState(ReviewState.queued);
      controller.setWord('bank');
      await pumpEventQueue();
      expect(controller.hasActiveFilters, isTrue);

      controller.clearFilters();
      await pumpEventQueue();

      expect(controller.hasActiveFilters, isFalse);
      expect(api.requests.last['reason'], isNull);
      expect(api.requests.last['state'], isNull);
      expect(api.requests.last['word'], isNull);
    });

    test('paging stays inside the queue and asks for the page', () async {
      final api = ScriptedReviewApi(
        result: pageOf(<QueueItem>[queueItem()], page: 1, pageCount: 3),
      );
      final controller = ReviewQueueController(
        api: api,
        onSessionExpired: () {},
      );
      addTearDown(controller.dispose);
      await controller.load();

      controller.goToPage(2);
      await pumpEventQueue();
      expect(controller.page, 2);
      expect(api.requests.last['page'], 2);

      controller.goToPage(99);
      await pumpEventQueue();
      expect(controller.page, 3);
      expect(api.requests.last['page'], 3);

      controller.goToPage(0);
      await pumpEventQueue();
      expect(controller.page, 1);
      expect(api.requests.last['page'], 1);
    });

    test('a stale response never overwrites a newer one', () async {
      final api = ScriptedReviewApi(
        result: pageOf(<QueueItem>[queueItem(lemma: 'bank')]),
      );
      final controller = ReviewQueueController(
        api: api,
        onSessionExpired: () {},
      );
      addTearDown(controller.dispose);

      final first = controller.load();
      api.result = pageOf(<QueueItem>[queueItem(lemma: 'crane')]);
      final second = controller.load();
      await Future.wait(<Future<void>>[first, second]);

      expect(controller.items.single.lemma, 'crane');
    });
  });
}
