import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scenova_console/models/review_entry.dart';
import 'package:scenova_console/models/review_queue.dart';
import 'package:scenova_console/screens/review_entry_controller.dart';
import 'package:scenova_console/screens/review_entry_screen.dart';
import 'package:scenova_console/services/review_api.dart';
import 'package:scenova_console/widgets/clip_player.dart';
import 'package:scenova_console/widgets/scenova_button.dart';
import 'package:scenova_console/widgets/skeleton.dart';
import 'package:scenova_console/widgets/status_badge.dart';

import 'support/harness.dart';

/// Pumps an already-built controller's screen.
Future<void> pumpController(
  WidgetTester tester,
  ReviewEntryController controller, {
  VoidCallback? onBack,
}) {
  return pumpThemed(
    tester,
    ReviewEntryScreen(
      entryId: controller.entryId,
      onBack: onBack ?? () {},
      controller: controller,
    ),
  );
}

/// Lets a confirmation SnackBar run out, so no timer outlives the test.
Future<void> settleSnackBar(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 5));
  await tester.pumpAndSettle();
}

/// Scrolls [finder] into view, then taps it.
///
/// The entry is taller than the test window, so its actions sit below the fold;
/// a bare tap would miss them.
Future<void> tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  group('ReviewEntryScreen · loading', () {
    testWidgets('holds the entry\'s shape while it loads', (tester) async {
      final api = DelayedReviewApi();
      final controller = ReviewEntryController(
        api: api,
        entryId: 'entry-bank-2',
        onSessionExpired: () {},
      );
      addTearDown(controller.dispose);
      unawaited(controller.load());

      await pumpController(tester, controller);

      expect(find.byType(SkeletonBlock), findsWidgets);
      expect(find.text('Decision'), findsNothing);

      api.entryCompleter.complete(entryDetail());
      await tester.pump();
      await tester.pump();
      expect(find.text('Decision'), findsOneWidget);
    });
  });

  group('ReviewEntryScreen · loaded', () {
    testWidgets('shows the clip, the word and sense, the phrase, and the '
        'evidence', (tester) async {
      await pumpEntryScreen(
        tester,
        api: ScriptedReviewApi(
          entryResult: entryDetail(
            lemma: 'bank',
            glossPhrase: 'a river bank',
            hasAudio: true,
          ),
        ),
      );

      expect(find.text('bank'), findsOneWidget);
      expect(find.text('Sense 2'), findsOneWidget);
      expect(find.text('bank · sense 2'), findsOneWidget);
      expect(find.text('a river bank'), findsWidgets);
      expect(find.byType(ClipPlayer), findsOneWidget);

      // The evidence: the report with its reason and note, and the rating.
      expect(find.text('Evidence'), findsOneWidget);
      expect(find.text('Wrong meaning'), findsOneWidget);
      expect(find.text('Not the sense I meant.'), findsOneWidget);
      expect(find.text('Wrong'), findsOneWidget);

      // Both states: where it sits in the queue and whether it serves.
      expect(find.byType(ReviewStatusBadge), findsOneWidget);
      expect(find.byType(EntryStatusBadge), findsOneWidget);
      expect(find.text('Queued'), findsOneWidget);
      expect(find.text('Serving'), findsOneWidget);

      // The actions and the phrase edit.
      expect(find.text('Clear'), findsOneWidget);
      expect(find.text('Hold'), findsOneWidget);
      expect(find.text('Retire'), findsOneWidget);
      expect(find.text('Replace'), findsOneWidget);
      expect(find.text('Regenerate'), findsOneWidget);
    });

    testWidgets('mutes a clip with audio and offers the sound explicitly', (
      tester,
    ) async {
      await pumpEntryScreen(
        tester,
        api: ScriptedReviewApi(entryResult: entryDetail(hasAudio: true)),
      );

      expect(find.text('Muted'), findsOneWidget);
      expect(find.text('Listen'), findsOneWidget);
    });

    testWidgets('shows an entry with no evidence without inventing any', (
      tester,
    ) async {
      await pumpEntryScreen(
        tester,
        api: ScriptedReviewApi(entryResult: entryDetailWithoutEvidence()),
      );

      expect(
        find.text('No reader reports against this entry.'),
        findsOneWidget,
      );
      expect(
        find.text('No negative feedback against this entry.'),
        findsOneWidget,
      );
    });

    testWidgets('keeps the still poster when a stream cannot be opened', (
      tester,
    ) async {
      // The test platform has no video implementation, so a playable source
      // exercises the same fallback a platform that cannot stream it would.
      await pumpEntryScreen(
        tester,
        api: ScriptedReviewApi(
          entryResult: entryDetail(clipUrl: 'https://clips.example/bank.mp4'),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(ClipPlayer), findsOneWidget);
      expect(find.text('This clip could not be loaded.'), findsOneWidget);
    });
  });

  group('ReviewEntryScreen · submitting', () {
    testWidgets('disables the actions and shows a spinner', (tester) async {
      final api = DelayedReviewApi()..entryCompleter.complete(entryDetail());
      final controller = await pumpEntryScreen(tester, api: api);

      await tester.ensureVisible(find.text('Clear'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Clear'));
      await tester.pump();

      expect(controller.isSubmitting, isTrue);
      final hold = tester.widget<ScenovaButton>(
        find.widgetWithText(ScenovaButton, 'Hold'),
      );
      expect(hold.onPressed, isNull);
    });
  });

  group('ReviewEntryScreen · error', () {
    testWidgets('shows the shared Error State with a retry', (tester) async {
      final api = ScriptedReviewApi(
        entryError: const ReviewApiException(
          503,
          'The review service is unavailable.',
        ),
      );
      final controller = await pumpEntryScreen(tester, api: api);

      expect(find.text('The entry could not be loaded'), findsOneWidget);
      expect(find.text('The review service is unavailable.'), findsOneWidget);

      api.entryError = null;
      await tapVisible(tester, find.text('Try again'));

      expect(controller.status, ReviewEntryStatus.loaded);
      expect(find.text('Decision'), findsOneWidget);
    });

    testWidgets('an offline failure explains the connection', (tester) async {
      await pumpEntryScreen(
        tester,
        api: ScriptedReviewApi(
          entryError: const ReviewApiException(0, 'unreachable'),
        ),
      );

      expect(
        find.textContaining('could not reach the review service'),
        findsOneWidget,
      );
    });

    testWidgets('an entry with nothing queued offers the way back', (
      tester,
    ) async {
      var backs = 0;
      await pumpEntryScreen(
        tester,
        api: ScriptedReviewApi(
          entryError: const ReviewApiException(
            404,
            'This entry is no longer waiting for review.',
          ),
        ),
        onBack: () => backs++,
      );

      expect(
        find.text('This entry is no longer waiting for review'),
        findsOneWidget,
      );
      await tapVisible(tester, find.text('Back to the queue'));
      expect(backs, 1);
    });

    testWidgets('a failed action shows the Error State where the actions are', (
      tester,
    ) async {
      var backs = 0;
      final api = ScriptedReviewApi(
        actionError: const ReviewApiException(
          503,
          'The review service is unavailable.',
        ),
      );
      await pumpEntryScreen(tester, api: api, onBack: () => backs++);

      await tapVisible(tester, find.text('Clear'));

      expect(find.text('The action could not be recorded'), findsOneWidget);
      expect(backs, 0);

      api.actionError = null;
      await tapVisible(tester, find.text('Try again'));

      expect(api.actions, hasLength(2));
      expect(api.actions.last.action, EntryAction.clear);
      expect(backs, 1);
      await settleSnackBar(tester);
    });

    testWidgets('a refused action gives the actions back, not a retry', (
      tester,
    ) async {
      final api = ScriptedReviewApi(
        actionError: const ReviewApiException(400, 'The request was refused.'),
      );
      await pumpEntryScreen(tester, api: api);

      await tapVisible(tester, find.text('Clear'));

      expect(find.text('The action could not be recorded'), findsOneWidget);
      expect(find.text('Try again'), findsNothing);

      await tapVisible(tester, find.text('Dismiss'));

      expect(find.text('Decision'), findsOneWidget);
      expect(find.text('Clear'), findsOneWidget);
    });
  });

  group('ReviewEntryScreen · refused', () {
    testWidgets('refuses access without offering a retry', (tester) async {
      await pumpEntryScreen(
        tester,
        api: ScriptedReviewApi(
          entryError: const ReviewApiException(403, 'The curator role.'),
        ),
      );

      expect(find.text('Access refused'), findsOneWidget);
      expect(find.text('Try again'), findsNothing);
      expect(find.text('Sign out'), findsOneWidget);
    });
  });

  group('ReviewEntryScreen · already moved', () {
    testWidgets('shows the note and its current state, with no actions', (
      tester,
    ) async {
      final api = ScriptedReviewApi();
      final controller = ReviewEntryController(
        api: api,
        entryId: 'entry-bank-2',
        onSessionExpired: () {},
      );
      addTearDown(controller.dispose);
      await controller.load();

      api.actionError = const ReviewApiException(409, 'The entry has moved.');
      api.entryResult = entryDetail(state: ReviewState.actioned);
      await controller.act(EntryAction.clear);

      await pumpController(tester, controller);

      expect(find.text('This entry has already moved'), findsOneWidget);
      expect(
        find.textContaining('Its current state is Actioned'),
        findsOneWidget,
      );
      expect(find.text('Actioned'), findsOneWidget);
      expect(find.text('Decision'), findsNothing);
      expect(find.text('Clear'), findsNothing);
    });
  });

  group('ReviewEntryScreen · actions', () {
    testWidgets('clears the entry, confirms, and returns to the queue', (
      tester,
    ) async {
      var backs = 0;
      final api = ScriptedReviewApi();
      await pumpEntryScreen(tester, api: api, onBack: () => backs++);

      await tapVisible(tester, find.text('Clear'));

      expect(api.actions.single.action, EntryAction.clear);
      expect(backs, 1);
      expect(
        find.text('Cleared. The clip is serving readers again.'),
        findsOneWidget,
      );
      await settleSnackBar(tester);
    });

    testWidgets('confirms a retire, stating its effect, before recording it', (
      tester,
    ) async {
      var backs = 0;
      final api = ScriptedReviewApi();
      await pumpEntryScreen(tester, api: api, onBack: () => backs++);

      await tapVisible(tester, find.text('Retire'));

      expect(find.byType(AlertDialog), findsOneWidget);
      expect(
        find.textContaining('Readers stop seeing this clip'),
        findsOneWidget,
      );

      await tapVisible(
        tester,
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('Retire'),
        ),
      );

      expect(api.actions.single.action, EntryAction.retire);
      expect(backs, 1);
      expect(find.byType(AlertDialog), findsNothing);
      await settleSnackBar(tester);
    });

    testWidgets('a cancelled confirmation records nothing', (tester) async {
      var backs = 0;
      final api = ScriptedReviewApi();
      await pumpEntryScreen(tester, api: api, onBack: () => backs++);

      await tapVisible(tester, find.text('Replace'));
      expect(
        find.textContaining('a new one is generated from a fresh phrase'),
        findsOneWidget,
      );

      await tapVisible(tester, find.text('Cancel'));

      expect(api.actions, isEmpty);
      expect(backs, 0);
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('a failed destructive action stays in the modal to retry', (
      tester,
    ) async {
      var backs = 0;
      final api = ScriptedReviewApi(
        actionError: const ReviewApiException(
          503,
          'The review service is unavailable.',
        ),
      );
      await pumpEntryScreen(tester, api: api, onBack: () => backs++);

      await tapVisible(tester, find.text('Retire'));
      await tapVisible(
        tester,
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('Retire'),
        ),
      );

      expect(find.byType(AlertDialog), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('The review service is unavailable.'),
        ),
        findsOneWidget,
      );
      expect(backs, 0);
    });
  });

  group('ReviewEntryScreen · phrase edit', () {
    testWidgets(
      'refuses a phrase that fails the rubric and leaves it unchanged',
      (tester) async {
        final api = ScriptedReviewApi();
        await pumpEntryScreen(tester, api: api);

        await tester.ensureVisible(find.byType(TextField));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), 'a b c d e f g h');
        await tapVisible(tester, find.text('Regenerate'));

        expect(
          find.text('Keep the phrase to 7 words or fewer.'),
          findsOneWidget,
        );
        expect(api.actions, isEmpty);
        // The entry's stored phrase is untouched.
        expect(find.text('a river bank'), findsWidgets);
      },
    );

    testWidgets('records a sound phrase and stays on the entry', (
      tester,
    ) async {
      var backs = 0;
      final api = ScriptedReviewApi();
      await pumpEntryScreen(tester, api: api, onBack: () => backs++);

      await tester.ensureVisible(find.byType(TextField));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'a place to keep money');
      await tapVisible(tester, find.text('Regenerate'));

      expect(api.actions.single.action, EntryAction.editPhrase);
      expect(api.actions.single.phrase, 'a place to keep money');
      expect(backs, 0);
      expect(find.text('a place to keep money'), findsWidgets);
      expect(
        find.text('Phrase saved. The entry is regenerating from it.'),
        findsOneWidget,
      );
      await settleSnackBar(tester);
    });
  });
}
