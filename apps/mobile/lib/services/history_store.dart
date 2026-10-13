import '../models/history_entry.dart';

/// The device's lookup history.
///
/// History is on the device only and never leaves it
/// (`docs/Scenova/nfr.md` → "Data lifecycle"). This interface is the seam the
/// History feature will replace with durable storage; the in-memory
/// implementation keeps the surface honest until it lands.
abstract interface class HistoryStore {
  /// The most recent lookups, newest first.
  Future<List<HistoryEntry>> recent({int limit = 5});

  /// Every saved lookup, newest first.
  Future<List<HistoryEntry>> all();

  /// Saves a lookup, replacing any earlier entry for the same word and sense.
  Future<void> save(HistoryEntry entry);

  Future<void> remove(String id);

  Future<void> clear();
}

/// An in-memory history, seeded for development and used in tests.
class InMemoryHistoryStore implements HistoryStore {
  InMemoryHistoryStore({List<HistoryEntry> seed = const <HistoryEntry>[]})
    : _entries = List<HistoryEntry>.of(seed);

  final List<HistoryEntry> _entries;

  @override
  Future<List<HistoryEntry>> recent({int limit = 5}) async {
    final ordered = await all();
    return ordered.take(limit).toList(growable: false);
  }

  @override
  Future<List<HistoryEntry>> all() async {
    final ordered = List<HistoryEntry>.of(_entries)
      ..sort((a, b) => b.savedAt.compareTo(a.savedAt));
    return ordered;
  }

  @override
  Future<void> save(HistoryEntry entry) async {
    _entries.removeWhere(
      (existing) =>
          existing.word == entry.word && existing.phrase == entry.phrase,
    );
    _entries.add(entry);
  }

  @override
  Future<void> remove(String id) async {
    _entries.removeWhere((entry) => entry.id == id);
  }

  @override
  Future<void> clear() async {
    _entries.clear();
  }
}
