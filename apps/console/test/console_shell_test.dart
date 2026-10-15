import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scenova_console/widgets/brand_lockup.dart';
import 'package:scenova_console/widgets/console_shell.dart';

import 'support/harness.dart';

void main() {
  group('ConsoleShell', () {
    testWidgets('carries the operator\'s identity and signs out', (
      tester,
    ) async {
      var signedOut = 0;
      await pumpThemed(
        tester,
        ConsoleShell(
          operatorLabel: 'curator@example.com',
          openCount: 3,
          queueSelected: true,
          onOpenQueue: () {},
          onSignOut: () => signedOut++,
          child: const SizedBox.shrink(),
        ),
      );

      expect(find.text('curator@example.com'), findsOneWidget);
      await tester.tap(find.text('Sign out'));
      await tester.pump();
      expect(signedOut, 1);
    });

    testWidgets('shows the open count in the sidebar and selects the queue', (
      tester,
    ) async {
      var openedQueue = 0;
      await pumpThemed(
        tester,
        ConsoleShell(
          operatorLabel: 'curator@example.com',
          openCount: 12,
          queueSelected: false,
          onOpenQueue: () => openedQueue++,
          onSignOut: () {},
          child: const SizedBox.shrink(),
        ),
      );

      expect(find.text('12'), findsOneWidget);
      await tester.tap(find.text('Review queue'));
      await tester.pump();
      expect(openedQueue, 1);
    });

    testWidgets('leads the top bar with the brand lockup', (tester) async {
      await pumpThemed(
        tester,
        ConsoleShell(
          operatorLabel: 'curator@example.com',
          openCount: 1,
          queueSelected: true,
          onOpenQueue: () {},
          onSignOut: () {},
          child: const SizedBox.shrink(),
        ),
      );

      // The lockup sizes the mark to the wordmark's cap height; the shell
      // keeps the product name beside the section label.
      expect(find.byType(BrandLockup), findsOneWidget);
      expect(find.text(BrandLockup.wordmark), findsOneWidget);
      expect(find.text('Review console'), findsOneWidget);
    });

    testWidgets('hides the count until the queue has loaded', (tester) async {
      await pumpThemed(
        tester,
        ConsoleShell(
          operatorLabel: 'curator@example.com',
          openCount: null,
          queueSelected: true,
          onOpenQueue: () {},
          onSignOut: () {},
          child: const SizedBox.shrink(),
        ),
      );

      expect(find.text('0'), findsNothing);
      expect(find.text('Review queue'), findsOneWidget);
    });
  });
}
