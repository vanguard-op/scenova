import 'package:flutter_test/flutter_test.dart';
import 'package:scenova/models/history_entry.dart';
import 'package:scenova/models/lookup.dart';
import 'package:scenova/services/history_store.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';

void main() {
  setUp(() {
    // The real store talks to the platform channel; the in-memory platform
    // stands in so the stored shape is exercised without a device.
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  test('a saved lookup survives a relaunch', () async {
    await SharedPreferencesHistoryStore().save(
      _entry(word: 'come', phrase: 'to move towards someone'),
    );

    // A second store reads the same device document, as the next launch does.
    final relaunched = await SharedPreferencesHistoryStore().all();

    expect(relaunched, hasLength(1));
    expect(relaunched.single.word, 'come');
    expect(relaunched.single.phrase, 'to move towards someone');
    expect(relaunched.single.kind, LookupKind.word);
    expect(relaunched.single.clipUrl, 'https://clips.example/come.mp4');
    expect(relaunched.single.clipLocalKey, 'clip-come');
    expect(relaunched.single.posterLocalKey, 'poster-come');
    expect(relaunched.single.hasAudio, isTrue);
  });

  test('history reads newest first', () async {
    final store = SharedPreferencesHistoryStore();
    await store.save(
      _entry(word: 'old', phrase: 'a', age: const Duration(days: 2)),
    );
    await store.save(_entry(word: 'new', phrase: 'b', age: Duration.zero));

    final ordered = await store.all();

    expect(ordered.map((entry) => entry.word), <String>['new', 'old']);
    expect((await store.recent(limit: 1)).single.word, 'new');
  });

  test('saving the same word and phrase replaces the earlier entry', () async {
    final store = SharedPreferencesHistoryStore();
    await store.save(_entry(word: 'bank', phrase: 'a place for money'));
    await store.save(_entry(word: 'bank', phrase: 'a place for money'));

    expect(await store.all(), hasLength(1));
  });

  test('the device keeps only the most recent lookups', () async {
    final store = SharedPreferencesHistoryStore(capacity: 3);
    for (var i = 0; i < 5; i++) {
      await store.save(
        _entry(
          word: 'word$i',
          phrase: 'meaning $i',
          age: Duration(minutes: 5 - i),
        ),
      );
    }

    final kept = await store.all();

    // The four oldest dropped off; the newest three are kept, newest first.
    expect(kept.map((entry) => entry.word), <String>[
      'word4',
      'word3',
      'word2',
    ]);
  });

  test('the store keeps only what the reader\'s plan allows', () async {
    // A Pro reader's plan carries no cap, so nothing drops off; a Free reader's
    // plan caps the device history (`FEAT-009`, `FEAT-013`).
    final store = SharedPreferencesHistoryStore(capacity: 3);
    store.planLimit = () async => null;
    for (var i = 0; i < 5; i++) {
      await store.save(
        _entry(
          word: 'word$i',
          phrase: 'meaning $i',
          age: Duration(minutes: 5 - i),
        ),
      );
    }

    expect(await store.all(), hasLength(5));

    store.planLimit = () async => 3;
    await store.save(_entry(word: 'sixth', phrase: 'c', age: Duration.zero));

    expect(await store.all(), hasLength(3));
  });

  test('removing an entry deletes it from the device', () async {
    final store = SharedPreferencesHistoryStore();
    await store.save(_entry(word: 'keep', phrase: 'a'));
    await store.save(_entry(word: 'drop', phrase: 'b'));

    await store.remove('seed-drop');

    expect((await store.all()).map((entry) => entry.word), <String>['keep']);
  });

  test('clearing history removes every entry', () async {
    final store = SharedPreferencesHistoryStore();
    await store.save(_entry(word: 'one', phrase: 'a'));
    await store.save(_entry(word: 'two', phrase: 'b'));

    await store.clear();

    expect(await store.all(), isEmpty);
  });

  test(
    'a write the device refuses is reported as full, and recovers',
    () async {
      final platform = _SwitchablePreferences()..writable = false;
      SharedPreferencesAsyncPlatform.instance = platform;
      final store = SharedPreferencesHistoryStore();

      await store.save(_entry(word: 'come', phrase: 'to arrive'));
      expect(await store.storageState(), HistoryStorageState.full);
      expect(await store.all(), isEmpty);

      platform.writable = true;
      await store.save(_entry(word: 'come', phrase: 'to arrive'));

      expect(await store.storageState(), HistoryStorageState.ok);
      expect(await store.all(), hasLength(1));
    },
  );

  test('an unreadable document reads empty rather than throwing', () async {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.withData(<String, Object>{
          'history.entries': 'not json',
        });

    expect(await SharedPreferencesHistoryStore().all(), isEmpty);
  });
}

/// A saved lookup for a test, aged so the order is deterministic.
HistoryEntry _entry({
  required String word,
  required String phrase,
  Duration age = const Duration(minutes: 1),
}) {
  return HistoryEntry(
    id: 'seed-$word',
    word: word,
    phrase: phrase,
    kind: LookupKind.word,
    savedAt: DateTime.now().subtract(age),
    clipUrl: 'https://clips.example/$word.mp4',
    clipLocalKey: 'clip-$word',
    posterLocalKey: 'poster-$word',
    hasAudio: true,
  );
}

/// An in-memory platform whose writes can be refused, so the store's full state
/// is exercised without a device.
final class _SwitchablePreferences extends InMemorySharedPreferencesAsync {
  _SwitchablePreferences() : super.empty();

  bool writable = true;

  @override
  Future<bool> setString(
    String key,
    String value,
    SharedPreferencesOptions options,
  ) async {
    if (!writable) throw StateError('the device is full');
    return super.setString(key, value, options);
  }
}
