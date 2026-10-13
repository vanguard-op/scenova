import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scenova/models/history_entry.dart';
import 'package:scenova/screens/clip_view_screen.dart';
import 'package:scenova/services/capture_intake.dart';
import 'package:scenova/services/history_store.dart';
import 'package:scenova/widgets/offline_banner.dart';
import 'package:scenova/widgets/skeleton.dart';
import 'package:scenova/widgets/states.dart';

import 'support/harness.dart';

void main() {
  testWidgets('Home shows a skeleton list while history loads', (tester) async {
    final history = DelayedHistoryStore();
    await pumpHarness(tester, history: history);
    await tester.pump();

    expect(find.byType(SkeletonList), findsOneWidget);

    history.completer.complete(<HistoryEntry>[]);
    await tester.pump();
    await teardown(tester);
  });

  testWidgets('Home lists recent lookups when history is loaded', (
    tester,
  ) async {
    await pumpHarness(
      tester,
      history: InMemoryHistoryStore(
        seed: <HistoryEntry>[
          seededEntry(word: 'come', phrase: 'to move towards someone'),
          seededEntry(word: 'bank', phrase: 'a place that keeps money safe'),
        ],
      ),
    );
    await tester.pump();

    expect(find.text('Recent'), findsOneWidget);
    expect(find.text('come'), findsOneWidget);
    expect(find.text('a place that keeps money safe'), findsOneWidget);
    await teardown(tester);
  });

  testWidgets('Home explains how to look up a word when history is empty', (
    tester,
  ) async {
    await pumpHarness(tester);
    await tester.pump();

    expect(find.byType(EmptyState), findsOneWidget);
    expect(find.text('Look up a word while you read'), findsOneWidget);
    await teardown(tester);
  });

  testWidgets('Home shows the offline banner and still lists history', (
    tester,
  ) async {
    await pumpHarness(
      tester,
      online: false,
      history: InMemoryHistoryStore(
        seed: <HistoryEntry>[seededEntry(word: 'come', phrase: 'to arrive')],
      ),
    );
    await tester.pump();

    expect(find.byType(OfflineBanner), findsOneWidget);
    expect(find.text('come'), findsOneWidget);
    await teardown(tester);
  });

  testWidgets('Home offers a retry when history fails to load', (tester) async {
    await pumpHarness(tester, history: const ThrowingHistoryStore());
    await tester.pump();

    expect(find.byType(ErrorState), findsOneWidget);
    expect(find.text('Your recent lookups did not load'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
    await teardown(tester);
  });

  testWidgets('an empty entry starts no lookup', (tester) async {
    await pumpHarness(tester);
    await tester.pump();

    await tester.enterText(find.byType(TextField), '   ');
    await tester.tap(find.text('Look up'));
    await tester.pump();

    expect(find.text('Type or paste a word to look up.'), findsOneWidget);
    expect(find.byType(ClipViewScreen), findsNothing);
    await teardown(tester);
  });

  testWidgets('an entry opens the clip view for the typed word', (
    tester,
  ) async {
    await pumpHarness(tester);
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'coming,');
    await tester.tap(find.text('Look up'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(ClipViewScreen), findsOneWidget);
    // The trailing comma was trimmed before the lookup.
    expect(find.text('coming'), findsWidgets);
    await teardown(tester);
  });

  testWidgets('a selection over six words is kept within the limit', (
    tester,
  ) async {
    await pumpHarness(tester);
    await tester.pump();

    await tester.enterText(
      find.byType(TextField),
      'the quick brown fox jumps over the lazy dog',
    );
    await tester.tap(find.text('Look up'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text(CaptureSelection.overLimitNotice), findsWidgets);
    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.text('the quick brown fox jumps over'), findsWidgets);
    await teardown(tester);
  });
}
