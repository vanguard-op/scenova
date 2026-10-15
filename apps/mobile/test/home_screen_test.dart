import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scenova/models/history_entry.dart';
import 'package:scenova/screens/clip_view_screen.dart';
import 'package:scenova/services/capture_intake.dart';
import 'package:scenova/services/history_store.dart';
import 'package:scenova_design/scenova_design.dart';

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

  testWidgets('the app bar draws the brand lockup from the delivered asset', (
    tester,
  ) async {
    await pumpHarness(tester);
    await tester.pump();

    // The app bar carries the lockup, which sizes the mark to the wordmark's
    // cap height; the mark is drawn from the asset rather than a hand-drawn
    // stand-in.
    expect(find.byType(BrandLockup), findsOneWidget);
    final mark = find.byType(BrandMark);
    expect(mark, findsOneWidget);
    final svg = tester.widget<SvgPicture>(
      find.descendant(of: mark, matching: find.byType(SvgPicture)),
    );
    expect(svg.bytesLoader.toString(), contains(BrandMark.assetPath));
    expect(find.text('Scenova'), findsOneWidget);
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

  testWidgets('a selection over six words asks the reader to narrow it', (
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

    // The reader is asked in place, with their selection left untouched, and
    // no lookup is opened.
    expect(find.text(CaptureSelection.overLimitNotice), findsOneWidget);
    expect(find.byType(ClipViewScreen), findsNothing);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'the quick brown fox jumps over the lazy dog',
    );
    await teardown(tester);
  });
}
