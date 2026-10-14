import 'package:flutter_test/flutter_test.dart';
import 'package:scenova_console/models/review_queue.dart';
import 'package:scenova_console/screens/review_queue_screen.dart';
import 'package:scenova_console/screens/sign_in_screen.dart';
import 'package:scenova_console/services/operator_auth.dart';
import 'package:scenova_console/services/review_api.dart';
import 'package:scenova_console/widgets/console_shell.dart';

import 'support/harness.dart';

void main() {
  group('ConsoleGate', () {
    testWidgets('shows the identity provider until there is a session', (
      tester,
    ) async {
      final auth = FakeOperatorAuth();
      addTearDown(auth.dispose);
      await pumpConsole(
        tester,
        auth: auth,
        reviewApi: ScriptedReviewApi(result: emptyPage),
      );

      expect(find.byType(SignInScreen), findsOneWidget);
      expect(find.byType(ConsoleShell), findsNothing);
    });

    testWidgets('shows the shell and the queue once signed in', (tester) async {
      final auth = FakeOperatorAuth(
        session: const OperatorSession(
          subject: 'operator',
          email: 'curator@example.com',
        ),
      );
      addTearDown(auth.dispose);
      await pumpConsole(
        tester,
        auth: auth,
        reviewApi: ScriptedReviewApi(
          result: pageOf(<QueueItem>[queueItem(lemma: 'bank')], openCount: 2),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(ConsoleShell), findsOneWidget);
      expect(find.byType(ReviewQueueScreen), findsOneWidget);
      expect(find.text('curator@example.com'), findsOneWidget);
      expect(find.text('bank'), findsOneWidget);
      expect(find.text('2'), findsWidgets);
    });

    testWidgets(
      'returns to sign-in when a session ends while the queue is open',
      (tester) async {
        final auth = FakeOperatorAuth(
          session: const OperatorSession(
            subject: 'operator',
            email: 'curator@example.com',
          ),
        );
        addTearDown(auth.dispose);
        await pumpConsole(
          tester,
          auth: auth,
          reviewApi: ScriptedReviewApi(
            error: const ReviewApiException(
              401,
              'The operator session is missing.',
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(auth.signOuts, 1);
        expect(find.byType(SignInScreen), findsOneWidget);
        expect(find.byType(ConsoleShell), findsNothing);
      },
    );

    testWidgets('signing out returns to sign-in', (tester) async {
      final auth = FakeOperatorAuth(
        session: const OperatorSession(
          subject: 'operator',
          email: 'curator@example.com',
        ),
      );
      addTearDown(auth.dispose);
      await pumpConsole(
        tester,
        auth: auth,
        reviewApi: ScriptedReviewApi(result: emptyPage),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Sign out'));
      await tester.pumpAndSettle();

      expect(find.byType(SignInScreen), findsOneWidget);
    });

    testWidgets('opens an entry from the queue and returns', (tester) async {
      final auth = FakeOperatorAuth(
        session: const OperatorSession(
          subject: 'operator',
          email: 'curator@example.com',
        ),
      );
      addTearDown(auth.dispose);
      await pumpConsole(
        tester,
        auth: auth,
        reviewApi: ScriptedReviewApi(
          result: pageOf(<QueueItem>[queueItem(lemma: 'bank')]),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('bank'));
      await tester.pumpAndSettle();

      expect(find.text('Sense 2'), findsOneWidget);
      expect(find.text('Back to the queue'), findsOneWidget);

      await tester.tap(find.text('Back to the queue'));
      await tester.pumpAndSettle();

      expect(find.byType(ReviewQueueScreen), findsOneWidget);
    });
  });
}
