import 'package:flutter_test/flutter_test.dart';
import 'package:scenova/dev/development_history.dart';
import 'package:scenova/services/history_store.dart';

void main() {
  group('development sample history', () {
    test('offers the loaded state the development surfaces need', () {
      final entries = sampleHistory();
      expect(entries, isNotEmpty);
      expect(
        entries.map((entry) => entry.word),
        containsAll(<String>['come', 'bank']),
      );
    });

    test('names no clip source that cannot play', () {
      // The samples stand in for the reader's own lookups, and a device that
      // opened one must not be handed a source it can never load; with no
      // source the shared still frame shows instead (FEAT-009).
      for (final entry in sampleHistory()) {
        expect(entry.clipUrl, isNull);
        expect(entry.hasClip, isFalse);
      }
    });
  });

  group('the launch history store', () {
    test(
      'a seeded run holds the samples in memory, never the device store',
      () async {
        final deviceStore = InMemoryHistoryStore();

        final store = launchHistoryStore(seed: true, deviceStore: deviceStore);

        // The reader's own store is the reader's alone, so the samples never
        // reach it, and they do not outlive the run (FEAT-009).
        expect(store, isNot(same(deviceStore)));
        expect(store, isA<InMemoryHistoryStore>());
        expect(
          (await store.all()).map((entry) => entry.word),
          containsAll(<String>['come', 'bank']),
        );
      },
    );

    test('a run that does not seed reads the reader\'s own store', () {
      final deviceStore = InMemoryHistoryStore();

      expect(
        launchHistoryStore(seed: false, deviceStore: deviceStore),
        same(deviceStore),
      );
    });
  });
}
