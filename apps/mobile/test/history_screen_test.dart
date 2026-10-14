import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scenova/models/history_entry.dart';
import 'package:scenova/screens/clip_view_screen.dart';
import 'package:scenova/services/feature_flags.dart';
import 'package:scenova/services/history_store.dart';
import 'package:scenova/services/lookup_api.dart';
import 'package:scenova/widgets/app_icons.dart';
import 'package:scenova/widgets/offline_banner.dart';
import 'package:scenova/widgets/skeleton.dart';
import 'package:scenova/widgets/states.dart';

import 'support/harness.dart';

void main() {
  testWidgets('History shows a skeleton list while the device loads', (
    tester,
  ) async {
    final history = DelayedHistoryStore();
    await pumpHistory(tester, history: history);
    await tester.pump();

    expect(find.byType(SkeletonList), findsOneWidget);

    history.completer.complete(<HistoryEntry>[]);
    await tester.pump();
    await teardown(tester);
  });

  testWidgets('History lists saved lookups newest first', (tester) async {
    await pumpHistory(
      tester,
      history: InMemoryHistoryStore(
        seed: <HistoryEntry>[
          seededEntry(
            word: 'come',
            phrase: 'to move towards someone',
            age: const Duration(minutes: 1),
          ),
          seededEntry(
            word: 'bank',
            phrase: 'a place that keeps money safe',
            age: const Duration(hours: 2),
          ),
        ],
      ),
    );
    await tester.pump();

    expect(find.text('come'), findsOneWidget);
    expect(find.text('to move towards someone'), findsOneWidget);
    // The newest lookup sits above the older one.
    expect(
      tester.getTopLeft(find.text('come')).dy,
      lessThan(tester.getTopLeft(find.text('bank')).dy),
    );
    await teardown(tester);
  });

  testWidgets('History shows the empty state with no saved lookups', (
    tester,
  ) async {
    await pumpHistory(tester);
    await tester.pump();

    expect(find.byType(EmptyState), findsOneWidget);
    expect(find.text('No saved lookups yet'), findsOneWidget);
    await teardown(tester);
  });

  testWidgets('History shows the offline banner and still lists history', (
    tester,
  ) async {
    await pumpHistory(
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

  testWidgets('History offers a retry when the device fails to read', (
    tester,
  ) async {
    await pumpHistory(tester, history: const ThrowingHistoryStore());
    await tester.pump();

    expect(find.byType(ErrorState), findsOneWidget);
    expect(find.text('Your history did not load'), findsOneWidget);
    await teardown(tester);
  });

  testWidgets('a long word truncates to two lines', (tester) async {
    const long = 'antidisestablishmentarianismcontinuingonandonandon';
    await pumpHistory(
      tester,
      history: InMemoryHistoryStore(
        seed: <HistoryEntry>[seededEntry(word: long, phrase: 'a long word')],
      ),
    );
    await tester.pump();

    final word = tester.widget<Text>(find.text(long));
    expect(word.maxLines, 2);
    expect(word.overflow, TextOverflow.ellipsis);
    await teardown(tester);
  });

  testWidgets('the search field narrows the list', (tester) async {
    await pumpHistory(
      tester,
      history: InMemoryHistoryStore(
        seed: <HistoryEntry>[
          seededEntry(word: 'come', phrase: 'to arrive'),
          seededEntry(word: 'bank', phrase: 'a place for money'),
        ],
      ),
    );
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'bank');
    await tester.pump();

    expect(find.text('a place for money'), findsOneWidget);
    expect(find.text('come'), findsNothing);
    await teardown(tester);
  });

  testWidgets('a search with no matches says so', (tester) async {
    await pumpHistory(
      tester,
      history: InMemoryHistoryStore(
        seed: <HistoryEntry>[seededEntry(word: 'come', phrase: 'to arrive')],
      ),
    );
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'zzz');
    await tester.pump();

    expect(find.text('No matches'), findsOneWidget);
    await teardown(tester);
  });

  testWidgets('removing an entry asks first, then shows the row deleting', (
    tester,
  ) async {
    final store = _DelayedRemoveHistoryStore(
      seed: <HistoryEntry>[
        seededEntry(word: 'come', phrase: 'to arrive'),
        seededEntry(word: 'bank', phrase: 'a place for money'),
      ],
    );
    await pumpHistory(tester, history: store);
    await tester.pump();

    await tester.tap(find.byTooltip('Remove come'));
    await tester.pumpAndSettle();
    expect(find.text('Remove this lookup?'), findsOneWidget);

    await tester.tap(find.text('Remove'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // The row shows a spinner while its clip is deleted from the device.
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    store.removed.complete();
    await tester.pump();

    expect(find.text('come'), findsNothing);
    expect(find.text('bank'), findsOneWidget);
    await teardown(tester);
  });

  testWidgets('keeping a lookup leaves it in the list', (tester) async {
    final store = InMemoryHistoryStore(
      seed: <HistoryEntry>[seededEntry(word: 'come', phrase: 'to arrive')],
    );
    await pumpHistory(tester, history: store);
    await tester.pump();

    await tester.tap(find.byTooltip('Remove come'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Keep'));
    await tester.pumpAndSettle();

    expect(find.text('come'), findsOneWidget);
    expect(await store.all(), hasLength(1));
    await teardown(tester);
  });

  testWidgets('the device full warning offers to clear history', (
    tester,
  ) async {
    final store = InMemoryHistoryStore(
      seed: <HistoryEntry>[seededEntry(word: 'come', phrase: 'to arrive')],
      storageFull: true,
    );
    await pumpHistory(tester, history: store);
    await tester.pump();

    expect(
      find.text('This device is out of room for saved lookups.'),
      findsOneWidget,
    );

    await tester.tap(find.text('Clear history'));
    await tester.pumpAndSettle();
    expect(find.text('Clear all history?'), findsOneWidget);

    await tester.tap(find.text('Clear'));
    await tester.pumpAndSettle();

    expect(find.byType(EmptyState), findsOneWidget);
    expect(await store.all(), isEmpty);
    await teardown(tester);
  });

  testWidgets('opening a saved lookup replays it from the device', (
    tester,
  ) async {
    final api = RecordingLookupApi(MockLookupApi());
    await pumpHistory(
      tester,
      api: api,
      history: InMemoryHistoryStore(
        seed: <HistoryEntry>[
          seededEntry(
            word: 'come',
            phrase: 'to move towards someone',
            clipUrl: 'https://clips.example/come.mp4',
          ),
        ],
      ),
    );
    await tester.pump();

    await tester.tap(find.text('come'));
    await tester.pumpAndSettle();

    expect(find.byType(ClipViewScreen), findsOneWidget);
    // The saved lookup plays from the device, so no lookup reaches the service.
    expect(api.createCalls, 0);
    await teardown(tester);
  });

  testWidgets('a saved lookup replays with no connection', (tester) async {
    await pumpHistory(
      tester,
      online: false,
      history: InMemoryHistoryStore(
        seed: <HistoryEntry>[
          seededEntry(
            word: 'come',
            phrase: 'to move towards someone',
            clipUrl: 'https://clips.example/come.mp4',
          ),
        ],
      ),
    );
    await tester.pump();

    await tester.tap(find.text('come'));
    await tester.pump();
    // The route settles; the fallback progress has not run to completion, so
    // the clip still reads as playing.
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(ClipViewScreen), findsOneWidget);
    // The saved clip plays rather than the offline "not on this device" state.
    expect(find.text('This word is not saved on this device'), findsNothing);
    expect(findIcon(AppIcons.pause), findsWidgets);
    await teardown(tester);
  });

  testWidgets('with offline replay off a saved lookup cannot replay offline', (
    tester,
  ) async {
    // The kill switch (`enable_offline_history`) disables offline replay; the
    // on-device history stays, so the list is unchanged and the word and phrase
    // still show, but the clip waits for a connection.
    await pumpHistory(
      tester,
      online: false,
      history: InMemoryHistoryStore(
        seed: <HistoryEntry>[
          seededEntry(
            word: 'come',
            phrase: 'to move towards someone',
            clipUrl: 'https://clips.example/come.mp4',
          ),
        ],
      ),
      featureFlags: const FixedFeatureFlags(offlineHistoryEnabled: false),
    );
    await tester.pump();

    // The saved lookup is still listed and the reader is told offline replay is
    // paused.
    expect(find.text('come'), findsOneWidget);
    expect(
      find.text('You are offline. Saved clips need a connection to play.'),
      findsOneWidget,
    );

    await tester.tap(find.text('come'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(ClipViewScreen), findsOneWidget);
    expect(find.text('to move towards someone'), findsWidgets);
    expect(find.text('Saved clips need a connection to play.'), findsOneWidget);
    expect(findIcon(AppIcons.pause), findsNothing);
    await teardown(tester);
  });
}

/// A history whose removal is held open, so the deleting state is visible.
class _DelayedRemoveHistoryStore extends InMemoryHistoryStore {
  _DelayedRemoveHistoryStore({super.seed});

  final Completer<void> removed = Completer<void>();

  @override
  Future<void> remove(String id) async {
    await removed.future;
    await super.remove(id);
  }
}
