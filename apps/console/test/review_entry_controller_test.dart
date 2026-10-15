import 'package:flutter_test/flutter_test.dart';
import 'package:scenova_console/models/review_entry.dart';
import 'package:scenova_console/models/review_queue.dart';
import 'package:scenova_console/screens/review_entry_controller.dart';
import 'package:scenova_console/services/review_api.dart';

import 'support/harness.dart';

void main() {
  group('ReviewEntryController · load', () {
    test('exposes the entry, its evidence, and its state', () async {
      final controller = ReviewEntryController(
        api: ScriptedReviewApi(
          entryResult: entryDetail(
            lemma: 'bank',
            glossPhrase: 'a river bank',
            state: ReviewState.queued,
          ),
        ),
        entryId: 'entry-bank-2',
        onSessionExpired: () {},
      );
      addTearDown(controller.dispose);

      await controller.load();

      expect(controller.status, ReviewEntryStatus.loaded);
      expect(controller.detail!.entry.lemma, 'bank');
      expect(controller.detail!.entry.glossPhrase, 'a river bank');
      expect(controller.detail!.state, ReviewState.queued);
      expect(controller.detail!.reports, hasLength(1));
      expect(controller.detail!.feedback, hasLength(1));
      expect(controller.canAct, isTrue);
    });

    test(
      'reports a session that ended rather than an error to retry',
      () async {
        var expired = 0;
        final controller = ReviewEntryController(
          api: ScriptedReviewApi(
            entryError: const ReviewApiException(401, 'The session ended.'),
          ),
          entryId: 'entry-bank-2',
          onSessionExpired: () => expired++,
        );
        addTearDown(controller.dispose);

        await controller.load();

        expect(expired, 1);
        expect(controller.failure, isNull);
      },
    );

    test('keeps a refused role as its own state', () async {
      final controller = ReviewEntryController(
        api: ScriptedReviewApi(
          entryError: const ReviewApiException(403, 'The curator role.'),
        ),
        entryId: 'entry-bank-2',
        onSessionExpired: () {},
      );
      addTearDown(controller.dispose);

      await controller.load();

      expect(controller.status, ReviewEntryStatus.refused);
      expect(controller.failure!.isForbidden, isTrue);
    });

    test('reads an entry with nothing queued as not found', () async {
      final controller = ReviewEntryController(
        api: ScriptedReviewApi(
          entryError: const ReviewApiException(
            404,
            'This entry is no longer waiting for review.',
          ),
        ),
        entryId: 'entry-bank-2',
        onSessionExpired: () {},
      );
      addTearDown(controller.dispose);

      await controller.load();

      expect(controller.status, ReviewEntryStatus.error);
      expect(controller.failure!.isNotFound, isTrue);
    });

    test('holds the loading state while the entry is in flight', () async {
      final api = DelayedReviewApi();
      final controller = ReviewEntryController(
        api: api,
        entryId: 'entry-bank-2',
        onSessionExpired: () {},
      );
      addTearDown(controller.dispose);

      final pending = controller.load();
      expect(controller.status, ReviewEntryStatus.loading);

      api.entryCompleter.complete(entryDetail());
      await pending;
      expect(controller.status, ReviewEntryStatus.loaded);
    });
  });

  group('ReviewEntryController · act', () {
    Future<ReviewEntryController> loaded(ScriptedReviewApi api) async {
      final controller = ReviewEntryController(
        api: api,
        entryId: 'entry-bank-2',
        onSessionExpired: () {},
      );
      addTearDown(controller.dispose);
      await controller.load();
      return controller;
    }

    test('sends the choice with the state the curator saw', () async {
      final api = ScriptedReviewApi();
      final controller = await loaded(api);

      final outcome = await controller.act(
        EntryAction.choose,
        chosenClip: ChosenClip.candidate,
      );

      expect(outcome, isA<EntryActionRecorded>());
      expect(api.actions.single.action, EntryAction.choose);
      expect(api.actions.single.chosenClip, ChosenClip.candidate);
      expect(api.actions.single.expectedState, ReviewState.queued);
      expect(controller.detail!.entry.status, EntryStatus.active);
      expect(controller.detail!.state, ReviewState.actioned);
    });

    test(
      'choosing the candidate makes it the clip the library serves',
      () async {
        final api = ScriptedReviewApi();
        final controller = await loaded(api);
        final candidate = controller.detail!.candidate!;

        await controller.act(
          EntryAction.choose,
          chosenClip: ChosenClip.candidate,
        );

        expect(controller.detail!.entry.clip.url, candidate.url);
        // The candidate is spent once it is the clip the library serves.
        expect(controller.detail!.hasCandidate, isFalse);
      },
    );

    test(
      'choosing the serving clip keeps it and spends the candidate',
      () async {
        final api = ScriptedReviewApi();
        final controller = await loaded(api);
        final serving = controller.detail!.entry.clip.url;

        await controller.act(
          EntryAction.choose,
          chosenClip: ChosenClip.serving,
        );

        expect(controller.detail!.entry.clip.url, serving);
        expect(controller.detail!.hasCandidate, isFalse);
      },
    );

    test(
      'refuses a choice that names no clip, without calling the service',
      () async {
        final api = ScriptedReviewApi();
        final controller = await loaded(api);

        final outcome = await controller.act(EntryAction.choose);

        expect(outcome, isA<EntryActionFailed>());
        expect(api.actions, isEmpty);
      },
    );

    test('records a phrase edit and leaves the entry under review', () async {
      final api = ScriptedReviewApi();
      final controller = await loaded(api);

      final outcome = await controller.act(
        EntryAction.editPhrase,
        phrase: 'a place to keep money',
      );

      expect(outcome, isA<EntryActionRecorded>());
      expect(api.actions.single.phrase, 'a place to keep money');
      expect(controller.detail!.entry.glossPhrase, 'a place to keep money');
      expect(controller.detail!.state, ReviewState.reviewed);
      expect(controller.detail!.hasCandidate, isFalse);
    });

    test(
      'reads a conflict as the entry having moved, and re-reads it',
      () async {
        final api = ScriptedReviewApi();
        final controller = await loaded(api);

        api.actionError = const ReviewApiException(
          409,
          'This entry has already moved since you opened it.',
        );
        api.entryResult = entryDetail(state: ReviewState.actioned);

        final outcome = await controller.act(
          EntryAction.choose,
          chosenClip: ChosenClip.serving,
        );

        expect(outcome, isA<EntryActionMoved>());
        expect(controller.status, ReviewEntryStatus.moved);
        expect(controller.canAct, isFalse);
        // The entry is re-read, so the note can show its current state.
        expect(api.entryRequests, hasLength(2));
        expect(controller.detail!.state, ReviewState.actioned);
      },
    );

    test('keeps a retryable failure for the Error State to retry', () async {
      final api = ScriptedReviewApi(
        actionError: const ReviewApiException(
          503,
          'The review service is unavailable.',
        ),
      );
      final controller = await loaded(api);

      final outcome = await controller.act(
        EntryAction.choose,
        chosenClip: ChosenClip.serving,
      );

      expect(outcome, isA<EntryActionFailed>());
      expect(controller.status, ReviewEntryStatus.loaded);
      expect(controller.actionFailure!.isRetryable, isTrue);
      expect(controller.failedAction, EntryAction.choose);
      expect(controller.failedChosenClip, ChosenClip.serving);

      api.actionError = null;
      final retried = await controller.retryFailedAction();

      expect(retried, isA<EntryActionRecorded>());
      expect(api.actions, hasLength(2));
      // The retry re-sends the same choice.
      expect(api.actions.last.chosenClip, ChosenClip.serving);
      expect(controller.actionFailure, isNull);
      expect(controller.detail!.entry.status, EntryStatus.active);
    });

    test('reports a session that ended during an action', () async {
      var expired = 0;
      final api = ScriptedReviewApi(
        actionError: const ReviewApiException(401, 'The session ended.'),
      );
      final controller = ReviewEntryController(
        api: api,
        entryId: 'entry-bank-2',
        onSessionExpired: () => expired++,
      );
      addTearDown(controller.dispose);
      await controller.load();

      final outcome = await controller.act(
        EntryAction.choose,
        chosenClip: ChosenClip.serving,
      );

      expect(outcome, isA<EntryActionFailed>());
      expect(expired, 1);
      expect(controller.actionFailure, isNull);
    });

    test('refuses the screen when the role is gone', () async {
      final api = ScriptedReviewApi(
        actionError: const ReviewApiException(403, 'The curator role.'),
      );
      final controller = await loaded(api);

      await controller.act(EntryAction.choose, chosenClip: ChosenClip.serving);

      expect(controller.status, ReviewEntryStatus.refused);
    });
  });
}
